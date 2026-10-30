#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${NODE_IMAGE_OUTPUT_DIR:-"$ROOT/output/nodes"}
WORK=${NODE_IMAGE_WORK_DIR:-"$ROOT/work-nodes"}
if [[ $# -ne 3 ]]; then
  echo "Usage: $0 MANIFEST.csv CONTROLLER_NODE_ID WORKER_NODE_ID" >&2
  exit 2
fi
MANIFEST=$1
CONTROLLER=$2
WORKER=$3
[[ $CONTROLLER != "$WORKER" ]] || { echo "Choose two different nodes." >&2; exit 2; }
command -v qemu-system-x86_64 >/dev/null || { echo "Install qemu-system-x86." >&2; exit 1; }
[[ -f $MANIFEST ]] || { echo "Manifest not found: $MANIFEST" >&2; exit 1; }

mapfile -t NODES < <(python3 - "$MANIFEST" "$CONTROLLER" "$WORKER" <<'PY'
import csv, sys
path, controller, worker = sys.argv[1:]
with open(path, newline="", encoding="utf-8") as source:
    rows = list(csv.DictReader(source))
by_id = {row["node_id"].strip(): row for row in rows}
if controller not in by_id or worker not in by_id:
    raise SystemExit("Both node IDs must be present in the manifest.")
if by_id[controller]["role"].strip() != "controller" or by_id[worker]["role"].strip() != "worker":
    raise SystemExit("Select one controller node and one worker node.")
for node in (controller, worker):
    print("\t".join((node, by_id[node]["hostname"].strip())))
PY
)
[[ ${#NODES[@]} -eq 2 ]] || exit 1

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

if [[ -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} ]]; then
  echo "This two-guest test needs graphical QEMU windows for the guest consoles." >&2
  echo "Run it from the Ubuntu desktop session." >&2
  exit 1
fi

declare -a PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

launch_node() {
  local index=$1 record=$2 id hostname raw seed vars wan_mac lan_mac forward
  local -a accel
  IFS=$'\t' read -r id hostname <<<"$record"
  raw="$OUT/$id.raw"
  seed="$WORK/nodes/$id/seed.iso"
  vars="$WORK/nodes/$id/OVMF_VARS-pair.fd"
  [[ -s $raw && -s $seed ]] || { echo "Missing image or seed for $id; build it first." >&2; exit 1; }
  cp "$UEFI_VARS_TEMPLATE" "$vars"
  if [[ $index -eq 1 ]]; then
    wan_mac=52:54:00:77:01:11; lan_mac=52:54:00:77:02:11; forward=2221
  else
    wan_mac=52:54:00:77:01:12; lan_mac=52:54:00:77:02:12; forward=2222
  fi
  if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    accel=(-enable-kvm -cpu host)
  else
    accel=(-accel tcg -cpu max)
  fi
  echo "Launching $id ($hostname); host SSH port $forward; shared-QEMU NIC MAC $lan_mac."
  qemu-system-x86_64 "${accel[@]}" -machine q35 -m "${QEMU_MEMORY:-6G}" -smp "${QEMU_CPUS:-2}" \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$UEFI_CODE" \
    -drive "if=pflash,format=raw,unit=1,file=$vars" \
    -drive "file=$raw,format=raw,if=virtio,cache=none" \
    -cdrom "$seed" -boot order=c,once=d \
    -device "virtio-net-pci,netdev=wan,mac=$wan_mac" \
    -netdev "user,id=wan,hostfwd=tcp::$forward-:22" \
    -device "virtio-net-pci,netdev=shared,mac=$lan_mac" \
    -netdev "socket,id=shared,mcast=${QEMU_SHARED_MCAST:-230.0.0.1:12345},localaddr=${QEMU_SHARED_LOCALADDR:-127.0.0.1}" \
    -name "Guerrilla $id" &
  PIDS+=("$!")
}

echo "Starting two guests on a private QEMU multicast LAN. The shared NIC has no DHCP."
echo "At each guest console, identify the shared NIC with 'ip -br link', then assign:"
echo "  $CONTROLLER -> sudo ip address add 192.168.77.11/24 dev enp0s4"
echo "  $WORKER     -> sudo ip address add 192.168.77.12/24 dev enp0s4"
echo "If the shared NIC is not enp0s4, substitute the interface shown by ip -br link."
echo "Run avahi-browse --resolve --terminate _guerrilla-node._tcp in either guest."
launch_node 1 "${NODES[0]}"
launch_node 2 "${NODES[1]}"
status=0
for pid in "${PIDS[@]}"; do
  wait "$pid" || status=$?
done
exit "$status"
