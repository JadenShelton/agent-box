#!/usr/bin/env bash
# Sourced by bootstrap.sh and the host/ scripts. Loads the defaults, then your overrides.
# shellcheck disable=SC2034  # variables are used by the scripts that source this file

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Under sudo, $HOME can be /root. Settings that point at your files use USER_HOME instead.
if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    USER_HOME="$HOME"
fi
export USER_HOME

# `set -a` exports everything we source, so child processes see the settings too.
set -a
# shellcheck disable=SC1091
. "$ROOT/config.example.env"
# shellcheck disable=SC1091
[ -f "$ROOT/config.env" ] && . "$ROOT/config.env"
set +a

# Derived values.
BRIDGE_IP="${BRIDGE_SUBNET%/*}"
if [ -z "${UPLINK:-}" ]; then
    UPLINK="$(ip -4 route show default | awk '/^default/ {print $5; exit}')"
fi
[ -n "$UPLINK" ] || { echo "Could not detect the uplink interface. Set UPLINK in config.env." >&2; exit 1; }
export BRIDGE_IP UPLINK

require_root() {
    [ "$(id -u)" -eq 0 ] || { echo "This step needs root. Run it with sudo." >&2; exit 1; }
}
