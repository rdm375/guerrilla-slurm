#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"

CPUS=${1:-8}
[[ "$CPUS" =~ ^[0-9]+$ ]] || { echo "Usage: $0 [CPUS, 2-16]" >&2; false; }
(( CPUS >= 2 && CPUS <= 16 )) || { echo "Choose 2 through 16 CPUs for dell7680." >&2; false; }
command -v sbatch >/dev/null || { echo "Run this on the Slurm controller." >&2; false; }
install -d -m 2775 /cluster/results

JOB_ID=$(sbatch --parsable --cpus-per-task="$CPUS" \
  "$ROOT/jobs/cpu-multithread-smoke.sbatch" | cut -d';' -f1)
echo "Submitted $CPUS-thread CPU smoke test as job $JOB_ID."

WAIT_SECONDS=${CPU_SMOKE_WAIT_SECONDS:-180}
POLL_SECONDS=3
ELAPSED=0
STATE=
while (( ELAPSED <= WAIT_SECONDS )); do
  STATE=$(sacct -M "$SLURM_CLUSTER_NAME" -nP -X -j "$JOB_ID" --format=State |
    head -n1 | tr -d '[:space:]')
  [[ "$STATE" == COMPLETED || "$STATE" == FAILED || "$STATE" == CANCELLED || "$STATE" == TIMEOUT ]] && break
  sleep "$POLL_SECONDS"
  ELAPSED=$((ELAPSED + POLL_SECONDS))
done

if [[ "$STATE" != COMPLETED ]]; then
  echo "CPU smoke job $JOB_ID ended in state ${STATE:-not recorded}." >&2
  squeue -j "$JOB_ID" -o '%.18i %.9T %.40R' >&2 || true
  scontrol show job "$JOB_ID" >&2 || true
  sacct -M "$SLURM_CLUSTER_NAME" -j "$JOB_ID" --format=JobID,State,ExitCode,Elapsed >&2 || true
  false
fi

cat "/cluster/results/cpu-smoke-$JOB_ID.out"
sacct -M "$SLURM_CLUSTER_NAME" -j "$JOB_ID" --format=JobID,State,ExitCode,Elapsed,AllocTRES
