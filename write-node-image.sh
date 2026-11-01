#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: sudo write-node-image.sh RAW_IMAGE /dev/disk/by-id/USB_DEVICE

The destination must be an unmounted whole-disk block device. The script shows
the device model/capacity and requires typing its exact path before erasing it.
EOF
  exit 2
}

[[ $# -eq 2 ]] || usage
IMAGE=$1
TARGET=$2
[[ -f $IMAGE && -r $IMAGE ]] || { echo "Raw image not readable: $IMAGE" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo: sudo $0 '$IMAGE' '$TARGET'" >&2; exit 1; }
[[ -b $TARGET ]] || { echo "Destination is not a block device: $TARGET" >&2; exit 1; }
for tool in lsblk dd blockdev python3 findmnt readlink qemu-img; do
  command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
done

DEVICE=$(readlink -f -- "$TARGET")
IMAGE_BYTES=$(stat -c %s -- "$IMAGE")
IMAGE_INFO=$(qemu-img info --output=json -- "$IMAGE")
DEVICE_INFO=$(lsblk -b -J -o PATH,TYPE,SIZE,MODEL,TRAN,MOUNTPOINTS "$DEVICE")
ROOT_SOURCE=$(findmnt -n -o SOURCE /)
ROOT_TREE=$(lsblk -s -n -o PATH "$ROOT_SOURCE" 2>/dev/null || true)

python3 - "$DEVICE" "$DEVICE_INFO" "$IMAGE_BYTES" "$ROOT_TREE" "$IMAGE_INFO" <<'PY'
import json, sys
device, encoded, image_bytes, root_real, image_info=sys.argv[1:]
image=json.loads(image_info)
if image.get("format") != "raw" or int(image.get("virtual-size", -1)) != int(image_bytes):
    raise SystemExit("Image must be a complete raw disk image with matching file and virtual sizes.")
root=json.loads(encoded)
item=root["blockdevices"][0]
if item.get("type") != "disk":
    raise SystemExit("Refusing to write a partition or non-disk device.")
if int(image_bytes) > int(item["size"]):
    raise SystemExit(f"Image is {image_bytes} bytes, larger than destination ({item['size']} bytes).")
def walk(node):
    yield node
    for child in node.get("children", []) or []:
        yield from walk(child)
nodes=list(walk(item))
if any(node.get("mountpoints") and any(node["mountpoints"]) for node in nodes):
    raise SystemExit("Refusing to overwrite a disk with mounted filesystems; unmount all its partitions first.")
root_devices=set(root_real.splitlines())
if any(node.get("path") in root_devices for node in nodes):
    raise SystemExit("Refusing to overwrite the disk containing the running system root.")
print(f"Destination model: {item.get('model') or '(model unavailable)'}")
print(f"Transport:        {item.get('tran') or '(not reported)'}")
print(f"Capacity:         {int(item['size']):,} bytes")
print(f"Image size:       {int(image_bytes):,} bytes")
PY

printf '\nDestination device tree:\n'
lsblk -o PATH,TYPE,SIZE,MODEL,TRAN,MOUNTPOINTS "$DEVICE"
printf '\nTHIS ERASES ALL DATA ON %s\n' "$TARGET"
read -r -p "Type 'ERASE $TARGET' to continue: " CONFIRM
[[ $CONFIRM == "ERASE $TARGET" ]] || { echo "Confirmation did not match; nothing was written." >&2; exit 1; }

dd if="$IMAGE" of="$DEVICE" bs=16M status=progress conv=fsync
sync
blockdev --rereadpt "$DEVICE" || true
echo "Image written to $TARGET. Safely eject the drive before booting it."
