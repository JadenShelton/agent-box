#!/usr/bin/env bash
# Host step 1: install Incus (the hypervisor) and create its storage pool and bridge.
#
# Why Incus: it runs full VMs (QEMU/KVM) and system containers behind one small CLI, and it is
# packaged in Ubuntu's own archive, so it gets normal security updates.
#
# Why a btrfs loop file: btrfs gives copy-on-write snapshots (take one before each experiment,
# roll back instead of repairing). A sparse file on the existing filesystem works even when the
# whole disk is already allocated to one LVM volume. It can be grown later but never shrunk.
#
# Why IPv6 off on the bridge: most home LANs have no global IPv6, and every IPv6 path would
# need its own egress rules. Off means one less thing to get wrong.
#
# Deliberately NOT done: adding you to the `incus-admin` group. That group is root-equivalent
# (it can create a privileged VM mounting the host's /). Use `sudo incus ...` instead.
set -euo pipefail
# shellcheck source=../lib/config.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/config.sh"
require_root

echo "== Hardware virtualization"
if grep -qE '(vmx|svm)' /proc/cpuinfo && [ -e /dev/kvm ]; then
    echo "   KVM available"
else
    echo "   /dev/kvm is missing: enable virtualization (VT-x / AMD-V / SVM) in the BIOS. Aborting."
    exit 1
fi

echo "== Installing Incus"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq incus btrfs-progs >/dev/null
echo "   $(incus --version)"
incus info 2>/dev/null | grep -qi 'qemu' \
    || echo "   WARNING: no QEMU driver listed by 'incus info'. VMs need it: apt install qemu-system-x86"

echo "== Storage pool and bridge"
if incus network show "$BRIDGE" >/dev/null 2>&1 || incus storage show default >/dev/null 2>&1; then
    echo "   Incus already has '$BRIDGE' or a 'default' pool: leaving the existing setup alone."
    echo "   (Check it matches your config.env: 'incus network show $BRIDGE', 'incus storage show default')"
else
    incus admin init --preseed <<EOF
networks:
- name: $BRIDGE
  type: bridge
  config:
    ipv4.address: $BRIDGE_SUBNET
    ipv4.nat: "true"
    ipv6.address: none
storage_pools:
- name: default
  driver: btrfs
  config:
    size: $STORAGE_POOL_SIZE
profiles:
- name: default
  devices:
    eth0:
      name: eth0
      network: $BRIDGE
      type: nic
    root:
      path: /
      pool: default
      type: disk
EOF
    echo "   created pool 'default' ($STORAGE_POOL_SIZE) and bridge '$BRIDGE' ($BRIDGE_SUBNET)"
fi

echo "== Result"
incus network list --format csv -c n,4,6 | grep "^$BRIDGE," | sed 's/^/   /' || true
incus storage list --format csv -c n,d,s | sed 's/^/   /' || true
