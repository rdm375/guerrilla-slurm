#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install -d -m 2775 /cluster/results
report="/cluster/results/cluster-throughput-$(date +%Y%m%d-%H%M%S).log"
echo "Lagrange cluster throughput benchmark" | tee "$report"
echo "Started: $(date --iso-8601=seconds)" | tee -a "$report"
echo "Mode: sequential per-resource peak estimates; run on a lightly loaded cluster." | tee -a "$report"
failures=()
run_failed=0
run() {
  local label=$1
  shift
  echo
  echo "===== $label ====="
  if "$@"; then
    echo "STAGE PASS: $label"
  else
    local rc=$?
    echo "STAGE FAIL: $label (exit $rc)"
    failures+=("$label")
  fi
}
{
  run 'CPU: dell7710, 8 Slurm CPUs' "$ROOT/cpu-throughput.sh" dell7710 8
  run 'CPU: dell7680, 16 Slurm CPUs' "$ROOT/cpu-throughput.sh" dell7680 16
  run 'GPU: dell7710, Quadro M3000M' "$ROOT/gpu-throughput.sh" dell7710
  run 'GPU: dell7680, RTX 4090 Laptop' "$ROOT/gpu-throughput.sh" dell7680
  run 'Hailo-10H: dell7680, EfficientNet-Lite0' "$ROOT/hailo-smoke-test.sh"
  echo
  echo "Finished: $(date --iso-8601=seconds)"
  if (( ${#failures[@]} )); then
    echo "Stages failed: ${failures[*]}"
  else
    echo "All five benchmark stages completed successfully."
  fi
  echo "Report: $report"
} 2>&1 | tee -a "$report" || run_failed=1

if python3 "$ROOT/summarize-throughput.py" "$report" 2>&1 | tee -a "$report"; then
  :
else
  echo "Summary generation failed or one or more benchmark stages did not complete." | tee -a "$report"
  run_failed=1
fi

if (( run_failed )); then
  exit 1
fi
