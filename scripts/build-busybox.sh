#!/usr/bin/env bash
set -euo pipefail

BUSYBOX="app/src/main/assets/tools/arm64-v8a/busybox"

if [ ! -f "$BUSYBOX" ]; then
  echo "ERROR: bundled ARM64 BusyBox is missing: $BUSYBOX" >&2
  exit 1
fi

if [ ! -s "$BUSYBOX" ]; then
  echo "ERROR: bundled ARM64 BusyBox is empty." >&2
  exit 1
fi

chmod 755 "$BUSYBOX"

if ! file "$BUSYBOX" | grep -q 'ARM aarch64'; then
  echo "ERROR: bundled BusyBox is not an ARM64/aarch64 executable:" >&2
  file "$BUSYBOX" >&2
  exit 1
fi

if ! file "$BUSYBOX" | grep -q 'statically linked'; then
  echo "ERROR: bundled BusyBox is not statically linked:" >&2
  file "$BUSYBOX" >&2
  exit 1
fi

echo "Using prebuilt ARM64 BusyBox: $BUSYBOX"
file "$BUSYBOX"
