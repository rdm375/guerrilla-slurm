#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${NODE_IMAGE_OUTPUT_DIR:-"$ROOT/output/nodes"}
WORK=${NODE_IMAGE_WORK_DIR:-"$ROOT/work-nodes"}
MCAST=${QEMU_SHARED_MCAST:-230.0.0.1:12345}
LOCALADDR=${QEMU_SHARED_LOCALADDR:-127.0.0.1}

if [[ $# -ne 1 || ! -f $1 ]]; then
  echo "Usage: $0 MANIFEST.csv" >&2
  exit 2
fi
MANIFEST=$1
for tool in qemu-system-x86_64 sshpass ssh python3 timeout; do
  command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done
[[ -r $WORK/login-name ]] || { echo "Build the node images first." >&2; exit 1; }
LOGIN=$(<"$WORK/login-name")

UEFI_CODE=
UEFI_VARS_TEMPLATE=
for fwdir in /usr/share/OVMF /usr/share/ovmf; do
  for code in "$fwdir"/OVMF_CODE*.fd; do
    [[ -r $code ]] || continue
    [[ $code == *secboot* || $code == *.ms.fd ]] && continue
    vars=${code/OVMF_CODE/OVMF_VARS}
    [[ -r $vars ]] || continue
    UEFI_CODE=$code
    UEFI_VARS_TEMPLATE=$vars
    break 2
  done
done
[[ -n $UEFI_CODE && -n $UEFI_VARS_TEMPLATE ]] || { echo "Install ovmf." >&2; exit 1; }

mapfile -t NODES < <(python3 - "$MANIFEST" <<'PY'
import csv, re, sys

with open(sys.argv[1], newline="", encoding="utf-8") as stream:
    reader = csv.DictReader(stream)
    required = ["cluster_id", "node_id", "role", "hostname"]
    if reader.fieldnames != required:
        raise SystemExit(f"CSV header must be exactly: {','.join(required)}")
    rows = list(reader)
if len(rows) < 2 or len(rows) > 200:
    raise SystemExit("QEMU cluster test supports 2 to 200 manifest nodes.")
controllers = [row for row in rows if row["role"].strip() == "controller"]
if len(controllers) != 1:
    raise SystemExit("Manifest must contain exactly one controller.")
clusters = {row["cluster_id"].strip() for row in rows}
if len(clusters) != 1:
    raise SystemExit("All nodes must use one cluster_id.")
slug = re.compile(r"^[a-z][a-z0-9-]{0,30}[a-z0-9]$|^[a-z]$")
host_re = re.compile(r"^[a-z][a-z0-9-]{0,61}[a-z0-9]$|^[a-z]$")
ids, hosts = set(), set()
for index, row in enumerate(rows):
    cluster, node, role, host = (row[k].strip() for k in ("cluster_id", "node_id", "role", "hostname"))
    if not slug.fullmatch(cluster) or not slug.fullmatch(node) or not host_re.fullmatch(host):
        raise SystemExit(f"Invalid identity in manifest row for {node!r}.")
    if role not in {"controller", "worker"} or node in ids or host in hosts:
        raise SystemExit(f"Invalid role or duplicate node/hostname in manifest row for {node!r}.")
    ids.add(node); hosts.add(host)
    ip_last = 11 + index
    mac_last = index + 1
    port = 2221 + index
    # Use a non-whitespace separator: Bash treats tabs in IFS as whitespace
    # and collapses adjacent delimiters, shifting empty CSV fields.
    print("|".join((cluster, node, role, host, f"192.168.77.{ip_last}",
                     f"52:54:00:77:01:{mac_last:02x}", f"52:54:00:77:02:{mac_last:02x}", str(port))))
PY
)
[[ ${#NODES[@]} -ge 2 ]] || exit 1

for record in "${NODES[@]}"; do
  IFS='|' read -r _ node _ _ _ _ _ _ <<<"$record"
  [[ -s $OUT/$node.raw && -s $WORK/nodes/$node/seed.iso ]] || {
    echo "Missing raw image or NoCloud seed for $node; build the manifest first." >&2
    exit 1
  }
done

read -r -s -p "Shared initial node password: " BOOTSTRAP_PASSWORD
printf '\n'
[[ -n $BOOTSTRAP_PASSWORD ]] || { echo "Password cannot be empty." >&2; exit 2; }
export SSHPASS=$BOOTSTRAP_PASSWORD

declare -a PIDS=() PORTS=() IPS=() HOSTS=() NODE_IDS=()
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
ssh_node() {
  local port=$1; shift
  sshpass -e ssh "${SSH_OPTIONS[@]}" -p "$port" "$LOGIN@127.0.0.1" "$@"
}
cleanup() {
  local index pid
  trap - EXIT INT TERM
  for index in "${!PORTS[@]}"; do
    ssh_node "${PORTS[$index]}" 'sudo poweroff' >/dev/null 2>&1 || true
  done
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  unset SSHPASS BOOTSTRAP_PASSWORD
}
trap cleanup EXIT INT TERM

echo "Launching ${#NODES[@]} guests on a private QEMU LAN. Test IPv4 range: 192.168.77.11-210/24."
echo "QEMU guest logs: $WORK/qemu-NODE_ID.log"
for index in "${!NODES[@]}"; do
  IFS='|' read -r cluster node role host address wan_mac lan_mac port <<<"${NODES[$index]}"
  vars="$WORK/nodes/$node/OVMF_VARS-cluster.fd"
  cp "$UEFI_VARS_TEMPLATE" "$vars"
  if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    accel=(-enable-kvm -cpu host)
  else
    accel=(-accel tcg -cpu max)
  fi
  qemu-system-x86_64 "${accel[@]}" -display none -serial "file:$WORK/qemu-$node.log" -monitor none \
    -machine q35 -m "${QEMU_MEMORY:-2G}" -smp "${QEMU_CPUS:-2}" \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$UEFI_CODE" \
    -drive "if=pflash,format=raw,unit=1,file=$vars" \
    -drive "file=$OUT/$node.raw,format=raw,if=virtio,cache=none" \
    -cdrom "$WORK/nodes/$node/seed.iso" -boot order=c,once=d \
    -device "virtio-net-pci,netdev=wan,mac=$wan_mac" \
    -netdev "user,id=wan,hostfwd=tcp:127.0.0.1:$port-:22" \
    -device "virtio-net-pci,netdev=shared,mac=$lan_mac" \
    -netdev "socket,id=shared,mcast=$MCAST,localaddr=$LOCALADDR" \
    -name "Guerrilla $node" &
  PIDS+=("$!"); PORTS+=("$port"); IPS+=("$address"); HOSTS+=("$host"); NODE_IDS+=("$node")
  echo "  $node ($role, $host) -> $address, SSH host port $port"
done

for index in "${!PIDS[@]}"; do
  node=${NODE_IDS[$index]}; port=${PORTS[$index]}; address=${IPS[$index]}; hostname=${HOSTS[$index]}
  echo "Waiting for $node cloud-init and inventory..."
  connected=0
  for attempt in $(seq 1 180); do
    if ssh_node "$port" true >/dev/null 2>&1; then connected=1; break; fi
    kill -0 "${PIDS[$index]}" 2>/dev/null || { echo "QEMU exited while booting $node." >&2; exit 1; }
    sleep 5
  done
  [[ $connected -eq 1 ]] || { echo "SSH did not become ready for $node." >&2; exit 1; }
  ssh_node "$port" 'sudo cloud-init status --wait --long'
  inventory=$(ssh_node "$port" 'sudo /usr/local/sbin/guerrilla-node-inventory')
  GUERRILLA_INVENTORY_JSON=$inventory EXPECTED_NODE=$node EXPECTED_HOST=$hostname EXPECTED_ROLE=$(IFS='|' read -r _ _ role _ _ _ _ _ <<<"${NODES[$index]}"; printf '%s' "$role") \
    python3 - <<'PY'
import json, os
x=json.loads(os.environ["GUERRILLA_INVENTORY_JSON"])
for key, env in (("node_id", "EXPECTED_NODE"), ("hostname", "EXPECTED_HOST"), ("role", "EXPECTED_ROLE")):
    if x.get(key) != os.environ[env]:
        raise SystemExit(f"{key} mismatch: got {x.get(key)!r}, expected {os.environ[env]!r}")
print(f"  {x['node_id']} {x['hostname']} CPUs={x['cpu_count']} RAM={x['memory_bytes']} bytes")
PY
  IFS='|' read -r _ _ _ _ _ _ lan_mac _ <<<"${NODES[$index]}"
  remote="set -e; iface=\$(ip -o link show | awk -F': ' -v mac='$lan_mac' 'tolower(\$0) ~ tolower(mac) {print \$2; exit}'); test -n \"\$iface\"; sudo ip link set dev \"\$iface\" up; sudo ip address replace '$address/24' dev \"\$iface\"; sudo systemctl restart avahi-daemon.service; sudo systemctl restart guerrilla-node-advertise.service; sleep 2; systemctl is-active --quiet avahi-daemon.service guerrilla-node-advertise.service; ip -brief -4 address show dev \"\$iface\""
  ssh_node "$port" "$remote"
done

controller_index=-1
for index in "${!NODES[@]}"; do
  IFS='|' read -r _ _ role _ _ _ _ _ <<<"${NODES[$index]}"
  [[ $role == controller ]] && controller_index=$index
done
[[ $controller_index -ge 0 ]] || { echo "Controller missing from manifest." >&2; exit 1; }
controller_port=${PORTS[$controller_index]}
controller_ip=${IPS[$controller_index]}
count=${#NODES[@]}
expected_worker_ids=$(for index in "${!NODES[@]}"; do
  IFS='|' read -r _ node role _ _ _ _ _ <<<"${NODES[$index]}"
  [[ $role == worker ]] && printf '%s\n' "$node"
done | paste -sd, -)

echo "Manifest worker IDs: ${expected_worker_ids//,/ }"
echo "Installing this checkout's enrollment command on the controller..."
sshpass -e scp -P "$controller_port" "${SSH_OPTIONS[@]}" \
  "$ROOT/scripts/guerrilla-cluster-admin" "$LOGIN@127.0.0.1:/tmp/guerrilla-cluster-admin"
ssh_node "$controller_port" \
  'sudo install -o root -g root -m 0755 /tmp/guerrilla-cluster-admin /usr/local/sbin/guerrilla-cluster-admin && rm /tmp/guerrilla-cluster-admin'

echo "Initializing controller at $controller_ip..."
ssh_node "$controller_port" "sudo /usr/local/sbin/guerrilla-cluster-admin init-controller '$controller_ip'"
echo "Automatically enrolling advertised workers..."
printf '%s\n' "$BOOTSTRAP_PASSWORD" | sshpass -e ssh "${SSH_OPTIONS[@]}" -T -p "$controller_port" \
  "$LOGIN@127.0.0.1" \
  "sudo -n /usr/local/sbin/guerrilla-cluster-admin enroll-discovered-workers '$LOGIN' 192.168.77.0/24 --password-stdin --expect-node-ids '$expected_worker_ids'"

echo "Checking Slurm controller and running one task per node..."
ssh_node "$controller_port" 'sudo scontrol ping'
actual_nodes=$(ssh_node "$controller_port" 'sinfo -N -h -o %N' | sort)
expected_nodes=$(printf '%s\n' "${HOSTS[@]}" | sort)
[[ $actual_nodes == "$expected_nodes" ]] || {
  echo "Slurm has not registered exactly the manifest nodes." >&2
  printf 'Expected nodes:\n%s\nRegistered nodes:\n%s\n' "$expected_nodes" "$actual_nodes" >&2
  exit 1
}
ssh_node "$controller_port" "srun --immediate=30 -N $count -n $count --ntasks-per-node=1 hostname" | tee "$WORK/qemu-cluster-smoke.txt"
actual=$(sort "$WORK/qemu-cluster-smoke.txt")
[[ $actual == "$expected_nodes" ]] || {
  echo "Smoke test did not run on exactly the manifest nodes." >&2
  printf 'Expected:\n%s\nActual:\n%s\n' "$expected_nodes" "$actual" >&2
  exit 1
}
echo "PASS: Slurm ran one task on all $count manifest nodes."

echo "Shutting down QEMU guests cleanly..."
for index in "${!PORTS[@]}"; do ssh_node "${PORTS[$index]}" 'sudo poweroff' >/dev/null 2>&1 || true; done
for pid in "${PIDS[@]}"; do wait "$pid" || true; done
PIDS=()
trap - EXIT INT TERM
unset SSHPASS BOOTSTRAP_PASSWORD
