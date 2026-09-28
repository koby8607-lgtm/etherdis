# USB0 Manager v1.8.1

R36S / Android 11 USB0 and RNDIS recovery toolkit.

## Recovery goals

The app is designed to recover both Android USB gadget mode and USB-host network interfaces. It uses LineageOS root (`su`) first, then its private helper stack.

### Gadget-mode recovery

- `svc usb getFunctions` / `setFunctions`
- persistent USB configuration properties
- ConfigFS RNDIS fallback when the framework USB setting path fails
- Android USB gadget reset (`svc usb resetUsbGadget`) when available
- USB function re-enumeration
- preservation of ADB when already enabled
- gadget MAC validation and ConfigFS `dev_addr` / `host_addr` repair
- optional USB-side DHCP/NAT fallback using bundled BusyBox `udhcpd`

### Host-mode recovery

- interface UP/DOWN/reset
- DHCPv4 retry
- connected-subnet and default-route repair
- Linux policy-routing / FIB-rule repair
- USB-only route flush/rebuild
- neighbour-table refresh
- active ARP gateway resolution
- explicit neighbour MAC installation
- MAC repair when a USB interface reports an invalid address
- MTU and `rp_filter` repair
- DNS/netd diagnostics and repair attempt
- USB device reset / re-authorization
- USB power/autosuspend recovery
- compatible kernel-driver discovery, loading and rebind attempts

### Bundled tools

The GitHub Actions build creates the real ARM64 `usb0-native` executable and builds BusyBox 1.37.0 for Android ARM64 with the required networking applets enabled. The resulting binaries are placed in `app/src/main/assets/tools/arm64-v8a/` before Gradle packages the APK.

BusyBox is used privately by the app; it does not replace system `/system/bin` utilities.

### Root

The app searches these LineageOS root entry points in order:

- `/system/xbin/su`
- `/system/bin/su`
- `/vendor/bin/su`
- `su` from PATH

### UI

The main screen is deliberately compact and vertically scrollable for small R36S displays. Long diagnostic output is kept in a separate smaller scroll region.

## CI packaging note

`busybox` is generated from the pinned official BusyBox 1.37.0 source during GitHub Actions and is copied into the APK as `assets/tools/arm64-v8a/busybox`. The source repository intentionally does not contain an x86 BusyBox binary or a prebuilt binary for the R36S; the workflow creates the correct AArch64 Android binary immediately before Gradle packages the APK.
