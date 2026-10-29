#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"

echo "=== dell7680 after-boot health ==="
ssh -o BatchMode=yes "${USER}@${SLURM_COMPUTE_IP}" \
  "test \"\$(hostname -s)\" = dell7680 && ip -4 -o address show | grep -F '${SLURM_COMPUTE_IP}/' && systemctl is-active munge slurmd && nvidia-smi -L && hailortcli scan"
echo
echo "=== Slurm nodes and configured resources ==="
sinfo -N -o '%N %t %G'
echo
echo "=== CPU task on dell7680 ==="
timeout --kill-after=5s 45s srun --immediate=10 --chdir=/tmp \
  -N1 -n1 -w dell7680 hostname
echo
echo "=== Shared storage task on dell7680 ==="
timeout --kill-after=5s 45s srun --immediate=10 \
  -N1 -n1 -w dell7680 --chdir=/cluster/projects pwd
echo
echo "=== Shared storage write/read round trip ==="
TOKEN="nfs-check-$(date +%s)-$$"
TEST_FILE="/cluster/projects/.slurm-nfs-check-$(date +%s)-$$"
cleanup() { rm -f "$TEST_FILE"; }
trap cleanup EXIT
timeout --kill-after=5s 45s srun --immediate=10 --chdir=/cluster/projects \
  -N1 -n1 -w dell7680 bash -c 'printf "%s" "$1" > "$2"' _ "$TOKEN" "$TEST_FILE"
[[ "$(cat "$TEST_FILE")" == "$TOKEN" ]] || {
  echo "NFS write/read check failed: worker write was not visible on controller." >&2
  exit 1
}
echo "Worker-created file was readable on the controller."
cleanup
trap - EXIT
echo
echo "=== RTX 4090 task on dell7680 ==="
timeout --kill-after=5s 45s srun --immediate=10 --chdir=/tmp \
  -N1 -n1 -w dell7680 --gres=gpu:rtx_4090:1 nvidia-smi -L
echo
echo "=== Hailo-10H task on dell7680 ==="
timeout --kill-after=5s 45s srun --immediate=10 --chdir=/tmp \
  -N1 -n1 -w dell7680 --gres=hailo10h:1 hailortcli scan
