#!/usr/bin/env bash
set -euo pipefail

# Copyright 2022 ThinkParQ GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

###############################################################################
# Synopsis:                                                                   #
# Entrypoint script for S3 container (Versity S3 GW) with BeeGFS backend      #
# Forked and expanded from https://github.com/ThinkParQ/beegfs-containers     #
# Author: @scaleoutSean (Github)                                              #
# Repository: https://github.com/scaleoutsean/eseries-opea-storage-stack      #
# License: the Apache License Version 2.0                                     #
###############################################################################

echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Starting BeeGFS S3 Gateway setup..."

# Create BeeGFS client configuration
echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Creating BeeGFS client configuration..."

# Get the IP address of the configured interface
INTERFACE=${INTERFACES:-br0}
BR0_IP=$(ip addr show $INTERFACE | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1 2>/dev/null || echo "127.0.0.1")
echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Using interface $INTERFACE with IP: $BR0_IP"

cat > /etc/beegfs/beegfs-client.conf << EOF
# BeeGFS Client Configuration
sysMgmtdHost = $BR0_IP
connMgmtdPort = 8008

# Client settings
connMaxInternodeNum = 10
connInterfacesList = $INTERFACE
connNetFilterList = 
connClientPortUDP = 8004

# Logging
logLevel = 4
logType = logfile
logClientID = true

# Disable authentication for testing
connDisableAuthentication = true
EOF

echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: BeeGFS client config created"

# Wait for BeeGFS management service to be available
echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Waiting for BeeGFS management service..."
timeout=60
count=0
while [ $count -lt $timeout ]; do
    if nc -z localhost 8008; then
        echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: BeeGFS management service is reachable"
        break
    fi
    echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: BeeGFS management service not ready, waiting 5 seconds..."
    sleep 5
    count=$((count + 5))
done

# Load BeeGFS kernel module manually (improved error handling)
echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Loading BeeGFS kernel module..."
KERNEL_VERSION=$(uname -r)
BEEGFS_MODULE="/lib/modules/${KERNEL_VERSION}/updates/fs/beegfs_autobuild/beegfs.ko"

# Check if module is already loaded
if lsmod | grep -q beegfs || cat /proc/modules | grep -q beegfs; then
    echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: BeeGFS module already loaded"
elif [ -f "$BEEGFS_MODULE" ]; then
    echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Loading BeeGFS module from $BEEGFS_MODULE"
    if insmod "$BEEGFS_MODULE" 2>/dev/null; then
        echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: BeeGFS module loaded successfully"
    else
        # Check if it failed because module was already loaded or is in use
        if lsmod | grep -q beegfs || cat /proc/modules | grep -q beegfs; then
            echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: BeeGFS module already loaded (detected after insmod attempt)"
        else
            echo "$(date --rfc-3339=ns) WARN [entrypoint.sh]: Failed to load BeeGFS module - insmod error"
            # Don't exit, continue anyway since host networking shares kernel modules
            echo "$(date --rfc-3339=ns) WARN [entrypoint.sh]: Continuing anyway with host networking..."
        fi
    fi
else
    echo "$(date --rfc-3339=ns) ERROR [entrypoint.sh]: BeeGFS module not found at $BEEGFS_MODULE"
    # Don't exit, continue anyway since host networking shares kernel modules
    echo "$(date --rfc-3339=ns) WARN [entrypoint.sh]: Continuing anyway with host networking..."
    exit 1
fi

# Create BeeGFS mounts configuration file
echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Creating BeeGFS mounts configuration..."
mkdir -p /mnt/beegfs
echo "/mnt/beegfs /etc/beegfs/beegfs-client.conf" > /etc/beegfs/beegfs-mounts.conf

# Create BeeGFS autobuild configuration if it doesn't exist
if [ ! -f /etc/beegfs/beegfs-client-autobuild.conf ]; then
    echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Creating BeeGFS client autobuild configuration..."
    cat > /etc/beegfs/beegfs-client-autobuild.conf << 'EOF'
# This file contains make options for the automatic building of BeeGFS client
# modules on first start. (Optional - this file can be empty.)

# Example: BEEGFS_OPENTK_IBVERBS=1
EOF
fi

# Start BeeGFS client service (v8 approach)
echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Starting BeeGFS client service..."
# Create the mount point and start client using systemd-style approach for v8
echo "/mnt/beegfs /etc/beegfs/beegfs-client.conf" > /etc/beegfs/beegfs-mounts.conf
# Mount BeeGFS directly for v8
echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Mounting BeeGFS..."
mount -t beegfs beegfs#nodev /mnt/beegfs -o cfgFile=/etc/beegfs/beegfs-client.conf

# Wait for BeeGFS to be mounted
timeout=30
count=0
while [ $count -lt $timeout ]; do
    if mountpoint -q /mnt/beegfs; then
        echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: BeeGFS mounted successfully"
        break
    fi
    echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Waiting for BeeGFS mount..."
    sleep 2
    count=$((count + 2))
done

# Verify BeeGFS mount
if mountpoint -q /mnt/beegfs; then
    echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: BeeGFS mounted successfully at /mnt/beegfs"
    ls -la /mnt/beegfs
else
    echo "$(date --rfc-3339=ns) WARN [entrypoint.sh]: BeeGFS not mounted - continuing to debug mode"
fi

# S3 Gateway Configuration
echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Configuring S3 Gateway..."

# Provide sensible defaults so the container can run without extra envs.
ROOT_ACCESS_KEY_ID=${ROOT_ACCESS_KEY_ID:-beegfs_s3_admin}
ROOT_SECRET_ACCESS_KEY=${ROOT_SECRET_ACCESS_KEY:-beegfs_s3_admin_secret}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-${ROOT_ACCESS_KEY_ID}}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-${ROOT_SECRET_ACCESS_KEY}}
VGW_CERT=${VGW_CERT:-/certs/s3.crt}
VGW_KEY=${VGW_KEY:-/certs/s3.key}
VGW_PORT=${VGW_PORT:-7070}
VGW_IP=${VGW_IP:-0.0.0.0}
VGW_DATA=${VGW_DATA:-/mnt/beegfs}
VGW_META_SIDECAR=${VGW_META_SIDECAR:-/metadata}

# Configure AWS CLI for local S3 endpoint
echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Configuring AWS CLI for local S3 endpoint..."
mkdir -p ~/.aws
cat > ~/.aws/config << EOF
[default]
region = us-east-1
output = json
s3 =
    endpoint_url = http://127.0.0.1:${VGW_PORT}
    signature_version = s3v4
EOF

cat > ~/.aws/credentials << EOF
[default]
aws_access_key_id = ${ROOT_ACCESS_KEY_ID}
aws_secret_access_key = ${ROOT_SECRET_ACCESS_KEY}
EOF

echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: AWS CLI configured for local S3 endpoint at 127.0.0.1:${VGW_PORT}"

echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Starting versitygw with: access=${ROOT_ACCESS_KEY_ID} cert=${VGW_CERT} key=${VGW_KEY} addr=${VGW_IP}:${VGW_PORT} data=${VGW_DATA}"

# Configure AWS CLI for local S3 testing
echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Configuring AWS CLI for local S3 API testing..."
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}

# Configure AWS CLI to use local S3 endpoint
aws configure set aws_access_key_id "${AWS_ACCESS_KEY_ID}" --profile default
aws configure set aws_secret_access_key "${AWS_SECRET_ACCESS_KEY}" --profile default
aws configure set region "${AWS_DEFAULT_REGION}" --profile default
aws configure set output json --profile default

echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: AWS CLI configured. Use 'aws --endpoint-url=http://localhost:${VGW_PORT} s3 ...' for local testing"

# If VGW_CHOWN_UID/GID are provided as numeric values, chown the data dir
# and then unset them so the versitygw binary doesn't try to parse them as
# boolean flags from the environment.
is_numeric() { printf '%s' "$1" | grep -qE '^[0-9]+$'; }

if [ -n "${VGW_CHOWN_UID:-}" ] && [ -n "${VGW_CHOWN_GID:-}" ]; then
	if is_numeric "$VGW_CHOWN_UID" && is_numeric "$VGW_CHOWN_GID"; then
		echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Setting ownership of ${VGW_DATA} to ${VGW_CHOWN_UID}:${VGW_CHOWN_GID}"
		if chown -R "${VGW_CHOWN_UID}:${VGW_CHOWN_GID}" "${VGW_DATA}"; then
			echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Ownership change successful"
		else
			echo "$(date --rfc-3339=ns) WARN [entrypoint.sh]: Failed to change ownership - continuing anyway"
		fi
		
		# Also set ownership of metadata sidecar directory if it exists
		if [ -n "${VGW_META_SIDECAR:-}" ] && [ -d "${VGW_META_SIDECAR}" ]; then
			echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Setting ownership of metadata sidecar ${VGW_META_SIDECAR} to ${VGW_CHOWN_UID}:${VGW_CHOWN_GID}"
			chown -R "${VGW_CHOWN_UID}:${VGW_CHOWN_GID}" "${VGW_META_SIDECAR}" || true
		fi
		
		# Unset these variables so versitygw doesn't try to parse them as boolean flags
		unset VGW_CHOWN_UID VGW_CHOWN_GID
	else
		# leave boolean-like values alone so versitygw can read them
		echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: VGW_CHOWN_UID/GID are not numeric, leaving for versitygw to handle"
	fi
fi

# Check if debug logging is enabled
if [ "${DEBUG:-false}" = "true" ]; then
	DEBUG_FLAG="--debug"
else
	DEBUG_FLAG=""
fi

echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: S3 Gateway ready - BeeGFS available via S3 API at ${VGW_IP}:${VGW_PORT}"

# Check if debug mode is enabled
if [ "${DEBUG:-false}" = "true" ]; then
    echo "$(date --rfc-3339=ns) DEBUG [entrypoint.sh]: Debug mode enabled - container will stay alive for manual setup"
    echo "$(date --rfc-3339=ns) DEBUG [entrypoint.sh]: To start S3 gateway manually:"
    echo "  env -u VGW_CHOWN_UID -u VGW_CHOWN_GID VGW_META_SIDECAR=/metadata versitygw --access \"$ROOT_ACCESS_KEY_ID\" --secret \"$ROOT_SECRET_ACCESS_KEY\" --port \"${VGW_IP}:${VGW_PORT}\" posix \"$VGW_DATA\""
    echo "$(date --rfc-3339=ns) DEBUG [entrypoint.sh]: To test S3 API with AWS CLI:"
    echo "  aws --endpoint-url=http://localhost:${VGW_PORT} s3 ls"
    echo "  aws --endpoint-url=http://localhost:${VGW_PORT} s3 mb s3://testbucket"
    echo "  aws --endpoint-url=http://localhost:${VGW_PORT} s3 cp /etc/hostname s3://testbucket/"
    echo "  aws --endpoint-url=http://localhost:${VGW_PORT} s3 ls s3://testbucket/"
    echo "$(date --rfc-3339=ns) DEBUG [entrypoint.sh]: To mount BeeGFS manually:"
    echo "  mount -t beegfs beegfs#nodev /mnt/beegfs -o cfgFile=/etc/beegfs/beegfs-client.conf"
    while true; do
        echo "$(date --rfc-3339=ns) DEBUG [entrypoint.sh]: Container alive and ready for debugging..."
        sleep 30
    done
else
    # Unset problematic VGW_CHOWN variables and set metadata sidecar
    unset VGW_CHOWN_UID VGW_CHOWN_GID
    export VGW_META_SIDECAR="${VGW_META_SIDECAR}"
    echo "$(date --rfc-3339=ns) INFO [entrypoint.sh]: Starting versitygw with metadata sidecar at ${VGW_META_SIDECAR}"
    exec versitygw --access "$ROOT_ACCESS_KEY_ID" --secret "$ROOT_SECRET_ACCESS_KEY" \
        --port "${VGW_IP}:${VGW_PORT}" $DEBUG_FLAG posix "$VGW_DATA"
fi