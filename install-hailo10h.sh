#!/usr/bin/env bash
set -euo pipefail

VERSION=5.4.0
SOURCE_ROOT="/usr/local/src/hailo-${VERSION}"
DRIVER_SOURCE="$SOURCE_ROOT/hailort-drivers"
HAILORT_SOURCE="$SOURCE_ROOT/hailort"
FIRMWARE_DIR=/lib/firmware/hailo/hailo10h
MARKER_DIR=/var/lib/slurm-node

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

PACKAGES=(
  build-essential cmake git wget linux-headers-amd64 python3-dev
  libssl-dev libprotobuf-dev protobuf-compiler libpcap-dev
  libjsoncpp-dev libusb-1.0-0-dev libudev-dev pkg-config zlib1g-dev
)
MISSING=()
for package in "${PACKAGES[@]}"; do
  if ! dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
    MISSING+=("$package")
  fi
done
if ((${#MISSING[@]})); then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING[@]}"
fi

install -d -m 0755 "$SOURCE_ROOT" "$FIRMWARE_DIR" "$MARKER_DIR"

if [[ ! -d "$DRIVER_SOURCE/.git" ]]; then
  git clone --depth 1 --branch "v${VERSION}" \
    https://github.com/hailo-ai/hailort-drivers.git "$DRIVER_SOURCE"
fi
if [[ ! -d "$HAILORT_SOURCE/.git" ]]; then
  git clone --depth 1 --branch "v${VERSION}" \
    https://github.com/hailo-ai/hailort.git "$HAILORT_SOURCE"
fi

# The Hailo-10H firmware is a separate vendor archive. The driver's downloader
# extracts it under its working tree; copy the extracted tree to the path the
# kernel firmware loader requests.
if [[ ! -s "$FIRMWARE_DIR/customer_certificate.bin" || \
      ! -s "$FIRMWARE_DIR/fitImage" || ! -s "$FIRMWARE_DIR/image-fs" ]]; then
  (cd "$DRIVER_SOURCE" && ./download_firmware_hailo10h.sh)
  CERTIFICATE=$(find "$DRIVER_SOURCE" -type f -name customer_certificate.bin -print -quit)
  [[ -n "$CERTIFICATE" ]] || {
    echo "Hailo 5.4.0 firmware archive did not contain customer_certificate.bin." >&2
    exit 1
  }
  FIRMWARE_SOURCE=${CERTIFICATE%/customer_certificate.bin}
  cp -a "$FIRMWARE_SOURCE/." "$FIRMWARE_DIR/"
fi
for firmware_file in customer_certificate.bin fitImage image-fs scu_fw.bin u-boot-spl.bin; do
  [[ -s "$FIRMWARE_DIR/$firmware_file" ]] || {
    echo "Required Hailo-10H firmware file is missing: $FIRMWARE_DIR/$firmware_file" >&2
    exit 1
  }
done

if ! modinfo hailo1x_pci >/dev/null 2>&1; then
  make -C "$DRIVER_SOURCE/linux/pcie" all
  make -C "$DRIVER_SOURCE/linux/pcie" install
  depmod -a
fi
install -d -m 0755 /etc/modules-load.d
printf '%s\n' hailo1x_pci > /etc/modules-load.d/hailo1x_pci.conf
modprobe hailo1x_pci
udevadm settle

if [[ ! -s "$MARKER_DIR/hailort-${VERSION}.installed" ]]; then
  cmake -S "$HAILORT_SOURCE" -B "$HAILORT_SOURCE/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  cmake --build "$HAILORT_SOURCE/build" --parallel "${HAILO_BUILD_JOBS:-4}"
  cmake --install "$HAILORT_SOURCE/build"
  ldconfig
  touch "$MARKER_DIR/hailort-${VERSION}.installed"
fi

if lspci -nn 2>/dev/null | grep -q '1e60:45c4'; then
  hailortcli scan
else
  echo "Hailo 5.4.0 driver, runtime, and firmware are installed; no Hailo-10H PCIe card is present on this boot."
fi
