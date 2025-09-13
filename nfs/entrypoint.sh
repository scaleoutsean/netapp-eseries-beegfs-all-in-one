#!/bin/bash

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

# Set up error handling but don't exit on every error
set -o pipefail

echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Starting BeeGFS NFS client setup..."

# Configure NFS version 4.1 (packages already installed in base image)
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Configuring NFSv4.1..."

# Create NFS configuration directory
mkdir -p /etc/nfs

# Configure NFS to use version 4.1
cat > /etc/default/nfs-kernel-server << 'EOF'
# Number of servers to start up
RPCNFSDCOUNT=8

# Runtime priority of server (see nice(1))
RPCNFSDPRIORITY=0

# Options for rpc.mountd.
RPCMOUNTDOPTS="--manage-gids"

# Do you want to start the svcgssd daemon? It is only required for Kerberos
# exports. Valid alternatives are "yes" and "no"; the default is "no".
NEED_SVCGSSD="no"

# Options for rpc.svcgssd.
RPCSVCGSSDOPTS=""

# Options for rpc.nfsd.
RPCNFSDOPTS="-V 4.1"
EOF

# Configure NFS common settings for NFSv4.1
cat > /etc/default/nfs-common << 'EOF'
# If you do not set values for the NEED_ options, they will be attempted
# autodetected; this should be sufficient for most people. Valid alternatives
# for the NEED_ options are "yes" and "no".

# Do you want to start the statd daemon? It is not needed for NFSv4.
NEED_STATD="yes"

# Options for rpc.statd.
STATDOPTS=""

# Do you want to start the idmapd daemon? It is only needed for NFSv4.
NEED_IDMAPD="yes"

# Do you want to start the gssd daemon? It is required for Kerberos mounts.
NEED_GSSD="no"
EOF

# Configure idmapd for NFSv4
cat > /etc/idmapd.conf << 'EOF'
[General]
Verbosity = 0
Pipefs-Directory = /run/rpc_pipefs
Domain = local

[Mapping]
Nobody-User = nobody
Nobody-Group = nogroup

[Translation]
Method = nsswitch
EOF

# Create BeeGFS client configuration
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Creating BeeGFS client configuration..."

# Get the IP address of the configured interface
INTERFACE=${INTERFACES:-br0}
BR0_IP=$(ip addr show $INTERFACE | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -n1 2>/dev/null || echo "127.0.0.1")
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Using interface $INTERFACE with IP: $BR0_IP"

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

# Connection authentication
connAuthFile = /etc/beegfs/conn.auth
EOF

# Wait for BeeGFS management service to be available
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Waiting for BeeGFS management service..."
timeout=60
count=0
while [ $count -lt $timeout ]; do
    if nc -z localhost 8008; then
        echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: BeeGFS management service is reachable"
        break
    fi
    echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: BeeGFS management service not ready, waiting 5 seconds..."
    sleep 5
    count=$((count + 5))
done

# Create BeeGFS autobuild configuration if it doesn't exist
if [ ! -f /etc/beegfs/beegfs-client-autobuild.conf ]; then
    echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Creating BeeGFS client autobuild configuration..."
    cat > /etc/beegfs/beegfs-client-autobuild.conf << 'EOF'
# This file contains make options for the automatic building of BeeGFS client
# modules on first start. (Optional - this file can be empty.)

# Example: BEEGFS_OPENTK_IBVERBS=1
EOF
fi

# Load BeeGFS kernel module manually
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Loading BeeGFS kernel module..."
KERNEL_VERSION=$(uname -r)
BEEGFS_MODULE="/lib/modules/${KERNEL_VERSION}/updates/fs/beegfs_autobuild/beegfs.ko"

# Check if module is already loaded
if lsmod | grep -q beegfs || cat /proc/modules | grep -q beegfs; then
    echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: BeeGFS module already loaded"
elif [ -f "$BEEGFS_MODULE" ]; then
    echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Loading BeeGFS module from $BEEGFS_MODULE"
    if insmod "$BEEGFS_MODULE" 2>/dev/null; then
        echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: BeeGFS module loaded successfully"
    else
        # Check if it failed because module was already loaded
        if lsmod | grep -q beegfs || cat /proc/modules | grep -q beegfs; then
            echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: BeeGFS module already loaded (loaded during insmod attempt)"
        else
            echo "$(date --rfc-3339=ns) ERROR [nfs-entrypoint.sh]: Failed to load BeeGFS module - insmod error"
            # Don't exit, continue anyway since host networking shares kernel modules
            echo "$(date --rfc-3339=ns) WARN [nfs-entrypoint.sh]: Continuing anyway with host networking..."
        fi
    fi
else
    echo "$(date --rfc-3339=ns) ERROR [nfs-entrypoint.sh]: BeeGFS module not found at $BEEGFS_MODULE"
    # Don't exit, continue anyway since host networking shares kernel modules
    echo "$(date --rfc-3339=ns) WARN [nfs-entrypoint.sh]: Continuing anyway with host networking..."
fi

# Create BeeGFS mounts configuration file
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Creating BeeGFS mounts configuration..."
mkdir -p /mnt/beegfs
echo "/mnt/beegfs /etc/beegfs/beegfs-client.conf" > /etc/beegfs/beegfs-mounts.conf

# Mount BeeGFS directly for v8
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Mounting BeeGFS..."
mount -t beegfs beegfs#nodev /mnt/beegfs -o cfgFile=/etc/beegfs/beegfs-client.conf

# Check BeeGFS client log
if [ -f /var/log/beegfs-client.log ]; then
    echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: BeeGFS client log:"
    tail -n 15 /var/log/beegfs-client.log
fi

# Check if BeeGFS is mounted (it should auto-mount based on config)
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Checking BeeGFS mount status..."
if mountpoint -q /mnt/beegfs; then
    echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: BeeGFS mounted successfully at /mnt/beegfs"
    ls -la /mnt/beegfs
else
    echo "$(date --rfc-3339=ns) WARNING [nfs-entrypoint.sh]: BeeGFS not mounted at /mnt/beegfs"
    # Show what mount points exist
    echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Current mount points:"
    mount | grep beegfs || echo "No BeeGFS mounts found"
    
    if [ -f /var/log/beegfs-client.log ]; then
        echo "$(date --rfc-3339=ns) ERROR [nfs-entrypoint.sh]: BeeGFS client log:"
        tail -n 20 /var/log/beegfs-client.log
    fi
fi

# Create NFS export directory structure
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Setting up NFS export structure..."
mkdir -p /exports/beegfs

# Create NFSv4 root filesystem
mkdir -p /exports
mount --bind /mnt/beegfs /exports/beegfs

# Configure NFS exports for NFSv4 (inspired by GitHub example)
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Configuring NFS exports..."
# rw,async,fsid=0,crossmnt,no_subtree_check,no_root_squash # https://doc.beegfs.io/latest/advanced_topics/nfs_export.html
export_options="fsid=0,async,crossmnt,no_subtree_check,no_root_squash"
echo "fs.leases-enable = 0" >> /etc/sysctl.conf && sysctl -p

cat > /etc/exports << EOF
# NFSv4 exports for BeeGFS
/mnt/beegfs *(${export_options})
EOF

# Start RPC services
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Starting RPC services..."
# Create missing directory for rpcbind
mkdir -p /run/sendsigs.omit.d
service rpcbind start || {
    echo "$(date --rfc-3339=ns) WARNING [nfs-entrypoint.sh]: service rpcbind failed, trying manual start..."
    rpcbind -w
}

# Ensure nfsd filesystem is mounted
if ! mountpoint -q /proc/fs/nfsd; then
    echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Mounting nfsd filesystem..."
    mount -t nfsd nfsd /proc/fs/nfsd
fi

# Create necessary directories for NFSv4
mkdir -p /var/lib/nfs/rpc_pipefs
mkdir -p /var/lib/nfs/v4recovery

# Start NFS services with explicit options (inspired by GitHub example)
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Starting NFSv4 services..."

# Start idmapd for NFSv4
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Starting rpc.idmapd..."
rpc.idmapd || echo "$(date --rfc-3339=ns) WARNING [nfs-entrypoint.sh]: rpc.idmapd failed to start"

# Export the filesystems
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Exporting filesystems..."
exportfs -rv

# Start NFS daemon with NFSv4 only, grace time, and specific options
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Starting rpc.nfsd..."
rpc.nfsd -V 4 --grace-time 10 8 || {
    echo "$(date --rfc-3339=ns) WARNING [nfs-entrypoint.sh]: rpc.nfsd with options failed, trying basic start..."
    rpc.nfsd 8
}

# Start mount daemon with NFSv4 and foreground mode
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Starting rpc.mountd..."
rpc.mountd -V 4 --foreground &
MOUNTD_PID=$!

# Wait a moment for services to initialize
sleep 3

# Verify NFS services are running
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: NFS service status:"
ps aux | grep -E '(nfsd|mountd|rpcbind)' | grep -v grep
rpcinfo -p localhost | grep -E '(nfs|mount)' || echo "No NFS services in rpcinfo yet"

echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: NFSv4.1 server started successfully"
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: BeeGFS available via NFS at:"
echo "  NFSv4.1: nfs4://<host>/beegfs"

# Function to cleanup on exit
cleanup() {
    echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Shutting down NFS services..."
    kill $MOUNTD_PID 2>/dev/null || true
    rpc.nfsd 0
    exportfs -ua
    umount /exports/beegfs 2>/dev/null || true
    umount /mnt/beegfs 2>/dev/null || true
    echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: NFS services stopped"
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT

# Keep container running and monitor services
echo "$(date --rfc-3339=ns) INFO [nfs-entrypoint.sh]: Monitoring services..."
while true; do
    sleep 30
    
    # Check if BeeGFS is still mounted
    if ! mountpoint -q /mnt/beegfs; then
        echo "$(date --rfc-3339=ns) WARNING [nfs-entrypoint.sh]: BeeGFS mount lost, attempting to remount..."
        beegfs-mount /mnt/beegfs
        if [ $? -eq 0 ]; then
            # Re-bind the export
            umount /exports/beegfs 2>/dev/null || true
            mount --bind /mnt/beegfs /exports/beegfs
            exportfs -ra
        fi
    fi
    
    # Check if mountd is still running
    if ! kill -0 $MOUNTD_PID 2>/dev/null; then
        echo "$(date --rfc-3339=ns) WARNING [nfs-entrypoint.sh]: mountd died, restarting..."
        rpc.mountd --foreground &
        MOUNTD_PID=$!
    fi
done
