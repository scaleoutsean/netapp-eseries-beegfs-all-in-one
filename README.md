# BeeGFS All-in-One Stack

This Docker Compose stack includes BeeGFS client services that can expose BeeGFS storage via NFS and S3 protocols.

What you get is a BeeGFS 8.1 cluster with a filesystem exported via NFSv4 or S3 (or both, in the "combined" container). 

You can mount it from the host (here it's `192.168.1.100`) via NFSv4 or access it via S3.

```sh
$ sudo mount -t nfs4 192.168.1.100:/mnt/beegfs /tmp/test-combined-nfs

$ ls -la /tmp/test-combined-nfs/testbucket/
total 2
drwxr-xr-x 3 sean sean  3 Sep 12 17:21 .
drwxrwxrwx 4 sean sean  9 Sep 12 17:31 ..
-rw-r--r-- 1 root root 38 Sep 12 17:21 combined-s3-test.txt
-rw-r--r-- 1 sean sean 42 Sep 12 16:49 s3test.txt
drwxr-xr-x 2 sean sean  0 Sep 12 17:21 .sgwtmp

$ docker exec -it beegfs-client-combined aws --endpoint-url http://192.168.1.100:7070 s3 ls testbucket
2025-09-12 09:21:50         38 combined-s3-test.txt
2025-09-12 08:49:06         42 s3test.txt
```

I first blogged about the idea [in 2024](https://scaleoutsean.github.io/2024/04/11/netapp-eseries-containerized-beegfs-nfs-s3-all-in-one.html), but I got a lot on my plate, so it remained an idea. Apart from the obvious (testing, development, training) one of the new use cases that have emerged on my personal radar is [NetApp E-Series with OPEA](https://scaleoutsean.github.io/2025/05/21/opean-ai-with-netapp-eseries.html), where I think this stack provides flexibility and value. But the stack works with any storage, including internal. 

## Requirements

- Docker Compose
- Ubuntu 24.04 LTS (unless you change base OS in BeeGFS client containers)
- BeeGFS Client 8.1 on the host (installed but disabled)

## Services added to ThinkParQ's "BeeGFS cluter in containers" stack

### beegfs-client-nfs

- **Purpose**: Mounts BeeGFS and exports it via NFS
- **Container**: `beegfs-client-nfs`
- **Ports**: 
  - `2049:2049` (NFS)
  - `111:111` (RPC portmapper)
- **Mount Point**: BeeGFS is mounted at `/mnt/beegfs` inside the container
- **NFS Export**: Available at the host's IP via NFS protocol

Access containerized NFS service running in BeeGFS container using the host IP (in my case `192.168.1.100`):

```sh
sudo mount -t nfs -o vers=4 192.168.1.100:/mnt/beegfs /tmp/test-nfs
```

### beegfs-client-s3

- **Purpose**: S3 gateway to BeeGFS
- **Container**: `beegfs-client-s3` 
- **Ports**: `7070:7070` (S3 API (HTTP))
- **Mount Point**: BeeGFS is mounted at `/mnt/beegfs` inside the container
- **Note**: HTTPS isn't provided for two reasons
  - Accessing S3 service running on your own system is by default secure
  - HTTPS on Versity S3 Gateway isn't hard, but that's not where it shoulid be done. Create another container (TLS-terminating reverse HTTP proxy) if you want TLS, pick your poison (NGINX, etc.) and get to work

### beegfs-client-combined

A combination of the above two.

If you use this, it is probably wise to use one service for read access and the other for write access. Or even better, use native BeeGFS for both, and one of them for when you have to.

## Prerequisites

### **IMPORTANT**

- 1. BeeGFS client (and therefore S3, NFS) won't work without the kind and version of OS on the host and client being *identical*. The BeeGFS client container uses Ubuntu 24.04 base image, so you'd have to have that and the same version of BeeGFS client on the host (or otherwise hack the NFS and S3 base OS to make it the same as your host). See Troubleshoting at the bottom for more. 
- 2. Without this precondition, you'll end up with "just" a BeeGFS cluster (management, meta, storage containers), which is what you get [here](https://github.com/ThinkParQ/beegfs-containers), so you may as well use that upstream repo for that. In that case, you can install BeeGFS client on your host and deploy NFS and S3 on your host to export your `/mnt/beegfs` path from the host via NFS and S3, which will give you the same thing (well, mostly, as S3 and NFS wouldn't be containerized).

### Create 

1. **Host Directories**: Create the following directories in cloned repository's root. Then edit the last line in `openssl.conf` - set it to use your host's IP address used to access S3, and generate certificates (currently mostly unused, but may be if reverse HTTPS proxy is added to the stack) and run `./generate-certs.sh`.   
  ```bash
  mkdir -p ./beegfs/mgmt_tgt_mgmt01
  mkdir -p ./beegfs/meta_01_tgt_0101
  mkdir -p ./beegfs/stor_01_tgt_101
  mkdir -p ./beegfs/stor_01_tgt_102
  mkdir -p ./beegfs/nfs-exports
  mkdir -p ./beegfs/s3-config
  bash generate-certs.sh
  ```

2. **Network Configuration**: All services use `network_mode: "host"` which is required for BeeGFS client connectivity. Modify firewall rules on the host to allow access to RPC portmapper, NFS, and S3 *from your host to your own host's IP address* (see examples in Troubleshooting). Do **not** open firewall ports to LAN clients unless you want them to be able to access stack services.
  ```bash
  Status: active

  To                         Action      From
  --                         ------      ----
  192.168.1.100 111/tcp       ALLOW       192.168.1.100
  192.168.1.100 111/udp       ALLOW       192.168.1.100
  192.168.1.100 7070/tcp      ALLOW       192.168.1.100
  192.168.1.100 2049/tcp      ALLOW       192.168.1.100
  192.168.1.100 2049/udp      ALLOW       192.168.1.100
  ```

## Usage

Remember that, due to the way Linux and Docker works, once BeeGFS client container starts, it will load kernel modules from the host. BeeGFS on the host is supposed to be installed but not supposed to run if BeeGFS client container is used.

If BeeGFS client modules aren't available, BeeGFS won't start. If they are available, you'll see them loaded on the host as well (with `lsmod`) when BeeGFS client container is executed. You don't have to remove (unload) them. When upgrading kernel and BeeGFS code, upgrade host and BeeGFS client container in lockstep.

### Start the full stack

```bash
docker compose docker-compose.yml up -d beegfs-management beegfs-meta beegfs-storage
docker compose docker-compose.yml up -d beegfs-client-s3
docker compose docker-compose.yml up -d beegfs-client-nfs
```

Now you should be able to mount NFS from host and - if you configure S3 client on the host - use S3 on default host IP, port 7070.

### Stop services

This is here to remind you:

- If you have NFS mounted on the host, don't stop the container before running `sudo umount` because - as always - it will leave your host shell stuck until you unmount
- To stop NFS server: unmount NFS on NFS clients first, and then stop the NFS server container with `docker stop beegfs-client-nfs`, for example

### Start individual services

`beegfs-management`, `beegfs-meta`, `beegfs-storage` must be running before a client container can successfully start.

```bash
# Start just the BeeGFS cluster and make sure it's working
docker compose docker-compose.yml up -d beegfs-management beegfs-meta beegfs-storage

# Run NFS server (and BeeGFS client)
docker compose docker-compose.yml up -d beegfs-client-nfs

# Run S3 gateway server (and BeeGFS client)
docker compose docker-compose.yml up -d beegfs-client-s3
```

It's best to try one additional service (e.g. NFS), then another, until you get familiar with any issues. There's also a "combined" container which runs both NFS and S3.

### Accessing BeeGFS via NFS

Once the `beegfs-client-nfs` service is running, you can mount BeeGFS on other systems via NFS:

```bash
# On another system (such as your host, if you haven't allowed external access from LAN), mount via NFS (replace <host-ip> with your Docker host IP)
mkdir /tmp/beegfs
sudo mount -t nfs <host-ip>:/mnt/beegfs /tmp/beegfs
```

Don't rely on `showmount -e <host-ip>`. If NFS service has started, simply try to mount NFSv4 root on your client (host) using `INTERFACE` address from `.env`.

```sh
sudo mount -t nfs4 <host-ip>:/ /tmp/beegfs
```

### Accessing BeeGFS via S3

The `beegfs-client-s3` service prepares BeeGFS for S3 gateway access. 

You'll need to enter the container and create a bucket and secret and access key. 

RTFM [here](https://github.com/versity/versitygw/wiki/Quickstart). You can enter the container with `docker exec -it beegfs-client-s3 bash` to do the management steps (create buckets, add extra keys, etc.), then from the host just use standard S3 API to S3 API endpoint `http://<host-ip>:7070`.

```sh
docker exec -it beegfs-client-combined aws --endpoint-url http://192.168.1.100:7070 s3 mb s3://opea
```

The above uses AWS CLI from the container, but you can use your own on the host. The S3 admin credentials are in `docker-compose.yml`.

## Configuration

### Environment variables

- `BEEGFS_VERSION`: BeeGFS version used (here, 8.1)
- `BEEGFS_CLIENT_TYPE`: Set to `nfs` or `s3` to determine client behavior
- `CONN_AUTH_FILE_DATA`: BeeGFS connection authentication data
- `S3_PORT`: port for S3 gateway (default: 7070 for Versity S3 Gateway)
- `INTERFACES`: host interface for services (host network on which services are to be accessed)
- `VGW_IP`: S3 IP. This defaults to 0.0.0.0, which is a looser restriction than Interfaces, which makes Versity S3 Gateway accessible to other Docker networks, for example. Tighten as appropriate.
- Review other settings in `.env` and `docker-compose.yml`. TLS in BeeGFS is not enabled because all containers are on the same host

## Security notes

- Containers run in privileged mode with `SYS_ADMIN` capability for mounting filesystems
- Containers use `host` mode, which means services are exposed on host ports, so if external access is not to be allowed, make sure all ports used by container services are closed to LAN hosts
- NFSv4 is not hooked into Kerberos because that would mean more containers and network-sensitive setup
- S3 API is served over HTTP, as explained at the top. Deploy a reverse HTTPS proxy if you need TLS
- Note that, while `.env` variable `INTERFACES` serves as configuration source for some services, there may be other settings (like `VGW_IP` mentioned earlier) that can be used to tighten or loosen security settings. Read BeeGFS, NFSv4 and Versity S3 Gateway documentation for more

## Troubleshooting

### Check BeeGFS client status

```bash
# Check if BeeGFS is mounted inside the client container
docker exec beegfs-client-s3 mountpoint /mnt/beegfs

# Check BeeGFS connectivity
docker exec beegfs-client-s3 

# View BeeGFS client logs
docker logs beegfs-client-s3
```

### NFS mounts

Showmount isn't expected to work. With `fsid=0` we need to mount NFSv4 root, not "root share".

```sh
mount server:/ /local/mount
```

Enter NFS (or "combined") container to check exports:

```sh
$ docker exec -it beegfs-client-combined bash
# inside of NFS container
root@scaleoutsean:/# cat /etc/exports 
# NFSv4 exports for BeeGFS
/mnt/beegfs *(rw,fsid=0,async,crossmnt,no_subtree_check,no_root_squash)
```

### Kernel and BeeGFS version

Because BeeGFS client loads kernel modules:

- Use the same container OS and host OS, same BeeGFS client
- Install the same version of BeeGFS (client at least) on the host. After you install BeeGFS client package on the host, stop it so that it does not interfere with Docker BeeGFS client containers
- Disable BeeGFS client (and NFS server, if you have it) from running on the host
- When containerized BeeGFS client starts, host will have modules loaded. This is handled (if client restarts, it won't load them again). When multiple clients start, they share the same module loaded from host. Whether that's better or worse than running all services in one BeeGFS client remains to be seen. In light testing both approaches work

Here we see BeeGFS kernel module loaded on the host. It doesn't have to be loaded, but when Dockerized BeeGFS client starts, it will be loaded if everything goes fine. The point is, it must exist.

```sh
$ find /lib/modules -name "*beegfs*" -type f 2>/dev/null
/lib/modules/6.8.0-71-generic/updates/fs/beegfs_autobuild/beegfs.ko
```
I use the same OS (and kernel) on host and in BeeGFS client (Ubuntu 24.04, but you can change the container OS to Debian or other OS if that's what you run on host).

```sh
$ uname -a
Linux scaleoutsean 6.8.0-71-generic #71-Ubuntu SMP PREEMPT_DYNAMIC Tue Jul 22 16:52:38 UTC 2025 x86_64 x86_64 x86_64 GNU/Linux
sean@scaleoutsean:~/code/beegfs-containers$ uname -r && ls -la /lib/modules/$(uname -r)/updates/fs/beegfs_autobuild/
6.8.0-71-generic
total 579
drwxr-xr-x 2 root root       3 Sep 12 10:34 .
drwxr-xr-x 3 root root       3 Sep 12 10:34 ..
-rw-r--r-- 1 root root 1416312 Sep 12 10:34 beegfs.ko
```

### Firewall

Because mount uses host IP, I allow myself to access NFS, but not LAN clients.

```sh
sudo ufw allow from 192.168.1.100 to 192.168.1.100 port 111    # RPC portmapper
sudo ufw allow from 192.168.1.100 to 192.168.1.100 port 2049   # NFS 
sudo ufw allow from 192.168.1.100 to 192.168.1.100 port 7070   # S3 (Versity Gateway)
```

## Authors and credits

- [scaleoutSean](https://github.com/scaleoutSean) - packaging and integration for BeeGFS client, NFS, and Versity S3 Gateway
- [ThinkParQ](https://github.com/ThinkParQ/beegfs-containers) - base BeeGFS cluster and containers

## License

- Apache License 2.0

