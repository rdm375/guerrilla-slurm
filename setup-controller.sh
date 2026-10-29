#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi
[[ $(hostname -s) == dell7710 ]] || { echo "Run this on dell7710." >&2; exit 2; }

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"
SLURM_CONTROLLER_IP=${SLURM_CONTROLLER_IP:-192.168.1.185}
SLURM_COMPUTE_IP=${SLURM_COMPUTE_IP:-192.168.1.199}
SLURM_SRUN_PORT_RANGE=${SLURM_SRUN_PORT_RANGE:-60001-63000}
SLURM_SHARED_EXPORT=${SLURM_SHARED_EXPORT:-/srv/slurm-share}
SLURM_SHARED_MOUNT=${SLURM_SHARED_MOUNT:-/cluster}

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y munge slurm-wlm slurm-wlm-basic-plugins slurm-wlm-nvml-plugin nfs-kernel-server

SHARE_OWNER=${SUDO_USER:-}
if [[ -z "$SHARE_OWNER" ]]; then
  SHARE_OWNER=$(getent passwd 1000 | cut -d: -f1)
fi
[[ -n "$SHARE_OWNER" ]] || { echo "Could not determine the non-root account that should own shared files." >&2; exit 1; }
SHARE_GROUP=$(id -gn "$SHARE_OWNER")
install -d -o "$SHARE_OWNER" -g "$SHARE_GROUP" -m 2775 \
  "$SLURM_SHARED_EXPORT/projects" "$SLURM_SHARED_EXPORT/data" \
  "$SLURM_SHARED_EXPORT/results" "$SLURM_SHARED_EXPORT/software"
install -d -m 0755 "$SLURM_SHARED_MOUNT" /etc/exports.d
EXPORT_LINE="$SLURM_SHARED_EXPORT $SLURM_COMPUTE_IP(rw,sync,no_subtree_check,fsid=0,root_squash)"
printf '%s\n' "$EXPORT_LINE" > /etc/exports.d/slurm.exports
BIND_LINE="$SLURM_SHARED_EXPORT $SLURM_SHARED_MOUNT none bind 0 0"
grep -qxF "$BIND_LINE" /etc/fstab || printf '%s\n' "$BIND_LINE" >> /etc/fstab
systemctl daemon-reload
mountpoint -q "$SLURM_SHARED_MOUNT" || mount "$SLURM_SHARED_MOUNT"
systemctl enable --now nfs-kernel-server
exportfs -ra

sed -i -E '/(^|[[:space:]])(dell7710|dell7680)([[:space:]]|$)/d' /etc/hosts
printf '%s dell7710\n%s dell7680\n' "$SLURM_CONTROLLER_IP" "$SLURM_COMPUTE_IP" >> /etc/hosts

install -d -o munge -g munge -m 0700 /etc/munge
if [[ ! -s /etc/munge/munge.key ]]; then
  /usr/sbin/create-munge-key -f
fi
chown munge:munge /etc/munge/munge.key
chmod 0400 /etc/munge/munge.key

# slurmd -C may report a Gres= field itself. Keep only the hardware topology
# here; the script adds one canonical Gres= declaration below.
CONTROLLER_SPEC=$(slurmd -C | head -n1 | sed -E 's/[[:space:]]Gres=[^[:space:]]+//g; s/NodeName=[^ ]*/NodeName=dell7710/')
GPU_COUNT=0
GPU_GRES=
if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_NAMES=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || true)
  GPU_COUNT=$(printf '%s\n' "$GPU_NAMES" | sed '/^[[:space:]]*$/d' | wc -l)
  if (( GPU_COUNT > 0 )); then
    GPU_NAME=$(printf '%s\n' "$GPU_NAMES" | sed -n '1p')
    GPU_TYPE=$(printf '%s' "$GPU_NAME" | tr '[:upper:]' '[:lower:]' |
      sed -E 's/[^a-z0-9]+/_/g; s/^nvidia_//; s/^geforce_//; s/_laptop_gpu$//; s/_gpu$//; s/^_+|_+$//g')
    [[ -n "$GPU_TYPE" ]] || { echo "Could not determine Slurm GPU type from: $GPU_NAME" >&2; exit 1; }
    GPU_GRES="gpu:${GPU_TYPE}:${GPU_COUNT}"
  fi
fi
if (( GPU_COUNT > 0 )); then
  CONTROLLER_SPEC+=" Gres=${GPU_GRES}"
fi

install -d -m 0755 /etc/slurm
cat > /etc/slurm/slurm.conf <<EOF
ClusterName=${SLURM_CLUSTER_NAME}
SlurmctldHost=dell7710
SlurmUser=slurm
SlurmctldPort=6817
SlurmdPort=6818
SrunPortRange=${SLURM_SRUN_PORT_RANGE}
AuthType=auth/munge
StateSaveLocation=/var/lib/slurmctld
SlurmdSpoolDir=/var/lib/slurmd
SwitchType=switch/none
MpiDefault=none
ProctrackType=proctrack/cgroup
TaskPlugin=task/cgroup,task/affinity
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
GresTypes=gpu,hailo10h
${CONTROLLER_SPEC}
NodeName=dell7680 NodeAddr=${SLURM_COMPUTE_IP} NodeHostname=dell7680 CPUs=16 Sockets=1 CoresPerSocket=8 ThreadsPerCore=2 RealMemory=60000 Gres=gpu:rtx_4090:1,hailo10h:1 State=UNKNOWN
PartitionName=compute Nodes=dell7710,dell7680 Default=YES MaxTime=INFINITE State=UP
EOF

cat > /etc/slurm/gres.conf <<'EOF'
AutoDetect=nvml
NodeName=dell7680 Name=hailo10h File=/dev/h1x-0
EOF
cat > /etc/slurm/cgroup.conf <<'EOF'
CgroupPlugin=autodetect
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainDevices=yes
EOF
chown root:root /etc/slurm/slurm.conf /etc/slurm/gres.conf /etc/slurm/cgroup.conf
chmod 0644 /etc/slurm/slurm.conf /etc/slurm/gres.conf /etc/slurm/cgroup.conf

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow from "$SLURM_COMPUTE_IP" to any port 6817 proto tcp
  ufw allow from "$SLURM_COMPUTE_IP" to any port "$SLURM_SRUN_PORT_RANGE" proto tcp
  ufw allow from "$SLURM_COMPUTE_IP" to any port 2049 proto tcp
fi

install -d -o slurm -g slurm -m 0755 /var/lib/slurmctld /var/lib/slurmd
systemctl enable munge slurmctld slurmd
systemctl restart munge slurmctld slurmd

SHARE=/root/slurm-node-share
install -d -o root -g root -m 0700 "$SHARE"
install -o root -g root -m 0600 /etc/munge/munge.key "$SHARE/munge.key"
install -o root -g root -m 0644 /etc/slurm/slurm.conf /etc/slurm/gres.conf /etc/slurm/cgroup.conf "$SHARE/"
cat > "$SHARE/README.txt" <<'EOF'
These files are transferred by ./join-compute-node.sh LOGIN. The MUNGE key is a
cluster secret: do not put it on the installer ISO, email it, or leave extra
copies behind. Hailo driver, runtime, and matching firmware are built on the
7680 after this configuration is installed.
EOF
chmod 0600 "$SHARE/munge.key" "$SHARE/README.txt"

echo "Configured dell7710 as controller and compute node."
echo "Slurm share files are staged in $SHARE; transfer them securely with ./join-compute-node.sh LOGIN."
echo "Cluster address defaults: controller=$SLURM_CONTROLLER_IP compute=$SLURM_COMPUTE_IP"
echo "Shared storage exported from $SLURM_SHARED_EXPORT and available locally at $SLURM_SHARED_MOUNT."
echo "Verify: sinfo; scontrol show nodes"
