package com.r36s.usb0manager

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.widget.*
import androidx.core.content.ContextCompat
import java.io.File
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.Executors

class MainActivity : Activity() {
    private lateinit var status: TextView
    private lateinit var log: TextView
    private val pool = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private var lastSnapshot = ""
    private lateinit var helper: File
    private val prefs by lazy { getSharedPreferences("settings", MODE_PRIVATE) }
    private val stamp get() = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date())

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        helper = HelperManager.install(this).helper

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(18, 18, 18, 18)
        }
        status = TextView(this).apply {
            textSize = 17f
            setPadding(8, 8, 8, 12)
        }
        log = TextView(this).apply {
            textSize = 12f
            setTextIsSelectable(true)
        }

        root.addView(TextView(this).apply {
            text = "USB0 / RNDIS Recovery Manager"
            textSize = 21f
            setPadding(8, 4, 8, 2)
        })
        root.addView(status)

        root.addView(makeRow("FIX EVERYTHING", "Auto recover", "USB/RNDIS reset"))
        root.addView(makeRow("Bring interface UP", "DHCP renew", "Route repair"))
        root.addView(makeRow("Policy repair", "Connected route", "Flush USB routes"))
        root.addView(makeRow("ARP refresh", "MTU repair", "rp_filter repair"))
        root.addView(makeRow("DNS repair", "Interface reset", "Bring interface DOWN"))
        root.addView(makeRow("Diagnose", "USB/RNDIS diag", "Firewall diag"))
        root.addView(makeRow("Driver status", "Driver fallback", "USB re-authorize"))
        root.addView(makeRow("PPP/modem scan", "Kernel capabilities", "USB host tree"))
        root.addView(makeRow("Test connectivity", "Save report", "Share report"))
        root.addView(makeRow("Restore", "Snapshot", "Command check"))
        root.addView(makeRow("Event log"))

        root.addView(TextView(this).apply {
            text = "Root helper console (bundled commands only)"
            textSize = 13f
            setPadding(8, 10, 8, 4)
        })
        val consoleRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            val input = EditText(this@MainActivity).apply {
                hint = "status / driver-info / driver-fallback / usb-reset"
                isSingleLine = true
                layoutParams = LinearLayout.LayoutParams(0, -2, 2.4f)
            }
            val run = Button(this@MainActivity).apply {
                text = "Run"
                setOnClickListener {
                    val cmd = input.text.toString().trim()
                    if (cmd.isBlank()) Toast.makeText(this@MainActivity, "Enter a bundled helper command", Toast.LENGTH_SHORT).show()
                    else action("CONSOLE:$cmd")
                }
                layoutParams = LinearLayout.LayoutParams(0, -2, .6f)
            }
            addView(input); addView(run)
        }
        root.addView(consoleRow)

        root.addView(TextView(this).apply {
            text = "Advanced static fallback (only use when DHCP cannot provide an address)"
            textSize = 13f
            setPadding(8, 10, 8, 4)
        })
        val staticRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            val ip = EditText(this@MainActivity).apply { hint = "IP"; inputType = 1; layoutParams = LinearLayout.LayoutParams(0, -2, 1f) }
            val prefix = EditText(this@MainActivity).apply { hint = "Prefix"; inputType = 2; layoutParams = LinearLayout.LayoutParams(0, -2, .45f) }
            val gw = EditText(this@MainActivity).apply { hint = "Gateway"; inputType = 1; layoutParams = LinearLayout.LayoutParams(0, -2, 1f) }
            val apply = Button(this@MainActivity).apply {
                text = "Apply"
                setOnClickListener {
                    if (ip.text.isNullOrBlank() || prefix.text.isNullOrBlank() || gw.text.isNullOrBlank()) {
                        Toast.makeText(this@MainActivity, "Enter IP, prefix and gateway", Toast.LENGTH_SHORT).show()
                    } else {
                        action("STATIC:${ip.text}:${prefix.text}:${gw.text}")
                    }
                }
            }
            addView(ip); addView(prefix); addView(gw); addView(apply, LinearLayout.LayoutParams(0, -2, .75f))
        }
        root.addView(staticRow)

        val monitor = CheckBox(this).apply {
            text = "Background USB0 monitor"
            isChecked = prefs.getBoolean("monitor_on", false)
            setOnCheckedChangeListener { _, checked -> setMonitor(checked) }
        }
        root.addView(monitor)

        val autoRecover = CheckBox(this).apply {
            text = "Automatically repair IP/routes/ARP when USB0 degrades"
            isChecked = prefs.getBoolean("auto_recover", false)
            setOnCheckedChangeListener { _, checked ->
                prefs.edit().putBoolean("auto_recover", checked).apply()
                append("[$stamp] Automatic network recovery ${if (checked) "enabled" else "disabled"}.")
                if (checked && !prefs.getBoolean("monitor_on", false)) {
                    monitor.isChecked = true
                }
            }
        }
        root.addView(autoRecover)

        val aggressive = CheckBox(this).apply {
            text = "Allow automatic USB device reset if usb0 is missing (disrupts USB briefly)"
            isChecked = prefs.getBoolean("auto_rndis", false)
            setOnCheckedChangeListener { _, checked ->
                prefs.edit().putBoolean("auto_rndis", checked).apply()
                append("[$stamp] Automatic RNDIS reset ${if (checked) "enabled" else "disabled"}.")
            }
        }
        root.addView(aggressive)

        val driverFallback = CheckBox(this).apply {
            text = "Allow automatic alternate-driver fallback after normal recovery fails"
            isChecked = prefs.getBoolean("auto_driver_fallback", false)
            setOnCheckedChangeListener { _, checked ->
                prefs.edit().putBoolean("auto_driver_fallback", checked).apply()
                append("[$stamp] Automatic driver fallback ${if (checked) "enabled" else "disabled"}.")
            }
        }
        root.addView(driverFallback)

        root.addView(TextView(this).apply {
            text = "Fix Everything is ordered and staged. It snapshots first, repairs only usb/rndis state, verifies, then retries with a usb0-only route rebuild if needed."
            textSize = 12f
            setPadding(8, 4, 8, 8)
        })
        root.addView(ScrollView(this).apply { addView(log) }, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)

        append("USB0 Manager v1.7.0\nSelf-contained ARM64 USB/RNDIS recovery + driver fallback engine.")
        append(KernelCapabilities.summary(this))
        append(runRoot("check"))
        refresh()
        handler.post(object : Runnable {
            override fun run() {
                refresh()
                handler.postDelayed(this, 3000)
            }
        })
    }

    private fun makeRow(vararg labels: String): LinearLayout = LinearLayout(this).apply {
        gravity = Gravity.CENTER_VERTICAL
        labels.forEach { label ->
            addView(Button(this@MainActivity).apply {
                text = label
                setOnClickListener { action(label) }
            }, LinearLayout.LayoutParams(0, -2, 1f))
        }
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        pool.shutdownNow()
        super.onDestroy()
    }

    private fun runRoot(command: String): String {
        return try {
            val tokens = command.trim().split(Regex("\\s+")).filter { it.isNotBlank() }
            if (tokens.isEmpty()) {
                ""
            } else {
                val safe = tokens.joinToString(" ") { token -> "'${token.replace("'", "'\\''")}'" }
                val helperQ = "'${helper.absolutePath.replace("'", "'\\''")}'"
                val p = Runtime.getRuntime().exec(arrayOf("su", "-c", "$helperQ $safe"))
                val stdout = p.inputStream.bufferedReader().readText()
                val stderr = p.errorStream.bufferedReader().readText()
                p.waitFor()
                stdout + if (stderr.isNotBlank()) "\n[stderr]\n$stderr" else ""
            }
        } catch (e: Exception) {
            "ROOT ERROR: ${e.message}"
        }
    }

    private fun refresh() {
        pool.submit {
            val s = runRoot("status")
            val marker = s.substringAfter("INTERFACE=", s).trim()
            if (lastSnapshot.isNotEmpty() && marker != lastSnapshot) {
                append("\n[$stamp] USB0 state changed\n$s")
            }
            lastSnapshot = marker
            runOnUiThread { status.text = parseSummary(s) }
        }
    }

    private fun action(a: String) {
        pool.submit {
            val out = when (a) {
                "FIX EVERYTHING" -> runRoot("fix-all")
                "Auto recover" -> runRoot("recover")
                "USB/RNDIS reset" -> runRoot("usb-reset")
                "USB re-authorize" -> runRoot("usb-reauthorize")
                "Bring interface UP" -> runRoot("up")
                "Bring interface DOWN" -> runRoot("down")
                "DHCP renew" -> runRoot("dhcp")
                "Route repair" -> runRoot("route")
                "Policy repair" -> runRoot("policy-repair")
                "Connected route" -> runRoot("route-connected")
                "Flush USB routes" -> runRoot("flush-usb-routes")
                "ARP refresh" -> runRoot("neigh")
                "MTU repair" -> runRoot("set-mtu 1500")
                "rp_filter repair" -> runRoot("set-rpfilter 2")
                "DNS repair" -> runRoot("dns")
                "Interface reset" -> runRoot("reset")
                "Diagnose" -> runRoot("diagnose")
                "USB/RNDIS diag" -> runRoot("usbdiag")
                "Firewall diag" -> runRoot("firewall")
                "Driver status" -> runRoot("driver-info")
                "Driver fallback" -> runRoot("driver-fallback")
                "USB host scan" -> UsbHostProbe.scan(this@MainActivity)
                "PPP/modem scan" -> UsbHostProbe.scan(this@MainActivity, networkOnly = true)
                "Kernel capabilities" -> KernelCapabilities.report(this@MainActivity)
                "USB host tree" -> runRoot("usb-host-tree")
                "Test connectivity" -> runRoot("test")
                "Restore" -> runRoot("restore")
                "Command check" -> runRoot("check")
                "Snapshot" -> runRoot("snapshot")
                "Save report" -> makeFullReport()
                "Share report" -> makeFullReport()
                "Event log" -> readEvents()
                else -> if (a.startsWith("CONSOLE:")) {
                    runRoot(a.removePrefix("CONSOLE:"))
                } else if (a.startsWith("STATIC:")) {
                    val parts = a.split(":")
                    if (parts.size == 4) runRoot("static ${parts[1]} ${parts[2]} ${parts[3]}") else "STATIC=BAD_INPUT"
                } else ""
            }
            append("\n[$stamp] $a\n$out")
            if (a == "Save report" || a == "Share report") {
                val f = saveReport(out)
                if (a == "Share report") shareFile(f)
            }
            refresh()
        }
    }

    private fun makeFullReport(): String =
        "=== USB0 MANAGER REPORT ===\n" +
            "Time=$stamp\n" +
            "--- COMMAND CHECK ---\n${runRoot("check")}\n" +
            "--- STATUS ---\n${runRoot("status")}\n" +
            "--- DIAGNOSTICS ---\n${runRoot("diagnose")}\n" +
            "--- USB/RNDIS DIAGNOSTICS ---\n${runRoot("usbdiag")}\n" +
            "--- DRIVER FALLBACK MATRIX ---\n${runRoot("driver-info")}\n" +
            "--- USB HOST PROBE ---\n${UsbHostProbe.scan(this)}\n" +
            "--- KERNEL CAPABILITIES ---\n${KernelCapabilities.report(this)}\n" +
            "--- POLICY ---\n${runRoot("policy")}\n" +
            "--- SNAPSHOT ---\n${runRoot("snapshot")}\n" +
            "--- EVENTS ---\n${readEvents()}"

    private fun readEvents(): String =
        File(filesDir, "events.log").takeIf { it.exists() }?.readText()?.takeLast(16000)
            ?: "No event history."

    private fun saveReport(report: String): File {
        val dir = File(getExternalFilesDir(null), "reports")
        dir.mkdirs()
        val f = File(dir, "usb0-${SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())}.txt")
        f.writeText(report)
        return f
    }

    private fun shareFile(f: File) {
        startActivity(Intent.createChooser(
            Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, f.readText())
            },
            "Share USB0 report"
        ))
    }

    private fun setMonitor(on: Boolean) {
        prefs.edit().putBoolean("monitor_on", on).apply()
        val i = Intent(this, MonitorService::class.java)
        if (on) ContextCompat.startForegroundService(this, i) else stopService(i)
        append("[$stamp] Background monitor ${if (on) "enabled" else "disabled"}.")
    }

    private fun parseSummary(s: String): String {
        fun v(k: String) = s.lines().firstOrNull { it.startsWith("$k=") }?.substringAfter("=")?.trim() ?: "-"
        return "Interface: ${v("INTERFACE")}  Link: ${v("LINK")}  Carrier: ${v("CARRIER")}\n" +
            "IP: ${v("IP")}/${v("PREFIX")}  GW: ${v("GW")}  Table: ${v("TABLE")}\n" +
            "Route: ${v("ROUTE")}  Gateway: ${v("GWTEST")}  Internet: ${v("INET")}  DNS: ${v("DNS")}  RP: ${v("RP_FILTER")}  MTU: ${v("MTU")}"
    }

    private fun append(s: String) {
        runOnUiThread { log.append("\n$s") }
    }
}
