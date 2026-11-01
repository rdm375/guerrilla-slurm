#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with sudo: sudo $0 /path/on/a/separate/backup-disk" >&2
  exit 1
fi
DEST=${1:-}
[[ -n $DEST && -d $DEST ]] || {
  echo "Usage: sudo $0 EXISTING_BACKUP_DIRECTORY" >&2
  exit 2
}
[[ -d /cluster && -d /var/lib/guerrilla-node ]] || {
  echo "This does not look like an initialized Guerrilla Cluster controller." >&2
  exit 1
}

for tool in findmnt realpath stat tar sha256sum mktemp systemctl squeue; do
  command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done

DEST=$(realpath "$DEST")
DEST_MOUNT=$(findmnt -n -o TARGET -T "$DEST")
DEST_SOURCE=$(findmnt -n -o SOURCE -T "$DEST")
ROOT_SOURCE=$(findmnt -n -o SOURCE -T /)
SHARE_SOURCE=$(findmnt -n -o SOURCE -T /cluster)
DEST_DEVICE=$(stat -c %d -- "$DEST")
ROOT_DEVICE=$(stat -c %d -- /)
SHARE_DEVICE=$(stat -c %d -- /cluster)
[[ $DEST_MOUNT != / && $DEST_SOURCE != "$ROOT_SOURCE" && \
   $DEST_SOURCE != "$SHARE_SOURCE" && $DEST_DEVICE != "$ROOT_DEVICE" && \
   $DEST_DEVICE != "$SHARE_DEVICE" ]] || {
  echo "Backup destination must be on a separate filesystem from / and /cluster." >&2
  exit 1
}
case "$DEST/" in
  /cluster/*) echo "Backup destination must not be inside /cluster." >&2; exit 1 ;;
esac

RESTART_SLURM=0
STAGING=
PUBLISHED=0
FINAL_SYSTEM=
FINAL_DATA=
FINAL_CHECKSUM=
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n $STAGING && -d $STAGING ]]; then
    rm -rf -- "$STAGING"
  fi
  if [[ $PUBLISHED -eq 0 ]]; then
    [[ -z $FINAL_SYSTEM ]] || rm -f -- "$FINAL_SYSTEM"
    [[ -z $FINAL_DATA ]] || rm -f -- "$FINAL_DATA"
    [[ -z $FINAL_CHECKSUM ]] || rm -f -- "$FINAL_CHECKSUM"
  fi
  if [[ $RESTART_SLURM -eq 1 ]] && ! systemctl start slurmctld.service slurmd.service; then
    echo "Backup cleanup could not restart Slurm services." >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

if systemctl is-active --quiet slurmctld.service; then
  if ! QUEUED_JOBS=$(squeue -h); then
    echo "Could not verify the Slurm queue; refusing to back up controller state." >&2
    exit 1
  fi
  if [[ -n $QUEUED_JOBS ]]; then
    echo "Refusing a controller backup while jobs are pending or running; drain the queue first." >&2
    exit 1
  fi
  RESTART_SLURM=1
  systemctl stop slurmd.service slurmctld.service
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SYSTEM_NAME="guerrilla-controller-system-$STAMP.tar.gz"
DATA_NAME="guerrilla-cluster-data-$STAMP.tar.gz"
CHECKSUM_NAME="guerrilla-controller-backup-$STAMP.sha256"
FINAL_SYSTEM="$DEST/$SYSTEM_NAME"
FINAL_DATA="$DEST/$DATA_NAME"
FINAL_CHECKSUM="$DEST/$CHECKSUM_NAME"
for path in "$FINAL_SYSTEM" "$FINAL_DATA" "$FINAL_CHECKSUM"; do
  [[ ! -e $path ]] || { echo "Backup output already exists: $path" >&2; exit 1; }
done
STAGING=$(mktemp -d "$DEST/.guerrilla-controller-backup-$STAMP.XXXXXX")
SYSTEM_STAGE="$STAGING/$SYSTEM_NAME"
DATA_STAGE="$STAGING/$DATA_NAME"
CHECKSUM_STAGE="$STAGING/$CHECKSUM_NAME"

SYSTEM_PATHS=(
  etc/guerrilla-node etc/munge etc/slurm etc/chrony/chrony.conf
  etc/hosts etc/exports.d/guerrilla-slurm.exports etc/fstab
  etc/systemd/network/05-guerrilla-dhcp.network
  etc/systemd/system/slurmctld.service.d/guerrilla-network.conf
  etc/systemd/system/slurmd.service.d/guerrilla-network.conf
  root/.ssh/guerrilla-cluster-ed25519 root/.ssh/guerrilla-cluster-ed25519.pub
  var/lib/guerrilla-node var/lib/slurmctld
)
EXISTING_PATHS=()
for path in "${SYSTEM_PATHS[@]}"; do
  [[ -e "/$path" ]] && EXISTING_PATHS+=("$path")
done
tar --numeric-owner --acls --xattrs --sparse -czf "$SYSTEM_STAGE" \
  -C / "${EXISTING_PATHS[@]}"
tar --numeric-owner --acls --xattrs --sparse -czf "$DATA_STAGE" -C /cluster .
tar -tzf "$SYSTEM_STAGE" >/dev/null
tar -tzf "$DATA_STAGE" >/dev/null
(cd "$STAGING" && sha256sum "$SYSTEM_NAME" "$DATA_NAME" > "$CHECKSUM_NAME" && \
  sha256sum --check "$CHECKSUM_NAME")
chmod 0600 "$SYSTEM_STAGE" "$DATA_STAGE" "$CHECKSUM_STAGE"

mv -- "$SYSTEM_STAGE" "$FINAL_SYSTEM"
mv -- "$DATA_STAGE" "$FINAL_DATA"
mv -- "$CHECKSUM_STAGE" "$FINAL_CHECKSUM"
PUBLISHED=1

echo "Backup complete on $DEST_MOUNT:"
printf '  %s\n' "$FINAL_SYSTEM" "$FINAL_DATA" "$FINAL_CHECKSUM"
