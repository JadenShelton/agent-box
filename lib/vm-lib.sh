#!/usr/bin/env bash
# Prepended to every vm/*.sh script by bootstrap.sh before it runs inside the VM as root.
# (The config variables are exported just above this by bootstrap.sh.)

export DEBIAN_FRONTEND=noninteractive
AGENT_USER=agents

# as_agents: run a script (read from stdin) as the `agents` user, with the same environment a
# systemd user service sees: its own HOME and a live user session bus, so `systemctl --user`
# works (lingering keeps that session alive with nobody logged in).
#
# The script is written to a file first: some commands (apt, npm, docker) read stdin, and
# would otherwise swallow the rest of a script fed through `bash -s`.
as_agents() {
    local f aid
    aid=$(id -u "$AGENT_USER")
    f=$(mktemp /tmp/as-agents.XXXXXX)
    cat > "$f"
    chmod 644 "$f"
    (
        cd "/home/$AGENT_USER"
        runuser -u "$AGENT_USER" -- env \
            HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
            XDG_RUNTIME_DIR="/run/user/$aid" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$aid/bus" \
            bash "$f" < /dev/null
    )
    local rc=$?
    rm -f "$f"
    return $rc
}

# wait_user_session: block until the agents user's systemd session is up (needs lingering).
wait_user_session() {
    local aid
    aid=$(id -u "$AGENT_USER")
    loginctl enable-linger "$AGENT_USER"
    systemctl start "user@$aid.service"
    for _ in $(seq 1 30); do
        [ -S "/run/user/$aid/bus" ] && return 0
        sleep 1
    done
    echo "The user session bus for $AGENT_USER never appeared." >&2
    return 1
}
