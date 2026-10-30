#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUT=${NODE_IMAGE_OUTPUT_DIR:-"$ROOT/output/nodes"}
WORK=${NODE_IMAGE_WORK_DIR:-"$ROOT/work-nodes"}
BASE="$WORK/debian-13-generic-amd64.qcow2"
BASE_URL="https://cloud.debian.org/images/cloud/trixie/latest"

usage() {
  cat >&2 <<EOF
Usage:
  $0 build MANIFEST.csv
  $0 qemu MANIFEST.csv NODE_ID

Build creates a raw image and a private cloud-init seed for each manifest row.
QEMU boots one selected raw image with its seed to complete first-boot setup.
EOF
  exit 2
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1" >&2
    exit 1
  }
}

[[ $# -ge 2 && $# -le 3 ]] || usage
ACTION=$1
MANIFEST=$2
case "$ACTION" in
  build) [[ $# -eq 2 ]] || usage ;;
  qemu) [[ $# -eq 3 ]] || usage; SELECTED_NODE=$3 ;;
  *) usage ;;
esac
[[ -f "$MANIFEST" ]] || { echo "Manifest not found: $MANIFEST" >&2; exit 1; }

umask 077
need python3
if [[ "$ACTION" == build ]]; then
  need curl
  need qemu-img
  need cloud-localds
  need openssl
else
  need qemu-system-x86_64
fi

mkdir -p "$OUT" "$WORK"
NODES_TSV="$WORK/nodes.tsv"
python3 - "$MANIFEST" > "$NODES_TSV" <<'PY'
import csv
import re
import sys

manifest = sys.argv[1]
slug = re.compile(r"^[a-z][a-z0-9-]{0,30}[a-z0-9]$|^[a-z]$")
hostname = re.compile(r"^[a-z][a-z0-9-]{0,61}[a-z0-9]$|^[a-z]$")
with open(manifest, newline="", encoding="utf-8") as stream:
    reader = csv.DictReader(stream)
    required = ["cluster_id", "node_id", "role", "hostname"]
    if reader.fieldnames != required:
        raise SystemExit(f"CSV header must be exactly: {','.join(required)}")
    rows = list(reader)
if not rows:
    raise SystemExit("Manifest must contain at least one node.")
ids, names, clusters = set(), set(), set()
controllers = 0
for line, row in enumerate(rows, 2):
    cluster, node, role, host = (row[k].strip() for k in required)
    if not slug.fullmatch(cluster):
        raise SystemExit(f"Line {line}: invalid cluster_id {cluster!r} (use lowercase letters, digits, and hyphens).")
    if not slug.fullmatch(node):
        raise SystemExit(f"Line {line}: invalid node_id {node!r} (use lowercase letters, digits, and hyphens).")
    if role not in {"controller", "worker"}:
        raise SystemExit(f"Line {line}: role must be controller or worker.")
    if not hostname.fullmatch(host):
        raise SystemExit(f"Line {line}: invalid hostname {host!r}.")
    if node in ids:
        raise SystemExit(f"Line {line}: duplicate node_id {node!r}.")
    if host in names:
        raise SystemExit(f"Line {line}: duplicate hostname {host!r}.")
    ids.add(node); names.add(host); clusters.add(cluster)
    controllers += role == "controller"
    print("\t".join((cluster, node, role, host)))
if len(clusters) != 1:
    raise SystemExit("All rows must have the same cluster_id.")
if controllers != 1:
    raise SystemExit("Manifest must contain exactly one controller.")
PY

if [[ "$ACTION" == build ]]; then
  while IFS=$'\t' read -r _ NODE_ID _ _; do
    [[ -n "$NODE_ID" ]] || continue
    [[ ! -e "$OUT/$NODE_ID.raw" ]] || {
      echo "Refusing to overwrite existing image: $OUT/$NODE_ID.raw" >&2
      echo "Move it aside before rebuilding." >&2
      exit 1
    }
    [[ ! -e "$WORK/nodes/$NODE_ID/$NODE_ID.raw.part" ]] || {
      echo "Remove incomplete temporary image before retrying: $WORK/nodes/$NODE_ID/$NODE_ID.raw.part" >&2
      exit 1
    }
  done < "$NODES_TSV"
fi

if [[ "$ACTION" == build ]]; then
  if [[ ! -s "$BASE" ]]; then
    echo "Downloading official Debian 13 generic amd64 cloud image..."
    curl -fL --retry 3 -o "$BASE.part" "$BASE_URL/debian-13-generic-amd64.qcow2"
    mv "$BASE.part" "$BASE"
  fi
  curl -fL --retry 3 -o "$WORK/SHA512SUMS" "$BASE_URL/SHA512SUMS"
  awk '$2 == "debian-13-generic-amd64.qcow2" { print }' \
    "$WORK/SHA512SUMS" > "$WORK/image-checksum"
  [[ -s "$WORK/image-checksum" ]] || {
    echo "Debian checksum entry not found." >&2
    exit 1
  }
  (cd "$WORK" && sha512sum --check --status image-checksum) || {
    echo "Cloud image checksum failed; removing cached image." >&2
    python3 - "$BASE" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).unlink(missing_ok=True)
PY
    exit 1
  }

  read -rp "Linux login name [slurmadmin]: " INSTALL_USER
  INSTALL_USER=${INSTALL_USER:-slurmadmin}
  [[ "$INSTALL_USER" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || {
    echo "Use a lowercase Linux username." >&2; exit 2;
  }
  read -rsp "Password for $INSTALL_USER: " PASSWORD; printf '\n'
  read -rsp "Confirm password: " PASSWORD_CONFIRM; printf '\n'
  [[ -n "$PASSWORD" && "$PASSWORD" == "$PASSWORD_CONFIRM" ]] || {
    echo "Passwords are empty or do not match." >&2; exit 2;
  }
  PASSWORD_HASH=$(printf '%s' "$PASSWORD" | openssl passwd -6 -stdin)
  unset PASSWORD PASSWORD_CONFIRM
  printf '%s\n' "$INSTALL_USER" > "$WORK/login-name"
  printf '%s\n' "$PASSWORD_HASH" > "$WORK/password-hash"
  chmod 0600 "$WORK/login-name" "$WORK/password-hash"
  export INSTALL_USER PASSWORD_HASH ROOT WORK

  while IFS=$'\t' read -r CLUSTER_ID NODE_ID NODE_ROLE NODE_HOSTNAME; do
    [[ -n "$NODE_ID" ]] || continue
    NODE_DIR="$WORK/nodes/$NODE_ID"
    RAW="$OUT/$NODE_ID.raw"
    SEED="$NODE_DIR/seed.iso"
    mkdir -p "$NODE_DIR"
    TMP_RAW="$NODE_DIR/$NODE_ID.raw.part"
    [[ ! -e "$TMP_RAW" ]] || {
      echo "Remove incomplete temporary image before retrying: $TMP_RAW" >&2
      exit 1
    }
    echo "Creating raw image for $NODE_ID ($NODE_ROLE / $NODE_HOSTNAME)..."
    qemu-img convert -p -f qcow2 -O raw "$BASE" "$TMP_RAW"
    qemu-img resize -f raw "$TMP_RAW" "${USB_IMAGE_SIZE:-100G}"
    mv "$TMP_RAW" "$RAW"

    python3 - "$ROOT" "$NODE_DIR/user-data" "$NODE_DIR/meta-data" \
      "$CLUSTER_ID" "$NODE_ID" "$NODE_ROLE" "$NODE_HOSTNAME" <<'PY'
import json
import pathlib
import sys

root, user_data, meta_data, cluster, node, role, hostname = sys.argv[1:]
root = pathlib.Path(root)
inventory = pathlib.Path(root, "scripts/guerrilla-node-inventory").read_text()
advertise = pathlib.Path(root, "scripts/guerrilla-node-advertise").read_text()
discover = pathlib.Path(root, "scripts/discover-guerrilla-nodes.sh").read_text()
service = pathlib.Path(root, "systemd/guerrilla-node-advertise.service").read_text()
admin = pathlib.Path(root, "scripts/guerrilla-cluster-admin").read_text()
generator = pathlib.Path(root, "scripts/generate-slurm-config.py").read_text()
remote_installer = pathlib.Path(root, "scripts/install-enrolled-slurm-node").read_text()
identity = json.dumps({
    "cluster_id": cluster,
    "node_id": node,
    "role": role,
    "hostname": hostname,
}, indent=2) + "\n"
config = {
    "hostname": hostname,
    "manage_etc_hosts": True,
    "timezone": "America/Chicago",
    "locale": "C.UTF-8",
    "ssh_pwauth": True,
    "users": [
        "default",
        {
            "name": __import__("os").environ["INSTALL_USER"],
            "gecos": "Guerrilla Cluster Administrator",
            "groups": ["sudo"],
            "sudo": "ALL=(ALL) NOPASSWD:ALL",
            "shell": "/bin/bash",
            "lock_passwd": False,
            "passwd": __import__("os").environ["PASSWORD_HASH"],
        },
    ],
    "write_files": [
        {"path": "/etc/guerrilla-node/node.json", "permissions": "0644", "content": identity},
        {"path": "/usr/local/sbin/guerrilla-node-inventory", "permissions": "0755", "content": inventory},
        {"path": "/usr/local/sbin/guerrilla-node-advertise", "permissions": "0755", "content": advertise},
        {"path": "/usr/local/sbin/guerrilla-discover-nodes", "permissions": "0755", "content": discover},
        {"path": "/usr/local/sbin/guerrilla-cluster-admin", "permissions": "0755", "content": admin},
        {"path": "/usr/local/lib/guerrilla-slurm/generate-slurm-config.py", "permissions": "0755", "content": generator},
        {"path": "/usr/local/lib/guerrilla-slurm/install-enrolled-slurm-node", "permissions": "0755", "content": remote_installer},
        {"path": "/etc/systemd/system/guerrilla-node-advertise.service", "permissions": "0644", "content": service},
        {"path": "/etc/systemd/network/05-guerrilla-dhcp.network", "permissions": "0644", "content": "[Match]\nName=e*\n\n[Network]\nDHCP=ipv4\nIPv6AcceptRA=no\n"},
    ],
    "runcmd": [
        ["/bin/bash", "-lc", "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server openssh-client sshpass sudo munge slurm-wlm avahi-daemon avahi-utils pciutils"],
        ["/bin/bash", "-lc", "systemctl disable --now slurmd.service slurmctld.service 2>/dev/null || true"],
        ["systemctl", "enable", "--now", "systemd-networkd.service", "ssh.service", "avahi-daemon.service"],
        ["systemctl", "daemon-reload"],
        ["systemctl", "enable", "--now", "guerrilla-node-advertise.service"],
    ],
}
pathlib.Path(user_data).write_text("#cloud-config\n" + json.dumps(config, indent=2) + "\n")
pathlib.Path(meta_data).write_text(
    f"instance-id: guerrilla-{cluster}-{node}\nlocal-hostname: {hostname}\n"
)
PY
    cloud-localds --filesystem=iso9660 "$SEED" "$NODE_DIR/user-data" "$NODE_DIR/meta-data"
    echo "  raw:  $RAW"
    echo "  seed: $SEED (private; contains the account password hash)"
  done < "$NODES_TSV"
  echo "Images created. Boot each image once with '$0 qemu MANIFEST.csv NODE_ID' before writing its raw file to USB."
  exit 0
fi

[[ -r "$WORK/login-name" ]] || {
  echo "Build the node images first so the login name is available." >&2; exit 1;
}
LOGIN=$(<"$WORK/login-name")
SELECTED_FOUND=0
while IFS=$'\t' read -r CLUSTER_ID NODE_ID NODE_ROLE NODE_HOSTNAME; do
  [[ "$NODE_ID" == "$SELECTED_NODE" ]] || continue
  SELECTED_FOUND=1
  RAW="$OUT/$NODE_ID.raw"
  SEED="$WORK/nodes/$NODE_ID/seed.iso"
  [[ -s "$RAW" && -s "$SEED" ]] || {
    echo "Missing raw image or seed for $NODE_ID; run build first." >&2; exit 1;
  }
  break
done < "$NODES_TSV"
[[ $SELECTED_FOUND -eq 1 ]] || { echo "Unknown node_id: $SELECTED_NODE" >&2; exit 1; }
UEFI_CODE=
UEFI_VARS_TEMPLATE=
for fwdir in /usr/share/OVMF /usr/share/ovmf; do
  for code in "$fwdir"/OVMF_CODE*.fd; do
    [[ -r "$code" ]] || continue
    [[ "$code" == *secboot* || "$code" == *.ms.fd ]] && continue
    vars=${code/OVMF_CODE/OVMF_VARS}
    [[ -r "$vars" ]] || continue
    UEFI_CODE=$code
    UEFI_VARS_TEMPLATE=$vars
    break 2
  done
done
[[ -n "$UEFI_CODE" && -n "$UEFI_VARS_TEMPLATE" ]] || {
  echo "Install OVMF: sudo apt install ovmf" >&2; exit 1;
}
UEFI_VARS="$WORK/nodes/$SELECTED_NODE/OVMF_VARS.fd"
cp "$UEFI_VARS_TEMPLATE" "$UEFI_VARS"
echo "Booting $SELECTED_NODE ($NODE_ROLE / $NODE_HOSTNAME) in QEMU."
echo "Log in as $LOGIN and wait for 'sudo cloud-init status --wait' to report done."
echo "Then shut down cleanly. The raw image is $RAW."
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL=(-enable-kvm -cpu host)
else
  ACCEL=(-accel tcg -cpu max)
fi
DISPLAY_ARGS=()
if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} ]]; then
  DISPLAY_ARGS=(-display none -serial mon:stdio -monitor none)
fi
qemu-system-x86_64 "${ACCEL[@]}" "${DISPLAY_ARGS[@]}" -machine q35 \
  -m "${QEMU_MEMORY:-8G}" -smp "${QEMU_CPUS:-4}" \
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$UEFI_CODE" \
  -drive "if=pflash,format=raw,unit=1,file=$UEFI_VARS" \
  -drive "file=$RAW,format=raw,if=virtio,cache=none" \
  -cdrom "$SEED" -boot order=c,once=d \
  -device virtio-net-pci,netdev=n1 -netdev user,id=n1,hostfwd=tcp::2222-:22
