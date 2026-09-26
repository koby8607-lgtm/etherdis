package com.r36s.usb0manager

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.Executors

class MainActivity : Activity() {
    private lateinit var output: TextView
    private val exec = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private var lastState = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 24, 24, 24)
        }
        output = TextView(this).apply { textSize = 13f; setTextIsSelectable(true) }

        fun button(label: String, action: () -> Unit): Button =
            Button(this).apply { text = label; setOnClickListener { action() } }

        root.addView(button("Refresh / Diagnose") { run("diagnose") })
        root.addView(button("Safe Repair usb0") { run("repair") })
        root.addView(button("Restore recorded state") { run("restore") })
        root.addView(button("RNDIS traffic test") { run("traffic") })
        root.addView(ScrollView(this).apply { addView(output) },
            LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)

        run("diagnose")
        scheduleMonitor()
    }

    private fun scheduleMonitor() {
        handler.postDelayed(object : Runnable {
            override fun run() {
                exec.submit {
                    val state = shell("ip -4 addr show dev usb0 2>/dev/null; ip route get 1.1.1.1 2>/dev/null")
                    if (state != lastState && lastState.isNotEmpty()) {
                        append("\n[usb0 change detected]\n$state")
                    }
                    lastState = state
                }
                handler.postDelayed(this, 3000)
            }
        }, 3000)
    }

    private fun run(mode: String) {
        exec.submit {
            val script = when (mode) {
                "diagnose" -> DIAGNOSE
                "repair" -> REPAIR
                "restore" -> RESTORE
                else -> TRAFFIC
            }
            val result = shell("su -c 'sh -c ${shellQuote(script)}'")
            append(result)
        }
    }

    private fun shell(cmd: String): String {
        return try {
            val p = Runtime.getRuntime().exec(arrayOf("sh", "-c", cmd))
            val out = BufferedReader(InputStreamReader(p.inputStream)).readText()
            val err = BufferedReader(InputStreamReader(p.errorStream)).readText()
            p.waitFor()
            out + if (err.isNotBlank()) "\n[stderr]\n$err" else ""
        } catch (e: Exception) { e.stackTraceToString() }
    }

    private fun shellQuote(s: String): String =
        "'" + s.replace("'", "'\\''") + "'"

    private fun append(s: String) = runOnUiThread {
        output.append("\n$s\n")
    }

    companion object {
        private const val COMMON = """
IF=usb0
echo "=== USB0 MANAGER ==="
date
id
ip link show dev "$IF" 2>&1
echo "--- driver ---"
readlink -f /sys/class/net/$IF/device/driver 2>&1
echo "--- address ---"
ip -4 addr show dev "$IF" 2>&1
echo "--- main routes ---"
ip route show dev "$IF" 2>&1
echo "--- usb0 table ---"
ip route show table "$IF" 2>&1
echo "--- all relevant rules ---"
ip rule show 2>&1 | grep -E 'usb0|lookup 100|lookup [0-9]+' || true
echo "--- route to internet ---"
ip route get 1.1.1.1 2>&1
echo "--- neighbors ---"
ip neigh show dev "$IF" 2>&1
echo "--- DNS properties ---"
getprop net.dns1
getprop net.dns2
echo "--- counters ---"
cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null
cat /sys/class/net/$IF/statistics/tx_packets 2>/dev/null
"""

        private const val DIAGNOSE = COMMON + """
echo "--- gateway ping ---"
GW=$(ip route show table "$IF" 2>/dev/null | awk '/^default via / {print $3; exit}')
[ -z "$GW" ] && GW=$(ip route show dev "$IF" 2>/dev/null | awk '/^default via / {print $3; exit}')
echo "gateway=$GW"
if [ -n "$GW" ]; then ping -c 3 -W 2 -I "$IF" "$GW" 2>&1; fi
echo "--- internet IP ping ---"
ping -c 3 -W 3 -I "$IF" 1.1.1.1 2>&1
echo "--- DNS ping ---"
ping -c 2 -W 5 -I "$IF" google.com 2>&1
"""

        private const val REPAIR = r"""
IF=usb0
mkdir -p /data/local/tmp/usb0-manager
ip route show table "$IF" > /data/local/tmp/usb0-manager/routes.before 2>/dev/null
ip rule show > /data/local/tmp/usb0-manager/rules.before 2>/dev/null
ip -4 addr show dev "$IF" > /data/local/tmp/usb0-manager/addr.before 2>/dev/null
GW=$(ip route show table "$IF" 2>/dev/null | awk '/^default via / {print $3; exit}')
DEV=$(ip -4 addr show dev "$IF" >/dev/null 2>&1 && echo "$IF")
echo "Detected gateway: ${GW:-none}"
if [ -n "$GW" ]; then
  ip route replace default via "$GW" dev "$IF" table "$IF" 2>&1
  echo "Default route refreshed in table $IF"
else
  echo "No gateway found; nothing changed."
fi
ip route get 1.1.1.1 2>&1
"""

        private const val RESTORE = r"""
IF=usb0
D=/data/local/tmp/usb0-manager
echo "Restoring only the route snapshot if it exists."
if [ -s "$D/routes.before" ]; then
  GW=$(awk '/^default via / {print $3; exit}' "$D/routes.before")
  if [ -n "$GW" ]; then
    ip route replace default via "$GW" dev "$IF" table "$IF" 2>&1
    echo "Restored default route: $GW"
  else
    echo "Snapshot had no default route."
  fi
else
  echo "No saved snapshot."
fi
"""

        private const val TRAFFIC = COMMON + """
echo "--- live counter sample ---"
A=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null)
B=$(cat /sys/class/net/$IF/statistics/tx_packets 2>/dev/null)
echo "before rx=$A tx=$B"
GW=$(ip route show table "$IF" 2>/dev/null | awk '/^default via / {print $3; exit}')
if [ -n "$GW" ]; then ping -c 5 -W 2 -I "$IF" "$GW" 2>&1; fi
C=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null)
D=$(cat /sys/class/net/$IF/statistics/tx_packets 2>/dev/null)
echo "after rx=$C tx=$D"
"""
    }
}
