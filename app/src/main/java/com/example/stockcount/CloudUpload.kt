package com.example.stockcount

import android.content.Context
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Sends this device's counted items to the Stock Count server on the local network
 * (local-server/StockCountServer.ps1) or, alternatively, the Google Sheet collector (google-sheet/Code.gs).
 * Each upload replaces this device's previous rows, so it can be repeated safely.
 */
object CloudUpload {

    class Config(private val context: Context) {
        private val prefs = context.getSharedPreferences("cloud", Context.MODE_PRIVATE).also { p ->
            // Moving from the Google Sheet to the local server: forget a Google URL typed in earlier.
            if (p.getString("url", "")!!.contains("script.google.com") && !p.getBoolean("movedToLocal", false)) {
                p.edit().remove("url").putBoolean("movedToLocal", true).apply()
            }
        }
        var url: String
            get() = prefs.getString("url", null)?.takeIf { it.isNotBlank() } ?: BuildConfig.UPLOAD_URL
            set(v) = prefs.edit().putString("url", v.trim()).apply()
        var key: String
            get() = prefs.getString("key", null)?.takeIf { it.isNotBlank() } ?: BuildConfig.SHEET_KEY
            set(v) = prefs.edit().putString("key", v.trim()).apply()
        var device: String
            get() = prefs.getString("device", null) ?: defaultDevice(context)
            set(v) = prefs.edit().putString("device", v.trim()).apply()
        val isSet get() = (url.startsWith("http://") || url.startsWith("https://")) && key.isNotBlank()
    }

    fun defaultDevice(context: Context): String {
        @Suppress("HardwareIds")
        val id = android.provider.Settings.Secure.getString(context.contentResolver, android.provider.Settings.Secure.ANDROID_ID)
            ?.takeLast(4)?.uppercase() ?: "0000"
        return "${Build.MODEL}-$id".replace(Regex("[^A-Za-z0-9_-]"), "")
    }

    /** How long to wait for the server's answer (a busy server answers late, not never). */
    private const val READ_TIMEOUT = 5 * 60 * 1000

    /** The server answered with an error (wrong key etc.): trying again will not help. */
    class ServerError(message: String) : Exception(message)

    /** Worth trying again at once? Not after a server error or a 5-minute wait for a busy server. */
    fun retryable(e: Throwable): Boolean = when (e) {
        is ServerError -> false
        is java.net.SocketTimeoutException -> e.message.orEmpty().contains("connect", true)
        else -> e is java.io.IOException
    }

    /** Plain-language reason for a failed upload. */
    fun describe(e: Throwable): String = when (e) {
        is ServerError -> "The server answered: ${e.message}"
        is java.net.SocketTimeoutException ->
            if (e.message.orEmpty().contains("connect", true))
                "No answer from the server PC. Check that the PDT is on the store Wi-Fi and that the server PC is on."
            else "The server is busy and did not answer in 5 minutes. Your count is safe on this PDT. Wait a few minutes, then upload again."
        is java.net.ConnectException, is java.net.NoRouteToHostException, is java.net.UnknownHostException ->
            "Server not reachable. Check that the PDT is on the store Wi-Fi and that the server PC is on."
        is java.io.IOException -> "Connection lost during the upload (${e.javaClass.simpleName}${e.message?.let { ": $it" } ?: ""}). Check Wi-Fi, then upload again."
        else -> e.message ?: e.javaClass.simpleName
    }

    /** Uploads all items. Returns the number of rows the Sheet received. Throws on failure. */
    fun upload(config: Config, planDate: String, branch: String, items: List<Item>): Int {
        val rows = JSONArray()
        val fmt = java.text.SimpleDateFormat("dd.MM.yyyy HH:mm:ss", java.util.Locale.US)
        // In scan order, so the server's log file lists the lines as they were scanned.
        for (i in items.sortedWith(compareBy({ it.scannedAt }, { it.id }))) {
            rows.put(JSONObject().apply {
                put("line", i.id)
                put("scannedAt", if (i.scannedAt > 0) fmt.format(java.util.Date(i.scannedAt)) else "")
                put("scannedMs", i.scannedAt)
                put("planDate", planDate)
                put("plant", branch)
                put("storageLoc", i.storageLoc)
                put("shelf", i.shelf)
                put("material", i.material.ifBlank { i.barcode })
                put("barcode", i.barcode)
                put("description", i.name)
                put("stockType", i.stockType)
                put("quantity", i.exportQty().toPlainString())   // in the base unit (3 OTR -> 30 EA)
                put("uom", i.exportUom())
                put("countedQty", fmtQty(i.quantity))
                put("countedUom", i.uom)
                put("zeroCount", i.zeroCount)
            })
        }
        val body = JSONObject().apply {
            put("key", config.key)
            put("device", config.device)
            put("rows", rows)
        }.toString()

        // Apps Script answers a POST with a redirect to the result, which must be fetched with GET.
        val post = (URL(config.url).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            instanceFollowRedirects = false
            connectTimeout = 15000
            readTimeout = READ_TIMEOUT
            setRequestProperty("Content-Type", "application/json; charset=utf-8")
        }
        post.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        var code = post.responseCode
        var text: String
        if (code in 300..399) {
            val location = post.getHeaderField("Location") ?: error("Upload failed (redirect without location)")
            post.disconnect()
            val get = (URL(location).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15000; readTimeout = READ_TIMEOUT
            }
            code = get.responseCode
            text = (if (code < 400) get.inputStream else get.errorStream)?.bufferedReader()?.readText().orEmpty()
            get.disconnect()
        } else {
            text = (if (code < 400) post.inputStream else post.errorStream)?.bufferedReader()?.readText().orEmpty()
            post.disconnect()
        }
        val json = runCatching { JSONObject(text) }.getOrNull()
        if (json != null && !json.optBoolean("ok")) throw ServerError(json.optString("error", "Upload failed"))
        if (code >= 400) throw java.io.IOException("server error HTTP $code")
        if (json == null) throw ServerError("unexpected answer. Check the URL in Upload settings.")
        return json.optInt("rows", items.size)
    }
}
