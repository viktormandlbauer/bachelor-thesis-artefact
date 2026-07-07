#!/usr/bin/env bash
#
# Creates (or reuses) the multipass VM "case-engines" that hosts the two
# single-host platforms of the SRQ3 comparison (docker compose and podman
# kube play), with the SAME allocation as the k3s VM (scripts/vm-up.sh:
# 4 CPUs / 8G / 40G, Ubuntu 24.04) so platform is the only variable.
#
#   bash measure/engines-vm-up.sh
#
# NOTE the 16 GiB host cannot run both 8 GiB VMs at once; the measurement
# scripts stop the other VM before starting (measure/lib/common.sh
# ensure_only_vm), which also keeps the hypervisor free of background load.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY="${VM_MEMORY:-8G}"
VM_DISK="${VM_DISK:-40G}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-24.04}"

command -v multipass >/dev/null || die "multipass not found"

ensure_only_vm "$ENGINES_VM" || true

if ! mp info "$ENGINES_VM" >/dev/null 2>&1; then
  say "Launching multipass VM '$ENGINES_VM' (Ubuntu $UBUNTU_IMAGE, $VM_CPUS CPUs, $VM_MEMORY RAM, $VM_DISK disk)"
  mp launch "$UBUNTU_IMAGE" --name "$ENGINES_VM" \
    --cpus "$VM_CPUS" --memory "$VM_MEMORY" --disk "$VM_DISK" \
    --timeout 900
else
  say "VM '$ENGINES_VM' already exists; reusing"
  mp start "$ENGINES_VM"
fi

if ! mp info "$ENGINES_VM" --format json | grep -q '"/repo"'; then
  say "Mounting repo at $ENGINES_VM:/repo"
  mp mount "$(host_path "$REPO_DIR")" "$ENGINES_VM:/repo"
fi

say "Provisioning (docker + compose v2 + podman + sysstat)"
mp exec "$ENGINES_VM" -- sudo bash /repo/measure/vm/provision-engines.sh

say "Done. VM IP: $(vm_ip "$ENGINES_VM")"
echo "Next: bash measure/images-load.sh"
