#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"

if ! systemctl is-active --quiet slurmdbd || ! systemctl is-active --quiet slurmctld; then
  echo "slurmdbd and slurmctld must both be active." >&2
  exit 1
fi

JOB_ID=$(sbatch --parsable --account=default --chdir=/tmp --wrap=/bin/true | cut -d';' -f1)
echo "Submitted accounting check job $JOB_ID."
WAIT_SECONDS=${SLURM_ACCOUNTING_WAIT_SECONDS:-600}
POLL_SECONDS=5
ELAPSED=0
STATE=
while (( ELAPSED <= WAIT_SECONDS )); do
  STATE=$(sacct -M "$SLURM_CLUSTER_NAME" -nP -X -j "$JOB_ID" --format=State |
    head -n1 | tr -d '[:space:]')
  [[ "$STATE" == COMPLETED ]] && break
  sleep "$POLL_SECONDS"
  ELAPSED=$((ELAPSED + POLL_SECONDS))
done
if [[ "$STATE" != COMPLETED ]]; then
  echo "Job $JOB_ID did not reach COMPLETED within ${WAIT_SECONDS}s (last accounting state: ${STATE:-not recorded})." >&2
  squeue -j "$JOB_ID" -o '%.18i %.9T %.40R' >&2 || true
  scontrol show job "$JOB_ID" >&2 || true
  sacct -M "$SLURM_CLUSTER_NAME" -j "$JOB_ID" --format=JobID,State,ExitCode,Elapsed >&2 || true
  exit 1
fi
sacct -M "$SLURM_CLUSTER_NAME" -j "$JOB_ID" --format=JobID,State,ExitCode,Elapsed,AllocTRES
