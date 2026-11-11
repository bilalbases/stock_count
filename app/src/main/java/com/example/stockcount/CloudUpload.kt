package com.example.stockcount

import android.content.Context
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Sends this device's counted items to the Google Sheet collector (google-sheet/Code.gs).
 * Each upload replaces this device's previous rows in the Sheet, so it can be repeated safely.
 * Counting itself never needs internet; only this upload does.
 */
object CloudUpload {

    class Config(private val context: Context) {
        private val prefs = context.getSharedPreferences("cloud", Context.MODE_PRIVATE)
        var url: String
            get() = prefs.getString("url", null)?.takeIf { it.isNotBlank() } ?: BuildConfig.SHEET_URL
            set(v) = prefs.edit().putString("url", v.trim()).apply()
        var key: String
            get() = prefs.getString("key", null)?.takeIf { it.isNotBlank() } ?: BuildConfig.SHEET_KEY
            set(v) = prefs.edit().putString("key", v.trim()).apply()
        var device: String
            get() = prefs.getString("device", null) ?: defaultDevice(context)
            set(v) = prefs.edit().putString("device", v.trim()).apply()
        val isSet get() = url.startsWith("https://") && key.isNotBlank()
    }

    fun defaultDevice(context: Context): String {
        @Suppress("HardwareIds")
        val id = android.provider.Settings.Secure.getString(context.contentResolver, android.provider.Settings.Secure.ANDROID_ID)
            ?.takeLast(4)?.uppercase() ?: "0000"
        return "${Build.MODEL}-$id".replace(Regex("[^A-Za-z0-9_-]"), "")
    }

    /** Uploads all items. Returns the number of rows the Sheet received. Throws on failure. */
    fun upload(config: Config, planDate: String, branch: String, items: List<Item>): Int {
        val rows = JSONArray()
        for (i in items) {
            rows.put(JSONObject().apply {
                put("planDate", planDate)
                put("plant", branch)
                put("storageLoc", i.storageLoc)
                put("shelf", i.shelf)
                put("material", i.material.ifBlank { i.barcode })
                put("barcode", i.barcode)
                put("description", i.name)
                put("stockType", i.stockType)
                put("quantity", i.quantity)
                put("uom", i.uom)
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
            connectTimeout = 20000
            readTimeout = 60000
            setRequestProperty("Content-Type", "application/json; charset=utf-8")
        }
        post.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        var code = post.responseCode
        var text: String
        if (code in 300..399) {
            val location = post.getHeaderField("Location") ?: error("Upload failed (redirect without location)")
            post.disconnect()
            val get = (URL(location).openConnection() as HttpURLConnection).apply {
                connectTimeout = 20000; readTimeout = 60000
            }
            code = get.responseCode
            text = (if (code < 400) get.inputStream else get.errorStream)?.bufferedReader()?.readText().orEmpty()
            get.disconnect()
        } else {
            text = (if (code < 400) post.inputStream else post.errorStream)?.bufferedReader()?.readText().orEmpty()
            post.disconnect()
        }
        if (code >= 400) error("Upload failed (HTTP $code)")
        val json = runCatching { JSONObject(text) }.getOrNull()
            ?: error("Unexpected answer from the Sheet. Check the URL (it must end with /exec).")
        if (!json.optBoolean("ok")) error(json.optString("error", "Upload failed"))
        return json.optInt("rows", items.size)
    }
}
