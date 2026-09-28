#!/system/bin/sh
set +e
BASE=$(dirname "$0")
NATIVE="$BASE/usb0-native"
BB="$BASE/busybox"
STATE="$BASE/state"
mkdir -p "$STATE"

has(){ command -v "$1" >/dev/null 2>&1; }
bb(){ [ -x "$BB" ] && "$BB" "$@"; }

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
  if [ -x "$BB" ]; then echo "bundled_busybox=YES:$BB"; "$BB" --help 2>&1 | head -1; else echo 'bundled_busybox=NO'; fi
  echo "DETECTED_INTERFACE=$IF"
  echo '--- USB PROPERTIES ---'
  for p in sys.usb.config sys.usb.state persist.sys.usb.config sys.usb.ffs.ready sys.usb.ffs.rndis.ready sys.usb.configfs; do echo "$p=$(getprop_safe "$p")"; done
  echo '--- KERNEL MODULES ---'
  for m in rndis g_ether usb_f_rndis; do [ -e "/sys/module/$m" ] && echo "$m=YES" || echo "$m=NO"; done
  echo '--- CONFIGFS/UDC ---'
  [ -d /config/usb_gadget ] && echo configfs_usb_gadget=YES || echo configfs_usb_gadget=NO
  [ -d /sys/kernel/config/usb_gadget ] && echo sysfs_configfs_usb_gadget=YES || true
  [ -d /sys/class/udc ] && ls -1 /sys/class/udc 2>/dev/null | sed 's/^/udc=/'
  echo '--- INTERFACES ---'
  for x in /sys/class/net/*; do [ -d "$x" ] || continue; n=${x##*/}; case "$n" in usb*|rndis*) echo "iface=$n";; esac; done
}

role(){
  cfg=$(getprop_safe sys.usb.config)
  if echo ",$cfg," | grep -qi ',rndis,' || echo ",$cfg," | grep -qi '^rndis,' || gadget_function_dir >/dev/null 2>&1; then
    echo GADGET
    return 0
  fi
  d=$(readlink -f "/sys/class/net/$IF/device/driver" 2>/dev/null)
  case "${d##*/}" in rndis_host|cdc_ether|cdc_eem|cdc_ncm|cdc_mbim|qmi_wwan|rtl8152|rtl8150|ax88179_178a|ax8817x|dm9601|sr9700|sr9800|smsc75xx|smsc95xx|lan78xx|ch9200) echo HOST; return 0;; esac
  if [ -d "/sys/class/net/$IF" ] && configfs_gadget_dir >/dev/null 2>&1; then
    echo GADGET
    return 0
  fi
  echo UNKNOWN
}

usb_function_get(){
  if has svc; then svc usb getFunctions 2>/dev/null && return 0; fi
  getprop_safe sys.usb.config
}

usb_function_set(){
  want="$1"
  if has svc && svc usb setFunctions "$want" >/dev/null 2>&1; then
    sleep 2
    cfg=$(usb_function_get)
    echo "USB_FUNCTION_SET=svc:$want CURRENT=$cfg"
    echo ",$cfg," | grep -qi ',rndis,' && return 0
  fi
  echo "USB_FUNCTION_FALLBACK=$want"
  if has setprop; then
    setprop sys.usb.config none >/dev/null 2>&1 || true
    sleep 1
    setprop persist.sys.usb.config "$want" >/dev/null 2>&1 || true
    setprop sys.usb.config "$want" >/dev/null 2>&1 || true
    sleep 3
  fi
  cfg=$(getprop_safe sys.usb.config)
  echo "USB_FUNCTION_SET=property:$want CURRENT=$cfg"
  echo ",$cfg," | grep -qi ',rndis,'
}

usb_gadget_reset(){
  echo '=== USB GADGET RESET ==='
  if has svc && svc usb resetUsbGadget >/tmp/usb0-gadget-reset.$$ 2>&1; then
    cat /tmp/usb0-gadget-reset.$$ 2>/dev/null || true
    rm -f /tmp/usb0-gadget-reset.$$ 2>/dev/null || true
    sleep 2
    echo 'USB_GADGET_RESET=SVC_OK' | sed 's/SV C/SVC/'
    return 0
  fi
  cat /tmp/usb0-gadget-reset.$$ 2>/dev/null || true
  rm -f /tmp/usb0-gadget-reset.$$ 2>/dev/null || true
  if has setprop; then
    old=$(getprop_safe sys.usb.config)
    setprop sys.usb.config none >/dev/null 2>&1 || true
    sleep 1
    [ -n "$old" ] && setprop sys.usb.config "$old" >/dev/null 2>&1 || true
    sleep 2
    echo 'USB_GADGET_RESET=PROPERTY_CYCLE'
    return 0
  fi
  echo 'USB_GADGET_RESET=UNAVAILABLE'
  return 1
}

configfs_gadget_dir(){
  for root in /config/usb_gadget /sys/kernel/config/usb_gadget; do
    [ -d "$root" ] || continue
    for g in "$root"/*; do
      [ -d "$g" ] || continue
      [ -f "$g/UDC" ] || continue
      [ -d "$g/configs" ] || continue
      echo "$g"
      return 0
    done
  done
  return 1
}

configfs_rndis_force(){
  echo '=== CONFIGFS RNDIS FALLBACK ==='
  g=$(configfs_gadget_dir)
  [ -n "$g" ] || { echo 'CONFIGFS_GADGET=NONE'; return 1; }

  func=""
  for f in "$g"/functions/rndis.* "$g"/functions/rndis*; do
    [ -d "$f" ] && { func="$f"; break; }
  done

  if [ -z "$func" ] && [ -d "$g/functions" ]; then
    mkdir -p "$g/functions/rndis.usb0" 2>/dev/null || true
    [ -d "$g/functions/rndis.usb0" ] && func="$g/functions/rndis.usb0"
  fi

  [ -n "$func" ] || { echo 'CONFIGFS_RNDIS_FUNCTION=NONE'; return 1; }

  IF=$(detect_iface)
  cur=$(cat "/sys/class/net/$IF/address" 2>/dev/null)
  case "$cur" in ''|00:00:00:00:00:00|ff:ff:ff:ff:ff:ff)
    new=$(random_mac)
    set_iface_mac "$new" || true
    cur=$(cat "/sys/class/net/$IF/address" 2>/dev/null)
    ;;
  esac

  host=$(printf '%s' "$cur" | sed 's/..$/fe/')
  [ "$host" = "$cur" ] && host=02:00:00:00:00:fd
  [ -w "$func/dev_addr" ] && printf '%s' "$cur" > "$func/dev_addr" 2>/dev/null || true
  [ -w "$func/host_addr" ] && printf '%s' "$host" > "$func/host_addr" 2>/dev/null || true

  bound_udc=""
  [ -f "$g/UDC" ] && bound_udc=$(cat "$g/UDC" 2>/dev/null)
  cfg=""
  for c in "$g"/configs/*; do [ -d "$c" ] && { cfg="$c"; break; }; done
  [ -n "$cfg" ] || { echo 'CONFIGFS_CONFIG=NONE'; return 1; }

  link="$cfg/$(basename "$func")"
  if [ ! -e "$link" ]; then
    if ! ln -s "$func" "$link" 2>/dev/null; then
      [ -w "$g/UDC" ] && printf '' > "$g/UDC" 2>/dev/null || true
      sleep 1
      ln -s "$func" "$link" 2>/dev/null || true
    fi
  fi

  udc=""
  if [ -n "$bound_udc" ]; then
    udc="$bound_udc"
  else
    for u in /sys/class/udc/*; do [ -e "$u" ] && { udc="$(basename "$u")"; break; }; done
  fi
  if [ -n "$udc" ] && [ -w "$g/UDC" ]; then
    printf '%s' "$udc" > "$g/UDC" 2>/dev/null || true
    echo "CONFIGFS_UDC=$udc"
  fi
  echo "CONFIGFS_GADGET=$g CONFIGFS_RNDIS_FUNCTION=$func CONFIGFS_DEV_MAC=${cur:-unknown} CONFIGFS_HOST_MAC=${host:-unknown}"
  [ -e "$link" ]
}

rndis_gadget(){
  echo '=== ANDROID RNDIS GADGET CONFIGURATION ==='
  cur=$(usb_function_get)
  echo "USB_FUNCTION_CURRENT=$cur"
  want=rndis
  echo ",$cur," | grep -qi ',adb,' && want=rndis,adb
  if ! usb_function_set "$want"; then
    usb_gadget_reset || true
    echo '[RNDIS] svc/setprop path did not confirm RNDIS; trying ConfigFS directly.'
    configfs_rndis_force || true
  fi
  sleep 2
  IF=$(detect_iface)
  if [ ! -d "/sys/class/net/$IF" ]; then
    echo '[RNDIS] No usb/rndis interface appeared; forcing ConfigFS re-enumeration.'
    configfs_rndis_force || true
    sleep 2
    IF=$(detect_iface)
  fi
  echo "USB_GADGET_INTERFACE=$IF"
  gadget_mac
  run_native up >/dev/null 2>&1 || true
  echo "USB_GADGET_CONFIG=$(getprop_safe sys.usb.config)"
  echo "USB_GADGET_STATE=$(getprop_safe sys.usb.state)"
}

rndis_gadget_persist(){
  cur=$(usb_function_get)
  want=rndis
  echo ",$cur," | grep -qi ',adb,' && want=rndis,adb
  if has setprop; then
    setprop persist.sys.usb.config "$want" 2>/dev/null || true
    setprop persist.vendor.usb.config "$want" 2>/dev/null || true
  fi
  if ! usb_function_set "$want"; then
    configfs_rndis_force || true
  fi
}

gadget_function_dir(){
  for root in /config/usb_gadget /sys/kernel/config/usb_gadget; do
    [ -d "$root" ] || continue
    for f in "$root"/*/functions/rndis*; do
      [ -d "$f" ] && { echo "$f"; return 0; }
    done
  done
  return 1
}

random_mac(){
  [ -x "$BB" ] || { printf '02:00:00:00:00:01\n'; return; }
  hex=$($BB od -An -tx1 -N6 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ "${#hex}" -eq 12 ] || { printf '02:00:00:00:00:01\n'; return; }
  first=${hex%??????????}
  rest=${hex#??}
  first=$(printf '%02x' $((0x$first & 0xfe | 2)))
  printf '%s:%s:%s:%s:%s:%s\n' "$first" "${rest:0:2}" "${rest:2:2}" "${rest:4:2}" "${rest:6:2}" "${rest:8:2}"
}

set_iface_mac(){
  mac="$1"
  [ -n "$mac" ] || return 1
  run_native set-mac "$mac" >/dev/null 2>&1 && return 0
  [ -x "$BB" ] && "$BB" ifconfig "$IF" hw ether "$mac" >/dev/null 2>&1 && return 0
  if has ifconfig; then ifconfig "$IF" hw ether "$mac" >/dev/null 2>&1 && return 0; fi
  return 1
}

gadget_mac(){
  [ -d "/sys/class/net/$IF" ] || return 0
  cur=$(cat "/sys/class/net/$IF/address" 2>/dev/null)
  case "$cur" in ''|00:00:00:00:00:00|ff:ff:ff:ff:ff:ff) new=$(random_mac); set_iface_mac "$new" || true; cur=$(cat "/sys/class/net/$IF/address" 2>/dev/null);; esac
  f=$(gadget_function_dir)
  if [ -n "$f" ]; then
    host=$(printf '%s' "$cur" | sed 's/..$/fe/')
    [ "$host" = "$cur" ] && host=02:00:00:00:00:fd
    [ -w "$f/dev_addr" ] && printf '%s' "$cur" > "$f/dev_addr" 2>/dev/null || true
    [ -w "$f/host_addr" ] && printf '%s' "$host" > "$f/host_addr" 2>/dev/null || true
    echo "GADGET_DEV_ADDR=$cur GADGET_HOST_ADDR=$host"
  fi
  echo "INTERFACE_MAC=${cur:-unknown}"
}

root_info(){
  echo '=== ROOT ACCESS ==='
  for su in /system/xbin/su /system/bin/su /vendor/bin/su; do
    if [ -x "$su" ]; then
      echo "SU_BINARY=$su"
      if "$su" -c id >/tmp/usb0-root-id.$$ 2>&1; then
        cat /tmp/usb0-root-id.$$ 2>/dev/null
        rm -f /tmp/usb0-root-id.$$ 2>/dev/null || true
        echo 'ROOT_EXEC=YES'
        return 0
      fi
      cat /tmp/usb0-root-id.$$ 2>/dev/null || true
      rm -f /tmp/usb0-root-id.$$ 2>/dev/null || true
    fi
  done
  if has su && su -c id >/tmp/usb0-root-id.$$ 2>&1; then
    cat /tmp/usb0-root-id.$$ 2>/dev/null
    rm -f /tmp/usb0-root-id.$$ 2>/dev/null || true
    echo 'SU_BINARY=PATH'
    echo 'ROOT_EXEC=YES'
    return 0
  fi
  cat /tmp/usb0-root-id.$$ 2>/dev/null || true
  rm -f /tmp/usb0-root-id.$$ 2>/dev/null || true
  echo 'ROOT_EXEC=NO'
  return 1
}

arp_fix(){
  run_native ensure-mac >/dev/null 2>&1 || true
  gw=$(run_native status 2>/dev/null | sed -n 's/^GW=//p' | head -1)
  [ -n "$gw" ] && [ "$gw" != "-" ] || { echo 'ARP_AUTO=NO_GATEWAY'; return 1; }
  echo "ARP_TARGET=$gw"
  run_native arp-gateway && return 0
  if [ -x "$BB" ]; then
    echo '[ARP] Native resolver failed; using bundled BusyBox arping/arp fallback.'
    bb arping -I "$IF" -c 3 -w 3 "$gw" >/tmp/usb0-arping.$$ 2>&1 || true
    mac=$(bb arp -n 2>/dev/null | awk -v g="$gw" '$1==g {print $3}' | head -1)
  case "$mac" in
      ??\:??\:??\:??\:??\:??)
        run_native arp-set "$gw" "$mac" && { echo "ARP_AUTO=BUSYBOX_OK MAC=$mac"; rm -f /tmp/usb0-arping.$$; return 0; } ;;
    esac
    if bb arp -i "$IF" -s "$gw" "$mac" >/dev/null 2>&1; then
      echo "ARP_AUTO=BUSYBOX_STATIC_OK MAC=$mac"
      rm -f /tmp/usb0-arping.$$ 2>/dev/null || true
      return 0
    fi
    cat /tmp/usb0-arping.$$ 2>/dev/null || true
    rm -f /tmp/usb0-arping.$$ 2>/dev/null || true
  fi
  echo 'ARP_AUTO=FAIL'
  return 1
}

usb_power_recovery(){
  echo '=== USB POWER/AUTOSUSPEND RECOVERY ==='
  p=$(usb_iface_path)
  [ -n "$p" ] || return 1
  root="$p"
  while [ "$root" != "/" ] && [ -n "$root" ]; do
    case "$root" in
      */usb[0-9]/*|*/[0-9]-[0-9]*) :;;
    esac
    if [ -f "$root/power/control" ]; then
      printf 'on' > "$root/power/control" 2>/dev/null || true
      echo "USB_POWER_CONTROL=on:$root"
      [ -f "$root/power/autosuspend_delay_ms" ] && printf '0' > "$root/power/autosuspend_delay_ms" 2>/dev/null || true
      return 0
    fi
    root=$(dirname "$root")
  done
  echo 'USB_POWER_CONTROL=UNAVAILABLE'
  return 1
}

gadget_dhcp_stop(){
  if [ -s "$STATE/udhcpd.pid" ]; then
    pid=$(cat "$STATE/udhcpd.pid" 2>/dev/null)
    kill "$pid" 2>/dev/null || true
    rm -f "$STATE/udhcpd.pid"
  fi
}

gadget_tether(){
  [ -d "/sys/class/net/$IF" ] || return 1
  echo '=== USB RNDIS DHCP/NAT FALLBACK ==='
  # Do not fight Android Tethering if it is already managing USB.
  if has dumpsys && dumpsys tethering 2>/dev/null | grep -qi "$IF"; then
    echo 'ANDROID_TETHERING=ALREADY_MANAGING_USB'
    return 0
  fi
  ipaddr=$(run_native status | sed -n 's/^IP=//p' | head -1)
  case "$ipaddr" in ''|-) run_native up >/dev/null 2>&1 || true; if [ -x "$BB" ] && "$BB" ip addr replace 192.168.42.1/24 dev "$IF" >/dev/null 2>&1; then :; elif has ip; then ip addr replace 192.168.42.1/24 dev "$IF"; fi;; esac
  run_native up >/dev/null 2>&1 || true
  cat > "$STATE/udhcpd.conf" <<EOF
interface $IF
start 192.168.42.2
end 192.168.42.100
option subnet 255.255.255.0
option lease 86400
option router 192.168.42.1
option dns 1.1.1.1 8.8.8.8
lease_file $STATE/udhcpd.leases
EOF
  gadget_dhcp_stop
  if [ -x "$BB" ]; then
    "$BB" udhcpd -f "$STATE/udhcpd.conf" >"$STATE/udhcpd.log" 2>&1 &
    echo $! > "$STATE/udhcpd.pid"
    sleep 1
    kill -0 "$(cat "$STATE/udhcpd.pid")" 2>/dev/null && echo 'USB_DHCP_SERVER=BUSYBOX_OK' || echo 'USB_DHCP_SERVER=FAILED'
  else
    echo 'USB_DHCP_SERVER=BUSYBOX_MISSING'
  fi
  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
  up=$(route_uplink)
  if [ -n "$up" ] && has iptables; then
    iptables -t nat -C POSTROUTING -s 192.168.42.0/24 -o "$up" -j MASQUERADE >/dev/null 2>&1 || iptables -t nat -A POSTROUTING -s 192.168.42.0/24 -o "$up" -j MASQUERADE >/dev/null 2>&1 || true
    iptables -C FORWARD -i "$IF" -o "$up" -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -i "$IF" -o "$up" -j ACCEPT >/dev/null 2>&1 || true
    iptables -C FORWARD -o "$IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -o "$IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 || true
    echo "USB_NAT_UPLINK=$up"
  fi
}

route_uplink(){
  if has ip; then
    ip route show default 2>/dev/null | awk '$0 !~ / dev (usb|rndis)/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
  else
    run_native status >/dev/null 2>&1
  fi
}

gadget_test(){
  echo '=== GADGET LINK TEST ==='
  IF=$(detect_iface)
  run_native status
  [ "$(run_native status 2>/dev/null | sed -n 's/^LINK=//p' | head -1)" = up ] || { echo 'GADGET_LINK=DOWN'; return 1; }
  echo 'GADGET_LINK=UP'
  cfg=$(getprop_safe sys.usb.config)
  echo "GADGET_FUNCTIONS=$cfg"
  echo ",$cfg," | grep -qi ',rndis,' && echo 'RNDIS_FUNCTION=ENABLED' || echo 'RNDIS_FUNCTION=NOT_CONFIRMED'
  if [ -s "$STATE/udhcpd.pid" ]; then
    pid=$(cat "$STATE/udhcpd.pid" 2>/dev/null)
    kill -0 "$pid" 2>/dev/null && echo 'GADGET_DHCP=RUNNING' || echo 'GADGET_DHCP=STOPPED'
  else
    echo 'GADGET_DHCP=NOT_APP_MANAGED'
  fi
  up=$(route_uplink)
  [ -n "$up" ] && echo "GADGET_UPLINK=$up" || echo 'GADGET_UPLINK=NONE'
  echo 'GADGET_TEST=OK'
  return 0
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
  echo '=== USB RNDIS RECOVERY ==='
  role_now=$(role)
  echo "USB_ROLE=$role_now"
  if [ "$role_now" = GADGET ]; then
    rndis_gadget
    return $?
  fi
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
  echo '[1] Detect USB role and RNDIS state'
  system_check
  ROLE=$(role)
  if [ "$ROLE" = UNKNOWN ] && configfs_gadget_dir >/dev/null 2>&1; then
    ROLE=GADGET
    echo 'USB_ROLE=GADGET (ConfigFS/UDC detected)'
  fi
  echo "USB_ROLE=$ROLE"
  if [ "$ROLE" = GADGET ]; then
    if [ "${USB0_AUTO_RNDIS:-1}" = 1 ]; then
      echo '[1a] Force the Android USB function to RNDIS (preserving ADB when already enabled)'
      rndis_gadget
    else
      echo '[1a] Automatic RNDIS gadget reconfiguration disabled'
    fi
    IF=$(detect_iface)
    echo '[1b] Repair gadget MAC/configfs state'
    gadget_mac
    usb_power_recovery || true
    IF=$(detect_iface)
  fi
  if [ ! -d "/sys/class/net/$IF" ]; then
    echo '[1c] No USB/RNDIS interface; reset the attached USB device and re-enumerate'
    rndis_set
    IF=$(detect_iface)
    if [ ! -d "/sys/class/net/$IF" ]; then echo 'RNDIS_INTERFACE=STILL_MISSING'; return 10; fi
  fi
  echo '[2] Ensure valid interface MAC before bringing the link up'
  run_native ensure-mac || true
  echo '[3] Interface UP'
  run_native up
  gadget_mac || true
  if [ "$ROLE" != GADGET ]; then
    echo '[4] DHCP/address acquisition'
    curip=$(run_native status | sed -n 's/^IP=//p' | head -1)
    if [ -z "$curip" ] || [ "$curip" = "-" ]; then
      i=1
      while [ "$i" -le 3 ]; do
        run_native dhcp && break
        i=$((i+1)); sleep 1
      done
    fi
  elif [ "${USB0_GADGET_DHCP:-1}" = 1 ]; then
    echo '[4] Gadget-side DHCP/NAT fallback when Android Tethering is not active'
    gadget_tether
  fi
  if [ "$ROLE" != GADGET ]; then
    echo '[5] Connected subnet + default route'
    run_native route
    echo '[6] Policy routing repair'
    run_native policy-repair
  fi
  echo '[7] ARP/neighbor refresh + gateway MAC resolution'
  run_native neigh || true
  arp_fix || true
  echo '[8] Reverse-path filter repair'
  rpf=$(run_native rpfilter | sed -n 's/^RP_FILTER=//p' | head -1)
  case "$rpf" in 1|2) run_native set-rpfilter 2;; esac
  echo '[9] MTU repair when obviously abnormal'
  mtu=$(run_native mtu | sed -n 's/^MTU=//p' | head -1)
  case "$mtu" in ''|*[!0-9]*) :;; *) [ "$mtu" -gt 2000 ] && run_native set-mtu 1500;; esac
  echo '[10] DNS resolver repair attempt'
  dns_fix
  echo '[11] USB power/autosuspend recovery'
  usb_power_recovery || true
  echo '[12] Verification'
  if [ "$ROLE" = GADGET ]; then testout=$(gadget_test 2>&1); else testout=$(run_native test 2>&1); fi
  echo "$testout"
  ok_pattern='INET=OK'; [ "$ROLE" = GADGET ] && ok_pattern='GADGET_TEST=OK'
  echo "$testout" | grep -q "$ok_pattern" || {
    echo '[12b] Standard network repair still failing; try an alternate registered USB network driver'
    [ "$ROLE" != GADGET ] && driver_fallback || true
    run_native up
    [ "$ROLE" != GADGET ] && run_native dhcp >/dev/null 2>&1 || true
    [ "$ROLE" != GADGET ] && run_native route || true
    [ "$ROLE" != GADGET ] && run_native policy-repair || true
    run_native neigh || true
    arp_fix || true
    if [ "$ROLE" = GADGET ]; then testout=$(gadget_test 2>&1); else testout=$(run_native test 2>&1); fi
    echo "$testout"
  }
  echo "$testout" | grep -q "$ok_pattern" || {
    echo '[12c] Internet still failing; flush only USB routes and rebuild them'
    [ "$ROLE" != GADGET ] && run_native flush-usb-routes || true
    [ "$ROLE" != GADGET ] && run_native route || true
    [ "$ROLE" != GADGET ] && run_native policy-repair || true
    run_native neigh || true
    arp_fix || true
    if [ "$ROLE" = GADGET ]; then testout=$(gadget_test 2>&1); else testout=$(run_native test 2>&1); fi
    echo "$testout"
  }
  echo '[13] Final state'
  run_native status
  usb_function_get
}

smart_recover(){
  role_now=$(role)
  echo "SMART_RECOVER_ROLE=$role_now"
  if [ "$role_now" = GADGET ] || [ "${USB0_AUTO_RNDIS:-0}" = 1 ]; then
    repair_all
  else
    run_native recover
  fi
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
check) system_check; root_info || true; run_native check ;;
status) echo "ROLE=$(role)"; echo "USB_FUNCTION=$(usb_function_get)"; run_native status ;;
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
rndis-reset) save_snapshot; usb_gadget_reset ;;
rndis-gadget) save_snapshot; rndis_gadget ;;
rndis-persist) save_snapshot; rndis_gadget_persist ;;
rndis-configfs) save_snapshot; configfs_rndis_force ;;
root-info) root_info ;;
usb-role) role ;;
usb-functions) usb_function_get ;;
gadget-mac) gadget_mac ;;
gadget-tether) save_snapshot; gadget_tether ;;
gadget-tether-stop) gadget_dhcp_stop ;;
arp-fix) save_snapshot; arp_fix ;;
mac-fix) save_snapshot; run_native ensure-mac; gadget_mac ;;
usb-power) usb_power_recovery ;;
rndis-aggressive) save_snapshot; if [ "$(role)" = GADGET ]; then usb_gadget_reset || true; else usb_host_reset || true; fi; sleep 2; IF=$(detect_iface); run_native up; run_native recover-aggressive ;;
usb-reauthorize) save_snapshot; info=$(usb_parent_device); [ -n "$info" ] || { echo 'USB_REAUTHORIZE=NO_DEVICE'; exit 1; }; set -- $info; path="$1"; if [ -w "$path/authorized" ]; then printf '0' > "$path/authorized" 2>/dev/null; sleep 1; printf '1' > "$path/authorized" 2>/dev/null; sleep 3; IF=$(detect_iface); echo "USB_REAUTHORIZE=OK INTERFACE=$IF"; else echo 'USB_REAUTHORIZE=UNAVAILABLE'; exit 1; fi ;;
reset) save_snapshot; run_native reset ;;
recover) save_snapshot; smart_recover ;;
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
smart-test) [ "$(role)" = GADGET ] && gadget_test || run_native test ;;
snapshot) run_native snapshot > "$STATE/snapshot.manual"; cat "$STATE/snapshot.manual" ;;
restore)
  if [ -s "$STATE/snapshot.before" ]; then
    echo '=== RESTORE ==='
    oldusb=$(grep '^sys.usb.config=' "$STATE/snapshot.before" | tail -1 | cut -d= -f2-)
    case "$oldusb" in
      ''|'none') : ;;
      *)
        if has setprop; then
          setprop sys.usb.config none >/dev/null 2>&1 || true
          sleep 1
          setprop persist.sys.usb.config "$oldusb" >/dev/null 2>&1 || true
          setprop persist.vendor.usb.config "$oldusb" >/dev/null 2>&1 || true
          setprop sys.usb.config "$oldusb" >/dev/null 2>&1 || true
          sleep 2
        fi
        ;;
    esac
    # Restore means restore a known-good interface state without restoring stale routes blindly.
    link=$(grep '^LINK=' "$STATE/snapshot.before" | tail -1 | cut -d= -f2)
    [ "$link" = up ] && run_native up || run_native down
    oldip=$(grep '^IP=' "$STATE/snapshot.before" | tail -1 | cut -d= -f2)
    oldtable=$(grep '^TABLE=' "$STATE/snapshot.before" | tail -1 | cut -d= -f2)
    case "$oldip" in ""|-) :;; *) run_native policy-delete "$oldip" "$oldtable";; esac
    smart_recover
    gadget_dhcp_stop
    echo 'RESTORE_DONE=1'
  else
    echo 'RESTORE=no-snapshot'; exit 1
  fi ;;
diagnose) system_check; run_native diagnose; echo '--- ANDROID CONNECTIVITY ---'; if has dumpsys; then dumpsys connectivity 2>&1 | grep -i -E 'usb0|rndis|Ethernet|NetworkAgent|netId|DNS|netd|default|route' | head -300; fi; echo '--- FIREWALL ---'; firewall_diag ;;
*) echo 'usage: usb0-helper {check|status|up|down|dhcp|dhcp-retry|static|route|route-connected|policy|policy-repair|policy-delete|flush-usb-routes|neigh|arp-fix|mac-fix|mtu|set-mtu|rpfilter|set-rpfilter|rndis|rndis-reset|rndis-gadget|rndis-persist|rndis-configfs|usb-reset|usb-reauthorize|rndis-aggressive|usb-role|usb-functions|root-info|gadget-mac|gadget-tether|gadget-tether-stop|usb-power|reset|recover|recover-aggressive|repair|fix-all|dns|firewall|usbdiag|driver-info|driver-fallback|driver-load|driver-rebind|usb-host-tree|test|smart-test|snapshot|restore|diagnose}'; exit 2 ;;
esac
