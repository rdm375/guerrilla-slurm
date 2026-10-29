#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ACTION=${1:-iso}
OUT="$ROOT/images"
WORK="$ROOT/work"
TREE="$WORK/iso-tree"
RAW="$ROOT/output/slurm-node-usb.img"
ISO="$OUT/slurm-node-amd64.iso"
DEBIAN_VERSION=${DEBIAN_VERSION:-13.7.0}
BASE_NAME="debian-${DEBIAN_VERSION}-amd64-netinst.iso"
BASE_DIR="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
BASE="$WORK/$BASE_NAME"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing build dependency: $1" >&2
    exit 1
  }
}

make_tree_writable() {
  [[ -d "$TREE" ]] && chmod -R u+rwX "$TREE" 2>/dev/null || true
}

build_iso() {
  umask 077
  need curl
  need xorriso
  need cpio
  need gzip
  need dpkg-deb
  need dpkg-scanpackages
  need openssl
  need python3

  mkdir -p "$OUT" "$WORK" "$ROOT/local-packages"
  cd "$ROOT"
  BUILD_OK=0
  cleanup_build() {
    [[ "$BUILD_OK" == 1 ]] || rm -f "$ISO"
    make_tree_writable
    rm -rf "$TREE" "$WORK/slurm-repo" "$WORK/preseed-initrd"
    rm -f "$WORK/preseed-initrd.gz" "$WORK/preseed.cfg" "$WORK/base-checksum"
  }
  trap cleanup_build EXIT

  # Build the node's tiny local APT repository. The installer gets ordinary
  # Debian packages from the Debian mirror and these project/vendor packages
  # from the repository embedded in the ISO.
  mkdir -p "$ROOT/packaging/slurm-node-bootstrap/usr/local/sbin"
  install -m 0755 "$ROOT/configure-node.sh" \
    "$ROOT/packaging/slurm-node-bootstrap/usr/local/sbin/configure-slurm-node"
  install -m 0755 "$ROOT/install-hailo10h.sh" \
    "$ROOT/packaging/slurm-node-bootstrap/usr/local/sbin/install-hailo10h"
  install -D -m 0644 "$ROOT/cluster.env" \
    "$ROOT/packaging/slurm-node-bootstrap/etc/default/slurm-node"
  chmod 0644 "$ROOT/packaging/slurm-node-bootstrap/lib/systemd/system/slurm-node-bootstrap.service"
  chmod 0755 "$ROOT/packaging/slurm-node-bootstrap/DEBIAN/postinst"
  rm -f "$ROOT/local-packages/slurm-node-bootstrap_1.0_all.deb"
  dpkg-deb --build --root-owner-group \
    "$ROOT/packaging/slurm-node-bootstrap" \
    "$ROOT/local-packages/slurm-node-bootstrap_1.0_all.deb" >/dev/null

  REPO="$WORK/slurm-repo"
  mkdir -p "$REPO"
  printf '%s\n' slurm-node-bootstrap > "$REPO/install-packages"
  for deb in "$ROOT"/local-packages/*.deb; do
    [[ -f "$deb" ]] || continue
    package=$(dpkg-deb -f "$deb" Package)
    architecture=$(dpkg-deb -f "$deb" Architecture)
    [[ "$architecture" == all || "$architecture" == amd64 ]] || {
      echo "Local package $deb has unsupported architecture: $architecture" >&2
      exit 1
    }
    [[ "$package" == slurm-node-bootstrap ]] && continue
    cp -f "$deb" "$REPO/"
    grep -qxF "$package" "$REPO/install-packages" ||
      printf '%s\n' "$package" >> "$REPO/install-packages"
  done
  cp "$ROOT/local-packages/slurm-node-bootstrap_1.0_all.deb" "$REPO/"
  (cd "$REPO" && dpkg-scanpackages . /dev/null > Packages && gzip -9c Packages > Packages.gz)

  read -rp "Debian login name [slurmadmin]: " INSTALL_USER
  INSTALL_USER=${INSTALL_USER:-slurmadmin}
  [[ "$INSTALL_USER" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || {
    echo "Use a lowercase Linux username." >&2
    exit 2
  }
  read -rsp "Password for $INSTALL_USER: " PASSWORD
  printf '\n'
  read -rsp "Confirm password: " PASSWORD_CONFIRM
  printf '\n'
  [[ -n "$PASSWORD" && "$PASSWORD" == "$PASSWORD_CONFIRM" ]] || {
    echo "Passwords are empty or do not match." >&2
    exit 2
  }
  PASSWORD_HASH=$(printf '%s' "$PASSWORD" | openssl passwd -6 -stdin)
  unset PASSWORD PASSWORD_CONFIRM

  PRESEED="$WORK/preseed.cfg"
  python3 - "$ROOT/profiles/slurm-node.preseed" "$PRESEED" \
    "$INSTALL_USER" "$PASSWORD_HASH" <<'PY'
import pathlib
import sys

source, destination, username, password_hash = sys.argv[1:]
text = pathlib.Path(source).read_text()
text = text.replace("__INSTALL_USER__", username)
text = text.replace("__PASSWORD_HASH__", password_hash)
pathlib.Path(destination).write_text(text)
PY
  unset PASSWORD_HASH

  if [[ ! -f "$BASE" ]]; then
    echo "Downloading Debian ${DEBIAN_VERSION} netinst..."
    curl -fL --retry 3 -o "$BASE.part" "$BASE_DIR/$BASE_NAME"
    mv "$BASE.part" "$BASE"
  fi
  echo "Checking Debian installer ISO checksum..."
  curl -fL --retry 3 -o "$WORK/SHA512SUMS" "$BASE_DIR/SHA512SUMS"
  awk -v name="$BASE_NAME" '$2 == name { print }' "$WORK/SHA512SUMS" > "$WORK/base-checksum"
  [[ -s "$WORK/base-checksum" ]] || {
    echo "No SHA512 entry for $BASE_NAME in the Debian checksum file." >&2
    exit 1
  }
  (cd "$WORK" && sha512sum --check --status base-checksum) || {
    rm -f "$BASE"
    echo "Debian installer ISO checksum failed; removed the cached ISO." >&2
    exit 1
  }

  make_tree_writable
  rm -rf "$TREE" "$WORK/preseed-initrd"
  mkdir -p "$TREE" "$WORK/preseed-initrd"
  install -m 0644 "$PRESEED" "$WORK/preseed-initrd/preseed.cfg"

  # Add preseed.cfg as a second initramfs archive. This preserves the stock
  # installer initrd's device nodes and other special files.
  (
    cd "$WORK/preseed-initrd"
    printf '%s\0' preseed.cfg | cpio --null --create --format=newc --owner=0:0
  ) | gzip -n -9 > "$WORK/preseed-initrd.gz"

  echo "Extracting Debian installer tree..."
  xorriso -osirrox on -indev "$BASE" -extract / "$TREE" >/dev/null
  # ISO files are extracted read-only; make owner-writable before replacing
  # initrds/configs and ensure failed builds can clean the work tree.
  chmod -R u+rwX "$TREE"
  install -m 0644 "$PRESEED" "$TREE/preseed.cfg"
  mkdir -p "$TREE/slurm"
  cp -a "$REPO" "$TREE/slurm/repo"
  install -m 0644 "$ROOT/network/05-enp0s31f6.network" "$TREE/slurm/05-enp0s31f6.network"

  for initrd in install.amd/initrd.gz install.amd/gtk/initrd.gz; do
    [[ -f "$TREE/$initrd" ]] || {
      echo "Expected Debian installer initrd not found: $initrd" >&2
      exit 1
    }
    cat "$TREE/$initrd" "$WORK/preseed-initrd.gz" > "$WORK/initrd.gz"
    mv "$WORK/initrd.gz" "$TREE/$initrd"
  done

  python3 - "$TREE" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
args = "auto=true priority=critical language=en country=US locale=en_US.UTF-8 keymap=us preseed/file=/preseed.cfg"
changed = {"isolinux": 0, "grub": 0}

for path in root.rglob("*.cfg"):
    lines = path.read_text(errors="replace").splitlines()
    updated = []
    modified = False
    is_isolinux = "isolinux" in path.parts
    is_grub = not is_isolinux and ("grub" in path.parts or path.name == "grub.cfg")
    for line in lines:
        stripped = line.lstrip()
        is_syslinux_kernel = is_isolinux and stripped.startswith("append ") and "initrd=" in line
        is_grub_kernel = is_grub and re.match(r"^(linux|linuxefi|linux16)\s+", stripped) and "/install.amd/vmlinuz" in line
        if (is_syslinux_kernel or is_grub_kernel) and "rescue/enable=true" not in line:
            if "preseed/file=" not in line:
                if "---" in line:
                    line = line.replace("---", f"{args} ---", 1)
                else:
                    line = f"{line} {args}"
                modified = True
        if is_grub and re.match(r"^set\s+timeout=", stripped):
            line = re.sub(r"timeout=\S+", "timeout=0", line)
            modified = True
        elif is_isolinux and re.match(r"^timeout\s+", stripped):
            line = re.sub(r"timeout\s+\S+", "timeout 0", line)
            modified = True
        updated.append(line)
    if is_grub and not any(re.match(r"^set\s+default=", line.lstrip()) for line in updated):
        updated.insert(0, 'set default="0"')
        modified = True
    if is_grub and not any(re.match(r"^set\s+timeout=", line.lstrip()) for line in updated):
        updated.insert(1 if updated and updated[0].startswith("set default=") else 0, "set timeout=0")
        modified = True
    if modified:
        path.write_text("\n".join(updated) + "\n")
        family = "isolinux" if is_isolinux else "grub"
        changed[family] += 1

for family, count in changed.items():
    if count == 0:
        raise SystemExit(f"No automatic-preseed boot entry updated for {family}.")
PY

  rm -f "$ISO"
  echo "Rebuilding hybrid BIOS/UEFI ISO..."
  xorriso -indev "$BASE" -outdev "$ISO" -boot_image any replay \
    -map "$TREE" / -volid SLURMNODET13 -commit

  BUILD_OK=1
  echo "Built: $ISO"
}

case "$ACTION" in
  iso)
    build_iso
    ;;
  qemu)
    need qemu-system-x86_64
    need qemu-img
    UEFI_CODE=
    UEFI_VARS_TEMPLATE=
    for fwdir in /usr/share/OVMF /usr/share/ovmf; do
      for code in "$fwdir"/OVMF_CODE*.fd; do
        [[ -r "$code" ]] || continue
        [[ "$code" == *secboot* || "$code" == *.ms.fd ]] && continue
        vars=${code/OVMF_CODE/OVMF_VARS}
        [[ -r "$vars" ]] || continue
        UEFI_CODE=$code
        UEFI_VARS_TEMPLATE=$vars
        break 2
      done
    done
    [[ -n "$UEFI_CODE" && -n "$UEFI_VARS_TEMPLATE" ]] || {
      echo "Could not find a matching OVMF_CODE/OVMF_VARS pair. Install OVMF: sudo apt install ovmf" >&2
      exit 1
    }
    [[ -s "$ISO" ]] || { echo "Build the ISO first: $0 iso" >&2; exit 1; }
    mkdir -p "$(dirname "$RAW")"
    UEFI_VARS="$ROOT/output/OVMF_VARS.fd"
    if [[ ! -s "$UEFI_VARS" ]]; then
      cp "$UEFI_VARS_TEMPLATE" "$UEFI_VARS"
    fi
    if [[ ! -e "$RAW" ]]; then
      qemu-img create -f raw "$RAW" "${USB_IMAGE_SIZE:-128G}"
    fi
    if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
      ACCEL=(-enable-kvm -cpu host)
    else
      ACCEL=(-accel tcg -cpu max)
    fi
    exec qemu-system-x86_64 "${ACCEL[@]}" -machine q35 -m 12G -smp 8 \
      -drive "if=pflash,format=raw,unit=0,readonly=on,file=$UEFI_CODE" \
      -drive "if=pflash,format=raw,unit=1,file=$UEFI_VARS" \
      -cdrom "$ISO" -boot order=c,once=d \
      -drive "file=$RAW,format=raw,if=virtio,cache=none" \
      -device virtio-net-pci,netdev=n1 -netdev user,id=n1,hostfwd=tcp::2222-:22
    ;;
  *)
    echo "Usage: $0 [iso|qemu]" >&2
    exit 2
    ;;
esac
