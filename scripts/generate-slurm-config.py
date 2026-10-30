#!/usr/bin/env python3
"""Generate one Slurm configuration from controller-approved inventories."""

import ipaddress
import json
import pathlib
import re
import sys


def fail(message):
    raise SystemExit(message)


def read_inventory(path):
    try:
        item = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"Cannot read inventory {path}: {exc}")
    required = {"cluster_id", "node_id", "role", "hostname", "slurm_address", "slurm_topology"}
    missing = required - item.keys()
    if missing:
        fail(f"{path}: missing fields: {', '.join(sorted(missing))}")
    if item["role"] not in {"controller", "worker"}:
        fail(f"{path}: invalid role {item['role']!r}")
    for field in ("cluster_id", "node_id"):
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,30}[a-z0-9]|[a-z]", str(item[field])):
            fail(f"{path}: invalid {field}: {item[field]!r}")
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,61}[a-z0-9]|[a-z]", str(item["hostname"])):
        fail(f"{path}: invalid hostname: {item['hostname']!r}")
    try:
        item["slurm_address"] = str(ipaddress.IPv4Address(item["slurm_address"]))
    except ipaddress.AddressValueError:
        fail(f"{path}: slurm_address must be an IPv4 address")
    topology = str(item["slurm_topology"]).splitlines()[0].strip()
    if not topology.startswith("NodeName="):
        fail(f"{path}: slurmd -C topology is missing its NodeName")
    tokens = topology.split()
    if not any(token.startswith("CPUs=") for token in tokens):
        fail(f"{path}: slurmd -C topology is missing CPUs")
    if not any(token.startswith("RealMemory=") for token in tokens):
        fail(f"{path}: slurmd -C topology is missing RealMemory")
    item["topology_tokens"] = [token for token in tokens[1:] if not token.startswith("Gres=")]
    if not item["topology_tokens"]:
        fail(f"{path}: empty slurmd topology")
    return item


def main():
    if len(sys.argv) != 3:
        fail(f"Usage: {sys.argv[0]} ENROLLED_DIRECTORY OUTPUT_DIRECTORY")
    registry, output = map(pathlib.Path, sys.argv[1:])
    records = [read_inventory(path) for path in sorted(registry.glob("*.json"))]
    if not records:
        fail(f"No enrolled node inventories found in {registry}")
    clusters = {item["cluster_id"] for item in records}
    if len(clusters) != 1:
        fail("Enrolled nodes contain multiple cluster IDs")
    controllers = [item for item in records if item["role"] == "controller"]
    if len(controllers) != 1:
        fail("Exactly one controller inventory is required")
    node_ids = [item["node_id"] for item in records]
    hostnames = [item["hostname"] for item in records]
    addresses = [item["slurm_address"] for item in records]
    for label, values in (("node_id", node_ids), ("hostname", hostnames), ("Slurm address", addresses)):
        if len(set(values)) != len(values):
            fail(f"Duplicate {label} in enrolled inventory")

    gpu_types = set()
    hailo_present = False
    node_lines = []
    hosts_lines = []
    for item in records:
        gres = []
        detected = item.get("nvidia_gpus", [])
        if detected:
            gres.append(f"gpu:{len(detected)}")
            gpu_types.add("gpu")
        hailos = item.get("hailo_devices", [])
        if hailos:
            gres.append(f"hailo10h:{len(hailos)}")
            gpu_types.add("hailo10h")
            hailo_present = True
        line = " ".join([
            f"NodeName={item['hostname']}",
            f"NodeAddr={item['slurm_address']}",
            f"NodeHostname={item['hostname']}",
            *item["topology_tokens"],
            *( [f"Gres={','.join(gres)}"] if gres else [] ),
            "State=UNKNOWN",
        ])
        node_lines.append(line)
        hosts_lines.append(f"{item['slurm_address']} {item['hostname']}")

    controller = controllers[0]
    node_names = ",".join(item["hostname"] for item in records)
    config = [
        f"ClusterName={controller['cluster_id']}",
        f"SlurmctldHost={controller['hostname']}",
        "SlurmUser=slurm",
        "SlurmctldPort=6817",
        "SlurmdPort=6818",
        "AuthType=auth/munge",
        "StateSaveLocation=/var/lib/slurmctld",
        "SlurmdSpoolDir=/var/lib/slurmd",
        "SwitchType=switch/none",
        "MpiDefault=none",
        "ProctrackType=proctrack/cgroup",
        "TaskPlugin=task/cgroup,task/affinity",
        "SelectType=select/cons_tres",
        "SelectTypeParameters=CR_Core_Memory",
    ]
    if gpu_types:
        config.append("GresTypes=" + ",".join(sorted(gpu_types)))
    config.extend(node_lines)
    config.append(f"PartitionName=compute Nodes={node_names} Default=YES MaxTime=INFINITE State=UP")

    output.mkdir(parents=True, exist_ok=True)
    (output / "slurm.conf").write_text("\n".join(config) + "\n", encoding="utf-8")
    gres_config = []
    if "gpu" in gpu_types:
        gres_config.extend(
            f"NodeName={item['hostname']} AutoDetect=nvidia"
            for item in records if item.get("nvidia_gpus")
        )
    if hailo_present:
        gres_config.extend(
            f"NodeName={item['hostname']} Name=hailo10h File={device}"
            for item in records for device in item.get("hailo_devices", [])
        )
    (output / "gres.conf").write_text("\n".join(gres_config) + ("\n" if gres_config else ""), encoding="utf-8")
    (output / "cgroup.conf").write_text(
        "CgroupPlugin=autodetect\nConstrainCores=yes\nConstrainRAMSpace=yes\nConstrainDevices=yes\n",
        encoding="utf-8",
    )
    (output / "hosts.entries").write_text("\n".join(hosts_lines) + "\n", encoding="utf-8")
    print(f"Generated Slurm config for {len(records)} nodes: {node_names}")


if __name__ == "__main__":
    main()
