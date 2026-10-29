#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"
node=${1:?Usage: ./gpu-throughput.sh NODE}
case "$node" in
  dell7710) gres=gpu:quadro_m3000m:1 ;;
  dell7680) gres=gpu:rtx_4090:1 ;;
  *) echo "Unknown GPU node: $node" >&2; exit 2 ;;
esac
command -v sbatch >/dev/null || { echo "Run this on the Slurm controller." >&2; exit 2; }
install -d -m 2775 /cluster/results /cluster/software/slurm-node-usb
install -m 0644 "$ROOT/jobs/cuda-driver-throughput.py" /cluster/software/slurm-node-usb/cuda-driver-throughput.py
job=$(sbatch --parsable --nodelist="$node" --gres="$gres" "$ROOT/jobs/gpu-throughput.sbatch" | cut -d';' -f1)
echo "Submitted CUDA FP32 and memory-bandwidth run on $node as job $job."
wait_seconds=${BENCHMARK_WAIT_SECONDS:-300}; elapsed=0; state=
while (( elapsed <= wait_seconds )); do
  state=$(sacct -M "$SLURM_CLUSTER_NAME" -nP -X -j "$job" --format=State | head -n1 | tr -d '[:space:]')
  [[ "$state" == COMPLETED || "$state" == FAILED || "$state" == CANCELLED || "$state" == TIMEOUT ]] && break
  sleep 3; elapsed=$((elapsed+3))
done
if [[ "$state" != COMPLETED ]]; then
  echo "GPU benchmark job $job ended in state ${state:-not recorded}." >&2
  sacct -M "$SLURM_CLUSTER_NAME" -j "$job" --format=JobID,State,ExitCode,Elapsed >&2 || true
  scontrol show job "$job" >&2 || true
  exit 1
fi
cat "/cluster/results/gpu-throughput-$job.out"
sacct -M "$SLURM_CLUSTER_NAME" -j "$job" --format=JobID,State,ExitCode,Elapsed,AllocTRES
