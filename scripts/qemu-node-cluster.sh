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
for tool in qemu-system-x86_64 qemu-img sshpass ssh python3 timeout; do
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
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=3)
ssh_node() {
  local port=$1; shift
  sshpass -e ssh "${SSH_OPTIONS[@]}" -p "$port" "$LOGIN@127.0.0.1" "$@"
}
cleanup() {
  local index pid
  trap - EXIT INT TERM
  if [[ -n ${PROVISION_PID:-} ]]; then
    kill "$PROVISION_PID" 2>/dev/null || true
    wait "$PROVISION_PID" 2>/dev/null || true
  fi
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

# Run cloud-init against each base image once. This leaves a deployable raw
# image with its unique identity and packages; the cluster qualification runs
# in disposable overlays so test addresses and credentials do not reach USB.
for record in "${NODES[@]}"; do
  IFS='|' read -r _ node role host _ _ _ port <<<"$record"
  echo "Preparing deployable raw image for $node ($host)..."
  vars="$WORK/nodes/$node/OVMF_VARS-firstboot.fd"
  cp "$UEFI_VARS_TEMPLATE" "$vars"
  if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    accel=(-enable-kvm -cpu host)
  else
    accel=(-accel tcg -cpu max)
  fi
  qemu-system-x86_64 "${accel[@]}" -display none -serial "file:$WORK/qemu-firstboot-$node.log" -monitor none \
    -machine q35 -m "${QEMU_MEMORY:-2G}" -smp "${QEMU_CPUS:-2}" \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$UEFI_CODE" \
    -drive "if=pflash,format=raw,unit=1,file=$vars" \
    -drive "file=$OUT/$node.raw,format=raw,if=virtio,cache=none" \
    -cdrom "$WORK/nodes/$node/seed.iso" -boot order=c,once=d \
    -netdev "user,id=wan,hostfwd=tcp:127.0.0.1:$port-:22" \
    -device virtio-net-pci,netdev=wan -name "Guerrilla firstboot $node" &
  PROVISION_PID=$!
  connected=0
  for attempt in $(seq 1 180); do
    if ssh_node "$port" true >/dev/null 2>&1; then connected=1; break; fi
    kill -0 "$PROVISION_PID" 2>/dev/null || { echo "QEMU exited while preparing $node." >&2; exit 1; }
    sleep 5
  done
  [[ $connected -eq 1 ]] || { echo "SSH did not become ready while preparing $node." >&2; exit 1; }
  if ! ssh_node "$port" 'sudo cloud-init status --wait --long'; then
    echo "First-boot cloud-init failed on $node; do not write this image to USB. Check guest DNS/network and rebuild the raw image after correcting the cause." >&2
    exit 1
  fi
  if [[ $role == controller ]]; then
    if ! ssh_node "$port" 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; for tool in slurmd munge chronyc avahi-publish-service exportfs; do command -v "$tool" >/dev/null || { echo "Missing required first-boot tool: $tool" >&2; exit 1; }; done; sudo slurmd -C >/dev/null'; then
      echo "First-boot package verification failed on $node; do not write this image to USB. Check guest DNS/network and rebuild the raw image after correcting the cause." >&2
      exit 1
    fi
  else
    if ! ssh_node "$port" 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; for tool in slurmd munge chronyc avahi-publish-service mount.nfs4; do command -v "$tool" >/dev/null || { echo "Missing required first-boot tool: $tool" >&2; exit 1; }; done; sudo slurmd -C >/dev/null'; then
      echo "First-boot package verification failed on $node; do not write this image to USB. Check guest DNS/network and rebuild the raw image after correcting the cause." >&2
      exit 1
    fi
  fi
  inventory=$(ssh_node "$port" 'sudo /usr/local/sbin/guerrilla-node-inventory')
  GUERRILLA_INVENTORY_JSON=$inventory EXPECTED_NODE=$node EXPECTED_HOST=$host EXPECTED_ROLE=$role \
    python3 - <<'PY'
import json, os
x=json.loads(os.environ["GUERRILLA_INVENTORY_JSON"])
for key, env in (("node_id", "EXPECTED_NODE"), ("hostname", "EXPECTED_HOST"), ("role", "EXPECTED_ROLE")):
    if x.get(key) != os.environ[env]:
        raise SystemExit(f"{key} mismatch: got {x.get(key)!r}, expected {os.environ[env]!r}")
PY
  ssh_node "$port" 'sudo poweroff' >/dev/null 2>&1 || true
  wait "$PROVISION_PID" || true
  unset PROVISION_PID
done

for record in "${NODES[@]}"; do
  IFS='|' read -r _ node _ _ _ _ _ _ <<<"$record"
  overlay="$WORK/nodes/$node/qemu-cluster-overlay.qcow2"
  rm -f -- "$overlay"
  qemu-img create -q -f qcow2 -F raw -b "$OUT/$node.raw" "$overlay"
done

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
    -drive "file=$WORK/nodes/$node/qemu-cluster-overlay.qcow2,format=qcow2,if=virtio,cache=none" \
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
  remote="set -e; iface=\$(ip -o link show | awk -F': ' -v mac='$lan_mac' 'tolower(\$0) ~ tolower(mac) {print \$2; exit}'); test -n \"\$iface\"; printf '[Match]\\nMACAddress=$lan_mac\\n\\n[Network]\\nAddress=$address/24\\nDHCP=no\\nIPv6AcceptRA=no\\n' | sudo tee /etc/systemd/network/04-guerrilla-qemu-test.network >/dev/null; sudo networkctl reload; sudo networkctl reconfigure \"\$iface\"; sudo systemctl restart avahi-daemon.service guerrilla-node-advertise.service; sleep 2; systemctl is-active --quiet avahi-daemon.service guerrilla-node-advertise.service; ip -brief -4 address show dev \"\$iface\""
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
echo "Installing this checkout's enrollment command and Slurm config generator on the controller..."
sshpass -e scp -P "$controller_port" "${SSH_OPTIONS[@]}" \
  "$ROOT/scripts/guerrilla-cluster-admin" \
  "$ROOT/scripts/generate-slurm-config.py" \
  "$ROOT/scripts/install-enrolled-slurm-node" \
  "$LOGIN@127.0.0.1:/tmp/"
ssh_node "$controller_port" \
  'sudo install -o root -g root -m 0755 /tmp/guerrilla-cluster-admin /usr/local/sbin/guerrilla-cluster-admin && sudo install -d -o root -g root -m 0755 /usr/local/lib/guerrilla-slurm && sudo install -o root -g root -m 0755 /tmp/generate-slurm-config.py /usr/local/lib/guerrilla-slurm/generate-slurm-config.py && sudo install -o root -g root -m 0755 /tmp/install-enrolled-slurm-node /usr/local/lib/guerrilla-slurm/install-enrolled-slurm-node && rm /tmp/guerrilla-cluster-admin /tmp/generate-slurm-config.py /tmp/install-enrolled-slurm-node'

echo "Initializing controller at $controller_ip..."
ssh_node "$controller_port" "sudo /usr/local/sbin/guerrilla-cluster-admin init-controller '$controller_ip' 192.168.77.0/24"
echo "Automatically enrolling advertised workers..."
printf '%s\n' "$BOOTSTRAP_PASSWORD" | sshpass -e ssh "${SSH_OPTIONS[@]}" -T -p "$controller_port" \
  "$LOGIN@127.0.0.1" \
  "sudo -n /usr/local/sbin/guerrilla-cluster-admin enroll-discovered-workers '$LOGIN' 192.168.77.0/24 --password-stdin --expect-node-ids '$expected_worker_ids'"

echo "Checking cluster clock synchronization..."
for index in "${!NODES[@]}"; do
  node=${NODE_IDS[$index]}; port=${PORTS[$index]}
  synchronized=0
  tracking=
  for attempt in $(seq 1 20); do
    tracking=$(ssh_node "$port" 'chronyc tracking')
    if grep -q 'Leap status.*Normal' <<<"$tracking"; then synchronized=1; break; fi
    sleep 2
  done
  [[ $synchronized -eq 1 ]] || {
    echo "MUNGE time synchronization is not healthy on $node:" >&2
    printf '%s\n' "$tracking" >&2
    exit 1
  }
done
echo "PASS: chrony is synchronized on all manifest nodes."

echo "Checking Slurm controller and running one task per node..."
ssh_node "$controller_port" 'sudo scontrol ping'
actual_nodes=$(ssh_node "$controller_port" 'sinfo -N -h -o %N' | sort)
expected_nodes=$(printf '%s\n' "${HOSTS[@]}" | sort)
[[ $actual_nodes == "$expected_nodes" ]] || {
  echo "Slurm has not registered exactly the manifest nodes." >&2
  printf 'Expected nodes:\n%s\nRegistered nodes:\n%s\n' "$expected_nodes" "$actual_nodes" >&2
  exit 1
}
storage_probe="/cluster/results/.guerrilla-nfs-probe-${RANDOM}-$$"
for index in "${!NODES[@]}"; do
  IFS='|' read -r _ node role _ _ _ _ _ <<<"${NODES[$index]}"
  [[ $role == worker ]] || continue
  worker_port=${PORTS[$index]}
  ssh_node "$worker_port" "printf '%s' '$node' > '$storage_probe'"
  observed=$(ssh_node "$controller_port" "cat '$storage_probe'")
  [[ $observed == "$node" ]] || {
    echo "NFS write from $node was not visible on the controller." >&2
    exit 1
  }
  ssh_node "$controller_port" "rm -f '$storage_probe'"
  echo "  Shared /cluster write/read passed for $node."
done
ssh_node "$controller_port" "srun --immediate=30 -N $count -n $count --ntasks-per-node=1 hostname" | tee "$WORK/qemu-cluster-smoke.txt"
actual=$(sort "$WORK/qemu-cluster-smoke.txt")
[[ $actual == "$expected_nodes" ]] || {
  echo "Smoke test did not run on exactly the manifest nodes." >&2
  printf 'Expected:\n%s\nActual:\n%s\n' "$expected_nodes" "$actual" >&2
  exit 1
}
echo "PASS: Slurm ran one task on all $count manifest nodes."
echo "PASS: Every worker verified shared NFS storage at /cluster."

batch_script="$WORK/qemu-batch-smoke.sbatch"
cat > "$batch_script" <<EOF
#!/usr/bin/env bash
#SBATCH --job-name=guerrilla-qemu-batch
#SBATCH --nodes=$count
#SBATCH --ntasks=$count
#SBATCH --ntasks-per-node=1
#SBATCH --output=/cluster/results/.guerrilla-qemu-batch-%j.log
set +e
srun --ntasks="\$SLURM_NTASKS" --ntasks-per-node=1 hostname > "/cluster/results/.guerrilla-qemu-batch-\$SLURM_JOB_ID.nodes"
result=\$?
printf '%s' "\$result" > "/cluster/results/.guerrilla-qemu-batch-\$SLURM_JOB_ID.status"
exit "\$result"
EOF
remote_batch="/tmp/guerrilla-qemu-batch-$$.sbatch"
sshpass -e scp -P "$controller_port" "${SSH_OPTIONS[@]}" \
  "$batch_script" "$LOGIN@127.0.0.1:$remote_batch"
batch_submit=$(ssh_node "$controller_port" "sbatch --parsable '$remote_batch'")
batch_job=${batch_submit%%;*}
[[ $batch_job =~ ^[0-9]+$ ]] || { echo "Could not parse sbatch job ID: $batch_submit" >&2; exit 1; }
echo "Submitted batch smoke job $batch_job; waiting for completion..."
batch_status=
for attempt in $(seq 1 90); do
  batch_status=$(ssh_node "$controller_port" \
    "cat '/cluster/results/.guerrilla-qemu-batch-$batch_job.status' 2>/dev/null || true")
  [[ -n $batch_status ]] && break
  sleep 2
done
[[ $batch_status == 0 ]] || {
  echo "Batch smoke job $batch_job failed or timed out (status=${batch_status:-missing})." >&2
  ssh_node "$controller_port" "cat '/cluster/results/.guerrilla-qemu-batch-$batch_job.log' 2>/dev/null || true" >&2
  exit 1
}
batch_nodes=$(ssh_node "$controller_port" \
  "cat '/cluster/results/.guerrilla-qemu-batch-$batch_job.nodes'" | sort)
[[ $batch_nodes == "$expected_nodes" ]] || {
  echo "Batch job did not run one task on each manifest node." >&2
  printf 'Expected:\n%s\nActual:\n%s\n' "$expected_nodes" "$batch_nodes" >&2
  exit 1
}
ssh_node "$controller_port" "rm -f '/cluster/results/.guerrilla-qemu-batch-$batch_job.'* '$remote_batch'"
echo "PASS: sbatch completed one task on every manifest node and wrote results to /cluster/results."

# Exercise worker recovery and address refresh while retaining the same node identity.
worker_index=-1
for index in "${!NODES[@]}"; do
  IFS='|' read -r _ _ role _ _ _ _ _ <<<"${NODES[$index]}"
  if [[ $role == worker ]]; then worker_index=$index; break; fi
done
worker_port=${PORTS[$worker_index]}
old_worker_ip=${IPS[$worker_index]}
new_worker_ip=192.168.77.211
[[ ! " ${IPS[*]} " =~ " $new_worker_ip " ]] || { echo "Recovery-test address collision." >&2; exit 1; }
echo "Rebooting ${NODE_IDS[$worker_index]} to qualify worker recovery..."
worker_boot_id=$(ssh_node "$worker_port" 'cat /proc/sys/kernel/random/boot_id')
ssh_node "$worker_port" 'sudo systemd-run --quiet --no-block --on-active=2s /usr/bin/systemctl reboot' >/dev/null 2>&1 || true
rebooted=0
for attempt in $(seq 1 120); do
  current_boot_id=$(ssh_node "$worker_port" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
  if [[ -n $current_boot_id && $current_boot_id != "$worker_boot_id" ]]; then
    rebooted=1
    break
  fi
  if ! kill -0 "${PIDS[$worker_index]}" 2>/dev/null; then
    echo "Worker QEMU process exited during reboot." >&2
    exit 1
  fi
  if (( attempt % 10 == 0 )); then
    echo "Waiting for worker reboot to complete (attempt $attempt/120)..."
  fi
  sleep 2
done
[[ $rebooted -eq 1 ]] || { echo "Worker boot ID did not change after reboot." >&2; exit 1; }
IFS='|' read -r _ _ _ _ _ _ worker_lan_mac _ <<<"${NODES[$worker_index]}"
ssh_node "$worker_port" "sudo cloud-init status --wait >/dev/null; iface=\$(ip -o link show | awk -F': ' -v mac='$worker_lan_mac' 'tolower(\$0) ~ tolower(mac) {print \$2; exit}'); test -n \"\$iface\"; printf '[Match]\\nMACAddress=$worker_lan_mac\\n\\n[Network]\\nAddress=$new_worker_ip/24\\nDHCP=no\\nIPv6AcceptRA=no\\n' | sudo tee /etc/systemd/network/04-guerrilla-qemu-test.network >/dev/null; sudo networkctl reload; sudo networkctl reconfigure \"\$iface\"; sudo systemctl restart avahi-daemon.service guerrilla-node-advertise.service; sleep 2"
ssh_node "$controller_port" \
  "sudo /usr/local/sbin/guerrilla-cluster-admin enroll-discovered-workers '$LOGIN' 192.168.77.0/24 --expect-node-ids '$expected_worker_ids'"
worker_hostname=${HOSTS[$worker_index]}
node_address=$(ssh_node "$controller_port" "scontrol show node '$worker_hostname' -o" | sed -n 's/.*NodeAddr=\([^ ]*\).*/\1/p')
[[ $node_address == "$new_worker_ip" ]] || {
  echo "Controller did not refresh $worker_hostname to $new_worker_ip (got ${node_address:-none})." >&2
  exit 1
}
echo "PASS: worker rebooted, rejoined with its existing key, and refreshed its address to $new_worker_ip."

echo "Rebooting the controller to qualify service and state recovery..."
controller_boot_id=$(ssh_node "$controller_port" 'cat /proc/sys/kernel/random/boot_id')
ssh_node "$controller_port" 'sudo systemd-run --quiet --no-block --on-active=2s /usr/bin/systemctl reboot' >/dev/null 2>&1 || true
controller_rebooted=0
for attempt in $(seq 1 120); do
  current_boot_id=$(ssh_node "$controller_port" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
  if [[ -n $current_boot_id && $current_boot_id != "$controller_boot_id" ]]; then
    controller_rebooted=1
    break
  fi
  if ! kill -0 "${PIDS[$controller_index]}" 2>/dev/null; then
    echo "Controller QEMU process exited during reboot." >&2
    exit 1
  fi
  if (( attempt % 10 == 0 )); then
    echo "Waiting for controller reboot to complete (attempt $attempt/120)..."
  fi
  sleep 2
done
[[ $controller_rebooted -eq 1 ]] || { echo "Controller boot ID did not change after reboot." >&2; exit 1; }
controller_ready=0
for attempt in $(seq 1 60); do
  if ssh_node "$controller_port" 'sudo scontrol ping >/dev/null 2>&1 && systemctl is-active --quiet nfs-kernel-server chrony'; then
    controller_ready=1; break
  fi
  sleep 2
done
[[ $controller_ready -eq 1 ]] || { echo "Slurm/NFS/chrony did not recover after controller reboot." >&2; exit 1; }
actual_nodes=$(ssh_node "$controller_port" 'sinfo -N -h -o %N' | sort)
[[ $actual_nodes == "$expected_nodes" ]] || {
  echo "Controller reboot changed the registered node set." >&2
  printf 'Expected:\n%s\nActual:\n%s\n' "$expected_nodes" "$actual_nodes" >&2
  exit 1
}
echo "Controller services and node registry are present after reboot."
expected_idle_states=$(while IFS= read -r node; do
  [[ -n $node ]] && printf '%s idle\n' "$node"
done <<<"$expected_nodes" | sort)
nodes_idle=0
for attempt in $(seq 1 60); do
  node_states=$(ssh_node "$controller_port" "sinfo -N -h -o '%N %T' | sort" 2>/dev/null || true)
  if [[ $node_states == "$expected_idle_states" ]]; then
    nodes_idle=1
    break
  fi
  if (( attempt % 5 == 0 )); then
    echo "Waiting for all Slurm nodes to become IDLE (attempt $attempt/60):"
    printf '%s\n' "$node_states"
  fi
  sleep 2
done
if [[ $nodes_idle -ne 1 ]]; then
  echo "Slurm nodes did not all return to IDLE after controller reboot:" >&2
  ssh_node "$controller_port" 'sinfo -N -o "%N %T %C"; scontrol show node -o' >&2 || true
  exit 1
fi
echo "PASS: all manifest nodes returned to IDLE after controller reboot."

recovered_probe="/cluster/results/.guerrilla-recovery-probe-$$"
for index in "${!NODES[@]}"; do
  IFS='|' read -r _ node role _ _ _ _ _ <<<"${NODES[$index]}"
  [[ $role == worker ]] || continue
  ssh_node "${PORTS[$index]}" "printf '%s' '$node' > '$recovered_probe'"
  recovered_value=$(ssh_node "$controller_port" "cat '$recovered_probe'")
  [[ $recovered_value == "$node" ]] || { echo "NFS recovery probe failed for $node." >&2; exit 1; }
done
ssh_node "$controller_port" "rm -f '$recovered_probe'"
recovered_srun=$(ssh_node "$controller_port" \
  "srun --immediate=30 -N $count -n $count --ntasks-per-node=1 hostname" | sort)
[[ $recovered_srun == "$expected_nodes" ]] || {
  echo "Slurm could not schedule across the cluster after controller reboot." >&2
  printf 'Expected:\n%s\nActual:\n%s\n' "$expected_nodes" "$recovered_srun" >&2
  exit 1
}
echo "PASS: shared storage and cross-node scheduling recovered after controller reboot."

echo "Shutting down QEMU guests cleanly..."
for index in "${!PORTS[@]}"; do ssh_node "${PORTS[$index]}" 'sudo poweroff' >/dev/null 2>&1 || true; done
for pid in "${PIDS[@]}"; do wait "$pid" || true; done
PIDS=()
trap - EXIT INT TERM
unset SSHPASS BOOTSTRAP_PASSWORD
