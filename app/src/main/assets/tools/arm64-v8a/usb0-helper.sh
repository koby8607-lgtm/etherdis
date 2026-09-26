#!/system/bin/sh
set +e
BASE=$(dirname "$0")
NATIVE="$BASE/usb0-native"
STATE="$BASE/state"
mkdir -p "$STATE"

has(){ command -v "$1" >/dev/null 2>&1; }

detect_iface(){
  if [ -d /sys/class/net/usb0 ]; then echo usb0; return; fi
  if [ -d /sys/class/net/rndis0 ]; then echo rndis0; return; fi
  for x in /sys/class/net/usb[0-9]* /sys/class/net/rndis[0-9]*; do
    [ -d "$x" ] || continue
    echo "${x##*/}"; return
  done
  echo usb0
}
IF=$(detect_iface)
run_native(){ [ -x "$NATIVE" ] || { echo NATIVE=UNAVAILABLE; return 127; }; USB0_IFACE="$IF" "$NATIVE" "$@"; }
getprop_safe(){ /system/bin/getprop "$1" 2>/dev/null; }

save_snapshot(){
  {
    echo "TIME=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "DETECTED_IF=$IF"
    run_native status
    echo '--- POLICY ---'
    run_native policy
    echo '--- USB ---'
    for p in sys.usb.config sys.usb.state persist.sys.usb.config sys.usb.ffs.rndis.ready sys.usb.configfs; do echo "$p=$(getprop_safe "$p")"; done
  } > "$STATE/snapshot.before"
}

system_check(){
  echo '--- SYSTEM COMMAND AVAILABILITY ---'
  for c in su ip ping getprop dumpsys toybox iptables ip6tables ndc svc cmd setprop modprobe insmod; do
    if has "$c"; then echo "$c=YES:$(command -v "$c")"; else echo "$c=NO"; fi
  done
  echo "DETECTED_INTERFACE=$IF"
  echo '--- USB PROPERTIES ---'
  for p in sys.usb.config sys.usb.state persist.sys.usb.config sys.usb.ffs.ready sys.usb.ffs.rndis.ready sys.usb.configfs; do echo "$p=$(getprop_safe "$p")"; done
  echo '--- KERNEL MODULES ---'
  for m in rndis g_ether usb_f_rndis; do [ -e "/sys/module/$m" ] && echo "$m=YES" || echo "$m=NO"; done
  echo '--- CONFIGFS/UDC ---'
  [ -d /config/usb_gadget ] && echo configfs_usb_gadget=YES || echo configfs_usb_gadget=NO
  [ -d /sys/class/udc ] && ls -1 /sys/class/udc 2>/dev/null | sed 's/^/udc=/'
  echo '--- INTERFACES ---'
  for x in /sys/class/net/*; do [ -d "$x" ] || continue; n=${x##*/}; case "$n" in usb*|rndis*) echo "iface=$n";; esac; done
}

find_usb_network_iface(){
  # Prefer interfaces whose descriptors identify common USB Ethernet transports.
  for wanted in e0:01:03 02:06 02:0d 02:0e ff; do
    for x in /sys/bus/usb/devices/*:*; do
      [ -d "$x" ] || continue
      cls=$(cat "$x/bInterfaceClass" 2>/dev/null)
      sub=$(cat "$x/bInterfaceSubClass" 2>/dev/null)
      proto=$(cat "$x/bInterfaceProtocol" 2>/dev/null)
      case "$wanted:$cls:$sub:$proto" in
        e0:01:03:e0:01:03|02:06:02:06:*|02:0d:02:0d:*|02:0e:02:0e:*|ff:ff:*:*) echo "$x"; return 0 ;;
      esac
    done
  done
  return 1
}

usb_parent_device(){
  devpath=$(usb_iface_path)
  [ -n "$devpath" ] || devpath=$(find_usb_network_iface)
  [ -n "$devpath" ] || return 1
  while [ "$devpath" != "/" ] && [ -n "$devpath" ]; do
    if [ -f "$devpath/busnum" ] && [ -f "$devpath/devnum" ]; then
      printf '%s %s %s\n' "$devpath" "$(cat "$devpath/busnum" 2>/dev/null)" "$(cat "$devpath/devnum" 2>/dev/null)"
      return 0
    fi
    devpath=$(dirname "$devpath")
  done
  return 1
}

usb_host_reset(){
  echo '=== HOST USB DEVICE RESET ==='
  info=$(usb_parent_device)
  if [ -z "$info" ]; then
    echo 'USB_RESET=NO_USB_DEVICE'
    return 1
  fi
  set -- $info
  path="$1"; bus="$2"; dev="$3"
  echo "USB_DEVICE=$path BUS=$bus DEV=$dev"
  if run_native usb-reset "$bus" "$dev"; then
    sleep 2
    IF=$(detect_iface)
    echo "USB_RESET=OK INTERFACE=$IF"
    return 0
  fi
  echo 'USBDEVFS_RESET failed; trying device re-authorization.'
  if [ -w "$path/authorized" ]; then
    printf '0' > "$path/authorized" 2>/dev/null || true
    sleep 1
    printf '1' > "$path/authorized" 2>/dev/null || true
    sleep 3
    IF=$(detect_iface)
    [ -e "/sys/class/net/$IF" ] && { echo "USB_REAUTHORIZE=OK INTERFACE=$IF"; return 0; }
  fi
  echo 'USB_RESET=FAILED'
  return 1
}

rndis_set(){
  echo '=== HOST-SIDE RNDIS RECOVERY ==='
  echo 'This resets the attached USB device; it does not change the R36S into USB-gadget RNDIS mode.'
  usb_host_reset
}

dns_fix(){
  dns1=$(getprop_safe dhcp.$IF.dns1)
  dns2=$(getprop_safe dhcp.$IF.dns2)
  [ -n "$dns1" ] || dns1=$(getprop_safe net.dns1)
  [ -n "$dns2" ] || dns2=$(getprop_safe net.dns2)
  [ -n "$dns1" ] || dns1=1.1.1.1
  [ -n "$dns2" ] || dns2=8.8.8.8
  echo "DNS_CANDIDATES=$dns1,$dns2"
  if has ndc && has dumpsys; then
    netid=$(dumpsys connectivity 2>/dev/null | grep -i -m1 -A3 -B3 "$IF" | grep -oE 'netId[ =:][0-9]+' | head -1 | grep -oE '[0-9]+' | head -1)
    if [ -n "$netid" ]; then
      ndc resolver setnetdns "$netid" '' "$dns1" "$dns2" >/dev/null 2>&1 && { echo "DNS_NETD=OK netId=$netid"; ndc resolver flushnet "$netid" >/dev/null 2>&1; return 0; }
    fi
  fi
  setprop net.dns1 "$dns1" >/dev/null 2>&1
  setprop net.dns2 "$dns2" >/dev/null 2>&1
  echo 'DNS_NETD=NOT_CONFIRMED'
}

firewall_diag(){
  echo '--- FILTER OUTPUT ---'
  if has iptables; then iptables -S 2>&1 | head -300; else echo iptables=UNAVAILABLE; fi
  echo '--- MANGLE OUTPUT ---'
  if has iptables; then iptables -t mangle -S 2>&1 | head -300; fi
  echo '--- NAT OUTPUT ---'
  if has iptables; then iptables -t nat -S 2>&1 | head -300; fi
}

repair_all(){
  save_snapshot
  echo '=== FULL USB/RNDIS RECOVERY ==='
  echo '[1] Detect RNDIS interface'
  system_check
  if [ ! -d "/sys/class/net/$IF" ]; then
    echo '[1b] No USB/RNDIS interface; reset the attached USB device and re-enumerate'
    rndis_set
    IF=$(detect_iface)
    if [ ! -d "/sys/class/net/$IF" ]; then echo 'RNDIS_INTERFACE=STILL_MISSING'; return 10; fi
  fi
  echo '[2] Interface UP + DHCP/address'
  run_native up
  curip=$(run_native status | sed -n 's/^IP=//p' | head -1)
  if [ -z "$curip" ] || [ "$curip" = "-" ]; then
    i=1
    while [ "$i" -le 3 ]; do
      run_native dhcp && break
      i=$((i+1))
      sleep 1
    done
  fi
  echo '[3] Connected subnet + default route'
  run_native route
  echo '[4] Policy routing repair'
  run_native policy-repair
  echo '[5] ARP/neighbor refresh'
  run_native neigh
  echo '[6] Reverse-path filter repair'
  rpf=$(run_native rpfilter | sed -n 's/^RP_FILTER=//p' | head -1)
  case "$rpf" in 1|2) run_native set-rpfilter 2;; esac
  echo '[7] MTU repair when obviously abnormal'
  mtu=$(run_native mtu | sed -n 's/^MTU=//p' | head -1)
  case "$mtu" in ''|*[!0-9]*) :;; *) [ "$mtu" -gt 2000 ] && run_native set-mtu 1500;; esac
  echo '[8] DNS resolver repair attempt'
  dns_fix
  echo '[9] Verification'
  testout=$(run_native test 2>&1)
  echo "$testout"
  echo "$testout" | grep -q 'INET=OK' || {
    echo '[9b] Standard network repair still failing; try an alternate registered USB network driver'
    driver_fallback || true
    run_native up
    run_native dhcp >/dev/null 2>&1 || true
    run_native route
    run_native policy-repair
    run_native neigh
    testout=$(run_native test 2>&1)
    echo "$testout"
  }
  echo "$testout" | grep -q 'INET=OK' || {
    echo '[9c] Internet still failing; flush only usb/rndis routes and rebuild them'
    run_native flush-usb-routes
    run_native route
    run_native policy-repair
    run_native neigh
    testout=$(run_native test 2>&1)
    echo "$testout"
  }
  echo '[10] Final state'
  run_native status
}


module_loaded(){
  m=$(echo "$1" | tr '-' '_')
  [ -e "/sys/module/$m" ] && return 0
  grep -q "^$m " /proc/modules 2>/dev/null
}

module_config_guess(){
  case "$1" in
    usbnet) echo CONFIG_USB_USBNET;;
    catc) echo CONFIG_USB_CATC;;
    kaweth) echo CONFIG_USB_KAWETH;;
    pegasus) echo CONFIG_USB_PEGASUS;;
    rtl8150) echo CONFIG_USB_RTL8150;;
    rtl8152) echo CONFIG_USB_RTL8152;;
    lan78xx) echo CONFIG_USB_NET_LAN78XX;;
    ax8817x) echo CONFIG_USB_NET_AX8817X;;
    ax88179_178a) echo CONFIG_USB_NET_AX88179_178A;;
    cdc_ether) echo CONFIG_USB_NET_CDCETHER;;
    cdc_eem) echo CONFIG_USB_NET_CDC_EEM;;
    cdc_ncm) echo CONFIG_USB_NET_CDC_NCM;;
    huawei_cdc_ncm) echo CONFIG_USB_NET_HUAWEI_CDC_NCM;;
    cdc_mbim) echo CONFIG_USB_NET_CDC_MBIM;;
    dm9601) echo CONFIG_USB_NET_DM9601;;
    sr9700) echo CONFIG_USB_NET_SR9700;;
    sr9800) echo CONFIG_USB_NET_SR9800;;
    smsc75xx) echo CONFIG_USB_NET_SMSC75XX;;
    smsc95xx) echo CONFIG_USB_NET_SMSC95XX;;
    gl620a) echo CONFIG_USB_NET_GL620A;;
    net1080) echo CONFIG_USB_NET_NET1080;;
    plusb) echo CONFIG_USB_NET_PLUSB;;
    mcs7830) echo CONFIG_USB_NET_MCS7830;;
    rndis_host) echo CONFIG_USB_NET_RNDIS_HOST;;
    cdc_subset) echo CONFIG_USB_NET_CDC_SUBSET;;
    ali_m5632) echo CONFIG_USB_ALI_M5632;;
    an2720) echo CONFIG_USB_AN2720;;
    belkin) echo CONFIG_USB_BELKIN;;
    armlinux) echo CONFIG_USB_ARMLINUX;;
    epson2888) echo CONFIG_USB_EPSON2888;;
    kc2190) echo CONFIG_USB_KC2190;;
    zaurus) echo CONFIG_USB_NET_ZAURUS;;
    cx82310_eth) echo CONFIG_USB_NET_CX82310_ETH;;
    kalmia) echo CONFIG_USB_NET_KALMIA;;
    qmi_wwan) echo CONFIG_USB_NET_QMI_WWAN;;
    hso) echo CONFIG_USB_HSO;;
    int51x1) echo CONFIG_USB_NET_INT51X1;;
    ipheth) echo CONFIG_USB_IPHETH;;
    sierra_net) echo CONFIG_USB_SIERRA_NET;;
    vl600) echo CONFIG_USB_VL600;;
    ch9200) echo CONFIG_USB_NET_CH9200;;
    rndis_wlan) echo CONFIG_USB_NET_RNDIS_WLAN;;
    ppp_generic) echo CONFIG_PPP;;
    ppp_async) echo CONFIG_PPP_ASYNC;;
    ppp_synctty) echo CONFIG_PPP_SYNC_TTY;;
    pppoe) echo CONFIG_PPPOE;;
    pppol2tp) echo CONFIG_PPPOL2TP;;
    usb_serial) echo CONFIG_USB_SERIAL;;
    cdc_acm) echo CONFIG_USB_ACM;;
    *) echo CONFIG_UNKNOWN;;
  esac
}

usb_iface_path(){
  [ -d "/sys/class/net/$IF/device" ] || return 1
  readlink -f "/sys/class/net/$IF/device" 2>/dev/null
}

usb_driver_info(){
  echo '--- ACTIVE NETWORK DRIVER ---'
  echo "INTERFACE=$IF"
  dpath=$(readlink -f "/sys/class/net/$IF/device/driver" 2>/dev/null)
  if [ -n "$dpath" ] && [ -d "$dpath" ]; then echo "DRIVER=${dpath##*/}"; else echo 'DRIVER=NONE'; fi
  devpath=$(usb_iface_path)
  echo "USB_INTERFACE=${devpath:-NONE}"
  [ -n "$devpath" ] || return 0
  for n in bInterfaceClass bInterfaceSubClass bInterfaceProtocol idVendor idProduct manufacturer product; do
    f="$devpath/$n"
    [ -f "$f" ] && echo "$n=$(cat "$f" 2>/dev/null)"
  done
  [ -f "$devpath/modalias" ] && echo "MODALIAS=$(cat "$devpath/modalias" 2>/dev/null)"
}

driver_present(){
  [ -d "/sys/bus/usb/drivers/$1" ]
}

load_driver(){
  drv="$1"
  if driver_present "$drv"; then echo "DRIVER_$drv=ALREADY_REGISTERED"; return 0; fi
  if module_loaded "$drv"; then echo "DRIVER_$drv=LOADED_BUT_NOT_REGISTERED"; return 0; fi
  if has modprobe; then
    modprobe "$drv" >/dev/null 2>&1 && { echo "DRIVER_$drv=MODPROBE_OK"; return 0; }
  fi
  for root in /vendor/lib/modules /vendor_dlkm/lib/modules /system/lib/modules /odm/lib/modules; do
    [ -d "$root" ] || continue
    f=$(find "$root" -type f \( -name "$drv.ko" -o -name "$drv.ko.xz" -o -name "$drv.ko.gz" -o -name "$drv.ko.zst" \) 2>/dev/null | head -1)
    case "$f" in
      *.ko)
        if has insmod && insmod "$f" >/dev/null 2>&1; then echo "DRIVER_$drv=INSMOD_OK:$f"; return 0; fi ;;
      '' ) : ;;
    esac
  done
  echo "DRIVER_$drv=UNAVAILABLE"
  return 1
}

driver_candidates(){
  devpath=$(usb_iface_path)
  cls=$(cat "$devpath/bInterfaceClass" 2>/dev/null)
  sub=$(cat "$devpath/bInterfaceSubClass" 2>/dev/null)
  proto=$(cat "$devpath/bInterfaceProtocol" 2>/dev/null)
  echo "USB_CLASS=${cls:-?} USB_SUBCLASS=${sub:-?} USB_PROTOCOL=${proto:-?}"
  case "$cls:$sub:$proto" in
    e0:01:03|E0:01:03) echo 'CANDIDATES=rndis_host cdc_ether cdc_eem cdc_subset' ;;
    02:06:*) echo 'CANDIDATES=cdc_ether cdc_ncm cdc_eem cdc_subset rndis_host' ;;
    02:0d:*) echo 'CANDIDATES=cdc_ncm cdc_ether cdc_eem cdc_subset' ;;
    02:0e:*) echo 'CANDIDATES=cdc_mbim cdc_ncm cdc_ether' ;;
    ff:*:*) echo 'CANDIDATES=rtl8152 rtl8150 ax88179_178a ax8817x dm9601 sr9700 sr9800 smsc75xx smsc95xx lan78xx ch9200' ;;
    *) echo 'CANDIDATES=rndis_host cdc_ether cdc_eem cdc_subset cdc_ncm cdc_mbim qmi_wwan hso sierra_net ipheth' ;;
  esac
}

driver_matrix(){
  echo '=== DRIVER FALLBACK MATRIX ==='
  for d in usbnet rndis_host cdc_ether cdc_eem cdc_subset cdc_ncm huawei_cdc_ncm cdc_mbim qmi_wwan hso sierra_net ipheth int51x1 vl600 rtl8152 rtl8150 ax88179_178a ax8817x lan78xx dm9601 sr9700 sr9800 smsc75xx smsc95xx gl620a net1080 plusb mcs7830 ch9200 catc kaweth pegasus ali_m5632 an2720 belkin armlinux epson2888 kc2190 zaurus cx82310_eth kalmia rndis_wlan ppp_generic ppp_async ppp_synctty pppoe pppol2tp usb_serial cdc_acm; do
    if driver_present "$d"; then state=REGISTERED;
    elif module_loaded "$d"; then state=LOADED;
    else state=ABSENT; fi
    printf '%-20s %-10s %s\n' "$d" "$state" "$(module_config_guess "$d")"
  done
}

rebind_driver(){
  newdrv="$1"
  devpath=$(usb_iface_path)
  [ -n "$devpath" ] || { echo 'REBIND=NO_USB_INTERFACE'; return 1; }
  dev=${devpath##*/}
  oldpath=$(readlink -f "/sys/class/net/$IF/device/driver" 2>/dev/null)
  olddrv=${oldpath##*/}
  [ -n "$olddrv" ] && [ "$olddrv" != "driver" ] || olddrv=''
  [ -d "/sys/bus/usb/drivers/$newdrv" ] || { echo "REBIND=$newdrv DRIVER_NOT_REGISTERED"; return 1; }
  echo "REBIND_ATTEMPT=$dev:$olddrv->$newdrv"
  if [ -n "$olddrv" ] && [ -w "/sys/bus/usb/drivers/$olddrv/unbind" ]; then
    printf '%s' "$dev" > "/sys/bus/usb/drivers/$olddrv/unbind" 2>/dev/null || return 1
    sleep 1
  fi
  if [ -w "/sys/bus/usb/drivers/$newdrv/bind" ] && printf '%s' "$dev" > "/sys/bus/usb/drivers/$newdrv/bind" 2>/dev/null; then
    sleep 2
    IF=$(detect_iface)
    [ -e "/sys/class/net/$IF" ] && { echo "REBIND_OK=1 DRIVER=$newdrv INTERFACE=$IF"; return 0; }
  fi
  # Rebind the original driver if the candidate failed.
  if [ -n "$olddrv" ] && [ -w "/sys/bus/usb/drivers/$olddrv/bind" ]; then
    printf '%s' "$dev" > "/sys/bus/usb/drivers/$olddrv/bind" 2>/dev/null
    sleep 1
  fi
  IF=$(detect_iface)
  echo "REBIND_FAILED=$newdrv RESTORED=${olddrv:-NONE}"
  return 1
}

driver_fallback(){
  save_snapshot
  echo '=== KERNEL DRIVER FALLBACK ==='
  usb_driver_info
  driver_candidates
  driver_matrix
  devpath=$(usb_iface_path)
  [ -n "$devpath" ] || { echo 'DRIVER_FALLBACK=NO_USB_INTERFACE'; return 10; }
  old=$(readlink -f "/sys/class/net/$IF/device/driver" 2>/dev/null); old=${old##*/}
  candidates=$(driver_candidates | sed -n 's/^CANDIDATES=//p')
  for d in $candidates; do
    [ "$d" = "$old" ] && continue
    echo "--- TRY $d ---"
    if ! load_driver "$d"; then continue; fi
    driver_present "$d" || continue
    if rebind_driver "$d"; then
      run_native up
      run_native dhcp >/tmp/usb0-dhcp.$$ 2>&1 || true
      run_native route >/tmp/usb0-route.$$ 2>&1 || true
      run_native policy-repair >/tmp/usb0-policy.$$ 2>&1 || true
      run_native neigh >/dev/null 2>&1 || true
      cat /tmp/usb0-dhcp.$$ /tmp/usb0-route.$$ /tmp/usb0-policy.$$ 2>/dev/null
      rm -f /tmp/usb0-dhcp.$$ /tmp/usb0-route.$$ /tmp/usb0-policy.$$
      if run_native test 2>&1 | tee /tmp/usb0-test.$$ | grep -q 'GATEWAY=OK'; then
        cat /tmp/usb0-test.$$; rm -f /tmp/usb0-test.$$
        echo "DRIVER_FALLBACK=SUCCESS DRIVER=$d"
        return 0
      fi
      cat /tmp/usb0-test.$$; rm -f /tmp/usb0-test.$$
    fi
  done
  echo "DRIVER_FALLBACK=NO_WORKING_ALTERNATIVE OLD=${old:-NONE}"
  return 20
}

case "${1:-status}" in
check) system_check; run_native check ;;
status) run_native status ;;
up) run_native up ;;
down) run_native down ;;
dhcp) save_snapshot; run_native dhcp ;;
dhcp-retry) save_snapshot; i=1; while [ "$i" -le 3 ]; do run_native dhcp && exit 0; i=$((i+1)); sleep 1; done; exit 1 ;;
route) save_snapshot; [ -n "$2" ] && run_native route "$2" || run_native route ;;
route-connected) save_snapshot; run_native route-connected ;;
policy) run_native policy ;;
policy-repair) save_snapshot; run_native policy-repair ;;
policy-delete) [ -s "$STATE/snapshot.before" ] || save_snapshot; oldip=$(grep "^IP=" "$STATE/snapshot.before" | tail -1 | cut -d= -f2); oldtable=$(grep "^TABLE=" "$STATE/snapshot.before" | tail -1 | cut -d= -f2); case "$oldip" in ""|-) :;; *) run_native policy-delete "$oldip" "$oldtable";; esac ;;
flush-usb-routes) save_snapshot; run_native flush-usb-routes ;;
neigh) save_snapshot; run_native neigh ;;
mtu) run_native mtu ;;
set-mtu) save_snapshot; [ -n "$2" ] && run_native set-mtu "$2" || run_native set-mtu 1500 ;;
rpfilter) run_native rpfilter ;;
set-rpfilter) save_snapshot; [ -n "$2" ] && run_native set-rpfilter "$2" || run_native set-rpfilter 2 ;;
rndis|usb-reset) save_snapshot; rndis_set ;;
rndis-aggressive) save_snapshot; rndis_set; sleep 2; IF=$(detect_iface); run_native up; run_native recover-aggressive ;;
usb-reauthorize) save_snapshot; info=$(usb_parent_device); [ -n "$info" ] || { echo 'USB_REAUTHORIZE=NO_DEVICE'; exit 1; }; set -- $info; path="$1"; if [ -w "$path/authorized" ]; then printf '0' > "$path/authorized" 2>/dev/null; sleep 1; printf '1' > "$path/authorized" 2>/dev/null; sleep 3; IF=$(detect_iface); echo "USB_REAUTHORIZE=OK INTERFACE=$IF"; else echo 'USB_REAUTHORIZE=UNAVAILABLE'; exit 1; fi ;;
reset) save_snapshot; run_native reset ;;
recover) save_snapshot; run_native recover ;;
recover-aggressive) repair_all ;;
repair|fix-all) repair_all ;;
static) save_snapshot; [ $# -ge 4 ] || { echo "usage: static <ip> <prefix> <gateway>"; exit 2; }; run_native static-ip "$2" "$3" "$4"; dns_fix; run_native test ;;
dns) save_snapshot; dns_fix; run_native test ;;
firewall) firewall_diag ;;
usbdiag) system_check; run_native diagnose ;;
driver-info) system_check; usb_driver_info; driver_candidates; driver_matrix ;;
driver-fallback) driver_fallback ;;
driver-load) [ -n "$2" ] && load_driver "$2" || { echo 'usage: driver-load <driver>'; exit 2; } ;;
driver-rebind) [ -n "$2" ] && rebind_driver "$2" || { echo 'usage: driver-rebind <driver>'; exit 2; } ;;
usb-host-tree) system_check; for x in /sys/bus/usb/devices/*:*; do [ -d "$x" ] || continue; echo "USB_IFACE=${x##*/}"; for n in idVendor idProduct manufacturer product bInterfaceClass bInterfaceSubClass bInterfaceProtocol modalias; do [ -f "$x/$n" ] && echo "  $n=$(cat "$x/$n" 2>/dev/null)"; done; done ;;
test) run_native test ;;
snapshot) run_native snapshot > "$STATE/snapshot.manual"; cat "$STATE/snapshot.manual" ;;
restore)
  if [ -s "$STATE/snapshot.before" ]; then
    echo '=== RESTORE ==='
    # Restore means restore a known-good interface state without restoring stale routes blindly.
    link=$(grep '^LINK=' "$STATE/snapshot.before" | tail -1 | cut -d= -f2)
    [ "$link" = up ] && run_native up || run_native down
    oldip=$(grep '^IP=' "$STATE/snapshot.before" | tail -1 | cut -d= -f2)
    oldtable=$(grep '^TABLE=' "$STATE/snapshot.before" | tail -1 | cut -d= -f2)
    case "$oldip" in ""|-) :;; *) run_native policy-delete "$oldip" "$oldtable";; esac
    run_native recover
    echo 'RESTORE_DONE=1'
  else
    echo 'RESTORE=no-snapshot'; exit 1
  fi ;;
diagnose) system_check; run_native diagnose; echo '--- ANDROID CONNECTIVITY ---'; if has dumpsys; then dumpsys connectivity 2>&1 | grep -i -E 'usb0|rndis|Ethernet|NetworkAgent|netId|DNS|netd|default|route' | head -300; fi; echo '--- FIREWALL ---'; firewall_diag ;;
*) echo 'usage: usb0-helper {check|status|up|down|dhcp|dhcp-retry|static|route|route-connected|policy|policy-repair|policy-delete|flush-usb-routes|neigh|mtu|set-mtu|rpfilter|set-rpfilter|rndis|usb-reset|usb-reauthorize|rndis-aggressive|reset|recover|recover-aggressive|repair|fix-all|dns|firewall|usbdiag|driver-info|driver-fallback|driver-load|driver-rebind|usb-host-tree|test|snapshot|restore|diagnose}'; exit 2 ;;
esac
