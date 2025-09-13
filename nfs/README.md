# NFSv4.1 Configuration for BeeGFS client

## Default NFSv4.1 export configuration

The BeeGFS NFS client container automatically sets BeeGFS to "allow all" (`chmod -R 777 /mnt/beegfs`) and configures NFSv4.1 exports at startup.

RTFM [here](https://doc.beegfs.io/latest/advanced_topics/nfs_export.html).

## Custom NFS export configuration

To customize NFS exports, you can mount a custom exports file:

1. Create a custom exports file on your *host*:
   ```sh
   vim /beegfs/nfs-exports/custom-exports
   ```

2. Mount it in the `docker-compose.yml`:
   
   ```yaml
   beegfs-client-nfs:
     # ... other configuration ...
     volumes:
       - ./beegfs/nfs-exports:/exports
       - ./beegfs/nfs-exports/custom-exports:/etc/exports:ro
   ```

## Testing NFSv4.1 access

`<host-ip>` is the address of the Docker host defined in `INTERFACES`.

### From Docker Host

```bash
# Show available exports on your host will NOT work - it will err: Connection refused
showmount -e <host-ip>

# Mount BeeGFS via NFSv4.1 on NFS client (try regardless of what you get with showmount -e)
# Because this is NFSv4 and the export uses fsid=0 by default, we don't specify root NFS directory (/mnt/beegfs) when mounting
sudo mkdir -p /tmp/beegfs-nfs
sudo mount -t nfs4 <host-ip>:/ /tmp/beegfs-nfs

# Test read/write access
echo "Hello from NFSv4.1" | sudo tee /tmp/beegfs-nfs/test.txt
cat /tmp/beegfs-nfs/test.txt
```

### From remote system

You'd have to allow external access on firewall (ports 111 and 2049) if you have it.

```bash
# Replace <docker-host-ip> with your Docker host's IP address
showmount -e <docker-host-ip>

# Mount via NFSv4.1 from remote system (recommended)
sudo mkdir -p /tmp/beegfs-nfs
sudo mount -t nfs4 <docker-host-ip>:/beegfs /tmp/beegfs-nfs
```

## Security Considerations

- The default configuration uses `no_root_squash` which is fine for a trusted client on localhost. In production (even with containers) with external access, use `root_squash` and proper network restrictions and run BeeGFS client in a separate namespace or Docker compose to eliminate `host` networking in Docker
- Consider using NFSv4 with Kerberos authentication for enhanced security
- Firewall rules should restrict NFS access to trusted networks only
