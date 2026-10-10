#!/usr/bin/env bash
# VM step 1 (as root): no default admin user, hardened SSH, and a default-deny firewall.
#
# Design: NO sudo-capable account exists in the VM. Admin access is only from the host with
# `incus exec` (root over a vsock channel, not the network). That has two benefits:
#   * a compromised agent has no account to escalate to, and no password to find;
#   * a broken SSH config or firewall in the VM can never lock you out, because `incus exec`
#     doesn't use the network.
set -euo pipefail

echo "== Remove the cloud image's default sudo user (if present)"
if id ubuntu >/dev/null 2>&1; then
    pkill -u ubuntu 2>/dev/null || true
    userdel -r ubuntu 2>&1 | grep -v 'mail spool' || true
    echo "   removed user 'ubuntu'"
else
    echo "   no 'ubuntu' user"
fi
rm -f /etc/sudoers.d/90-cloud-init-users
visudo -c >/dev/null && echo "   sudoers still parses"

echo "== Stop cloud-init from re-creating default users"
# (cloud-init's schema validator complains about files in cloud.cfg.d that lack a
#  '#cloud-config' header. That is a validator quirk, not a broken file.)
cat > /etc/cloud/cloud.cfg.d/99-no-default-user.cfg <<'EOF'
# agent-box: no default user. Accounts are managed by the provisioning scripts.
users: []
EOF

echo "== Write the SSH hardening drop-in BEFORE installing sshd"
# Order matters: if the config exists first, sshd never runs a single second with defaults.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
# agent-box SSH hardening. sshd uses the FIRST value it sees for each option, and "00-"
# sorts before every other drop-in, so these win.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
# One account, reachable only from the host (you arrive with: ssh -J you@host agents@VM).
AllowUsers $AGENT_USER@$BRIDGE_IP
# Never let a VM process use your workstation's ssh-agent (it could use your keys elsewhere).
AllowAgentForwarding no
X11Forwarding no
EOF
chmod 644 /etc/ssh/sshd_config.d/00-hardening.conf

echo "== Install openssh-server and ufw"
apt-get update -qq
apt-get install -y -qq openssh-server ufw >/dev/null
sshd -t && echo "   sshd -t OK"
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|allowusers|allowagentforwarding) ' | sed 's/^/   /'

echo "== Firewall: deny in, allow out; SSH and the Paperclip port from the host only"
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$BRIDGE_IP" to any port 22 proto tcp comment 'ssh from host only'
ufw allow from "$BRIDGE_IP" to any port "$PAPERCLIP_PORT" proto tcp comment 'paperclip UI via the host proxy'
ufw --force enable
ufw status verbose | sed 's/^/   /'
