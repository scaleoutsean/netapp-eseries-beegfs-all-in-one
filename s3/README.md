# S3 gateway configuration for BeeGFS client

The BeeGFS S3 client container mounts BeeGFS at `/mnt/beegfs` and makes it accessible over S3.

Note that a second, "local" Docker volume is [required for S3 metadata capability in Versity S3 Gateway](https://scaleoutsean.github.io/2025/06/22/data-pipeline-with-beegfs-file-system-notifications-and-versity-s3-gateway.html#catches). We don't necessarily need that, but it's nice to have so it's defined in `docker-compose.yml`.

Versity Gateway is designed for high-performance parallel filesystems like BeeGFS and OSS in the spirit of OPEA.

## Testing S3 Access

### Using AWS CLI

`<host-ip>` is the address of the Docker host defined in `INTERFACES`. Get S3 credentials and endpoint URL from your `docker-compose.yml`.

```bash
# Configure AWS CLI for local S3 gateway
aws configure set aws_access_key_id minioadmin
aws configure set aws_secret_access_key minioadmin
aws configure set default.region us-east-1

# Test S3 operations
aws --endpoint-url http://<host-ip>:7070 s3 mb s3://test-bucket
aws --endpoint-url http://<host-ip>:7070 s3 cp /etc/hosts s3://test-bucket/
aws --endpoint-url http://<host-ip>:7070 s3 ls s3://test-bucket/
```

## Monitoring and Troubleshooting

### Check BeeGFS Mount in S3 Container
```bash
docker exec beegfs-client-s3 df -h /mnt/beegfs
docker exec beegfs-client-s3 ls -la /mnt/beegfs
```

### Test Versity S3 Gateway status

```bash
docker compose logs beegfs-client-s3
```

### Enter Versity S3 Gateway container

Use `beegfs-client-combined` if running S3 in the combined container, `beegfs-client-s3` if stand-alone.

```bash
docker exec -it beegfs-client-combined bash
```

Inside the container you may interact with Versity S3 Gateway and S3 service (AWS CLI v2 is pre-installed):

```sh
cd /root/ && cat .aws/credentials
aws s3 ls --endpoint-url http://<host-ip>:7070

versitygw -v
versitygw -h
versitygw admin -h
ADMIN_ACCESS_KEY_ID=beegfs_s3_admin ADMIN_SECRET_ACCESS_KEY=beegfs_s3_admin_secret ADMIN_ENDPOINT_URL=http://<host-ip>:7070 versitygw admin list-users
# 2025/09/12 15:52:37 api error XAdminMethodNotSupported: The method is not supported in single root user mode.
```

Note that `versitygw` as CLI may be tricky, so the last example is there to showcase that.

## Security Notes

- Default credentials are in `./docker-compose.yml`. Change them for production
- Consider implementing proper IAM policies for S3 access
- Deploy TLS-terminating reverse HTTPS proxy in front of Versity S3 Gateway in production environments
- Implement ACLs and network security groups/firewall rules appropriately

