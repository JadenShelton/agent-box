#!/usr/bin/env bash
# VM step 8 (as `agents`): install and start Paperclip as a systemd USER service.
#
# Run this only AFTER onboarding (`./bootstrap.sh onboard`), which creates Paperclip's config.
# The service starts at boot because lingering is on, and restarts itself if it crashes.
set -euo pipefail

wait_user_session

as_agents <<EOF
set -euo pipefail
. "\$HOME/.agent-box-env"
systemctl --user reset-failed paperclipai 2>/dev/null || true
paperclipai service install
sleep 3
echo "== Service"
systemctl --user is-active paperclipai | sed 's/^/   state: /'
echo "== Health (any HTTP answer means the server is up; 403 is the hostname allowlist doing its job)"
for _ in \$(seq 1 30); do
    code=\$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PAPERCLIP_PORT/api/health" || true)
    [ "\$code" != "000" ] && { echo "   /api/health -> HTTP \$code"; break; }
    sleep 2
done
echo "   logs: journalctl --user -u paperclipai   (as the agents user)"
EOF
