#!/usr/bin/env bash
#SBATCH --job-name=gpu-throughput
#SBATCH --partition=compute
#SBATCH --time=00:02:00
#SBATCH --output=/cluster/results/gpu-throughput-%j.out
#SBATCH --chdir=/tmp
#SBATCH --export=ALL
set -euo pipefail
script=${CUDA_THROUGHPUT_SCRIPT:-/cluster/software/slurm-node-usb/cuda-driver-throughput.py}
test -r "$script" || { echo "Missing benchmark script: $script" >&2; exit 2; }
python3 "$script"
