#!/usr/bin/env bash
# agent-box driver. Run it on the HOST machine, as root (sudo).
#
#   sudo ./bootstrap.sh host            # Incus + firewall rules + the VM
#   sudo ./bootstrap.sh vm              # provision everything inside the VM
#   sudo ./bootstrap.sh onboard         # interactive Paperclip setup (answers are in the README)
#   sudo ./bootstrap.sh service         # install + start the Paperclip service
#   sudo ./bootstrap.sh expose          # (optional) publish the UI on your tailnet
#   sudo ./bootstrap.sh verify          # prove the egress firewall works
#
# More: firewall (dry-run preview), audit, paperclip <args>, shell, snapshot <name>, ssh-config.
# Run `./bootstrap.sh help` for the full list. Settings live in config.env (see config.example.env).
set -euo pipefail
# shellcheck source=lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/config.sh"

usage() { sed -n '2,/^set -e/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# vm_run <script> [args]: run a script from vm/ or verify/ inside the VM, as root. The config
# values are exported at the top of the script, followed by lib/vm-lib.sh (helper functions).
vm_run() {
    local script="$1" tmp
    tmp=$(mktemp)
    {
        echo '#!/usr/bin/env bash'
        for v in VM_NAME BRIDGE_IP PAPERCLIP_PORT PAPERCLIP_VERSION NVM_VERSION NODE_MAJOR \
                 HOST_LAN_IP HOST_TAILNET_IP VERIFY_BLOCKED; do
            printf 'export %s=%q\n' "$v" "${!v:-}"
        done
        cat "$ROOT/lib/vm-lib.sh"
        cat "$script"
    } > "$tmp"
    incus file push "$tmp" "$VM_NAME/root/agent-box-run.sh" >/dev/null
    rm -f "$tmp"
    local rc=0
    incus exec "$VM_NAME" -- bash /root/agent-box-run.sh || rc=$?
    incus exec "$VM_NAME" -- rm -f /root/agent-box-run.sh
    return $rc
}

# in_vm_as_agents <command...>: run a command in the VM as the agents user, with its environment.
in_vm_as_agents() {
    incus exec "$VM_NAME" -- runuser -u agents -- bash -c '
        export HOME=/home/agents XDG_RUNTIME_DIR=/run/user/$(id -u)
        export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
        cd ~ && . ~/.agent-box-env
        exec "$@"' bash "$@"
}

detect_host_addresses() {
    HOST_LAN_IP=$(ip -4 -o addr show dev "$UPLINK" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
    HOST_TAILNET_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
    export HOST_LAN_IP HOST_TAILNET_IP
}

cmd="${1:-help}"; shift || true

case "$cmd" in
    help|-h|--help) usage; exit 0 ;;
esac
require_root

case "$cmd" in
    host)
        "$ROOT/host/10-incus.sh"
        "$ROOT/host/20-firewall.sh" apply
        "$ROOT/host/30-vm.sh"
        ;;
    firewall)
        "$ROOT/host/20-firewall.sh" "$@"     # no argument = dry run
        ;;
    vm)
        incus info "$VM_NAME" >/dev/null 2>&1 || { echo "VM '$VM_NAME' doesn't exist. Run: sudo ./bootstrap.sh host"; exit 1; }
        [ -f "$AGENTS_PUBKEY_FILE" ] || { echo "Public key not found: $AGENTS_PUBKEY_FILE (see AGENTS_PUBKEY_FILE in config.example.env)"; exit 1; }
        incus file push "$AGENTS_PUBKEY_FILE" "$VM_NAME/root/agents.pub" >/dev/null
        only="${1:-}"      # optional: run a single step, e.g. `./bootstrap.sh vm 60`
        for s in "$ROOT"/vm/*.sh; do
            name=$(basename "$s")
            [ -z "$only" ] || [[ "$name" == "$only"* ]] || continue
            [ "$name" = "70-service.sh" ] && continue     # runs after onboarding, via `service`
            echo; echo "################ $name"
            vm_run "$s"
        done
        echo
        echo "VM provisioned. Next: take a snapshot, then onboard Paperclip:"
        echo "  sudo ./bootstrap.sh snapshot provisioned"
        echo "  sudo ./bootstrap.sh onboard"
        ;;
    onboard)
        in_vm_as_agents paperclipai onboard --no-install-service
        ;;
    service)
        vm_run "$ROOT/vm/70-service.sh"
        ;;
    expose)
        "$ROOT/host/40-tailscale-serve.sh"
        ;;
    verify)
        detect_host_addresses
        vm_run "$ROOT/verify/egress-check.sh"
        ;;
    audit)
        vm_run "$ROOT/verify/vm-audit.sh"
        ;;
    paperclip)
        in_vm_as_agents paperclipai "$@"
        ;;
    shell)
        exec incus exec "$VM_NAME" -- bash -l
        ;;
    snapshot)
        name="${1:?usage: ./bootstrap.sh snapshot <name>}"
        echo "Stopping $VM_NAME for a clean snapshot, then starting it again."
        incus stop "$VM_NAME"
        incus snapshot create "$VM_NAME" "$name"
        incus start "$VM_NAME"
        incus snapshot list "$VM_NAME"
        ;;
    ssh-config)
        # Prints the block for your WORKSTATION's ~/.ssh/config (nothing is changed here).
        cat <<EOF
Host agent-box
    HostName $VM_IP
    User agents
    ProxyJump ${SUDO_USER:-you}@$(hostname)
    IdentityFile ~/.ssh/agent_box_agents
    IdentitiesOnly yes
    ForwardAgent no
EOF
        ;;
    *)
        echo "Unknown command: $cmd"; usage; exit 1 ;;
esac
