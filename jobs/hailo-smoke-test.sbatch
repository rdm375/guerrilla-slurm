#!/usr/bin/env bash
#SBATCH --job-name=hailo-smoke
#SBATCH --partition=compute
#SBATCH --nodelist=dell7680
#SBATCH --gres=hailo10h:1
#SBATCH --time=00:05:00
#SBATCH --chdir=/cluster/software/hailo10h
#SBATCH --output=/cluster/results/hailo-smoke-%j.out

set -euo pipefail
HEF=${1:?Pass a Hailo-10H-compatible HEF file.}
[[ -r "$HEF" ]] || { echo "HEF is not readable: $HEF" >&2; exit 1; }
[[ -e /dev/h1x-0 ]] || { echo "Allocated Hailo device /dev/h1x-0 is missing." >&2; exit 1; }

# Keep HailoRT's optional log in writable local scratch, not the shared tree.
RUN_DIR=$(mktemp -d "/tmp/hailo-smoke-${SLURM_JOB_ID}.XXXXXX")
cd "$RUN_DIR"
echo "Hailo-10H inference benchmark"
echo "Node: $(hostname -s)"
echo "HEF: $HEF"
hailortcli benchmark "$HEF" --time-to-run 10
