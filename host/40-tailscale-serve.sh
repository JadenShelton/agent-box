#!/usr/bin/env bash
# Host step 4 (optional): publish the Paperclip UI on your tailnet with `tailscale serve`.
#
# Why the HOST forwards and the VM does not join the tailnet: a tailnet node can reach every
# other node you own. Putting the VM on the tailnet would undo the LAN egress block, since a
# compromised agent could then reach your laptop and servers over Tailscale. Instead the host
# (already a tailnet node) proxies one port to the VM, and the VM's own firewall accepts that
# port from the host only.
#
# `serve` (tailnet only) is used, never `funnel` (public internet).
#
# Prerequisites: Tailscale installed and logged in on the host, and HTTPS certificates enabled
# for your tailnet (admin console -> DNS -> HTTPS Certificates).
#
# Note: every device on your tailnet can reach the resulting URL. Paperclip's own login is the
# guard. If that is too open, restrict it with a Tailscale ACL grant.
# Undo: sudo tailscale serve reset
set -euo pipefail
# shellcheck source=../lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
require_root

command -v tailscale >/dev/null || { echo "tailscale is not installed on the host. See https://tailscale.com/download"; exit 1; }

tailscale serve --bg "http://$VM_IP:$PAPERCLIP_PORT"
tailscale serve status
echo
echo "The URL above returns 502 until Paperclip's service is running (./bootstrap.sh service)."
echo "Add that hostname to Paperclip's allowed hostnames (see README, 'Onboarding')."
