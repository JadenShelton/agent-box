#!/usr/bin/env bash
# VM step 7 (as `agents`): install Paperclip and Claude Code, a launcher, and the service environment.
#
# Why `npm install -g` and a hand-made launcher instead of `paperclipai install`:
# `paperclipai install` is broken with npm 11 (it can't parse npm's JSON array response for
# `npm view`, and aborts with "npm returned an unexpected version response"). So we install
# the pinned version with npm, then write the same kind of launcher that Paperclip's managed
# installer would. See docs/gotchas.md for the details, including WHERE the launcher must NOT go.
#
# Run this step again after upgrading Node or Paperclip: the launcher hardcodes both paths.
set -euo pipefail

as_agents <<EOF
set -euo pipefail

# ---- environment shared by interactive shells, SSH commands and the bootstrap helpers ----
ENVFILE="\$HOME/.agent-box-env"
cat > "\$ENVFILE" <<'ENVEOF'
# agent-box: loaded at the top of ~/.bashrc, so it applies to non-interactive SSH commands too.
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh" >/dev/null
# Paperclip's database driver takes the socket directory from PGHOST (a ?host= in the URL is ignored).
export PGHOST=/var/run/postgresql
# Where our launcher lives (official override; see docs/gotchas.md).
export PAPERCLIP_SHIM_PATH="\$HOME/.local/libexec/paperclipai-launcher"
# Telemetry off: both switches Paperclip checks, plus Claude Code's.
export PAPERCLIP_TELEMETRY_DISABLED=1 DO_NOT_TRACK=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1
ENVEOF
grep -qF 'agent-box-env' "\$HOME/.bashrc" || sed -i '1i [ -f "\$HOME/.agent-box-env" ] \&\& . "\$HOME/.agent-box-env"  # agent-box' "\$HOME/.bashrc"
. "\$ENVFILE"

# ---- install ----
# npm 11 blocks dependency install scripts by default. That is what we want here: the packages
# affected are optional native speed-ups and the embedded database we don't use. Don't set
# allow-scripts globally.
npm install -g "paperclipai@$PAPERCLIP_VERSION" @anthropic-ai/claude-code
echo "   paperclipai \$(paperclipai --version), claude \$(claude --version)"

# ---- launcher ----
LAUNCHER="\$PAPERCLIP_SHIM_PATH"
NODE=\$(command -v node)
ENTRY="\$(npm root -g)/paperclipai/dist/index.js"
[ -f "\$ENTRY" ] || { echo "Paperclip entrypoint not found at \$ENTRY"; exit 1; }
mkdir -p "\$(dirname "\$LAUNCHER")"
cat > "\$LAUNCHER" <<LAUNCHEOF
#!/bin/sh
# agent-box: hand-made equivalent of Paperclip's managed shim (absolute node path + node's dir
# first on PATH, so systemd finds node and the nvm-installed 'claude' without a login shell).
export PATH="\$(dirname "\$NODE")":"\\\${PATH:-/usr/local/bin:/usr/bin:/bin}"
exec "\$NODE" "\$ENTRY" "\\\$@"
LAUNCHEOF
chmod 755 "\$LAUNCHER"
echo "   launcher: \$LAUNCHER"
# It must work with the minimal environment systemd gives a service.
env -i HOME="\$HOME" PATH=/usr/bin:/bin "\$LAUNCHER" --version | sed 's/^/   launcher check: /'

# ---- systemd drop-in: our environment, kept apart from the generated unit ----
# 'paperclipai service install' (re)writes paperclipai.service. A drop-in survives that.
D="\$HOME/.config/systemd/user/paperclipai.service.d"
mkdir -p "\$D"
cat > "\$D/10-agent-box.conf" <<'DROPEOF'
[Service]
# The doctor check inside 'paperclipai run' must see the same launcher path the unit was generated with.
Environment=PAPERCLIP_SHIM_PATH=%h/.local/libexec/paperclipai-launcher
Environment=PGHOST=/var/run/postgresql
# Agents run on this machine and call Paperclip back at PAPERCLIP_API_URL. Left unset, Paperclip
# derives it from the first allowed hostname (your tailnet name), which the VM can't reach by
# design. Loopback is always accepted by the hostname guard. See docs/gotchas.md.
Environment=PAPERCLIP_API_URL=http://127.0.0.1:$PAPERCLIP_PORT
Environment=PAPERCLIP_TELEMETRY_DISABLED=1
Environment=DO_NOT_TRACK=1
# Inherited by the agent CLIs Paperclip launches. Auto-updates for Claude Code stay ON here;
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC would switch the updater off as well.
Environment=DISABLE_TELEMETRY=1
Environment=DISABLE_ERROR_REPORTING=1
DROPEOF
systemctl --user daemon-reload
echo "   wrote \$D/10-agent-box.conf"
EOF
