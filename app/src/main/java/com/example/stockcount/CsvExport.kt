package com.example.stockcount

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Writes the count to a CSV file and opens the share sheet (email, Drive, WhatsApp, Excel...). */
object CsvExport {

    fun share(context: Context, branch: String, items: List<Item>) {
        val now = Date()
        val stamp = SimpleDateFormat("yyyy-MM-dd_HHmm", Locale.US).format(now)
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        val name = listOf("stock-count", branch.ifBlank { null }, stamp).filterNotNull().joinToString("_")
            .replace(Regex("[^A-Za-z0-9._-]"), "-")
        val file = File(dir, "$name.csv")
        file.writeText(toCsv(branch, items, now), Charsets.UTF_8)

        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/csv"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, "Stock count ${branch.ifBlank { "" }} $stamp".trim())
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(send, "Export stock count"))
    }

    fun toCsv(branch: String, items: List<Item>, at: Date = Date()): String {
        val time = SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.US).format(at)
        val sb = StringBuilder("\uFEFF") // BOM so Excel reads accents/Arabic text correctly
        sb.append("Branch ID,Shelf ID,Item,Barcode,Quantity,Zero count,Counted at\r\n")
        for (i in items) {
            sb.append(listOf(branch, i.shelf, i.name, i.barcode, i.quantity.toString(), if (i.zeroCount) "Yes" else "No", time)
                .joinToString(",") { field(it) }).append("\r\n")
        }
        return sb.toString()
    }

    private fun field(v: String): String =
        if (v.any { it == ',' || it == '"' || it == '\n' || it == '\r' }) "\"" + v.replace("\"", "\"\"") + "\"" else v
}
