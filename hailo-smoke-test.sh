#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"

MODEL_DIR=${HAILO_MODEL_DIR:-/cluster/software/hailo10h}
HEF="$MODEL_DIR/efficientnet_lite0.hef"
HEF_URL=https://hailo-model-zoo.s3.eu-west-2.amazonaws.com/ModelZoo/Compiled/v5.4.0/hailo10h/efficientnet_lite0.hef
LOG_DIR=/cluster/results

command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
command -v sbatch >/dev/null || { echo "Run this on the Slurm controller." >&2; exit 1; }
install -d -m 2775 "$MODEL_DIR" "$LOG_DIR"

if [[ ! -s "$HEF" ]]; then
  echo "Downloading the Hailo Model Zoo v5.4.0 Hailo-10H EfficientNet-Lite0 HEF..."
  curl -fL --retry 3 "$HEF_URL" -o "$HEF.tmp"
  mv "$HEF.tmp" "$HEF"
fi

JOB_ID=$(sbatch --parsable "$ROOT/jobs/hailo-smoke-test.sbatch" "$HEF" | cut -d';' -f1)
echo "Submitted Hailo-10H inference benchmark as job $JOB_ID."

WAIT_SECONDS=${HAILO_SMOKE_WAIT_SECONDS:-600}
POLL_SECONDS=5
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
  echo "Hailo test job $JOB_ID ended in state ${STATE:-not recorded}." >&2
  squeue -j "$JOB_ID" -o '%.18i %.9T %.40R' >&2 || true
  scontrol show job "$JOB_ID" >&2 || true
  sacct -M "$SLURM_CLUSTER_NAME" -j "$JOB_ID" --format=JobID,State,ExitCode,Elapsed >&2 || true
  exit 1
fi

cat "$LOG_DIR/hailo-smoke-$JOB_ID.out"
sacct -M "$SLURM_CLUSTER_NAME" -j "$JOB_ID" --format=JobID,State,ExitCode,Elapsed
