#!/usr/bin/env bash
# VM step 6 (as root): PostgreSQL from Ubuntu's archive, for Paperclip.
#
# Why not Paperclip's bundled ("embedded") PostgreSQL: Ubuntu's gets automatic security updates
# and normal maintenance, the bundled one depends on npm install scripts that npm 11 blocks
# (see docs/gotchas.md), and it ships old libraries.
#
# Hardening: no TCP listener at all (the database is reachable only through a Unix socket
# inside the VM), and the `agents` role is an ordinary role that owns one database. It is not
# a superuser and cannot create roles or databases. Authentication is "peer": Linux user
# `agents` is DB role `agents`, so there is no database password to leak.
set -euo pipefail

echo "== Install postgresql"
apt-get install -y -qq postgresql >/dev/null
PGVER=$(ls /etc/postgresql | sort -V | tail -1)
echo "   cluster version: $PGVER"

echo "== Socket only: listen_addresses = ''"
cat > "/etc/postgresql/$PGVER/main/conf.d/10-agent-box.conf" <<'EOF'
# agent-box: no TCP listener. Clients use the Unix socket in /var/run/postgresql only.
listen_addresses = ''
EOF
systemctl restart "postgresql@$PGVER-main"

echo "== Role and database"
if runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$AGENT_USER'" | grep -q 1; then
    echo "   role $AGENT_USER exists"
else
    runuser -u postgres -- createuser --no-superuser --no-createdb --no-createrole "$AGENT_USER"
    echo "   created role $AGENT_USER"
fi
if runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='paperclip'" | grep -q 1; then
    echo "   database paperclip exists"
else
    runuser -u postgres -- createdb --owner="$AGENT_USER" --encoding=UTF8 paperclip
    echo "   created database paperclip (owner $AGENT_USER)"
fi

echo "== Verify"
echo "   TCP listeners on 5432: $(ss -tlnH 'sport = :5432' | wc -l) (must be 0)"
echo "   connect as $AGENT_USER over the socket (peer auth, no password):"
runuser -u "$AGENT_USER" -- psql -h /var/run/postgresql -d paperclip -tAc \
    "SELECT 'user=' || current_user || ' db=' || current_database() || ' superuser=' || (SELECT rolsuper FROM pg_roles WHERE rolname=current_user)" \
    | sed 's/^/     /'
