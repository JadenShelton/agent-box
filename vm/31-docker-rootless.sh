#!/usr/bin/env bash
# VM step 4 (as root, then as `agents`): set up the rootless Docker daemon for the agents user.
set -euo pipefail

wait_user_session

as_agents <<'EOF'
set -euo pipefail
dockerd-rootless-setuptool.sh install
systemctl --user enable --now docker
docker context use rootless >/dev/null
echo "== Rootless daemon check"
docker info --format '   security options: {{.SecurityOptions}}'
docker run --rm hello-world | sed -n '2p' | sed 's/^/   /'
docker compose version | sed 's/^/   /'
EOF
