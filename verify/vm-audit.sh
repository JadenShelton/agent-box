#!/usr/bin/env bash
# Read-only inventory of the VM: accounts, SSH, firewall, updates, listeners.
# Run it with: sudo ./bootstrap.sh audit
# Look for: no password-less sudo, only `agents` with a login shell, SSH key-only, ufw active,
# and nothing listening beyond sshd, the Paperclip port, and local DNS.
. /etc/os-release; echo "== OS: $PRETTY_NAME, kernel $(uname -r), hostname $(hostname)"

echo "== Accounts with a login shell"
awk -F: '$7 !~ /(nologin|false|sync)$/ {print "  " $1 " uid=" $3 " shell=" $7}' /etc/passwd
echo "== Members of sudo/admin/docker groups (all should be empty)"
for g in sudo admin docker; do printf '  %-7s %s\n' "$g:" "$(getent group "$g" | cut -d: -f4)"; done
echo "== Root password state (L = locked)"
echo "  $(passwd -S root | awk '{print $2}')"
echo "== Files in /etc/sudoers.d"
ls -1 /etc/sudoers.d 2>/dev/null | sed 's/^/  /'

echo "== SSH server"
if command -v sshd >/dev/null; then
    sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|allowusers|allowagentforwarding) ' | sed 's/^/  /'
else
    echo "  openssh-server not installed"
fi

echo "== Firewall"
command -v ufw >/dev/null && ufw status numbered | sed 's/^/  /' || echo "  ufw not installed"

echo "== Unattended upgrades"
echo "  $(systemctl is-enabled unattended-upgrades 2>/dev/null) / $(systemctl is-active unattended-upgrades 2>/dev/null)"

echo "== Listening sockets"
ss -tulnH | awk '{print "  " $1 " " $5}' | sort -u

echo "== Docker: rootful daemon should be off, rootless on"
echo "  docker.service (system): $(systemctl is-enabled docker.service 2>/dev/null || true) / $(systemctl is-active docker.service 2>/dev/null || true)"
echo "  docker.sock present: $([ -S /var/run/docker.sock ] && echo yes || echo no)"
echo "== Time sync"
timedatectl show -p NTPSynchronized --value | sed 's/^/  NTPSynchronized=/'
