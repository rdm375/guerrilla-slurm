#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"
SLURM_SHARED_EXPORT=${SLURM_SHARED_EXPORT:-/srv/slurm-share}

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with sudo: sudo $0 /path/on/mounted/backup-disk" >&2
  exit 1
fi
DEST=${1:-}
[[ -n "$DEST" ]] || {
  echo "Usage: sudo $0 /path/on/mounted/backup-disk" >&2
  exit 2
}
[[ -d "$SLURM_SHARED_EXPORT" ]] || {
  echo "Shared data directory not found: $SLURM_SHARED_EXPORT" >&2
  exit 1
}
install -d -m 0700 "$DEST"
DEST=$(realpath "$DEST")
MOUNTPOINT=$(findmnt -n -o TARGET -T "$DEST")
DEST_SOURCE=$(findmnt -n -o SOURCE -T "$DEST")
SHARE_SOURCE=$(findmnt -n -o SOURCE -T "$SLURM_SHARED_EXPORT")
[[ "$MOUNTPOINT" != / ]] || {
  echo "Backup destination must be on a separately mounted disk, not the root filesystem." >&2
  exit 1
}
[[ "$DEST_SOURCE" != "$SHARE_SOURCE" ]] || {
  echo "Backup destination is on the same filesystem as the shared data." >&2
  exit 1
}
case "$DEST/" in
  "$SLURM_SHARED_EXPORT"/*)
    echo "Backup destination must not be inside the exported shared directory." >&2
    exit 1
    ;;
esac

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SYSTEM_ARCHIVE="$DEST/slurm-controller-system-$STAMP.tar.gz"
SHARE_ARCHIVE="$DEST/slurm-shared-data-$STAMP.tar.gz"
ARCHIVES=("$SYSTEM_ARCHIVE" "$SHARE_ARCHIVE")

tar --numeric-owner --acls --xattrs --sparse -czf "$SYSTEM_ARCHIVE" \
  -C / etc/munge etc/slurm etc/hosts etc/exports.d/slurm.exports etc/fstab \
  var/lib/slurmctld
tar --numeric-owner --acls --xattrs --sparse -czf "$SHARE_ARCHIVE" \
  -C "$SLURM_SHARED_EXPORT" .
if command -v mariadb-dump >/dev/null 2>&1 && \
   mariadb -NBe "SHOW DATABASES LIKE 'slurm_acct_db'" | grep -qx slurm_acct_db; then
  ACCOUNTING_DUMP="$DEST/slurm-accounting-db-$STAMP.sql.gz"
  mariadb-dump --single-transaction --routines --triggers slurm_acct_db |
    gzip -9 > "$ACCOUNTING_DUMP"
  ARCHIVES+=("$ACCOUNTING_DUMP")
fi
chmod 0600 "${ARCHIVES[@]}"
BASENAMES=()
for archive in "${ARCHIVES[@]}"; do BASENAMES+=("$(basename "$archive")"); done
(cd "$DEST" && sha256sum "${BASENAMES[@]}" > "slurm-backup-$STAMP.sha256")
chmod 0600 "$DEST/slurm-backup-$STAMP.sha256"

echo "Backup complete on $MOUNTPOINT:"
printf '  %s\n' "${ARCHIVES[@]}" "$DEST/slurm-backup-$STAMP.sha256"
