#!/usr/bin/env bash
# VM step 2 (as root): the `agents` user. Paperclip and every agent run as this one account.
#
# Non-admin: no sudo, no password (locked), key-only SSH. Everything agents install goes in
# their own home (nvm, npm -g, rootless Docker), so they never need root.
#
# Heads-up: Paperclip's local adapters run every agent as the SAME OS user as Paperclip, so
# agents share this home directory, its files and its credentials. There's no isolation
# between agents. The VM is the boundary, not the user. See the README's threat model.
#
# Expects bootstrap.sh to have pushed your public key to /root/agents.pub.
set -euo pipefail
KEY=/root/agents.pub
[ -f "$KEY" ] || { echo "Missing $KEY: bootstrap.sh pushes AGENTS_PUBKEY_FILE there. Does the file exist?"; exit 1; }

echo "== Key to install"
ssh-keygen -l -f "$KEY"

if id "$AGENT_USER" >/dev/null 2>&1; then
    echo "== User '$AGENT_USER' already exists, leaving it as is"
else
    echo "== Creating user '$AGENT_USER' (own group only, no sudo, no password)"
    useradd --create-home --shell /bin/bash --user-group "$AGENT_USER"
fi
chmod 750 "/home/$AGENT_USER"

echo "== Installing authorized_keys"
install -d -m 700 -o "$AGENT_USER" -g "$AGENT_USER" "/home/$AGENT_USER/.ssh"
install -m 600 -o "$AGENT_USER" -g "$AGENT_USER" "$KEY" "/home/$AGENT_USER/.ssh/authorized_keys"
rm -f "$KEY"

echo "== Verify"
id "$AGENT_USER"
echo "   password state: $(passwd -S "$AGENT_USER" | awk '{print $2}')   (L = locked: no password login possible)"
echo "   sudo group members: '$(getent group sudo | cut -d: -f4)' (must not include $AGENT_USER)"
