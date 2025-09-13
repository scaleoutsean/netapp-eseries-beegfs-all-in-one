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

echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Starting BeeGFS Combined NFS+S3 Gateway setup..."

# Create BeeGFS client configuration
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Creating BeeGFS client configuration..."

# Get the IP address of the configured interface
INTERFACE=${INTERFACES:-br0}
BR0_IP=$(ip addr show $INTERFACE | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1 2>/dev/null || echo "127.0.0.1")
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Using interface $INTERFACE with IP: $BR0_IP"

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

echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: BeeGFS client config created"

# Wait for BeeGFS management service to be available
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Waiting for BeeGFS management service..."
timeout=60
count=0
while [ $count -lt $timeout ]; do
    if nc -z localhost 8008; then
        echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: BeeGFS management service is reachable"
        break
    fi
    echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: BeeGFS management service not ready, waiting 5 seconds..."
    sleep 5
    count=$((count + 5))
done

# Load BeeGFS kernel module manually (improved error handling)
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Loading BeeGFS kernel module..."
KERNEL_VERSION=$(uname -r)
BEEGFS_MODULE="/lib/modules/${KERNEL_VERSION}/updates/fs/beegfs_autobuild/beegfs.ko"

# Check if module is already loaded
if lsmod | grep -q beegfs || cat /proc/modules | grep -q beegfs; then
    echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: BeeGFS module already loaded"
elif [ -f "$BEEGFS_MODULE" ]; then
    echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Loading BeeGFS module from $BEEGFS_MODULE"
    if insmod "$BEEGFS_MODULE" 2>/dev/null; then
        echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: BeeGFS module loaded successfully"
    else
        # Check if it failed because module was already loaded or is in use
        if lsmod | grep -q beegfs || cat /proc/modules | grep -q beegfs; then
            echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: BeeGFS module already loaded (detected after insmod attempt)"
        else
            echo "$(date --rfc-3339=ns) WARN [combined-entrypoint.sh]: Failed to load BeeGFS module - insmod error"
            echo "$(date --rfc-3339=ns) WARN [combined-entrypoint.sh]: Continuing anyway with host networking..."
        fi
    fi
else
    echo "$(date --rfc-3339=ns) ERROR [combined-entrypoint.sh]: BeeGFS module not found at $BEEGFS_MODULE"
    echo "$(date --rfc-3339=ns) WARN [combined-entrypoint.sh]: Continuing anyway with host networking..."
fi

# Create BeeGFS mounts configuration file
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Creating BeeGFS mounts configuration..."
mkdir -p /mnt/beegfs
echo "/mnt/beegfs /etc/beegfs/beegfs-client.conf" > /etc/beegfs/beegfs-mounts.conf

# Create BeeGFS autobuild configuration if it doesn't exist
if [ ! -f /etc/beegfs/beegfs-client-autobuild.conf ]; then
    echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Creating BeeGFS client autobuild configuration..."
    cat > /etc/beegfs/beegfs-client-autobuild.conf << 'EOF'
# This file contains make options for the automatic building of BeeGFS client
# modules on first start. (Optional - this file can be empty.)

# Example: BEEGFS_OPENTK_IBVERBS=1
EOF
fi

# Mount BeeGFS directly for v8
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Mounting BeeGFS..."
mount -t beegfs beegfs#nodev /mnt/beegfs -o cfgFile=/etc/beegfs/beegfs-client.conf

# Verify BeeGFS mount
if mountpoint -q /mnt/beegfs; then
    echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: BeeGFS mounted successfully at /mnt/beegfs"
    ls -la /mnt/beegfs
else
    echo "$(date --rfc-3339=ns) ERROR [combined-entrypoint.sh]: BeeGFS not mounted - cannot continue"
    exit 1
fi

# Configure services
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Configuring combined NFS+S3 services..."

# S3 Gateway Configuration
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

# Configure AWS CLI for local S3 testing
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Configuring AWS CLI for local S3 API testing..."
export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
export AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-1}

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

# Handle VGW_CHOWN for ownership
is_numeric() { printf '%s' "$1" | grep -qE '^[0-9]+$'; }

if [ -n "${VGW_CHOWN_UID:-}" ] && [ -n "${VGW_CHOWN_GID:-}" ]; then
	if is_numeric "$VGW_CHOWN_UID" && is_numeric "$VGW_CHOWN_GID"; then
		echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Setting ownership of ${VGW_DATA} to ${VGW_CHOWN_UID}:${VGW_CHOWN_GID}"
		if chown -R "${VGW_CHOWN_UID}:${VGW_CHOWN_GID}" "${VGW_DATA}"; then
			echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Ownership change successful"
		else
			echo "$(date --rfc-3339=ns) WARN [combined-entrypoint.sh]: Failed to change ownership - continuing anyway"
		fi
		
		# Also set ownership of metadata sidecar directory if it exists
		if [ -n "${VGW_META_SIDECAR:-}" ] && [ -d "${VGW_META_SIDECAR}" ]; then
			echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Setting ownership of metadata sidecar ${VGW_META_SIDECAR} to ${VGW_CHOWN_UID}:${VGW_CHOWN_GID}"
			chown -R "${VGW_CHOWN_UID}:${VGW_CHOWN_GID}" "${VGW_META_SIDECAR}" || true
		fi
		
		# Unset these variables so versitygw doesn't try to parse them as boolean flags
		unset VGW_CHOWN_UID VGW_CHOWN_GID
	fi
fi

# Start NFS Server
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Starting NFS server..."

# Configure NFS version 4.1
mkdir -p /etc/nfs

# Configure NFS to use version 4.1
cat > /etc/default/nfs-kernel-server << 'EOF'
# Number of servers to start up
RPCNFSDCOUNT=8

# Runtime priority of server (see nice(1))
RPCNFSDPRIORITY=0

# Options for rpc.mountd.
RPCMOUNTDOPTS="--manage-gids -V 4"

# Do you want to start the svcgssd daemon? It is only required for Kerberos
# exports. Valid alternatives are "yes" and "no"; the default is "no".
NEED_SVCGSSD="no"

# Options for rpc.svcgssd.
RPCSVCGSSDOPTS=""
EOF

# Create NFSv4 root filesystem and bind mount
mkdir -p /exports/beegfs
mount --bind /mnt/beegfs /exports/beegfs

# Create NFS exports configuration for BeeGFS
# export_options="rw,fsid=0,async,crossmnt,no_subtree_check,insecure,no_root_squash"
export_options="rw,fsid=0,async,crossmnt,no_subtree_check,no_root_squash"
echo "fs.leases-enable = 0" >> /etc/sysctl.conf && sysctl -p

cat > /etc/exports << EOF
# NFSv4 exports for BeeGFS
/mnt/beegfs *(${export_options})
EOF

# Start NFS services in background
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Starting rpcbind..."
rpcbind

echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Starting rpc.idmapd..."
rpc.idmapd || echo "$(date --rfc-3339=ns) WARNING [combined-entrypoint.sh]: rpc.idmapd failed to start"

echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Exporting filesystems..."
exportfs -ra

echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Loading nfsd kernel module..."
modprobe nfsd || echo "$(date --rfc-3339=ns) WARNING [combined-entrypoint.sh]: Failed to load nfsd module"

echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Starting rpc.nfsd..."
rpc.nfsd -V 4 --grace-time 10 8 || {
    echo "$(date --rfc-3339=ns) WARNING [combined-entrypoint.sh]: rpc.nfsd with options failed, trying basic start..."
    rpc.nfsd 8
}

echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Starting rpc.mountd..."
rpc.mountd -V 4 --foreground &
MOUNTD_PID=$!

# Give NFS a moment to start
sleep 3

echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: NFS service status:"
ps aux | grep -E "(rpc|nfs)" | grep -v grep
rpcinfo -p | head -10

# Start S3 Gateway in background
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Starting S3 Gateway..."
unset VGW_CHOWN_UID VGW_CHOWN_GID  # Ensure these are not set
export VGW_META_SIDECAR="${VGW_META_SIDECAR}"

# Check if debug logging is enabled
if [ "${DEBUG:-false}" = "true" ]; then
	DEBUG_FLAG="--debug"
else
	DEBUG_FLAG=""
fi

echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Starting versitygw with metadata sidecar at ${VGW_META_SIDECAR}"
versitygw --access "$ROOT_ACCESS_KEY_ID" --secret "$ROOT_SECRET_ACCESS_KEY" \
    --port "${VGW_IP}:${VGW_PORT}" $DEBUG_FLAG posix "$VGW_DATA" &
S3_PID=$!

# Give S3 gateway a moment to start
sleep 3

echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Services started successfully!"
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: BeeGFS available via:"
echo "  - NFS: nfs4://${BR0_IP}/mnt/beegfs"
echo "  - S3 API: http://${BR0_IP}:${VGW_PORT}"
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: AWS CLI configured for local endpoint: aws --endpoint-url=http://localhost:${VGW_PORT} s3 ..."

# Monitor services and keep container running
echo "$(date --rfc-3339=ns) INFO [combined-entrypoint.sh]: Monitoring services..."
while true; do
    sleep 30
    
    # Check if BeeGFS is still mounted
    if ! mountpoint -q /mnt/beegfs; then
        echo "$(date --rfc-3339=ns) WARNING [combined-entrypoint.sh]: BeeGFS mount lost, attempting to remount..."
        mount -t beegfs beegfs#nodev /mnt/beegfs -o cfgFile=/etc/beegfs/beegfs-client.conf
        if [ $? -eq 0 ]; then
            exportfs -ra  # Re-export for NFS
        fi
    fi
    
    # Check if mountd is still running
    if ! kill -0 $MOUNTD_PID 2>/dev/null; then
        echo "$(date --rfc-3339=ns) WARNING [combined-entrypoint.sh]: mountd died, restarting..."
        rpc.mountd -V 4 --foreground &
        MOUNTD_PID=$!
    fi
    
    # Check if S3 gateway is still running
    if ! kill -0 $S3_PID 2>/dev/null; then
        echo "$(date --rfc-3339=ns) WARNING [combined-entrypoint.sh]: S3 gateway died, restarting..."
        unset VGW_CHOWN_UID VGW_CHOWN_GID
        export VGW_META_SIDECAR="${VGW_META_SIDECAR}"
        versitygw --access "$ROOT_ACCESS_KEY_ID" --secret "$ROOT_SECRET_ACCESS_KEY" \
            --port "${VGW_IP}:${VGW_PORT}" $DEBUG_FLAG posix "$VGW_DATA" &
        S3_PID=$!
    fi
done
