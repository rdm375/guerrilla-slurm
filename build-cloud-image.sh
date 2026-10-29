#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUT="$ROOT/output"
WORK="$ROOT/work-cloud"
BASE="$WORK/debian-13-generic-amd64.qcow2"
RAW=${SLURM_RAW_IMAGE:-"$OUT/dell7680-slurm.raw"}
SEED="$WORK/seed.iso"
USERDATA="$WORK/user-data"
METADATA="$WORK/meta-data"
BASE_URL="https://cloud.debian.org/images/cloud/trixie/latest"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing build dependency: $1 (install cloud-image-utils qemu-utils ovmf curl openssl)" >&2
    exit 1
  }
}

case "${1:-qemu}" in
  qemu|image) ;;
  *) echo "Usage: $0 [image|qemu]" >&2; exit 2 ;;
esac
ACTION=${1:-qemu}
umask 077
need curl
need qemu-img
need cloud-localds
need openssl

mkdir -p "$OUT" "$WORK"

if [[ ! -s "$BASE" ]]; then
  echo "Downloading official Debian 13 generic amd64 cloud image..."
  curl -fL --retry 3 -o "$BASE.part" "$BASE_URL/debian-13-generic-amd64.qcow2"
  mv "$BASE.part" "$BASE"
fi
curl -fL --retry 3 -o "$WORK/SHA512SUMS" "$BASE_URL/SHA512SUMS"
awk '$2 == "debian-13-generic-amd64.qcow2" { print }' "$WORK/SHA512SUMS" > "$WORK/image-checksum"
[[ -s "$WORK/image-checksum" ]] || { echo "Debian checksum entry not found." >&2; exit 1; }
(cd "$WORK" && sha512sum --check --status image-checksum) || {
  echo "Cloud image checksum failed; removing cached image." >&2
  rm -f "$BASE"
  exit 1
}

read -rp "Debian login name [slurmadmin]: " INSTALL_USER
INSTALL_USER=${INSTALL_USER:-slurmadmin}
[[ "$INSTALL_USER" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || { echo "Use a lowercase Linux username." >&2; exit 2; }
read -rsp "Password for $INSTALL_USER: " PASSWORD; printf '\n'
read -rsp "Confirm password: " PASSWORD_CONFIRM; printf '\n'
[[ -n "$PASSWORD" && "$PASSWORD" == "$PASSWORD_CONFIRM" ]] || { echo "Passwords are empty or do not match." >&2; exit 2; }
PASSWORD_HASH=$(printf '%s' "$PASSWORD" | openssl passwd -6 -stdin)
unset PASSWORD PASSWORD_CONFIRM

python3 - "$ROOT" "$USERDATA" "$METADATA" "$INSTALL_USER" "$PASSWORD_HASH" <<'PY'
import json
import pathlib
import sys
root, user_data, meta_data, username, password_hash = sys.argv[1:]
configure = pathlib.Path(root, "configure-node.sh").read_text()
install_hailo = pathlib.Path(root, "install-hailo10h.sh").read_text()
cluster_env = pathlib.Path(root, "cluster.env").read_text()
network_file = pathlib.Path(root, "network/05-enp0s31f6.network").read_text()
service = """[Unit]
Description=Join Dell 7680 to the dell7710 Slurm cluster
Wants=network-online.target
After=network-online.target munge.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 15
ExecStart=/usr/local/sbin/configure-slurm-node
TimeoutStartSec=0
Restart=on-failure
RestartSec=60s

[Install]
WantedBy=multi-user.target
"""
firstboot = """#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/slurm-node-firstboot.log) 2>&1
sed -i -E 's/^Components: main$/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server sudo munge slurm-wlm slurm-wlm-nvml-plugin nvidia-driver firmware-nvidia-gsp linux-headers-amd64 dkms build-essential cmake git wget curl ca-certificates pciutils usbutils python3 python3-venv nfs-common libssl-dev libprotobuf-dev protobuf-compiler libpcap-dev libjsoncpp-dev libusb-1.0-0-dev libudev-dev pkg-config zlib1g-dev
systemctl enable munge slurmd
systemctl enable systemd-networkd.service
systemctl daemon-reload
systemctl enable slurm-node-bootstrap.service
"""
config = {
  "hostname": "dell7680",
  "manage_etc_hosts": False,
  "timezone": "America/Chicago",
  "locale": "C.UTF-8",
  "ssh_pwauth": True,
  "users": [
    "default",
    {"name": username, "gecos": "Slurm Administrator", "groups": ["sudo"],
     "sudo": "ALL=(ALL) NOPASSWD:ALL", "shell": "/bin/bash",
     "lock_passwd": False, "passwd": password_hash}
  ],
  "write_files": [
    {"path": "/usr/local/sbin/configure-slurm-node", "permissions": "0755", "content": configure},
    {"path": "/usr/local/sbin/install-hailo10h", "permissions": "0755", "content": install_hailo},
    {"path": "/etc/default/slurm-node", "permissions": "0644", "content": cluster_env},
    {"path": "/etc/systemd/network/05-enp0s31f6.network", "permissions": "0644", "content": network_file},
    {"path": "/usr/local/sbin/slurm-node-firstboot", "permissions": "0755", "content": firstboot},
    {"path": "/etc/systemd/system/slurm-node-bootstrap.service", "permissions": "0644", "content": service}
  ],
  "runcmd": [["/usr/local/sbin/slurm-node-firstboot"]]
}
pathlib.Path(user_data).write_text("#cloud-config\n" + json.dumps(config, indent=2) + "\n")
pathlib.Path(meta_data).write_text("instance-id: iid-dell7680-slurm\nlocal-hostname: dell7680\n")
PY
unset PASSWORD_HASH

if [[ ! -s "$RAW" ]]; then
  echo "Creating raw disk image from Debian's preinstalled image..."
  qemu-img convert -p -f qcow2 -O raw "$BASE" "$RAW"
  qemu-img resize "$RAW" "${USB_IMAGE_SIZE:-128G}"
fi
cloud-localds --filesystem=iso9660 "$SEED" "$USERDATA" "$METADATA"

if [[ "$ACTION" == image ]]; then
  echo "Image ready: $RAW"
  echo "Cloud-init seed: $SEED"
  exit 0
fi

cleanup_seed() {
  rm -f "$SEED" "$USERDATA" "$METADATA" "$WORK/image-checksum"
}
trap cleanup_seed EXIT

need qemu-system-x86_64
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
[[ -n "$UEFI_CODE" && -n "$UEFI_VARS_TEMPLATE" ]] || { echo "Install OVMF: sudo apt install ovmf" >&2; exit 1; }
UEFI_VARS="$WORK/OVMF_VARS.fd"
cp "$UEFI_VARS_TEMPLATE" "$UEFI_VARS"

cat <<MSG
Starting Debian 13 cloud image in QEMU.
Cloud-init installs Slurm and NVIDIA packages on first boot; allow several minutes.
After boot, log in as $INSTALL_USER. The image is at $RAW.
MSG
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL=(-enable-kvm -cpu host)
else
  ACCEL=(-accel tcg -cpu max)
fi
qemu-system-x86_64 "${ACCEL[@]}" -machine q35 -m 12G -smp 8 \
  -drive "if=pflash,format=raw,unit=0,readonly=on,file=$UEFI_CODE" \
  -drive "if=pflash,format=raw,unit=1,file=$UEFI_VARS" \
  -drive "file=$RAW,format=raw,if=virtio,cache=none" \
  -cdrom "$SEED" -boot order=c,once=d \
  -device virtio-net-pci,netdev=n1 -netdev user,id=n1,hostfwd=tcp::2222-:22
