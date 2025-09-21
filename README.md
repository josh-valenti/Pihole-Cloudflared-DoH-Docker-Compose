# Pi-hole + Cloudflared DNS-over-HTTPS

A simple Docker setup that blocks ads across your entire network while keeping your DNS queries private. Pi-hole does the ad blocking, and Cloudflared encrypts all your DNS requests so your ISP can't see what websites you're visiting.

## What this does

Your devices → Pi-hole (blocks ads) → Cloudflared (encrypts DNS) → Cloudflare

Instead of your DNS queries going out in plain text where anyone can see them, they get encrypted and sent over HTTPS. Plus you get network-wide ad blocking without installing anything on individual devices.

## What you need

- A Raspberry Pi or any Linux machine with Docker
- A static IP address for your Pi
- About 10 minutes

## Setup

1. **Get the files**
   ```bash
   git clone https://github.com/josh-valenti/Pihole-Cloudflared-DoH-Docker-Compose.git
   cd Pihole-Cloudflared-DoH-Docker-Compose
   ```

2. **Fix the IP address**
   
   Edit `docker-compose.yml` and change `192.168.0.29` to your Pi's IP address:
   ```yaml
   ports:
     - "YOUR_PI_IP:53:53/tcp"
     - "YOUR_PI_IP:53:53/udp"
     - "YOUR_PI_IP:8081:80/tcp"
   ```

3. **Create folders**
   ```bash
   mkdir -p ./config/pihole ./config/dnsmasq.d
   ```

4. **Start everything**
   ```bash
   docker-compose up -d
   ```

5. **Check it's working**
   ```bash
   docker-compose ps
   # Both containers should show "Up" and pihole should show "healthy"
   ```

## Using it

### Pi-hole admin panel
Go to `http://YOUR_PI_IP:8081/admin`

To get/set the password:
```bash
# See the random password it generated
docker logs pihole | grep "random password"

# Or set your own
docker exec pihole pihole setpassword yourpassword
```

### Test DNS blocking
```bash
# This should work normally
nslookup google.com YOUR_PI_IP

# This should return 0.0.0.0 (blocked)
nslookup doubleclick.net YOUR_PI_IP
```

### Make sure DoH is working
```bash
# Watch for HTTPS traffic to Cloudflare (encrypted DNS)
sudo tcpdump -i any host 1.1.1.1 and port 443

# Then in another terminal, make a DNS query
nslookup facebook.com YOUR_PI_IP
```

You should see encrypted traffic on port 443. If you see traffic on port 53 instead, something's wrong.

## Router setup

To get network-wide ad blocking:

1. Log into your router
2. Find DHCP/DNS settings
3. Set primary DNS to your Pi's IP address
4. Save and reboot router

Now every device on your network gets ad blocking automatically.

## Test your setup

A test script is included to verify everything is working correctly:

```bash
# Make the script executable
chmod +x test-doh.sh

# Run basic tests
./test-doh.sh

# Run with network traffic verification (recommended)
sudo ./test-doh.sh
```

The script checks:
- Container health and status
- DNS resolution through Pi-hole
- Ad blocking functionality
- DoH configuration and traffic encryption
- Proper upstream communication
- DNS leak detection

Running with sudo allows the script to monitor network traffic and confirm that DNS queries are actually being encrypted via HTTPS instead of sent as plain text.

## Troubleshooting

**Containers won't start**
- Make sure nothing else is using port 53: `sudo netstat -tulpn | grep :53`
- Check you updated the IP address in docker-compose.yml

**DNS not working**
- Verify containers are running: `docker-compose ps`
- Check logs: `docker-compose logs pihole`

**Ads still showing**
- Wait a few minutes for blocklists to load
- Check the Pi-hole admin panel to see if queries are being blocked

**Want to see what's happening**
```bash
# Real-time DNS query log
docker exec pihole tail -f /var/log/pihole/pihole.log
```
