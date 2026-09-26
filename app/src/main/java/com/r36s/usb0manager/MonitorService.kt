package com.r36s.usb0manager

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import java.io.File

class MonitorService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var last = ""
    private var lastRecoveryAt = 0L
    private val recoverCooldownMs = 30_000L

    private val tick = object : Runnable {
        override fun run() {
            val state = runStatus()
            if (state.isNotBlank() && state != last) {
                appendEvent(state)
                updateNotification(state)
                if (shouldRecover(state) && System.currentTimeMillis() - lastRecoveryAt >= recoverCooldownMs) {
                    lastRecoveryAt = System.currentTimeMillis()
                    val command = if (allowAggressive() && state.contains("NATIVE_INTERFACE=NO")) "recover-aggressive" else "recover"
                    val result = runHelper(command)
                    appendEvent("AUTO_RECOVER[$command] $result")
                    if (getSharedPreferences("settings", MODE_PRIVATE).getBoolean("auto_driver_fallback", false) &&
                        (result.contains("INET=FAIL") || result.contains("ROUTE=FAIL") || result.contains("NO_INTERFACE"))) {
                        val fallback = runHelper("driver-fallback")
                        appendEvent("AUTO_DRIVER_FALLBACK $fallback")
                    }
                    updateNotification("Recovery attempted")
                }
                last = state
            }
            handler.postDelayed(this, 5000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        HelperManager.install(this)
        createChannel()
        startForeground(7, notification("USB0 monitor starting"))
        handler.post(tick)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun allowAggressive() = getSharedPreferences("settings", MODE_PRIVATE).getBoolean("auto_rndis", false)

    private fun shouldRecover(state: String): Boolean {
        val prefs = getSharedPreferences("settings", MODE_PRIVATE)
        if (!prefs.getBoolean("auto_recover", false) && !(allowAggressive() && state.contains("NATIVE_INTERFACE=NO"))) return false
        return state.contains("NATIVE_INTERFACE=NO") ||
            state.contains("LINK=down") ||
            state.contains("CARRIER=0") ||
            state.contains("IP=-") ||
            state.contains("GW=-") ||
            state.contains("ROUTE=FAIL") ||
            state.contains("GWTEST=FAIL")
    }

    private fun runStatus(): String = runHelper("status").let { out ->
        if (out.isBlank()) return@let "empty"
        out.lines()
            .filter {
                it.startsWith("INTERFACE=") || it.startsWith("NATIVE_INTERFACE=") ||
                    it.startsWith("LINK=") || it.startsWith("CARRIER=") ||
                    it.startsWith("IP=") || it.startsWith("GW=") ||
                    it.startsWith("TABLE=") || it.startsWith("ROUTE=") ||
                    it.startsWith("GWTEST=") || it.startsWith("INET=") ||
                    it.startsWith("DNS=") || it.startsWith("MTU=") ||
                    it.startsWith("RP_FILTER=")
            }
            .joinToString(" ")
    }

    private fun runHelper(command: String): String = try {
        val helper = HelperManager.install(this).helper
        val q = "'${helper.absolutePath.replace("'", "'\\''")}' $command"
        val p = Runtime.getRuntime().exec(arrayOf("su", "-c", q))
        val out = p.inputStream.bufferedReader().readText()
        val err = p.errorStream.bufferedReader().readText()
        p.waitFor()
        out + if (err.isNotBlank()) "\n[stderr]\n$err" else ""
    } catch (e: Exception) {
        "root-error=${e.message}"
    }

    private fun appendEvent(state: String) {
        File(filesDir, "events.log").appendText("${System.currentTimeMillis()} $state\n")
        val f = File(filesDir, "events.log")
        if (f.length() > 256 * 1024) {
            val lines = f.readLines().takeLast(1000)
            f.writeText(lines.joinToString("\n") + "\n")
        }
    }

    private fun createChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel("usb0", "USB0 monitoring", NotificationManager.IMPORTANCE_LOW)
        )
    }

    private fun notification(text: String): Notification =
        NotificationCompat.Builder(this, "usb0")
            .setSmallIcon(android.R.drawable.stat_sys_data_usb)
            .setContentTitle("USB0 Manager")
            .setContentText(text.take(120))
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

    private fun updateNotification(state: String) {
        getSystemService(NotificationManager::class.java).notify(7, notification(state))
    }
}
