package com.example.stockcount

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import androidx.core.content.ContextCompat

/**
 * Support for the built-in laser/imager scanner on Zebra devices (via Zebra DataWedge).
 *
 * On start we ask DataWedge to create a "StockCount" profile for this app that sends every scan
 * to us as a broadcast intent (and turns off keystroke output so barcodes are not typed into
 * text fields). On non-Zebra phones nobody listens to these intents, so nothing happens.
 */
object ZebraScanner {
    const val SCAN_ACTION = "com.example.stockcount.SCAN"
    private const val DW_ACTION = "com.symbol.datawedge.api.ACTION"
    private const val PROFILE = "StockCount"

    fun configure(context: Context) {
        // 1. Create the profile (ignored if it already exists).
        context.sendBroadcast(Intent(DW_ACTION).putExtra("com.symbol.datawedge.api.CREATE_PROFILE", PROFILE))

        // 2. Link it to this app and enable the barcode scanner.
        setConfig(context, "CREATE_IF_NOT_EXIST", "BARCODE", Bundle().apply {
            putString("scanner_selection", "auto")
            putString("scanner_input_enabled", "true")
        }, withAppList = true)

        // 3. Send scans to the app as a broadcast intent.
        setConfig(context, "UPDATE", "INTENT", Bundle().apply {
            putString("intent_output_enabled", "true")
            putString("intent_action", SCAN_ACTION)
            putString("intent_delivery", "2") // 2 = broadcast
        })

        // 4. Don't also type the barcode as keystrokes.
        setConfig(context, "UPDATE", "KEYSTROKE", Bundle().apply {
            putString("keystroke_output_enabled", "false")
        })
    }

    private fun setConfig(context: Context, mode: String, plugin: String, params: Bundle, withAppList: Boolean = false) {
        val config = Bundle().apply {
            putString("PROFILE_NAME", PROFILE)
            putString("PROFILE_ENABLED", "true")
            putString("CONFIG_MODE", mode)
            putBundle("PLUGIN_CONFIG", Bundle().apply {
                putString("PLUGIN_NAME", plugin)
                putString("RESET_CONFIG", "true")
                putBundle("PARAM_LIST", params)
            })
            if (withAppList) {
                putParcelableArray("APP_LIST", arrayOf(Bundle().apply {
                    putString("PACKAGE_NAME", context.packageName)
                    putStringArray("ACTIVITY_LIST", arrayOf("*"))
                }))
            }
        }
        context.sendBroadcast(Intent(DW_ACTION).putExtra("com.symbol.datawedge.api.SET_CONFIG", config))
    }

    /** Starts listening for scans. Call [unregister] with the returned receiver when done. */
    fun register(context: Context, onScan: (String) -> Unit): BroadcastReceiver {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                val code = intent.getStringExtra("com.symbol.datawedge.data_string")?.trim()
                if (!code.isNullOrEmpty()) onScan(code)
            }
        }
        // DataWedge is a separate app, so the receiver must be exported.
        ContextCompat.registerReceiver(context, receiver, IntentFilter(SCAN_ACTION), ContextCompat.RECEIVER_EXPORTED)
        return receiver
    }

    fun unregister(context: Context, receiver: BroadcastReceiver) {
        runCatching { context.unregisterReceiver(receiver) }
    }
}
