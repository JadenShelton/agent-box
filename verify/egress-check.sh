#!/usr/bin/env bash
# Egress check, run INSIDE the VM (bootstrap.sh verify does this for you). Read-only.
#
# Proves the firewall does what the README claims: the internet works, and the host's services,
# the LAN and the tailnet are all unreachable from the VM. A check marked GAP is a real hole.
#
# Inputs (environment): BRIDGE_IP, HOST_LAN_IP, HOST_TAILNET_IP, VERIFY_BLOCKED ("host:port ...")
# Empty ones are skipped.

check() {  # check <label> <target: reachable|blocked> <command string>
    local label="$1" target="$2" cmd="$3" got mark
    if timeout 4 bash -c "$cmd" >/dev/null 2>&1; then got=reachable; else got=blocked; fi
    mark="OK "; [ "$got" = "$target" ] || mark="GAP"
    printf '%s  %-42s got=%-9s target=%s\n' "$mark" "$label" "$got" "$target"
    [ "$mark" = "OK " ] || FAILED=1
}
FAILED=0

ip -br -4 addr show scope global
echo
echo "-- Must work"
check "internet ping 1.1.1.1"      reachable "ping -c2 -W2 1.1.1.1"
check "DNS lookup ubuntu.com"      reachable "getent hosts ubuntu.com"
check "HTTPS ubuntu.com"           reachable "curl -fsS -o /dev/null https://ubuntu.com"

echo "-- Must be blocked: the host's own services (only DHCP and DNS are allowed)"
[ -n "${BRIDGE_IP:-}" ]       && check "host SSH via bridge $BRIDGE_IP:22"        blocked "</dev/tcp/$BRIDGE_IP/22"
[ -n "${HOST_LAN_IP:-}" ]     && check "host SSH via LAN $HOST_LAN_IP:22"         blocked "</dev/tcp/$HOST_LAN_IP/22"
[ -n "${HOST_TAILNET_IP:-}" ] && check "host SSH via tailnet $HOST_TAILNET_IP:22" blocked "</dev/tcp/$HOST_TAILNET_IP/22"

echo "-- Must be blocked: the rest of your network"
for t in ${VERIFY_BLOCKED:-}; do
    check "LAN target $t" blocked "</dev/tcp/${t%:*}/${t##*:}"
done
[ -n "${VERIFY_BLOCKED:-}" ] || echo "   (nothing listed: set VERIFY_BLOCKED=\"192.168.1.1:80 192.168.1.50:22\" in config.env to test your router/servers)"

echo
if [ "$FAILED" -eq 0 ]; then echo "All checks OK."; else echo "At least one GAP: do not trust this VM with agents yet."; fi
exit "$FAILED"
