#!/usr/bin/env bash
set -euo pipefail

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

DEST=$(realpath "$DEST")
DEST_MOUNT=$(findmnt -n -o TARGET -T "$DEST")
DEST_SOURCE=$(findmnt -n -o SOURCE -T "$DEST")
ROOT_SOURCE=$(findmnt -n -o SOURCE -T /)
SHARE_SOURCE=$(findmnt -n -o SOURCE -T /cluster)
[[ $DEST_MOUNT != / && $DEST_SOURCE != "$ROOT_SOURCE" && $DEST_SOURCE != "$SHARE_SOURCE" ]] || {
  echo "Backup destination must be on a separately mounted filesystem." >&2
  exit 1
}
case "$DEST/" in
  /cluster/*) echo "Backup destination must not be inside /cluster." >&2; exit 1 ;;
esac

RESTART_SLURM=0
if systemctl is-active --quiet slurmctld.service; then
  if [[ -n $(squeue -h 2>/dev/null || true) ]]; then
    echo "Refusing a controller backup while jobs are pending or running; drain the queue first." >&2
    exit 1
  fi
  RESTART_SLURM=1
  systemctl stop slurmd.service slurmctld.service
fi
restart_slurm() {
  if [[ $RESTART_SLURM -eq 1 ]]; then
    systemctl start slurmctld.service slurmd.service
  fi
}
trap restart_slurm EXIT

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SYSTEM_ARCHIVE="$DEST/guerrilla-controller-system-$STAMP.tar.gz"
DATA_ARCHIVE="$DEST/guerrilla-cluster-data-$STAMP.tar.gz"
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
tar --numeric-owner --acls --xattrs --sparse -czf "$SYSTEM_ARCHIVE" \
  -C / "${EXISTING_PATHS[@]}"
tar --numeric-owner --acls --xattrs --sparse -czf "$DATA_ARCHIVE" -C /cluster .
chmod 0600 "$SYSTEM_ARCHIVE" "$DATA_ARCHIVE"
(cd "$DEST" && sha256sum "$(basename "$SYSTEM_ARCHIVE")" "$(basename "$DATA_ARCHIVE")" \
  > "guerrilla-controller-backup-$STAMP.sha256")
chmod 0600 "$DEST/guerrilla-controller-backup-$STAMP.sha256"

echo "Backup complete on $DEST_MOUNT:"
printf '  %s\n' "$SYSTEM_ARCHIVE" "$DATA_ARCHIVE" "$DEST/guerrilla-controller-backup-$STAMP.sha256"
