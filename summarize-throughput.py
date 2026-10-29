#!/usr/bin/env python3
"""Turn a cluster-throughput log into a compact Markdown scorecard."""

from __future__ import annotations

import re
import sys
from pathlib import Path


STAGES = [
    "CPU: dell7710, 8 Slurm CPUs",
    "CPU: dell7680, 16 Slurm CPUs",
    "GPU: dell7710, Quadro M3000M",
    "GPU: dell7680, RTX 4090 Laptop",
    "Hailo-10H: dell7680, EfficientNet-Lite0",
]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {Path(sys.argv[0]).name} CLUSTER_THROUGHPUT_LOG", file=sys.stderr)
        return 2

    log_path = Path(sys.argv[1]).expanduser()
    if not log_path.is_file():
        print(f"Benchmark log not found: {log_path}", file=sys.stderr)
        return 2

    raw = log_path.read_text(errors="replace")
    current = ""
    results = {stage: {"compute": None, "bandwidth": None, "inference": None, "status": "not run"} for stage in STAGES}
    for line in raw.splitlines():
        heading = re.match(r"^===== (.+) =====$", line.strip())
        if heading:
            current = heading.group(1)
            continue
        if current not in results:
            continue
        if "STAGE PASS:" in line:
            results[current]["status"] = "PASS"
        elif "STAGE FAIL:" in line:
            results[current]["status"] = "FAIL"
        if current.startswith("CPU:"):
            match = re.search(r"CPU FP32 FMA estimate:\s*([\d.]+)\s*GFLOP/s", line)
            if match:
                results[current]["compute"] = f"{float(match.group(1)):,.3f} GFLOP/s"
        elif current.startswith("GPU:"):
            match = re.search(r"FP32 FMA estimate:\s*([\d.]+)\s*TFLOP/s", line)
            if match:
                results[current]["compute"] = f"{float(match.group(1)):,.3f} TFLOP/s"
            match = re.search(r"Device-memory copy estimate:\s*([\d.]+)\s*GB/s", line)
            if match:
                results[current]["bandwidth"] = f"{float(match.group(1)):,.1f} GB/s"
        elif current.startswith("Hailo"):
            match = re.search(r"FPS:\s*([\d.]+)", line)
            if match:
                results[current]["inference"] = f"{float(match.group(1)):,.2f} images/s"

    stamp = re.search(r"^Started:\s*(.+)$", raw, re.MULTILINE)
    rows = []
    fp32_tf = 0.0
    gpu_bw = 0.0
    fp32_count = 0
    bw_count = 0
    failures = 0
    for stage in STAGES:
        row = results[stage]
        if row["status"] != "PASS":
            failures += 1
        if stage.startswith("CPU:") and row["compute"]:
            fp32_tf += float(row["compute"].split()[0].replace(",", "")) / 1000.0
            fp32_count += 1
        if stage.startswith("GPU:"):
            if row["compute"]:
                fp32_tf += float(row["compute"].split()[0].replace(",", ""))
                fp32_count += 1
            if row["bandwidth"]:
                gpu_bw += float(row["bandwidth"].split()[0].replace(",", ""))
                bw_count += 1

        name = stage
        if stage.startswith("CPU:"):
            node = "dell7710" if "dell7710" in stage else "dell7680"
            resource = "CPU (8 threads)" if node == "dell7710" else "CPU (16 threads)"
        elif stage.startswith("GPU:"):
            node = "dell7710" if "dell7710" in stage else "dell7680"
            resource = "Quadro M3000M" if node == "dell7710" else "RTX 4090 Laptop"
        else:
            node, resource = "dell7680", "Hailo-10H / EfficientNet-Lite0"

        rows.append(
            f"| {node} | {resource} | {row['compute'] or '—'} | "
            f"{row['bandwidth'] or '—'} | {row['inference'] or '—'} | {row['status']} |"
        )

    summary_path = log_path.with_suffix(".md")
    lines = [
        "# Lagrange cluster throughput summary",
        "",
        f"**Run:** {stamp.group(1) if stamp else 'time not recorded'}  ",
        "**Source:** `" + log_path.name + "`",
        "",
        "| Node | Resource | FP32 compute | Device-memory bandwidth | Inference rate | Stage |",
        "|---|---|---:|---:|---:|---|",
        *rows,
        "",
        "## Cluster totals (sum of individual peak runs)",
        "",
        f"- FP32 CPU + NVIDIA throughput: **{fp32_tf:,.3f} TFLOP/s** ({fp32_count}/4 measured).",
        f"- NVIDIA device-memory copy bandwidth: **{gpu_bw:,.1f} GB/s** ({bw_count}/2 GPUs measured).",
        "- Hailo is reported as model inferences per second; this run does not measure Hailo TOPS.",
        "- The CPU and GPU runs are sequential. Totals are sums of separate measurements, not a simultaneous cluster run; CPU RAM bandwidth is not measured.",
        "",
    ]
    summary_path.write_text("\n".join(lines))
    print("\n".join(lines))
    print(f"Saved summary: {summary_path}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
