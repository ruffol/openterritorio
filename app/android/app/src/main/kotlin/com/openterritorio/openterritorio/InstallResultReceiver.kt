package com.openterritorio.openterritorio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.util.Log

/** Recibe el resultado de la sesión de PackageInstaller lanzada por MainActivity. */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_INSTALL) return
        val status = intent.getIntExtra(
            PackageInstaller.EXTRA_STATUS,
            PackageInstaller.STATUS_FAILURE,
        )
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
        if (status == PackageInstaller.STATUS_SUCCESS) {
            Log.i(TAG, "APK instalado correctamente")
        } else {
            Log.w(TAG, "instalación fallida status=$status message=$message")
        }
    }

    companion object {
        const val ACTION_INSTALL = "com.openterritorio.openterritorio.INSTALL_RESULT"
        private const val TAG = "OpenterritorioOta"
    }
}
