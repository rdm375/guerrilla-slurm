#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$ROOT/cluster.env"

if [[ ${EUID} -ne 0 ]]; then
  echo "Run from your dell7710 login: sudo $0" >&2
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
getent passwd "$CALLER" >/dev/null
CLUSTER=$(awk -F= '$1 == "ClusterName" {print $2; exit}' /etc/slurm/slurm.conf)
[[ -n "$CLUSTER" ]] || { echo "ClusterName is missing from /etc/slurm/slurm.conf." >&2; exit 1; }

if squeue -h -o '%i' | grep -q .; then
  echo "Drain/finish queued and running jobs before enabling accounting; slurmctld will restart." >&2
  exit 1
fi

run_as_caller() { runuser -u "$CALLER" -- "$@"; }
run_as_caller ssh -o BatchMode=yes "$CALLER@$SLURM_COMPUTE_IP" 'sudo -n true' || {
  echo "Passwordless SSH and sudo from $CALLER to $SLURM_COMPUTE_IP are required to distribute slurm.conf." >&2
  exit 1
}

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server slurmdbd

if [[ -s /etc/slurm/slurmdbd.conf ]]; then
  DB_PASSWORD=$(sed -n 's/^StoragePass=//p' /etc/slurm/slurmdbd.conf | head -n1)
else
  DB_PASSWORD=$(openssl rand -hex 32)
fi
[[ -n "$DB_PASSWORD" ]] || { echo "Could not generate/read the slurmdbd database password." >&2; exit 1; }

systemctl enable --now mariadb munge
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS slurm_acct_db CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
ALTER DATABASE slurm_acct_db CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER 'slurm'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'localhost';
FLUSH PRIVILEGES;
SQL

install -d -o slurm -g slurm -m 0755 /var/log/slurm
cat > /etc/slurm/slurmdbd.conf <<EOF
AuthType=auth/munge
DbdHost=dell7710
DbdAddr=${SLURM_CONTROLLER_IP}
DbdPort=6819
SlurmUser=slurm
StorageType=accounting_storage/mysql
StorageHost=localhost
StoragePort=3306
StorageUser=slurm
StoragePass=${DB_PASSWORD}
StorageLoc=slurm_acct_db
LogFile=/var/log/slurm/slurmdbd.log
EOF
chown slurm:slurm /etc/slurm/slurmdbd.conf
chmod 0600 /etc/slurm/slurmdbd.conf
unset DB_PASSWORD

# slurmdbd validates slurmdbd.conf even when asked to print its version.
# Keep this check after the first complete config has been written; otherwise
# a fresh installation exits before it can create the file.
CTLD_VERSION=$(slurmctld -V | awk '{print $2}')
DBD_VERSION=$(slurmdbd -V | awk '{print $2}')
[[ "$CTLD_VERSION" == "$DBD_VERSION" ]] || {
  echo "Version mismatch: slurmctld=$CTLD_VERSION slurmdbd=$DBD_VERSION. No Slurm config was changed." >&2
  exit 1
}

set_slurm_conf() {
  local key=$1 value=$2
  if grep -q "^${key}=" /etc/slurm/slurm.conf; then
    sed -i "s#^${key}=.*#${key}=${value}#" /etc/slurm/slurm.conf
  else
    printf '%s=%s\n' "$key" "$value" >> /etc/slurm/slurm.conf
  fi
}
STAMP=$(date +%Y%m%d%H%M%S)
cp -a /etc/slurm/slurm.conf "/etc/slurm/slurm.conf.before-accounting-$STAMP"
set_slurm_conf AccountingStorageType accounting_storage/slurmdbd
set_slurm_conf AccountingStorageHost dell7710
set_slurm_conf AccountingStoragePort 6819
set_slurm_conf JobAcctGatherType jobacct_gather/linux
set_slurm_conf JobAcctGatherFrequency 30
chown root:root /etc/slurm/slurm.conf
chmod 0644 /etc/slurm/slurm.conf

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow from "$SLURM_CONTROLLER_IP" to any port 6819 proto tcp
  ufw allow from "$SLURM_COMPUTE_IP" to any port 6819 proto tcp
fi

run_as_caller scp -o BatchMode=yes /etc/slurm/slurm.conf \
  "$CALLER@$SLURM_COMPUTE_IP:/tmp/slurm.conf"
run_as_caller ssh -o BatchMode=yes "$CALLER@$SLURM_COMPUTE_IP" \
  'sudo -n install -o root -g root -m 0644 /tmp/slurm.conf /etc/slurm/slurm.conf && sudo -n systemctl restart slurmd'

systemctl enable slurmdbd
systemctl restart slurmdbd
systemctl is-active --quiet slurmdbd || {
  journalctl -u slurmdbd --no-pager -n 50 >&2
  exit 1
}
systemctl restart slurmctld
systemctl is-active --quiet slurmctld || {
  journalctl -u slurmctld --no-pager -n 50 >&2
  exit 1
}

for attempt in {1..30}; do
  sacctmgr -nP show cluster format=Cluster >/dev/null 2>&1 && break
  sleep 2
done
sacctmgr -nP show cluster format=Cluster | grep -Fxq "$CLUSTER" ||
  sacctmgr -i add cluster "$CLUSTER"
sacctmgr -nP show assoc where "cluster=$CLUSTER" "account=default" \
  format=Cluster,Account | grep -Fxq "$CLUSTER|default" ||
  sacctmgr -i add account name=default cluster="$CLUSTER" Description=Default
sacctmgr -nP show assoc where cluster="$CLUSTER" user="$CALLER" format=User,Account |
  grep -Fxq "$CALLER|default" ||
  sacctmgr -i add user name="$CALLER" account=default cluster="$CLUSTER"

echo "SlurmDBD accounting is enabled for cluster $CLUSTER."
echo "Default account association created for $CALLER."
echo "Verify with: sacctmgr show cluster; sacctmgr show assoc where cluster=$CLUSTER"
echo "Accounting config backup: /etc/slurm/slurm.conf.before-accounting-$STAMP"
