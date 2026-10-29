#!/usr/bin/env bash
#SBATCH --job-name=hailo-inference
#SBATCH --partition=compute
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:10:00
#SBATCH --gres=hailo10h:1
#SBATCH --chdir=/cluster/projects
#SBATCH --output=/cluster/results/hailo-%j.out

set -euo pipefail
KIT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec "$KIT_DIR/hailo-infer.sh" "$@"
