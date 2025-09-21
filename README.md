# Pi-hole with Cloudflared DNS-over-HTTPS

Secure Docker Compose setup for Pi-hole with Cloudflared providing encrypted DNS-over-HTTPS (DoH) upstream resolution.

## Features

- **Network-wide ad blocking** via Pi-hole
- **Encrypted DNS queries** through Cloudflare DNS-over-HTTPS
- **Security-focused** bridge network configuration
- **Resource isolation** with proper Docker security practices
- **High performance** with local DNS caching

## Architecture

```
Client Device → Pi-hole (Port 53) → Cloudflared (Port 5053) → Cloudflare DoH (Port 443/HTTPS)
```

- **Pi-hole**: Handles DNS requests, blocks ads, provides web interface
- **Cloudflared**: Converts DNS queries to encrypted HTTPS requests
- **Cloudflare**: Upstream DNS provider with DoH support

## Prerequisites

- Docker and Docker Compose installed
- Static IP address configured for your host system
- Root/sudo access for container management

## Quick Start

1. **Clone this repository**
   ```bash
   git clone <repository-url>
   cd pihole-cloudflared-docker
   ```

2. **Update configuration**
   - Edit `docker-compose.yml`
   - Replace `192.168.0.29` with your host's static IP address
   - Adjust timezone in `TZ` environment variable

3. **Create directories**
   ```bash
   mkdir -p ./config/pihole ./config/dnsmasq.d
   ```

4. **Deploy the stack**
   ```bash
   docker-compose up -d
   ```

5. **Verify deployment**
   ```bash
   docker-compose ps
   docker-compose logs
   ```

## Configuration

### Network Configuration

Update the IP address binding in `docker-compose.yml`:

```yaml
ports:
  - "YOUR_HOST_IP:53:53/tcp"
  - "YOUR_HOST_IP:53:53/udp"
  - "YOUR_HOST_IP:8081:80/tcp"
```

Replace `YOUR_HOST_IP` with your system's static IP address.

### Pi-hole Access

- **Web Interface**: `http://YOUR_HOST_IP:8081/admin`
- **Default Password**: Random password generated on first start
- **View Password**: `docker logs pihole | grep "random password"`
- **Set Custom Password**: `docker exec pihole pihole setpassword YOUR_PASSWORD`

### Timezone Configuration

Set your local timezone in the environment variables:

```yaml
environment:
  TZ: "America/New_York"  # Replace with your timezone
```

Find your timezone: [List of tz database time zones](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones)

## Security Features

### Container Security
- **No privileged containers**: Uses minimal required capabilities
- **Read-only filesystems**: Cloudflared runs with read-only root filesystem
- **No new privileges**: Prevents privilege escalation
- **Bridge networking**: Containers isolated from host network
- **Minimal capabilities**: Only NET_ADMIN for Pi-hole DNS binding

### Network Security
- **Encrypted upstream DNS**: All external DNS queries use HTTPS encryption
- **Local network binding**: Services only accessible from specified IP
- **No exposed credentials**: Passwords managed through Docker secrets/environment

## Verification

### Test DNS Resolution
```bash
# Test through Pi-hole
nslookup google.com YOUR_HOST_IP

# Test ad blocking
nslookup doubleclick.net YOUR_HOST_IP
```

### Verify DoH Encryption
```bash
# Monitor HTTPS traffic to Cloudflare
sudo tcpdump -i any -n host 1.1.1.1 and port 443

# Make DNS query (in another terminal)
nslookup example.com YOUR_HOST_IP
```

You should see encrypted HTTPS traffic on port 443, not plain DNS on port 53.

### Check Container Health
```bash
# View container status
docker-compose ps

# Check logs for errors
docker-compose logs pihole | grep -E "(ERROR|WARNING)"
docker-compose logs cloudflared-doh
```

## Troubleshooting

### Common Issues

**Container fails to start**
- Verify port 53 is not in use: `sudo netstat -tulpn | grep :53`
- Check IP address binding matches your host IP
- Ensure Docker has sufficient permissions

**DNS queries timeout**
- Verify containers are running: `docker-compose ps`
- Check network connectivity between containers
- Test individual components separately

**Ad blocking not working**
- Access Pi-hole web interface to verify blocklists are loaded
- Check that queries are going through Pi-hole, not upstream DNS
- Review Pi-hole logs for blocked queries

**DoH not functioning**
- Verify cloudflared container is running and healthy
- Test direct cloudflared access: `docker exec pihole dig @cloudflared -p 5053 google.com`
- Monitor network traffic to confirm HTTPS usage

### Log Analysis

```bash
# Pi-hole logs
docker exec pihole tail -f /var/log/pihole/pihole.log

# Container logs
docker-compose logs -f pihole
docker-compose logs -f cloudflared-doh

# System DNS resolution
sudo tcpdump -i any port 53
```

## Router Configuration

To provide network-wide DNS filtering:

1. Access your router's admin interface
2. Navigate to DHCP/DNS settings
3. Set primary DNS server to your host IP address
4. Set secondary DNS to `1.1.1.1` (fallback)
5. Save and restart router if required

**Note**: Some devices may cache DNS settings. Restart devices or flush DNS cache after router configuration.

## Maintenance

### Updates
```bash
# Pull latest images
docker-compose pull

# Recreate containers with new images
docker-compose up -d
```

### Backup Configuration
```bash
# Backup Pi-hole configuration
sudo cp -r ./config/pihole ./config/pihole.backup.$(date +%Y%m%d)

# Backup compose file
cp docker-compose.yml docker-compose.yml.backup.$(date +%Y%m%d)
```

### Performance Monitoring
```bash
# View resource usage
docker stats pihole cloudflared-doh

# Monitor query volume
docker exec pihole pihole -c -e
```

## Customization

### Additional Upstream DNS Servers

To add multiple upstream servers, modify the environment variable:

```yaml
FTLCONF_dns_upstreams: "cloudflared#5053;1.1.1.1;8.8.8.8"
```

### Custom Blocklists

Add custom blocklists through the Pi-hole web interface:
1. Navigate to Group Management → Adlists
2. Add desired blocklist URLs
3. Update gravity: Tools → Update Gravity

### Advanced Configuration

Additional Pi-hole settings can be configured using `FTLCONF_` environment variables. See [Pi-hole documentation](https://docs.pi-hole.net/docker/configuration/) for complete options.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Test changes thoroughly
4. Submit a pull request with detailed description

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- [Pi-hole](https://pi-hole.net/) - Network-wide ad blocking
- [Cloudflared](https://github.com/cloudflare/cloudflared) - DNS-over-HTTPS proxy
- [Cloudflare](https://www.cloudflare.com/) - DNS-over-HTTPS provider

## Support

For issues related to:
- **Pi-hole**: [Pi-hole Discourse](https://discourse.pi-hole.net/)
- **Cloudflared**: [Cloudflare Community](https://community.cloudflare.com/)
- **Docker**: [Docker Documentation](https://docs.docker.com/)

For configuration-specific issues, please open an issue in this repository.
