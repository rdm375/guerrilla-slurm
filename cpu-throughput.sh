#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"
node=${1:?Usage: ./cpu-throughput.sh NODE [THREADS]}
case "$node" in
  dell7710) max_threads=8 ;;
  dell7680) max_threads=16 ;;
  *) echo "Unknown node: $node" >&2; exit 2 ;;
esac
threads=${2:-$max_threads}
[[ "$threads" =~ ^[1-9][0-9]*$ ]] && (( threads <= max_threads )) || { echo "THREADS must be 1-$max_threads for $node" >&2; exit 2; }
command -v sbatch >/dev/null || { echo "Run this on the Slurm controller." >&2; exit 2; }
install -d -m 2775 /cluster/results
job=$(sbatch --parsable --nodelist="$node" --cpus-per-task="$threads" "$ROOT/jobs/cpu-throughput.sbatch" | cut -d';' -f1)
echo "Submitted $threads-thread CPU throughput run on $node as job $job."
wait_seconds=${BENCHMARK_WAIT_SECONDS:-300}; elapsed=0; state=
while (( elapsed <= wait_seconds )); do
  state=$(sacct -M "$SLURM_CLUSTER_NAME" -nP -X -j "$job" --format=State | head -n1 | tr -d '[:space:]')
  [[ "$state" == COMPLETED || "$state" == FAILED || "$state" == CANCELLED || "$state" == TIMEOUT ]] && break
  sleep 3; elapsed=$((elapsed+3))
done
if [[ "$state" != COMPLETED ]]; then
  echo "CPU benchmark job $job ended in state ${state:-not recorded}." >&2
  scontrol show job "$job" >&2 || true
  exit 1
fi
cat "/cluster/results/cpu-throughput-$job.out"
sacct -M "$SLURM_CLUSTER_NAME" -j "$job" --format=JobID,State,ExitCode,Elapsed,AllocTRES
