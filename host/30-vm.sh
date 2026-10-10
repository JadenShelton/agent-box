#!/usr/bin/env bash
# Host step 3: create the VM, give it a fixed IP and a clean baseline snapshot.
#
# Safe to re-run: if a VM with this name exists, nothing is changed.
#
# Choices, and why:
#  * --vm (full virtual machine), not a container. Agents will run `docker compose`. Inside a
#    container that needs the host's Docker socket or privileged mode, which hands an agent
#    root on the host. In a VM, Docker runs inside and the VM is the boundary.
#  * Fixed IP via the NIC's ipv4.address (a dnsmasq reservation). The host needs a stable
#    address to forward the web UI to and to allow SSH from.
#  * boot.autostart=true: the VM comes back by itself after a host reboot or power cut.
#  * No host mounts, no virtiofs shares, no GPU/USB passthrough. Nothing from the host is
#    visible inside the VM. What you don't mount can't be read or encrypted by a rogue agent.
set -euo pipefail
# shellcheck source=../lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
require_root

if incus info "$VM_NAME" >/dev/null 2>&1; then
    echo "VM '$VM_NAME' already exists: leaving it alone."
    exit 0
fi

echo "== Creating $VM_NAME ($VM_IMAGE, $VM_CPU vCPU, $VM_MEMORY RAM, $VM_DISK disk)"
incus init "$VM_IMAGE" "$VM_NAME" --vm -d root,size="$VM_DISK"
incus config set "$VM_NAME" limits.cpu="$VM_CPU" limits.memory="$VM_MEMORY" boot.autostart=true
# The profile's eth0 comes from the default profile; 'override' gives this VM its own copy to pin the IP.
incus config device override "$VM_NAME" eth0 ipv4.address="$VM_IP"

echo "== Devices the VM will have (expect only eth0 and root)"
incus config show "$VM_NAME" --expanded | sed -n '/^devices:/,/^ephemeral:/p' | sed 's/^/   /'

echo "== First boot"
incus start "$VM_NAME"
echo -n "   waiting for the Incus guest agent "
for _ in $(seq 1 90); do
    incus exec "$VM_NAME" -- true >/dev/null 2>&1 && break
    echo -n "."; sleep 2
done
echo
incus exec "$VM_NAME" -- cloud-init status --wait

echo "== Baseline snapshot (taken stopped, so the disk image is clean)"
incus stop "$VM_NAME"
incus snapshot create "$VM_NAME" baseline-firstboot
incus start "$VM_NAME"
echo "   restore any time with: sudo incus snapshot restore $VM_NAME baseline-firstboot"
echo "== Done. VM address: $VM_IP"
