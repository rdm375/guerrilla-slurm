#!/usr/bin/env bash
#SBATCH --job-name=hailo-image
#SBATCH --partition=compute
#SBATCH --nodelist=dell7680
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:05:00
#SBATCH --gres=hailo10h:1
#SBATCH --chdir=/tmp
#SBATCH --output=/cluster/results/hailo-image-%j.out

set -euo pipefail
IMAGE=${1:?Pass an image path.}
HEF=${2:?Pass a Hailo-10H-compatible HEF file.}
LABELS=${3:?Pass the ImageNet labels file.}
PYTHON=/cluster/software/hailo10h/pyhailort-5.4.0-py313/bin/python
SCRIPT=/cluster/software/hailo10h/hailo-classify-image.py

[[ -r "$IMAGE" && -r "$HEF" && -r "$LABELS" ]] || {
  echo "Image, HEF, and labels must be readable on the compute node." >&2
  false
}
[[ -x "$PYTHON" ]] || { echo "PyHailoRT environment is missing: $PYTHON" >&2; false; }
[[ -e /dev/h1x-0 ]] || { echo "Allocated Hailo device /dev/h1x-0 is missing." >&2; false; }
exec "$PYTHON" "$SCRIPT" "$IMAGE" "$HEF" "$LABELS"
