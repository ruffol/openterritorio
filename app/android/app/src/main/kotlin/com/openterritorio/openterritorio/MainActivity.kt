package com.openterritorio.openterritorio

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.BatteryManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Canal OTA: versión instalada, directorio de caché e instalación de APK
 * mediante PackageInstaller (sin necesidad de FileProvider ni permisos root).
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getVersion" -> result.success(versionInfo())
                    "cacheDir" -> result.success(cacheDir.absolutePath)
                    "install" -> install(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "batteryPct" -> result.success(battery().first)
                    "isCharging" -> result.success(battery().second)
                    else -> result.notImplemented()
                }
            }
    }

    /** (nivel 0–100, 1 si está cargando) según BatteryManager. */
    private fun battery(): Pair<Int, Int> {
        val manager = getSystemService(BATTERY_SERVICE) as? BatteryManager
        val level = manager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
        val charging = if (manager?.isCharging == true) 1 else 0
        return Pair(if (level in 0..100) level else -1, charging)
    }

    private fun versionInfo(): Map<String, Any?> {
        // minSdk 34: PackageInfoFlags y longVersionCode siempre disponibles.
        val info = packageManager.getPackageInfo(
            packageName,
            PackageManager.PackageInfoFlags.of(0),
        )
        return mapOf(
            "version_name" to info.versionName,
            "version_code" to info.longVersionCode,
        )
    }

    private fun install(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("args", "falta la ruta del APK", null)
            return
        }
        val file = File(path)
        if (!file.isFile) {
            result.error("args", "no existe el APK: $path", null)
            return
        }
        if (!packageManager.canRequestPackageInstalls()) {
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    ),
                )
            } catch (_: Exception) {
                // Sin pantalla de ajustes: el mensaje de Dart guía al usuario.
            }
            result.success("permission")
            return
        }
        try {
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL,
            )
            params.setAppPackageName(packageName)
            val installer = packageManager.packageInstaller
            val sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                session.openWrite("openterritorio.apk", 0, file.length()).use { out ->
                    file.inputStream().use { input -> input.copyTo(out) }
                    session.fsync(out)
                }
                val intent = Intent(this, InstallResultReceiver::class.java).apply {
                    action = InstallResultReceiver.ACTION_INSTALL
                    setPackage(packageName)
                }
                // Android 14 exige que el PendingIntent del instalador sea mutable.
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    PendingIntent.FLAG_MUTABLE
                val pending = PendingIntent.getBroadcast(this, sessionId, intent, flags)
                session.commit(pending.intentSender)
            }
            result.success("ok")
        } catch (error: Exception) {
            result.error("install", error.message ?: error.toString(), null)
        }
    }

    companion object {
        private const val CHANNEL = "openterritorio/ota"
        private const val DEVICE_CHANNEL = "openterritorio/device"
    }
}
