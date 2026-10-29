#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 MODEL.hef PREPROCESSED_INPUT.bin" >&2
  exit 2
fi
[[ -n ${SLURM_JOB_ID:-} ]] || {
  echo "Run this through Slurm with --gres=hailo10h:1." >&2
  exit 2
}
HEF=$(realpath -e -- "$1")
INPUT=$(realpath -e -- "$2")
[[ -f "$HEF" && -r "$HEF" ]] || { echo "HEF is not a readable file: $HEF" >&2; exit 1; }
[[ -f "$INPUT" && -r "$INPUT" ]] || { echo "Input is not a readable file: $INPUT" >&2; exit 1; }
[[ -e /dev/h1x-0 ]] || { echo "Allocated Hailo device /dev/h1x-0 is missing." >&2; exit 1; }
command -v hailortcli >/dev/null || { echo "hailortcli is not installed." >&2; exit 1; }

# HailoRT writes its optional hailort.log in the current directory. Use
# job-local scratch so shared project/result directories remain clean.
RUN_DIR=$(mktemp -d "/tmp/hailo-${SLURM_JOB_ID}.XXXXXX")
cd "$RUN_DIR"
echo "Running HailoRT inference execution for $HEF"
echo "Input tensor: $INPUT"
exec hailortcli run "$HEF" --input-files "$INPUT" --frames-count 1
