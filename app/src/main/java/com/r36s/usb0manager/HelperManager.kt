package com.r36s.usb0manager

import android.content.Context
import java.io.File

object HelperManager {
    private const val HELPER_VERSION = "1.7.0"
    private val assetDir = "tools/arm64-v8a"

    data class InstalledTools(val dir: File, val helper: File, val native: File)

    fun install(context: Context): InstalledTools {
        val dir = File(context.filesDir, assetDir)
        dir.mkdirs()
        val helper = File(dir, "usb0-helper")
        val native = File(dir, "usb0-native")
        val script = File(dir, "usb0-helper.sh")
        val marker = File(dir, "helper.version")
        val installed = marker.takeIf { it.exists() }?.readText()?.trim()
        val needsInstall = installed != HELPER_VERSION ||
            !helper.exists() || helper.length() < 100L ||
            !native.exists() || native.length() < 100L ||
            !script.exists() || script.length() < 100L
        if (needsInstall) {
            copyAsset(context, "tools/arm64-v8a/usb0-helper", helper)
            copyAsset(context, "tools/arm64-v8a/usb0-helper.sh", script)
            copyAsset(context, "tools/arm64-v8a/usb0-native", native)
            copyAsset(context, "r36s/lineageos_r36s_defconfig.txt", File(context.filesDir, "r36s/lineageos_r36s_defconfig.txt"))
            copyAsset(context, "r36s/kernel-capabilities.txt", File(context.filesDir, "r36s/kernel-capabilities.txt"))
            helper.setExecutable(true, false)
            script.setExecutable(true, false)
            native.setExecutable(true, false)
            marker.writeText(HELPER_VERSION)
        }
        return InstalledTools(dir, helper, native)
    }

    private fun copyAsset(context: Context, asset: String, target: File) {
        target.parentFile?.mkdirs()
        context.assets.open(asset).use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        }
    }
}
