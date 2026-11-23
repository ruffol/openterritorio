package com.openterritorio.openterritorio

import android.app.Application
import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log

/**
 * Captura crashes de Java/Kotlin (incluidos UnsatisfiedLinkError por ABI) y
 * deja un informe en Descargas/openterritorio-crash.txt para diagnóstico,
 * con la versión de Android y las ABIs reales del teléfono.
 */
class CrashApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                writeReport(error)
            } catch (_: Throwable) {
                // Si ni esto se puede, el handler original sigue informando.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    private fun writeReport(error: Throwable) {
        val report = buildString {
            appendLine("OPENTERITORIO crash")
            appendLine("Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})")
            appendLine("ABIs: ${Build.SUPPORTED_ABIS.joinToString()}")
            appendLine("Dispositivo: ${Build.MANUFACTURER} ${Build.MODEL}")
            appendLine()
            append(Log.getStackTraceString(error))
        }
        // minSdk 34: MediaStore.Downloads está disponible sin permisos extra.
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, "openterritorio-crash.txt")
            put(MediaStore.Downloads.MIME_TYPE, "text/plain")
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
        }
        val uri = contentResolver.insert(
            MediaStore.Downloads.EXTERNAL_CONTENT_URI,
            values,
        ) ?: return
        contentResolver.openOutputStream(uri)?.use { output ->
            output.write(report.toByteArray())
        }
    }
}
