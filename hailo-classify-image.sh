#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"

IMAGE=${1:?Usage: ./hailo-classify-image.sh IMAGE [HEF]}
MODEL_DIR=${HAILO_MODEL_DIR:-/cluster/software/hailo10h}
HEF=${2:-$MODEL_DIR/efficientnet_lite0.hef}
LABELS=$MODEL_DIR/imagenet_classes.txt
VENV=$MODEL_DIR/pyhailort-5.4.0-py313
HAILORT_SOURCE=/usr/local/src/hailo-5.4.0/hailort

[[ -r "$IMAGE" ]] || { echo "Image is not readable: $IMAGE" >&2; false; }
[[ -r "$HEF" ]] || { echo "HEF is not readable: $HEF" >&2; false; }
command -v ssh >/dev/null || { echo "ssh is required." >&2; false; }
command -v sbatch >/dev/null || { echo "Run this on the Slurm controller." >&2; false; }
command -v curl >/dev/null || { echo "curl is required." >&2; false; }

install -d -m 2775 "$MODEL_DIR" /cluster/results
if [[ ! -s "$LABELS" ]]; then
  curl -fL --retry 3 \
    https://raw.githubusercontent.com/pytorch/hub/master/imagenet_classes.txt \
    -o "$LABELS.tmp"
  mv "$LABELS.tmp" "$LABELS"
fi
install -m 0644 "$ROOT/jobs/hailo-classify-image.py" \
  "$MODEL_DIR/hailo-classify-image.py"

echo "Preparing PyHailoRT 5.4.0 for the Debian 13 compute node..."
ssh "$(id -un)@$SLURM_COMPUTE_IP" 'bash -s' <<REMOTE
set -euo pipefail
model_dir='$MODEL_DIR'
venv="$VENV"
source_dir='$HAILORT_SOURCE/libhailort/bindings/python/platform'
if ! python3 -c 'import pathlib, sysconfig; raise SystemExit(0 if (pathlib.Path(sysconfig.get_path("include")) / "Python.h").is_file() else 1)'; then
  echo "Python development headers are missing. Run: sudo apt-get install -y python3-dev" >&2
  false
fi
if [[ ! -x "\$venv/bin/python" ]]; then
  python3 -m venv "\$venv"
fi
"\$venv/bin/python" -m pip install --upgrade pip
"\$venv/bin/python" -m pip install pillow numpy
if ! "\$venv/bin/python" -c 'import hailo_platform' >/dev/null 2>&1; then
  if [[ ! -s "\$source_dir/pyproject.toml" ]]; then
    source_root="\$HOME/.cache/hailort-source-5.4.0"
    if [[ ! -s "\$source_root/hailort/libhailort/bindings/python/platform/pyproject.toml" ]]; then
      mkdir -p "\$HOME/.cache"
      git clone --depth 1 --branch v5.4.0 https://github.com/hailo-ai/hailort.git "\$source_root"
    fi
    source_dir="\$source_root/hailort/libhailort/bindings/python/platform"
  fi
  "\$venv/bin/python" -m pip install "\$source_dir"
fi
"\$venv/bin/python" -c 'import hailo_platform, numpy, PIL; print("PyHailoRT", hailo_platform.__file__); print("NumPy", numpy.__version__)'
REMOTE

JOB_ID=$(sg hailo -c "sbatch --parsable '$ROOT/jobs/hailo-classify-image.sbatch' '$IMAGE' '$HEF' '$LABELS'" | cut -d';' -f1)
echo "Submitted image classification as job $JOB_ID."

WAIT_SECONDS=${HAILO_INFER_WAIT_SECONDS:-600}
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

cat "/cluster/results/hailo-image-$JOB_ID.out" 2>/dev/null || true
sacct -M "$SLURM_CLUSTER_NAME" -j "$JOB_ID" --format=JobID,State,ExitCode,Elapsed
if [[ "$STATE" != COMPLETED ]]; then
  echo "Image inference job $JOB_ID ended in state ${STATE:-not recorded}." >&2
  squeue -j "$JOB_ID" -o '%.18i %.9T %.40R' >&2 || true
  scontrol show job "$JOB_ID" >&2 || true
  false
fi
