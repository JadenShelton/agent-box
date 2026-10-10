#!/usr/bin/env bash
# VM step 5 (as `agents`): Node.js through nvm, installed in the agents' home.
#
# Why nvm and not apt/NodeSource: agents (and Paperclip) can `npm i -g` their own CLIs without
# root. Trade-off: nvm's Node gets no automatic security updates. Update it deliberately, and
# re-run `./bootstrap.sh vm` step 60 afterwards, because the launcher hardcodes Node's path.
#
# The installer is downloaded to a file from a pinned release tag, not piped from `master`
# into a shell.
set -euo pipefail

as_agents <<EOF
set -euo pipefail
export NVM_DIR="\$HOME/.nvm"
if [ ! -s "\$NVM_DIR/nvm.sh" ]; then
    curl -fsSL -o "\$HOME/nvm-install.sh" "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh"
    PROFILE=/dev/null bash "\$HOME/nvm-install.sh"   # PROFILE=/dev/null: we edit shell files ourselves
    rm -f "\$HOME/nvm-install.sh"
fi
. "\$NVM_DIR/nvm.sh"
nvm install "$NODE_MAJOR"      # nvm verifies the download checksum
nvm alias default "$NODE_MAJOR" >/dev/null
echo "   node \$(node -v), npm \$(npm -v)"
node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>24||(a===24&&b>=11)?0:1)' \
    || { echo "Paperclip needs Node >= 24.11"; exit 1; }
EOF
