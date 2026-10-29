#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

HOST=$(hostname -s)
if [[ "$HOST" != dell7680 ]]; then
  echo "This script configures the Dell 7680 compute node; hostname is $HOST." >&2
  exit 2
fi

if [[ -r /etc/default/slurm-node ]]; then
  # shellcheck disable=SC1091
  source /etc/default/slurm-node
fi
SLURM_CONTROLLER_IP=${SLURM_CONTROLLER_IP:-192.168.1.185}
SLURM_COMPUTE_IP=${SLURM_COMPUTE_IP:-192.168.1.199}
SLURM_SHARED_MOUNT=${SLURM_SHARED_MOUNT:-/cluster}

if [[ ! -s /etc/munge/munge.key || ! -s /etc/slurm/slurm.conf ]]; then
  echo "Waiting for the shared MUNGE key and Slurm config from dell7710." >&2
  exit 2
fi
grep -q '^SlurmctldHost=dell7710$' /etc/slurm/slurm.conf || {
  echo "/etc/slurm/slurm.conf does not point at dell7710." >&2; exit 2;
}

sed -i -E '/(^|[[:space:]])(dell7710|dell7680)([[:space:]]|$)/d' /etc/hosts
printf '%s dell7710\n%s dell7680\n' "$SLURM_CONTROLLER_IP" "$SLURM_COMPUTE_IP" >> /etc/hosts

DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-common
install -d -m 0755 "$SLURM_SHARED_MOUNT"
NFS_LINE="$SLURM_CONTROLLER_IP:/ $SLURM_SHARED_MOUNT nfs4 rw,_netdev,nofail,x-systemd.automount,vers=4.2,proto=tcp 0 0"
grep -qxF "$NFS_LINE" /etc/fstab || printf '%s\n' "$NFS_LINE" >> /etc/fstab
systemctl daemon-reload
if ! mountpoint -q "$SLURM_SHARED_MOUNT"; then
  systemctl start "$(systemd-escape --path --suffix=automount "$SLURM_SHARED_MOUNT")"
fi

command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null || {
  echo "NVIDIA GPU is not available; install/fix its driver before joining Slurm." >&2; exit 2;
}

"/usr/local/sbin/install-hailo10h"
[[ -e /dev/h1x-0 ]] || { echo "Hailo device /dev/h1x-0 is not available yet." >&2; exit 2; }

chown munge:munge /etc/munge/munge.key
chmod 0400 /etc/munge/munge.key
install -d -o slurm -g slurm -m 0755 /var/lib/slurmd
systemctl enable munge slurmd
systemctl restart munge
systemctl restart slurmd

echo "Configured dell7680 as a Slurm compute node controlled by dell7710."
echo "Detected GPU: $(nvidia-smi -L 2>/dev/null | head -n1 || echo unavailable)"
echo "Detected Hailo device: $(test -e /dev/h1x-0 && echo /dev/h1x-0 || echo unavailable)"
echo "Shared storage is configured at $SLURM_SHARED_MOUNT."
