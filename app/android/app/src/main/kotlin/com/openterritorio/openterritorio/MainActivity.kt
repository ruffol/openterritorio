package com.openterritorio.openterritorio

import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInstaller
import androidx.core.content.FileProvider
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
    private var otaChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        otaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getVersion" -> result.success(versionInfo())
                        "cacheDir" -> result.success(cacheDir.absolutePath)
                        "install" -> install(call.argument<String>("path"), result)
                        else -> result.notImplemented()
                    }
                }
            }
        // El resultado real de la sesión vuelve a Dart (motivo del fallo incluido).
        InstallBus.onResult = { sessionId, _status, message, success ->
            reportInstall(sessionId, success, message)
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

        // Comprobaciones previas: si la firma o la versión no cuadran, el
        // instalador del sistema fallaría con la ventana ya cerrada.
        checkCompatibility(file)?.let { motivo ->
            result.success("error:$motivo")
            return
        }

        // 1) Vía preferida: abrir el instalador del sistema con un content://
        //    (FileProvider). Es la ruta que respetan MIUI, HyperOS y One UI; las
        //    sesiones de PackageInstaller en segundo plano fallan ahí con
        //    "error del instalador" sin explicar nada.
        if (installWithIntent(file, result)) return

        // 2) Respaldo: sesión de PackageInstaller (sin ventana intermedia).
        try {
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL,
            )
            params.setAppPackageName(packageName)
            val installer = packageManager.packageInstaller
            val sessionId = installer.createSession(params)
            val session = installer.openSession(sessionId)
            session.openWrite("openterritorio.apk", 0, file.length()).use { out ->
                file.inputStream().use { input -> input.copyTo(out) }
                session.fsync(out)
            }
            val intent = Intent(this, InstallResultReceiver::class.java).apply {
                action = InstallResultReceiver.ACTION_INSTALL
                setPackage(packageName)
                putExtra(InstallBus.EXTRA_SESSION_ID, sessionId)
            }
            // Android 14 exige que el PendingIntent del instalador sea mutable.
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                PendingIntent.FLAG_MUTABLE
            val pending = PendingIntent.getBroadcast(this, sessionId, intent, flags)

            // Respaldo: si el broadcast nunca llega, la sesión sí notifica.
            installer.registerSessionCallback(
                object : PackageInstaller.SessionCallback() {
                    override fun onCreated(id: Int) {}
                    override fun onBadgingChanged(id: Int) {}
                    override fun onActiveChanged(id: Int, active: Boolean) {}
                    override fun onProgressChanged(id: Int, progress: Float) {}
                    override fun onFinished(id: Int, success: Boolean) {
                        if (id != sessionId) return
                        installer.unregisterSessionCallback(this)
                        reportInstall(sessionId, success, null)
                    }
                },
            )

            // Ojo: NO cerrar la sesión aquí. Cerrarla justo después de `commit`
            // hacía que Android abortara la instalación sin mostrar nada.
            session.commit(pending.intentSender)
            result.success("ok")
        } catch (error: Exception) {
            result.error("install", error.message ?: error.toString(), null)
        }
    }


    /** Abre el instalador del sistema con el APK; devuelve false si no hay quién lo atienda. */
    private fun installWithIntent(file: File, result: MethodChannel.Result): Boolean {
        return try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success("ok")
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    /** Motivo por el que la instalación no podría completarse, o null si todo cuadra. */
    private fun checkCompatibility(apk: File): String? {
        val flags = PackageManager.PackageInfoFlags.of(
            PackageManager.GET_SIGNING_CERTIFICATES.toLong(),
        )
        val installed = packageManager.getPackageInfo(packageName, flags)
        val candidate = packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: return "el APK descargado está dañado o incompleto"

        val installedCert = installed.signingInfo?.apkContentsSigners?.firstOrNull()
        val candidateCert = candidate.signingInfo?.apkContentsSigners?.firstOrNull()
        if (installedCert == null || candidateCert == null) return null
        if (!installedCert.toByteArray().contentEquals(candidateCert.toByteArray())) {
            return "la firma de la actualización no coincide con la app instalada; " +
                "desinstala OPENTERITORIO y vuelve a instalarlo"
        }
        if (candidate.longVersionCode <= installed.longVersionCode) {
            return "el APK descargado (${candidate.longVersionCode}) no es más nuevo " +
                "que el instalado (${installed.longVersionCode})"
        }
        return null
    }

    private val reportedSessions = mutableSetOf<Int>()

    /** Entrega a Flutter el resultado real de la sesión (una vez por sesión). */
    private fun reportInstall(sessionId: Int, success: Boolean, message: String?) {
        synchronized(reportedSessions) {
            if (!reportedSessions.add(sessionId)) return
        }
        val status = if (success) {
            PackageInstaller.STATUS_SUCCESS
        } else {
            PackageInstaller.STATUS_FAILURE
        }
        otaChannel?.invokeMethod(
            "installResult",
            mapOf(
                "session" to sessionId,
                "success" to success,
                "status" to status,
                "message" to (message ?: ""),
            ),
        )
    }

    companion object {
        private const val CHANNEL = "openterritorio/ota"
        private const val DEVICE_CHANNEL = "openterritorio/device"
    }
}
