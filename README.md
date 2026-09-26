# USB0 Manager v1.7.0

Android 11/API 30+ root-first USB/RNDIS recovery manager for R36S-class ARM64 devices.

## Goal

The app is intended to cover the common failure layers involved in getting a USB/RNDIS upstream working: USB function state, RNDIS interface presence, link state, DHCP/addressing, connected routes, default routes, Android policy routing, neighbours/ARP, reverse-path filtering, MTU, DNS resolution, and staged connectivity verification.

It is deliberately root-first. Read-only diagnostics work as far as Android permits; repairs require root because changing interface state, IPv4 addresses, routes, policy rules, `rp_filter`, MTU, and USB gadget functions are privileged operations.

## Main recovery actions

- Fix Everything: full staged recovery with a before-action snapshot and verification.
- Auto recover: conservative interface/DHCP/route/neighbor recovery.
- RNDIS reset: reset Android USB functions and request an RNDIS-capable function string.
- Bring interface up/down.
- DHCPv4 renew using the bundled client.
- Connected-subnet route repair.
- Default-route repair in the detected table.
- Policy-rule repair for a dedicated USB route table.
- Flush only routes owned by the detected USB interface/table, then rebuild them.
- Neighbor/ARP refresh by netlink.
- MTU inspection and 1500-byte normalization.
- Per-interface `rp_filter` repair to loose mode (`2`) when enabled.
- DNS resolver repair attempt through Android netd (`ndc resolver setnetdns`) with compatibility property fallback.
- USB/RNDIS and firewall diagnostics.
- Snapshot/restore, event log, and shareable reports.

## Full recovery order

1. Detect `usb0`, `rndis0`, or another `usb*`/`rndis*` interface.
2. Inspect Android USB function/configuration state.
3. If requested by the aggressive path and the interface is absent, reset USB functions to an RNDIS-capable configuration.
4. Bring the interface UP.
5. Obtain an IPv4 address through the embedded DHCPv4 client when necessary.
6. Add/repair the connected subnet route.
7. Repair the default route in the table associated with the USB interface.
8. Add a source policy rule only when a non-main dedicated table is detected and the rule is missing.
9. Refresh ARP/neighbor state.
10. Repair per-interface reverse-path filtering when it is non-zero.
11. Normalize obviously abnormal MTU values.
12. Attempt Android netd DNS repair and flush resolver state when a matching netId can be discovered.
13. Verify gateway, internet and DNS reachability.
14. If internet still fails, flush only `usb*`/`rndis*` interface routes from the detected table and rebuild them before the final test.

## Embedded ARM64 engine

The APK contains the private ARM64 user-space helpers under app-private storage:

- `usb0-helper`: small launcher.
- `usb0-helper.sh`: recovery orchestration and Android-specific commands.
- `usb0-native`: native ARM64 network engine.

`usb0-native` uses Linux ioctls and `NETLINK_ROUTE` for interface state, IPv4 address handling, routes, policy rules, neighbours, MTU, and tests. Linux documents `rtnetlink` as the interface for reading and modifying routes, addresses, neighbour state and related networking objects.

The app still relies on the Android kernel networking stack, `netd`, the USB/RNDIS kernel driver, and Android's USB service. Replacing those system components inside an APK would not make the device more reliable.

## Host-side USB/RNDIS reset

The R36S is the USB host in the intended phone-tethering use case, so the recovery path does **not** pretend that the R36S's own USB gadget function can reset the attached phone. Instead it locates the USB device behind the network interface, issues a `USBDEVFS_RESET` to that host device when permitted, and falls back to a sysfs `authorized=0/1` re-enumeration cycle. The latter is a device re-enumeration, not a guaranteed electrical power cycle.

Android gadget-function controls are deliberately not used as the primary host reset. The recovery path targets the attached USB device itself.

## DNS / netd

Where available, the helper attempts the Android `netd` resolver command `resolver setnetdns <netId> <domains> <dns...>` and flushes that network's DNS cache. AOSP exposes that command in netd's command listener.

Because OEM Android builds differ, a failure to find a netId does not stop the network recovery flow; the helper reports that the netd update was not confirmed.

## Safety boundaries

- No system `ip`, `ping`, DHCP or `iptables` binary is overwritten.
- The embedded engine is private to the app.
- Standard Auto Recover does not automatically reset USB functions.
- Route flushing is scoped to the detected USB/RNDIS interface and its detected route table.
- Policy-rule creation is limited to a single source rule at the app's reserved priority when a dedicated table is detected.
- Firewall changes are diagnostic only in this build; the app does not flush or rewrite the device firewall automatically.
- Every destructive repair path records a snapshot first.

## Automatic monitoring

The foreground monitor can run at boot and keep an event history. Conservative Auto Recover can react to a missing/down link, carrier loss, missing IPv4 address, missing gateway, failed route, or failed gateway test. A separate opt-in setting permits the aggressive RNDIS reset when no USB/RNDIS interface exists.

## Build

GitHub Actions installs the Android SDK/NDK and cross-compiles both private ARM64 helpers before the Gradle build. The workflow uses `android-actions/setup-android@v4` and does not request the obsolete `tools` SDK package.

Minimum Android version: Android 11 / API 30.

## Driver fallback and transport detection

The app now inventories the actual USB network driver bound to the detected interface and presents a fallback matrix for the major USB networking families. The fallback order is conservative: it prefers the currently bound driver, then tries compatible registered drivers, and only attempts module loading/rebinding when root and the kernel expose those operations. Failed rebinding attempts attempt to restore the original driver.

For this R36S kernel configuration, the supplied defconfig reports these host-side USB networking paths as enabled: RNDIS host, CDC Ethernet, CDC EEM, CDC subset, RTL8150 and RTL8152. It reports CDC NCM, CDC MBIM, QMI WWAN, HSO, Sierra Net, IPHETH, and several vendor USB-Ethernet drivers as disabled. The app therefore cannot magically make a disabled kernel driver exist; it detects that condition and reports it. The full supplied defconfig is bundled in the APK assets for reference.

The app can also enumerate USB host devices and interface descriptors using Android's USB Host API. This is inspired by PPP Widget 3's device-autodetection/logging approach and is intentionally protocol-aware rather than relying only on VID/PID guesses. PPP Widget 3 documented userspace handling for NCM, ECM and QMI and emphasized autodetection and detailed USB/PPP logs.

The current R36S kernel has PPP core, MPPE and PPTP enabled, but its defconfig disables `PPP_ASYNC`, `PPP_SYNC_TTY`, `USB_SERIAL`, and `USB_ACM`; therefore this build adds PPP/modem *detection* and capability reporting, not a claim of full PPP-over-serial support on this kernel.

## Recovery philosophy

`Fix Everything` now uses alternate-driver fallback only after the ordinary RNDIS/interface/address/route/policy/neighbor/MTU/DNS sequence fails. Automatic driver fallback is separately opt-in because unbinding/rebinding a USB driver can briefly interrupt the device.

## PPP Widget 3-inspired features

PPP Widget 3 documented two ideas that are useful here: automatic USB modem/interface detection and connection logging, with support for protocols such as NCM, ECM and QMI when the surrounding Android/kernel environment makes them usable. This project adopts those ideas without copying its implementation: the app has a USB Host API probe, protocol/interface classification, driver capability matrix, persistent diagnostics, and a staged recovery log.

The USB Host probe reports RNDIS, ECM, NCM, MBIM, CDC-data, modem/ACM candidates and vendor-specific WWAN candidates from descriptors. It does not claim to establish a userspace PPP/NCM/QMI link when the supplied R36S kernel lacks the corresponding kernel transport; those cases are explicitly shown as unsupported or candidate-only.
