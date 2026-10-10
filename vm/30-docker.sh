#!/usr/bin/env bash
# VM step 3 (as root): install Docker from Docker's own apt repo, and keep the ROOTFUL
# daemon switched off. Agents get a ROOTLESS daemon instead (next step).
#
# Why rootless: access to the normal Docker daemon is root-equivalent (the `docker` group is
# a well-known privilege-escalation path). A rootless daemon runs entirely as the `agents`
# user, so "an agent can run containers" doesn't become "an agent is root in the VM".
# It also doesn't punch holes in the firewall: rootful Docker writes its own iptables rules
# that bypass ufw, while rootless published ports are ordinary user sockets that ufw filters.
# Trade-offs accepted: no published ports below 1024, a little network overhead.
#
# Why Docker's repo and not the snap or Ubuntu's docker.io: current versions, and the rootless
# extras package. Note that unattended-upgrades only covers Ubuntu's own origins, so Docker
# packages must be updated deliberately (apt upgrade) from time to time.
set -euo pipefail

# Docker's published release-signing key fingerprint (docs.docker.com/engine/install/ubuntu).
DOCKER_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

echo "== Prerequisites (uidmap + slirp4netns are what rootless mode needs)"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg uidmap dbus-user-session slirp4netns >/dev/null

echo "== Docker apt key (checking the fingerprint before trusting it)"
install -d -m 0755 /etc/apt/keyrings
tmp=$(mktemp)
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmp"
got=$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
if [ "$got" != "$DOCKER_FPR" ]; then
    echo "   FINGERPRINT MISMATCH: got '$got', expected '$DOCKER_FPR'. Aborting."
    rm -f "$tmp"; exit 1
fi
install -m 0644 "$tmp" /etc/apt/keyrings/docker.asc; rm -f "$tmp"
echo "   fingerprint OK"

echo "== Docker apt source (pinned to that key)"
. /etc/os-release
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update -qq

echo "== Install Docker packages"
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
    docker-compose-plugin docker-ce-rootless-extras >/dev/null
dpkg-query -W -f='   ${Package} ${Version}\n' docker-ce docker-ce-rootless-extras docker-compose-plugin

echo "== Disable the rootful daemon"
systemctl disable --now docker.service docker.socket containerd.service >/dev/null 2>&1 || true
rm -f /var/run/docker.sock
echo "   docker.service: $(systemctl is-enabled docker.service 2>/dev/null || true)/$(systemctl is-active docker.service 2>/dev/null || true)"
echo "   docker group members: '$(getent group docker | cut -d: -f4)' (must be empty)"

echo "== AppArmor: rootlesskit needs unprivileged user namespaces"
# Ubuntu restricts them by default. Recent releases ship a rootlesskit profile that allows it;
# if yours doesn't, add a minimal one.
if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ]; then
    if grep -lqs 'rootlesskit' /etc/apparmor.d/* 2>/dev/null; then
        echo "   a rootlesskit profile already exists"
    else
        cat > /etc/apparmor.d/usr.bin.rootlesskit <<'EOF'
# agent-box: rootless Docker needs unprivileged user namespaces (restricted by default on Ubuntu).
abi <abi/4.0>,
include <tunables/global>

/usr/bin/rootlesskit flags=(unconfined) {
  userns,

  include if exists <local/usr.bin.rootlesskit>
}
EOF
        apparmor_parser -r /etc/apparmor.d/usr.bin.rootlesskit
        echo "   added and loaded a rootlesskit profile"
    fi
else
    echo "   userns not restricted: nothing to do"
fi

echo "== subuid/subgid ranges for $AGENT_USER (rootless maps container users into these)"
grep "^$AGENT_USER:" /etc/subuid /etc/subgid | sed 's/^/   /' \
    || { echo "   MISSING: add with 'usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $AGENT_USER'"; exit 1; }

echo "== Lingering: the user's services keep running with nobody logged in"
loginctl enable-linger "$AGENT_USER"
echo "   Linger=$(loginctl show-user "$AGENT_USER" -p Linger --value)"
