#!/usr/bin/env bash
set -euo pipefail

VERSION="1.37.0"
URL="https://busybox.net/downloads/busybox-${VERSION}.tar.bz2"
WORK="${RUNNER_TEMP:-/tmp}/usb0-busybox"
SRC="${WORK}/busybox-${VERSION}"
OUT="app/src/main/assets/tools/arm64-v8a/busybox"
NDK="${ANDROID_NDK_ROOT:-${ANDROID_HOME}/ndk/27.2.12479018}"
CLANG="${NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang"

rm -rf "${WORK}"
mkdir -p "${WORK}"
curl -fsSL "${URL}" -o "${WORK}/busybox.tar.bz2"

curl -fsSL "${URL}.sha256" -o "${WORK}/busybox.sha256"
(
  cd "${WORK}"
  sha256sum --check busybox.sha256
)

tar -xjf "${WORK}/busybox.tar.bz2" -C "${WORK}"
cd "${SRC}"

make defconfig
if [ -x scripts/config ]; then
  scripts/config --disable CONFIG_STATIC || true
  scripts/config --enable CONFIG_PIE || true
  scripts/config --enable CONFIG_IP || true
  scripts/config --enable CONFIG_FEATURE_IP_ADDRESS || true
  scripts/config --enable CONFIG_FEATURE_IP_LINK || true
  scripts/config --enable CONFIG_FEATURE_IP_ROUTE || true
  scripts/config --enable CONFIG_FEATURE_IP_RULE || true
  scripts/config --enable CONFIG_ARP || true
  scripts/config --enable CONFIG_ARPING || true
  scripts/config --enable CONFIG_IFCONFIG || true
  scripts/config --enable CONFIG_ROUTE || true
  scripts/config --enable CONFIG_UDHCPC || true
  scripts/config --enable CONFIG_UDHCPD || true
  scripts/config --enable CONFIG_PING || true
  scripts/config --enable CONFIG_NETSTAT || true
  scripts/config --enable CONFIG_PS || true
  scripts/config --enable CONFIG_LS || true
  scripts/config --enable CONFIG_READLINK || true
  scripts/config --enable CONFIG_OD || true
  scripts/config --enable CONFIG_MODPROBE || true
  scripts/config --enable CONFIG_INSMOD || true
  yes '' | make oldconfig >/dev/null
else
  sed -i 's/^CONFIG_STATIC=y/# CONFIG_STATIC is not set/' .config || true
  grep -q '^CONFIG_PIE=y$' .config || printf '\nCONFIG_PIE=y\n' >> .config
fi

make -j"$(nproc)" \
  CC="${CLANG}" \
  CFLAGS="-Os -fPIE -D__ANDROID_API__=30" \
  LDFLAGS="-pie"

mkdir -p "$(dirname "${OUT}")"
cp busybox "${OUT}"
chmod 755 "${OUT}"

"${NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" "${OUT}" || true
file "${OUT}"
"${NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf" -h "${OUT}" | grep -E 'Class:|Machine:|Type:'


echo '--- REQUIRED BUSYBOX APPLETS ---'
for applet in ip arp arping ifconfig route udhcpc udhcpd ping netstat ps ls readlink od modprobe insmod; do
  "${OUT}" --list | grep -qx "${applet}" || {
    echo "Missing BusyBox applet: ${applet}"
    exit 1
  }
done
