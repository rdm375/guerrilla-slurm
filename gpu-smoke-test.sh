#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"

command -v sbatch >/dev/null || { echo "Run this on the Slurm controller." >&2; false; }
install -d -m 2775 /cluster/results

JOB_ID=$(sbatch --parsable "$ROOT/jobs/gpu-smoke-test.sbatch" | cut -d';' -f1)
echo "Submitted RTX 4090 Slurm GPU smoke test as job $JOB_ID."

WAIT_SECONDS=${GPU_SMOKE_WAIT_SECONDS:-180}
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
  echo "GPU smoke job $JOB_ID ended in state ${STATE:-not recorded}." >&2
  squeue -j "$JOB_ID" -o '%.18i %.9T %.40R' >&2 || true
  scontrol show job "$JOB_ID" >&2 || true
  sacct -M "$SLURM_CLUSTER_NAME" -j "$JOB_ID" --format=JobID,State,ExitCode,Elapsed >&2 || true
  false
fi

cat "/cluster/results/gpu-smoke-$JOB_ID.out"
sacct -M "$SLURM_CLUSTER_NAME" -j "$JOB_ID" --format=JobID,State,ExitCode,Elapsed,AllocTRES
