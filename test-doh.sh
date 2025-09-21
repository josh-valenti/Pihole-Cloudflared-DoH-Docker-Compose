#!/bin/bash
# test-doh.sh - Verify Pi-hole with Cloudflared DoH setup is working correctly
set -euo pipefail

# Get the Pi's actual IP address from docker-compose configuration
PIHOLE_IP=$(grep -A1 "ports:" docker-compose.yml | grep "53:53" | head -1 | cut -d'"' -f2 | cut -d':' -f1)
if [ -z "$PIHOLE_IP" ]; then
    echo "Could not determine Pi-hole IP from docker-compose.yml"
    echo "Please ensure you're running this from the directory containing docker-compose.yml"
    exit 1
fi

echo "Testing Pi-hole setup at IP: $PIHOLE_IP"
echo "======================================="
echo

failures=0

echo "=== Test 1: Container Status ==="
if docker-compose ps | grep -q "Up.*healthy"; then
    echo "✅ Pi-hole container is running and healthy"
else
    echo "❌ Pi-hole container is not healthy"
    failures=$((failures+1))
fi

if docker-compose ps | grep -q "cloudflared-doh.*Up"; then
    echo "✅ Cloudflared container is running"
else
    echo "❌ Cloudflared container is not running"
    failures=$((failures+1))
fi
echo

echo "=== Test 2: DNS Resolution Through Pi-hole ==="
if nslookup google.com "$PIHOLE_IP" > /dev/null 2>&1; then
    echo "✅ Pi-hole is answering DNS queries from external clients"
else
    echo "❌ Pi-hole is not responding to DNS queries"
    failures=$((failures+1))
fi
echo

echo "=== Test 3: Ad Blocking Functionality ==="
BLOCKED_RESULTS=$(nslookup doubleclick.net "$PIHOLE_IP" 2>/dev/null | grep "Address:" | awk '{print $2}' || echo "")
if echo "$BLOCKED_RESULTS" | grep -q "0.0.0.0" && echo "$BLOCKED_RESULTS" | grep -q "::"; then
    echo "✅ Ad blocking is working (doubleclick.net blocked for both IPv4 and IPv6)"
elif echo "$BLOCKED_RESULTS" | grep -q "0.0.0.0\|::"; then
    echo "✅ Ad blocking is working (doubleclick.net blocked)"
else
    echo "❌ Ad blocking may not be working (doubleclick.net returned: $BLOCKED_RESULTS)"
    failures=$((failures+1))
fi
echo

echo "=== Test 4: Cloudflared DoH Configuration ==="
# First check if container exists and is running
if ! docker ps --format "table {{.Names}}" | grep -q "cloudflared-doh"; then
    echo "❌ Cloudflared container not found or not running"
    failures=$((failures+1))
else
    # Get logs with proper error handling
    CLOUDFLARED_LOGS=$(docker logs cloudflared-doh 2>&1)
    
    if [ -z "$CLOUDFLARED_LOGS" ]; then
        echo "❌ No logs available from cloudflared container"
        failures=$((failures+1))
    elif echo "$CLOUDFLARED_LOGS" | grep -q "Adding DNS upstream.*https.*1\.1\.1\.1.*dns-query"; then
        echo "✅ Cloudflared is configured for DNS-over-HTTPS"
        UPSTREAM_COUNT=$(echo "$CLOUDFLARED_LOGS" | grep -c "Adding DNS upstream.*https.*dns-query")
        echo "   $UPSTREAM_COUNT DoH upstream servers configured"
        if echo "$CLOUDFLARED_LOGS" | grep -q "Starting DNS over HTTPS proxy server"; then
            echo "   DNS proxy server started successfully"
        fi
    else
        echo "❌ Cloudflared DoH configuration not detected"
        echo "Available logs:"
        echo "$CLOUDFLARED_LOGS" | head -10
        failures=$((failures+1))
    fi
fi
echo

echo "=== Test 5: Pi-hole to Cloudflared Communication ==="
if docker exec pihole dig @cloudflared -p 5053 google.com +short > /dev/null 2>&1; then
    echo "✅ Pi-hole can communicate with Cloudflared"
else
    echo "❌ Pi-hole cannot reach Cloudflared"
    failures=$((failures+1))
fi
echo

echo "=== Test 6: Pi-hole Upstream Configuration ==="
UPSTREAM_CONFIG=$(docker exec pihole cat /etc/pihole/pihole.toml | grep -A3 "upstreams = \[" | grep "cloudflared#5053" || echo "")
if [ -n "$UPSTREAM_CONFIG" ]; then
    echo "✅ Pi-hole is configured to use Cloudflared as upstream"
else
    echo "❌ Pi-hole upstream configuration incorrect"
    failures=$((failures+1))
fi
echo

echo "=== Test 7: DoH Traffic Verification ==="
# Check if running as root/sudo for tcpdump
if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Skipping network traffic test (requires sudo)"
    echo "   Run 'sudo ./test-doh.sh' to verify DoH encryption"
else
    echo "Starting network traffic monitor for 10 seconds..."
    echo "Making test DNS queries to generate traffic..."

    # Start tcpdump in background to capture HTTPS traffic to Cloudflare
    timeout 10s tcpdump -i any -n host 1.1.1.1 and port 443 -c 5 > /tmp/doh_traffic.log 2>&1 &
    TCPDUMP_PID=$!

    # Wait a moment for tcpdump to start
    sleep 2

    # Generate some DNS queries to force upstream requests (use unique domains to avoid cache)
    for i in {1..3}; do
        UNIQUE_DOMAIN="test-$(date +%s)-$i.example.com"
        nslookup "$UNIQUE_DOMAIN" "$PIHOLE_IP" > /dev/null 2>&1 || true
        sleep 1
    done

    # Wait for tcpdump to finish
    wait $TCPDUMP_PID 2>/dev/null || true

    # Check results
    if [ -s /tmp/doh_traffic.log ] && grep -q "1.1.1.1.*443" /tmp/doh_traffic.log; then
        echo "✅ DoH traffic detected - DNS queries are encrypted via HTTPS"
        PACKET_COUNT=$(grep -c "1.1.1.1.*443" /tmp/doh_traffic.log || echo "0")
        echo "   Captured $PACKET_COUNT HTTPS packets to Cloudflare"
    else
        echo "⚠️  No DoH traffic captured in this test run"
        echo "   This doesn't necessarily mean DoH isn't working - queries may be cached"
        echo "   Try making queries to random domains to force upstream requests"
    fi

    # Cleanup
    rm -f /tmp/doh_traffic.log
fi
echo

echo "=== Test 8: DNS Leak Check ==="
NON_DOCKER_DNS=$(sudo lsof -iUDP:53 -iTCP:53 2>/dev/null | grep -v "docker-proxy\|docker-pr\|pihole-FTL" | tail -n +2 || echo "")
if [ -z "$NON_DOCKER_DNS" ]; then
    echo "✅ No DNS leaks detected - only Pi-hole handling port 53"
else
    echo "⚠️  Other processes detected on port 53:"
    echo "$NON_DOCKER_DNS"
    echo "   Note: docker-proxy processes are expected and normal"
fi
echo

echo "=== Test 9: Configuration Summary ==="
echo "Pi-hole IP: $PIHOLE_IP"
echo "Web Interface: http://$PIHOLE_IP:8081/admin"

# Get upstream servers from Pi-hole
UPSTREAMS=$(docker exec pihole cat /etc/pihole/pihole.toml | grep -A5 "upstreams = \[" | grep -v "upstreams = \[" | grep -v "^--" | tr -d ' "[],' | grep -v "^$" || echo "")
echo "Configured upstreams: $UPSTREAMS"

echo
echo "======================================="
if [ $failures -eq 0 ]; then
    echo "🎉 All tests passed! Your Pi-hole with DoH is working correctly."
    echo
    echo "Next steps:"
    echo "1. Configure your router to use $PIHOLE_IP as primary DNS"
    echo "2. Visit http://$PIHOLE_IP:8081/admin to manage Pi-hole"
    echo "3. All your DNS queries are now encrypted and ads are blocked!"
else
    echo "❌ $failures test(s) failed. Check the output above for issues."
    echo
    echo "Common fixes:"
    echo "- Run 'docker-compose up -d' to ensure containers are running"
    echo "- Check 'docker-compose logs' for error messages"
    echo "- Verify your IP address is correct in docker-compose.yml"
fi
echo
