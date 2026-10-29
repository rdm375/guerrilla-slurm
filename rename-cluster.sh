#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"

if [[ ${EUID} -ne 0 ]]; then
  echo "Run from your dell7710 login: sudo $0 [new-cluster-name]" >&2
  exit 1
fi
[[ $(hostname -s) == dell7710 ]] || {
  echo "Run this on dell7710, the Slurm controller." >&2
  exit 2
}
CALLER=${SUDO_USER:-}
[[ -n "$CALLER" && "$CALLER" != root ]] || {
  echo "Run with sudo from your normal login so the worker SSH key can be used." >&2
  exit 2
}

NEW_NAME=${1:-$SLURM_CLUSTER_NAME}
[[ "$NEW_NAME" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || {
  echo "Use a lowercase Slurm cluster ID, such as lagrange." >&2
  exit 2
}
CONF=/etc/slurm/slurm.conf
OLD_NAME=$(awk -F= '$1 == "ClusterName" {print $2; exit}' "$CONF")
[[ -n "$OLD_NAME" ]] || { echo "ClusterName is missing from $CONF." >&2; exit 1; }
[[ "$OLD_NAME" != "$NEW_NAME" ]] || {
  echo "The Slurm configuration already uses $NEW_NAME." >&2
  exit 0
}

if squeue -h -o '%i' | grep -q .; then
  echo "Finish or cancel queued/running jobs before renaming the cluster." >&2
  exit 1
fi

run_as_caller() { runuser -u "$CALLER" -- "$@"; }
run_as_caller ssh -o BatchMode=yes "$CALLER@$SLURM_COMPUTE_IP" 'sudo -n true' || {
  echo "Passwordless SSH and sudo to $SLURM_COMPUTE_IP are required." >&2
  exit 1
}

sacctmgr -nP show cluster format=Cluster |
  grep -Fxq "$OLD_NAME" || {
    echo "The accounting database does not contain cluster $OLD_NAME." >&2
    exit 1
  }
if sacctmgr -nP show cluster format=Cluster | grep -Fxq "$NEW_NAME"; then
  echo "The accounting database already contains cluster $NEW_NAME; continuing with its existing record."
else
  # Slurm does not support changing a cluster's Name with `modify cluster`.
  # Register the new identity and retain the old record as historical data.
  sacctmgr -i add cluster "$NEW_NAME"
fi

# Ensure the invoking user has a usable default association on the new cluster.
sacctmgr -nP show assoc where "cluster=$NEW_NAME" "account=default" \
  format=Cluster,Account | grep -Fxq "$NEW_NAME|default" ||
  sacctmgr -i add account name=default cluster="$NEW_NAME" Description=Default
sacctmgr -nP show assoc where "cluster=$NEW_NAME" "user=$CALLER" format=User,Account |
  grep -Fxq "$CALLER|default" ||
  sacctmgr -i add user name="$CALLER" account=default cluster="$NEW_NAME"

STAMP=$(date +%Y%m%d%H%M%S)
cp -a "$CONF" "$CONF.before-rename-$STAMP"
sed -i "s/^ClusterName=${OLD_NAME}$/ClusterName=${NEW_NAME}/" "$CONF"
chown root:root "$CONF"
chmod 0644 "$CONF"

run_as_caller scp -o BatchMode=yes "$CONF" \
  "$CALLER@$SLURM_COMPUTE_IP:/tmp/slurm.conf"
run_as_caller ssh -o BatchMode=yes "$CALLER@$SLURM_COMPUTE_IP" \
  'sudo -n install -o root -g root -m 0644 /tmp/slurm.conf /etc/slurm/slurm.conf && sudo -n systemctl restart slurmd'

systemctl restart slurmd

# Slurm refuses to start under a renamed ClusterName while the state directory
# still contains the previous clustername marker. Preserve that marker, then
# let slurmctld create a fresh one for the new cluster ID.
STATE_DIR=$(awk -F= '$1 == "StateSaveLocation" {print $2; exit}' "$CONF")
[[ -n "$STATE_DIR" ]] || STATE_DIR=/var/lib/slurmctld
CLUSTER_MARKER="$STATE_DIR/clustername"
if [[ -f "$CLUSTER_MARKER" ]]; then
  SAVED_NAME=$(<"$CLUSTER_MARKER")
  if [[ "$SAVED_NAME" == "$OLD_NAME" ]]; then
    mv "$CLUSTER_MARKER" "$CLUSTER_MARKER.before-rename-$STAMP"
  elif [[ "$SAVED_NAME" != "$NEW_NAME" ]]; then
    echo "Unexpected Slurm state marker: $CLUSTER_MARKER contains '$SAVED_NAME'." >&2
    exit 1
  fi
fi

systemctl restart slurmctld

for attempt in {1..30}; do
  row=$(sacctmgr -nP show cluster where "name=$NEW_NAME" \
    format=Cluster,ControlHost,ControlPort 2>/dev/null || true)
  IFS='|' read -r registered host port <<<"$row"
  if [[ "$registered" == "$NEW_NAME" && -n "$host" && "$port" != 0 ]]; then
    printf 'Renamed Slurm cluster to %s; controller registered as %s:%s.\n' \
      "$NEW_NAME" "$host" "$port"
    echo "Configuration backup: $CONF.before-rename-$STAMP"
    exit 0
  fi
  sleep 2
done

echo "Slurm configuration now uses $NEW_NAME, but SlurmDBD still reports no controller host/port." >&2
echo "Check: sacctmgr show cluster format=Cluster,ControlHost,ControlPort" >&2
echo "Configuration backup: $CONF.before-rename-$STAMP" >&2
echo "The prior accounting record $OLD_NAME was retained." >&2
exit 1
