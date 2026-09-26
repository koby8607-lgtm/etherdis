# USB0 Manager v1.2.0

Android 11/API 30+ root-first RNDIS/USB Ethernet diagnostics for the R36S.

## Self-contained helper design

The APK carries a private helper under its own app storage and never replaces Android system binaries.

- Primary target: `arm64-v8a`
- Native helper source: `app/src/main/cpp/usb0-helper.c`
- APK asset: `app/src/main/assets/tools/arm64-v8a/usb0-helper`
- On first launch the helper is extracted to the app's private `files/` directory and made executable.
- The helper runs through `su`; no Shizuku dependency is used.
- The helper intentionally delegates networking to the R36S's Android/kernel/Toybox tools (`ip`, `ping`, `getprop`, `dumpsys`, `iptables`).
- If a command is missing, Command Check reports it rather than silently substituting an arbitrary binary.

The checked-in asset is a shell fallback so the project remains buildable without an NDK. GitHub Actions builds the real ARM64 helper and replaces the asset before assembling the APK.

## Safety

Safe Repair only refreshes an already-discovered default route in the `usb0` routing table. It does not flush iptables, add global default routes, or delete Android policy rules.

## Build

GitHub Actions installs Android NDK 27.2, cross-compiles the ARM64 helper, then assembles debug and release APKs. Android 11/API 30 is the minimum target.
