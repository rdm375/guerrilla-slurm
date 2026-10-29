#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 LOGIN [COMPUTE_IPV4]" >&2
  exit 2
fi
LOGIN=$1
COMPUTE_IP=${2:-$SLURM_COMPUTE_IP}
[[ "$LOGIN" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || { echo "Invalid Linux login name." >&2; exit 2; }
[[ "$COMPUTE_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Use an IPv4 address." >&2; exit 2; }

SHARE=/root/slurm-node-share
for file in munge.key slurm.conf gres.conf cgroup.conf; do
  [[ -s "$SHARE/$file" ]] || { echo "Missing $SHARE/$file; run sudo ./setup-controller.sh first." >&2; exit 1; }
done

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/slurm-node-share.XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
sudo install -o "$(id -un)" -g "$(id -gn)" -m 0600 "$SHARE/munge.key" "$STAGE/munge.key"
sudo install -o "$(id -un)" -g "$(id -gn)" -m 0644 "$ROOT/cluster.env" "$STAGE/cluster.env"
sudo install -o "$(id -un)" -g "$(id -gn)" -m 0644 \
  "$SHARE/slurm.conf" "$SHARE/gres.conf" "$SHARE/cgroup.conf" "$STAGE/"

REMOTE_DIR="/tmp/slurm-node-share-${$}"
ssh "$LOGIN@$COMPUTE_IP" "mkdir -m 0700 '$REMOTE_DIR'"
scp "$STAGE/munge.key" "$STAGE/slurm.conf" "$STAGE/gres.conf" "$STAGE/cgroup.conf" "$STAGE/cluster.env" \
  "$LOGIN@$COMPUTE_IP:$REMOTE_DIR/"
ssh -t "$LOGIN@$COMPUTE_IP" \
  "sudo install -o root -g root -m 0644 '$REMOTE_DIR/slurm.conf' '$REMOTE_DIR/gres.conf' '$REMOTE_DIR/cgroup.conf' /etc/slurm/ && \
   sudo install -o root -g root -m 0644 '$REMOTE_DIR/cluster.env' /etc/default/slurm-node && \
   sudo install -o munge -g munge -m 0400 '$REMOTE_DIR/munge.key' /etc/munge/munge.key && \
   sudo rm -rf '$REMOTE_DIR' && \
   sudo systemctl restart slurm-node-bootstrap && \
   sudo systemctl --no-pager --full status slurm-node-bootstrap"

echo "Transferred the shared Slurm config and MUNGE key to dell7680 over SSH."
