#!/bin/bash
# =====================================================================
# test-doh.sh - Verify Pi-hole + Cloudflared DoH stack is working
#
# Changes from previous version:
#   - Detects "docker compose" (v2) vs "docker-compose" (v1) automatically
#   - Pi-hole IP detected from the RUNNING container first (docker port),
#     with the compose file as a fallback -- the old grep -A1 parse was
#     fragile and broke if port ordering in the YAML changed
#   - Upstream tests now check the static cloudflared IP (172.28.0.2),
#     matching the new compose file
#   - New Test 0: NTP sync check (Pi 4 has no RTC; bad clock breaks TLS
#     handshakes for DoH right after a reboot)
#   - Test 8 (DNS leak) no longer calls sudo when not running as root;
#     it is skipped with a notice instead (was inconsistent with Test 7)
#   - Fixed grep -c bug where "|| echo 0" double-printed the count
#   - tcpdump now matches 1.1.1.1 OR 1.0.0.1 (cloudflared uses both)
# =====================================================================
set -euo pipefail

# --------------------------------------------------------------------
# Section: Configuration
# --------------------------------------------------------------------
CLOUDFLARED_IP="172.28.0.2"     # Must match docker-compose.yml static IP
CLOUDFLARED_PORT="5053"
failures=0

# --------------------------------------------------------------------
# Section: Helpers
# --------------------------------------------------------------------
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; failures=$((failures+1)); }
warn() { echo "⚠️  $1"; }

# --------------------------------------------------------------------
# Section: Preconditions
# --------------------------------------------------------------------
# Must be run from the directory containing docker-compose.yml
if [ ! -f docker-compose.yml ]; then
    echo "docker-compose.yml not found in current directory."
    echo "Run this script from the compose project directory."
    exit 1
fi

# Detect Compose v2 plugin vs legacy standalone binary
if docker compose version > /dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose > /dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    echo "Neither 'docker compose' nor 'docker-compose' is available."
    exit 1
fi

# --------------------------------------------------------------------
# Section: Determine Pi-hole LAN IP
# Prefer the live container binding (authoritative), fall back to
# parsing the compose file if the container isn't running yet.
# --------------------------------------------------------------------
PIHOLE_IP=$(docker port pihole 53/udp 2>/dev/null | head -1 | cut -d: -f1 || true)
if [ -z "${PIHOLE_IP:-}" ] || [ "$PIHOLE_IP" = "0.0.0.0" ]; then
    PIHOLE_IP=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:53:53' docker-compose.yml | head -1 | cut -d: -f1 || true)
fi
if [ -z "${PIHOLE_IP:-}" ]; then
    echo "Could not determine Pi-hole IP from running container or docker-compose.yml"
    exit 1
fi

echo "Testing Pi-hole setup at IP: $PIHOLE_IP"
echo "Compose command: $COMPOSE"
echo "======================================="
echo

# --------------------------------------------------------------------
# Test 0: System clock / NTP sync
# The Pi 4 has no RTC. Right after a reboot the clock can be wrong
# until NTP syncs, which makes cloudflared's TLS (DoH) handshakes fail.
# --------------------------------------------------------------------
echo "=== Test 0: System Clock Sync ==="
NTP_SYNCED=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "unknown")
case "$NTP_SYNCED" in
    yes)     pass "System clock is NTP-synchronized" ;;
    no)      fail "System clock is NOT synchronized - DoH TLS may fail until NTP syncs" ;;
    *)       warn "Could not determine NTP sync state (timedatectl unavailable)" ;;
esac
echo

# --------------------------------------------------------------------
# Test 1: Container status
# Uses docker inspect rather than grepping compose ps output, which
# changed format between compose v1 and v2.
# --------------------------------------------------------------------
echo "=== Test 1: Container Status ==="
PIHOLE_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' pihole 2>/dev/null || echo "missing")
if [ "$PIHOLE_HEALTH" = "healthy" ]; then
    pass "Pi-hole container is running and healthy"
else
    fail "Pi-hole container is not healthy (state: $PIHOLE_HEALTH)"
fi

CLOUDFLARED_STATE=$(docker inspect -f '{{.State.Status}}' cloudflared-doh 2>/dev/null || echo "missing")
if [ "$CLOUDFLARED_STATE" = "running" ]; then
    pass "Cloudflared container is running"
else
    fail "Cloudflared container is not running (state: $CLOUDFLARED_STATE)"
fi
echo

# --------------------------------------------------------------------
# Test 2: DNS resolution through Pi-hole (external client view)
# --------------------------------------------------------------------
echo "=== Test 2: DNS Resolution Through Pi-hole ==="
if nslookup google.com "$PIHOLE_IP" > /dev/null 2>&1; then
    pass "Pi-hole is answering DNS queries from external clients"
else
    fail "Pi-hole is not responding to DNS queries"
fi
echo

# --------------------------------------------------------------------
# Test 3: Ad blocking
# --------------------------------------------------------------------
echo "=== Test 3: Ad Blocking Functionality ==="
BLOCKED_RESULTS=$(nslookup doubleclick.net "$PIHOLE_IP" 2>/dev/null | grep "Address:" | awk '{print $2}' || true)
if echo "$BLOCKED_RESULTS" | grep -q "0.0.0.0" && echo "$BLOCKED_RESULTS" | grep -q "::"; then
    pass "Ad blocking is working (doubleclick.net blocked for IPv4 and IPv6)"
elif echo "$BLOCKED_RESULTS" | grep -q "0.0.0.0\|::"; then
    pass "Ad blocking is working (doubleclick.net blocked)"
else
    fail "Ad blocking may not be working (doubleclick.net returned: ${BLOCKED_RESULTS:-nothing})"
fi
echo

# --------------------------------------------------------------------
# Test 4: Cloudflared DoH configuration (from container logs)
# --------------------------------------------------------------------
echo "=== Test 4: Cloudflared DoH Configuration ==="
if [ "$CLOUDFLARED_STATE" != "running" ]; then
    fail "Skipping - cloudflared container is not running"
else
    CLOUDFLARED_LOGS=$(docker logs cloudflared-doh 2>&1 || true)
    if [ -z "$CLOUDFLARED_LOGS" ]; then
        fail "No logs available from cloudflared container"
    elif echo "$CLOUDFLARED_LOGS" | grep -q "Adding DNS upstream.*https.*dns-query"; then
        pass "Cloudflared is configured for DNS-over-HTTPS"
        # NOTE: grep -c prints the count itself; "|| true" only guards the
        # nonzero exit code when count is 0 (old version double-printed "0")
        UPSTREAM_COUNT=$(echo "$CLOUDFLARED_LOGS" | grep -c "Adding DNS upstream.*https.*dns-query" || true)
        echo "   $UPSTREAM_COUNT DoH upstream servers configured"
        if echo "$CLOUDFLARED_LOGS" | grep -q "Starting DNS over HTTPS proxy server"; then
            echo "   DNS proxy server started successfully"
        fi
    else
        fail "Cloudflared DoH configuration not detected"
        echo "First 10 log lines:"
        echo "$CLOUDFLARED_LOGS" | head -10
    fi
fi
echo

# --------------------------------------------------------------------
# Test 5: Pi-hole -> Cloudflared communication (by static IP)
# --------------------------------------------------------------------
echo "=== Test 5: Pi-hole to Cloudflared Communication ==="
if docker exec pihole dig @"$CLOUDFLARED_IP" -p "$CLOUDFLARED_PORT" google.com +short +time=3 +tries=1 > /dev/null 2>&1; then
    pass "Pi-hole can reach Cloudflared at $CLOUDFLARED_IP:$CLOUDFLARED_PORT"
else
    fail "Pi-hole cannot reach Cloudflared at $CLOUDFLARED_IP:$CLOUDFLARED_PORT"
fi
echo

# --------------------------------------------------------------------
# Test 6: Pi-hole upstream configuration (expects static IP upstream)
# --------------------------------------------------------------------
echo "=== Test 6: Pi-hole Upstream Configuration ==="
if docker exec pihole grep -q "${CLOUDFLARED_IP}#${CLOUDFLARED_PORT}" /etc/pihole/pihole.toml 2>/dev/null; then
    pass "Pi-hole upstream is set to ${CLOUDFLARED_IP}#${CLOUDFLARED_PORT}"
else
    fail "Pi-hole upstream configuration does not match ${CLOUDFLARED_IP}#${CLOUDFLARED_PORT}"
fi
echo

# --------------------------------------------------------------------
# Test 7: DoH traffic verification (requires root for tcpdump)
# --------------------------------------------------------------------
echo "=== Test 7: DoH Traffic Verification ==="
if [ "$EUID" -ne 0 ]; then
    warn "Skipping network traffic test (requires root)"
    echo "   Run 'sudo ./test-doh.sh' to verify DoH encryption on the wire"
else
    echo "Capturing HTTPS traffic to Cloudflare for up to 10 seconds..."
    # Cloudflared load-balances between 1.1.1.1 and 1.0.0.1 - match both
    timeout 10s tcpdump -i any -n '(host 1.1.1.1 or host 1.0.0.1) and port 443' -c 5 > /tmp/doh_traffic.log 2>&1 &
    TCPDUMP_PID=$!
    sleep 2

    # Query unique, uncached domains to force upstream lookups
    for i in 1 2 3; do
        nslookup "test-$(date +%s)-$i.example.com" "$PIHOLE_IP" > /dev/null 2>&1 || true
        sleep 1
    done

    wait $TCPDUMP_PID 2>/dev/null || true

    if [ -s /tmp/doh_traffic.log ] && grep -Eq "1\.1\.1\.1|1\.0\.0\.1" /tmp/doh_traffic.log; then
        pass "DoH traffic detected - DNS queries are encrypted via HTTPS"
        PACKET_COUNT=$(grep -Ec "1\.1\.1\.1\.443|1\.0\.0\.1\.443" /tmp/doh_traffic.log || true)
        echo "   Captured $PACKET_COUNT HTTPS packets to Cloudflare"
    else
        warn "No DoH traffic captured in this run"
        echo "   Queries may have been cached; not necessarily a failure"
    fi
    rm -f /tmp/doh_traffic.log
fi
echo

# --------------------------------------------------------------------
# Test 8: DNS leak check (requires root for lsof on other users' sockets)
# Previous version called sudo even when not root - now gated like Test 7
# --------------------------------------------------------------------
echo "=== Test 8: DNS Leak Check ==="
if [ "$EUID" -ne 0 ]; then
    warn "Skipping DNS leak check (requires root)"
    echo "   Run 'sudo ./test-doh.sh' to check for other listeners on port 53"
else
    NON_DOCKER_DNS=$(lsof -iUDP:53 -iTCP:53 2>/dev/null | grep -v "docker-proxy\|docker-pr\|pihole-FTL" | tail -n +2 || true)
    if [ -z "$NON_DOCKER_DNS" ]; then
        pass "No DNS leaks detected - only Pi-hole handling port 53"
    else
        warn "Other processes detected on port 53:"
        echo "$NON_DOCKER_DNS"
    fi
fi
echo

# --------------------------------------------------------------------
# Test 9: Configuration summary
# --------------------------------------------------------------------
echo "=== Test 9: Configuration Summary ==="
echo "Pi-hole IP:     $PIHOLE_IP"
echo "Web Interface:  http://$PIHOLE_IP:8081/admin"
UPSTREAMS=$(docker exec pihole sh -c "grep -A5 'upstreams = \[' /etc/pihole/pihole.toml" 2>/dev/null | grep -v "upstreams = \[" | grep -v "^--" | tr -d ' "[],' | grep -v "^$" || true)
echo "Upstreams:      ${UPSTREAMS:-unknown}"
echo

# --------------------------------------------------------------------
# Section: Final result
# --------------------------------------------------------------------
echo "======================================="
if [ $failures -eq 0 ]; then
    echo "🎉 All tests passed! Pi-hole with DoH is working correctly."
else
    echo "❌ $failures test(s) failed. Review the output above."
    echo
    echo "Common fixes:"
    echo "- '$COMPOSE up -d' to ensure containers are running"
    echo "- '$COMPOSE logs' for error messages"
    echo "- Confirm CLOUDFLARED_IP in this script matches docker-compose.yml"
fi
echo
