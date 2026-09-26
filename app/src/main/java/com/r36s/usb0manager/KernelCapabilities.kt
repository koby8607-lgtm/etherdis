package com.r36s.usb0manager

import android.content.Context

object KernelCapabilities {
    private fun lines(context: Context): List<String> =
        context.assets.open("r36s/kernel-capabilities.txt").bufferedReader().readLines().filter { it.isNotBlank() }

    private fun state(line: String): String? {
        val text = line.substringAfter(": ", line)
        return when {
            text.startsWith("# CONFIG_") && text.endsWith(" is not set") -> "n"
            text.startsWith("CONFIG_") && '=' in text -> text.substringAfter('=')
            else -> null
        }
    }

    fun summary(context: Context): String {
        val all = lines(context)
        val enabled = all.count { state(it)?.let { v -> v == "y" || v == "m" } == true }
        return "Supplied R36S kernel profile: $enabled/${all.size} relevant USB/network/PPP options enabled."
    }

    fun report(context: Context): String = buildString {
        append("=== R36S KERNEL CAPABILITIES (SUPPLIED DEFCONFIG) ===\n")
        lines(context).forEach { append(it).append('\n') }
        append("\nInterpretation:\n")
        append("The supplied config has host-side USB RNDIS, CDC Ethernet, CDC EEM, CDC subset, RTL8150 and RTL8152 support enabled.\n")
        append("CDC NCM, CDC MBIM, QMI WWAN, HSO, Sierra Net, IPHETH and several vendor USB-network drivers are disabled in this defconfig.\n")
        append("PPP core/PPTP/MPPE are enabled, while PPP async/sync-TTY paths and USB serial/ACM are disabled.\n")
    }
}
