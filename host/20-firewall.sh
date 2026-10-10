#!/usr/bin/env bash
# Host step 2: ufw rules for the Incus bridge, including the LAN egress block.
#
#   sudo ./host/20-firewall.sh          # dry run: prints every rule, changes nothing
#   sudo ./host/20-firewall.sh apply    # applies them
#
# THE PROBLEM. ufw's default is "deny incoming, deny forwarded". A VM on the Incus bridge needs
# three things the defaults block: DHCP and DNS from the host's dnsmasq, and forwarded traffic
# to the internet. Incus's docs suggest `ufw allow in on incusbr0`, but that also lets the VM
# reach every service on the host (SSH included). We open only what is needed instead:
#
#   1. DHCP  (udp 67 on the bridge)      so the VM gets an address
#   2. DNS   (53 on the bridge)          so the VM can resolve names
#   3. REJECT bridge -> uplink to private ranges   so a compromised agent can't reach your LAN,
#                                                  router or other servers
#   4. ALLOW  bridge -> uplink           internet access
#
# Rule ORDER matters: ufw checks rules top to bottom and the first match wins, so the rejects
# (3) must sit above the allow (4). This script handles that even on a re-run.
#
# We also never add a rule for traffic INTO the bridge (`route allow out on $BRIDGE`), so
# nothing on the LAN can start connections to the VM. Replies to the VM's own connections work
# through ufw's established/related rule. The host itself CAN connect to the VM (host output is
# allowed), which is how SSH and the Paperclip UI proxy reach it.
#
# `reject` rather than `deny`: the VM gets an immediate "connection refused" instead of
# a hang until timeout, which makes a blocked agent fail fast and visibly.
#
# Lockout safety: these rules only touch the bridge interface. They cannot affect your SSH
# session to the host. Still, keep a second session open the first time.
set -euo pipefail
# shellcheck source=../lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
require_root

DRY=(--dry-run)
[ "${1:-}" = "apply" ] && DRY=()

u() { echo "+ ufw $*"; ufw "${DRY[@]}" "$@"; }

if ! ufw status | head -1 | grep -q 'Status: active'; then
    cat <<EOF
WARNING: ufw is not active on this host.
  Without it, nothing enforces the LAN block below, and the VM can reach your LAN.
  These rules will be stored, but they only take effect once ufw is enabled.
  Enable ufw yourself, carefully: keep a second SSH session open and allow SSH first
  (e.g. 'sudo ufw allow from <your LAN subnet> to any port 22 proto tcp'), then 'sudo ufw enable'.
EOF
fi
[ ${#DRY[@]} -gt 0 ] && echo "DRY RUN: nothing will be changed. Re-run with 'apply'."
echo "Bridge: $BRIDGE   Uplink: $UPLINK   Blocked ranges: $BLOCKED_RANGES"

echo "== 1+2. DHCP and DNS from the VM to the host's dnsmasq"
u allow in on "$BRIDGE" to any port 67 proto udp comment 'incus: VM DHCP'
u allow in on "$BRIDGE" to any port 53 comment 'incus: VM DNS'

echo "== 3. Reject VM egress to private ranges (must come before the allow)"
# If the egress allow already exists (a re-run), insert the rejects above it.
POS=$(ufw status numbered | grep -F '# incus: VM egress' | grep -v '(v6)' | head -n1 \
        | sed -E 's/^\[ *([0-9]+)\].*/\1/' || true)
for r in $BLOCKED_RANGES; do
    if [ -n "$POS" ]; then
        u route insert "$POS" reject in on "$BRIDGE" out on "$UPLINK" log to "$r" comment 'incus: no private egress'
    else
        u route reject in on "$BRIDGE" out on "$UPLINK" log to "$r" comment 'incus: no private egress'
    fi
done

echo "== 4. Allow VM egress to the rest (the internet)"
u route allow in on "$BRIDGE" out on "$UPLINK" comment 'incus: VM egress'

echo "== 5. Remove IPv6 copies of the allow rules, if ufw made any"
# ufw adds a (v6) twin of every rule when IPV6=yes in /etc/default/ufw. The bridge has no IPv6,
# and the rejects above are IPv4-only, so a v6 twin of the egress ALLOW would be an unfiltered
# path to your LAN if IPv6 were ever turned on. '::/0' in the delete spec matches only the twins.
u delete allow in on "$BRIDGE" to ::/0 port 67 proto udp 2>/dev/null || true
u delete allow in on "$BRIDGE" to ::/0 port 53 2>/dev/null || true
u route delete allow in on "$BRIDGE" out on "$UPLINK" from ::/0 to ::/0 2>/dev/null || true

if [ ${#DRY[@]} -eq 0 ]; then
    echo "== Result"
    ufw status numbered
fi
