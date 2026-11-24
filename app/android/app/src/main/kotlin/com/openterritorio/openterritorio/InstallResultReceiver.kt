package com.openterritorio.openterritorio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.util.Log

/**
 * Puente entre el receptor de Android y Flutter: la app necesita saber **por qué**
 * falló una instalación, no solo que se cerró la ventana.
 */
object InstallBus {
    const val EXTRA_SESSION_ID = "session_id"

    @Volatile
    var onResult: ((sessionId: Int, status: Int, message: String?, success: Boolean) -> Unit)? = null

    fun deliver(sessionId: Int, status: Int, message: String?, success: Boolean) {
        onResult?.invoke(sessionId, status, message, success)
    }
}

/** Recibe el resultado de la sesión de PackageInstaller lanzada por MainActivity. */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_INSTALL) return
        val sessionId = intent.getIntExtra(InstallBus.EXTRA_SESSION_ID, -1)
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        val success = status == PackageInstaller.STATUS_SUCCESS
        Log.i(TAG, "instalación status=$status success=$success message=$message")
        InstallBus.deliver(sessionId, status, message, success)
    }

    companion object {
        const val ACTION_INSTALL = "com.openterritorio.openterritorio.INSTALL_RESULT"
        private const val TAG = "OpenterritorioOta"
    }
}
