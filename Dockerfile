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

# Using multi-stage docker with the same base image for all daemons.

FROM --platform=$TARGETPLATFORM debian:12.10-slim AS base
ARG DEBIAN_FRONTEND=noninteractive
ENV PATH="/opt/beegfs/sbin/:${PATH}"
# Note this is the default used when no version is specified.
# Normally images are built using CI and the version is determined based on the Git tag.
# Can be overridden via .env file or build args
ARG BEEGFS_VERSION="8.1"
ENV BEEGFS_VERSION=$BEEGFS_VERSION

# Enable RDMA support
RUN apt-get update && apt-get install rdma-core  infiniband-diags perftest -y && rm -rf /var/lib/apt/lists/*

# Install Required Utilities:
# Notes:
# 1) The following packages enable: ps (procps), lsmod (kmod), firewall mgmt (iptables), mkfs.xfs (xfsprogs), ip CLI utilities (iproute2).
# 2) Not installing ethtool as it should be included in the base image. 
# 3) ca-certificates is required to connect to the BeeGFS repo over HTTPS.
# 4) wget is only used to download the BeeGFS GPG key and repository file.
RUN apt-get update && apt-get install procps kmod iptables xfsprogs iproute2 ca-certificates wget -y && rm -rf /var/lib/apt/lists/*

# Install Optional Utilities:
RUN apt-get update && apt-get install nano vim dstat sysstat -y && rm -rf /var/lib/apt/lists/*

# Install Beegfs binaries from the public repo.
RUN wget https://www.beegfs.io/release/beegfs_$BEEGFS_VERSION/gpg/GPG-KEY-beegfs -O /etc/apt/trusted.gpg.d/beegfs.asc
RUN wget https://www.beegfs.io/release/beegfs_$BEEGFS_VERSION/dists/beegfs-bookworm.list -P /etc/apt/sources.list.d/

# Container expects the desired BeeGFS service to be specified as part of the run command: 
# Example: docker run -it beegfs/beegfs-mgmtd:7.3.0 beegfs-mgmtd storeMgmtdDirectory=/mnt/beegfs-mgmtd\
COPY servers/start.sh /root/start.sh
COPY servers/client-start.sh /root/client-start.sh
COPY servers/init.py /root/init.py
RUN chmod +x /root/start.sh /root/client-start.sh /root/init.py
# Make a default directory where BeeGFS services can store data:
RUN mkdir -p /data/beegfs


# Build beegfs-mgmtd docker image with `docker build -t repo/image-name  --target beegfs-mgmtd .`  
FROM --platform=$TARGETPLATFORM  base AS beegfs-mgmtd
ARG BEEGFS_SERVICE="beegfs-mgmtd"
ENV BEEGFS_SERVICE=$BEEGFS_SERVICE
RUN apt-get update && apt-get install $BEEGFS_SERVICE libbeegfs-ib -y && \
    if [ "${BEEGFS_VERSION%%.*}" -ne 7 ]; then apt-get install libbeegfs-license -y; fi && \
    rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["/root/start.sh"]


# Build beegfs-meta docker image with `docker build -t repo/image-name  --target beegfs-meta .`  
FROM --platform=$TARGETPLATFORM base AS beegfs-meta
ARG BEEGFS_SERVICE="beegfs-meta"
ENV BEEGFS_SERVICE=$BEEGFS_SERVICE
RUN apt-get update && apt-get install $BEEGFS_SERVICE libbeegfs-ib -y && rm -rf /var/lib/apt/lists/*
RUN rm -rf /etc/beegfs/*conf
ENTRYPOINT ["/root/start.sh"]


# Build beegfs-storage docker image with `docker build -t repo/image-name  --target beegfs-storage .`  
FROM --platform=$TARGETPLATFORM base AS beegfs-storage
ARG BEEGFS_SERVICE="beegfs-storage"
ENV BEEGFS_SERVICE=$BEEGFS_SERVICE
RUN apt-get update && apt-get install $BEEGFS_SERVICE libbeegfs-ib -y && rm -rf /var/lib/apt/lists/*
RUN rm -rf /etc/beegfs/*conf
ENTRYPOINT ["/root/start.sh"]


# Build beegfs-client-base docker image with all packages pre-installed
# Use Ubuntu 24.04 for client to match host kernel modules
FROM --platform=$TARGETPLATFORM ubuntu:24.04 AS beegfs-client-base

# Install base packages for BeeGFS client
RUN apt-get update && apt-get install -y \
    procps kmod iptables xfsprogs iproute2 ca-certificates wget gnupg2 \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# Install BeeGFS repository
ARG BEEGFS_VERSION="8.1"
ENV BEEGFS_VERSION=$BEEGFS_VERSION
RUN wget https://www.beegfs.io/release/beegfs_$BEEGFS_VERSION/gpg/GPG-KEY-beegfs -O /etc/apt/trusted.gpg.d/beegfs.asc
RUN wget https://www.beegfs.io/release/beegfs_$BEEGFS_VERSION/dists/beegfs-noble.list -P /etc/apt/sources.list.d/

# Install BeeGFS client and utilities
RUN apt-get update && apt-get install -y beegfs-client beegfs-utils beegfs-tools libbeegfs-ib

# Install NFS server packages for NFS export functionality
RUN apt-get install -y nfs-kernel-server nfs-common rpcbind

# Install S3 gateway dependencies (for future S3 service)
RUN apt-get install -y curl unzip && rm -rf /var/lib/apt/lists/*

# Clean up BeeGFS config files
RUN rm -rf /etc/beegfs/*conf

# Create mount point for BeeGFS
RUN mkdir -p /mnt/beegfs

# Create NFS export directories
RUN mkdir -p /exports

# Default entrypoint (can be overridden)
ENTRYPOINT ["/root/client-start.sh"]


# BeeGFS Client for NFS service
FROM beegfs-client-base AS beegfs-client-nfs
ARG BEEGFS_SERVICE="beegfs-client"
ENV BEEGFS_SERVICE=$BEEGFS_SERVICE
ENV BEEGFS_CLIENT_TYPE=nfs

# Copy NFS entrypoint script
COPY nfs/entrypoint.sh /nfs-entrypoint.sh
RUN chmod +x /nfs-entrypoint.sh

ENTRYPOINT ["/nfs-entrypoint.sh"]


# BeeGFS Client for combined NFS+S3 service
FROM beegfs-client-base AS beegfs-client-combined
ARG BEEGFS_SERVICE="beegfs-client"
ENV BEEGFS_SERVICE=$BEEGFS_SERVICE
ENV BEEGFS_CLIENT_TYPE=combined

# Set default Versity S3 Gateway version (can be overridden at build time)
ARG VERSITY_S3GW_VERSION=1.0.14
ENV VERSITY_S3GW_VERSION=${VERSITY_S3GW_VERSION}

# Install Versity S3 Gateway and AWS CLI
RUN wget https://github.com/versity/versitygw/releases/download/v${VERSITY_S3GW_VERSION}/versitygw_${VERSITY_S3GW_VERSION}_linux_amd64.deb && \
    apt-get update && \
    apt-get install -y ./versitygw_${VERSITY_S3GW_VERSION}_linux_amd64.deb curl unzip && \
    rm versitygw_${VERSITY_S3GW_VERSION}_linux_amd64.deb && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update && \
    rm -rf aws awscliv2.zip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy combined entrypoint script
COPY combined/entrypoint.sh /combined-entrypoint.sh
RUN chmod +x /combined-entrypoint.sh

ENTRYPOINT ["/combined-entrypoint.sh"]


# BeeGFS Client for S3 service using Versity S3 Gateway
FROM beegfs-client-base AS beegfs-client-s3
ARG BEEGFS_SERVICE="beegfs-client"
ENV BEEGFS_SERVICE=$BEEGFS_SERVICE
ENV BEEGFS_CLIENT_TYPE=s3

# Set default Versity S3 Gateway version (can be overridden at build time)
ARG VERSITY_S3GW_VERSION=1.0.14
ENV VERSITY_S3GW_VERSION=${VERSITY_S3GW_VERSION}

# Install Versity S3 Gateway and AWS CLI
RUN wget https://github.com/versity/versitygw/releases/download/v${VERSITY_S3GW_VERSION}/versitygw_${VERSITY_S3GW_VERSION}_linux_amd64.deb && \
    apt-get update && \
    apt-get install -y ./versitygw_${VERSITY_S3GW_VERSION}_linux_amd64.deb curl unzip && \
    rm versitygw_${VERSITY_S3GW_VERSION}_linux_amd64.deb && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update && \
    rm -rf aws awscliv2.zip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy S3 entrypoint script
COPY s3/entrypoint.sh /s3-entrypoint.sh
RUN chmod +x /s3-entrypoint.sh

ENTRYPOINT ["/s3-entrypoint.sh"]


# Generic beegfs-client (backwards compatibility)
FROM beegfs-client-base AS beegfs-client
ARG BEEGFS_SERVICE="beegfs-client"
ENV BEEGFS_SERVICE=$BEEGFS_SERVICE


# Build beegfs-all docker image with `docker build -t repo/image-name  --target beegfs-all .`  
FROM --platform=$TARGETPLATFORM base AS beegfs-all
ARG BEEGFS_SERVICE="beegfs-all"
RUN apt-get update && apt-get install libbeegfs-ib beegfs-mgmtd beegfs-meta beegfs-storage -y && rm -rf /var/lib/apt/lists/*
RUN rm -rf /etc/beegfs/*conf
ENTRYPOINT ["/root/start.sh"]
# arguments passed as commands in docker run will be passed as arguments to start.sh inturn passed to BeeGFS service.
