package com.example.stockcount

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * Exports the count as an .xlsx in the PI template layout:
 * DATE, PLAN_DATE, GJAHR, PLANT, STGE_LOC, ITEM, MATERIAL, STOCK_TYPE, ENTRY_QNT, ENTRY_UOM, ZERO_COUNT
 *
 * DATE = today, PLAN_DATE = the "Plan date" field (today if empty), GJAHR = current year,
 * PLANT = branch ID, STGE_LOC = storage location, ITEM = running number, MATERIAL = material number
 * from the material list (falls back to the barcode, then the name), ZERO_COUNT = "X" when the checkbox is ticked.
 * Written by hand (no library) so it stays small and works offline.
 */
object XlsxExport {

    private val HEADERS = listOf(
        "DATE", "PLAN_DATE", "GJAHR", "PLANT", "STGE_LOC", "ITEM",
        "MATERIAL", "STOCK_TYPE", "ENTRY_QNT", "ENTRY_UOM", "ZERO_COUNT"
    )

    private fun dateFormat() = SimpleDateFormat("dd.MM.yyyy", Locale.US).apply { isLenient = false }

    fun isValidDate(s: String): Boolean =
        Regex("""\d{2}\.\d{2}\.\d{4}""").matches(s) && runCatching { dateFormat().parse(s) }.isSuccess

    /**
     * Writes the export, keeps a copy in Downloads/StockCount, then opens the share menu.
     * Returns where the copy was saved (or null if saving to Downloads failed).
     */
    class Result(val file: File, val savedTo: String?, val unchanged: Boolean = false)

    /**
     * Creates the export and saves it to Downloads/StockCount (one file per export; exporting
     * again in the same minute replaces that file instead of making a duplicate).
     * Sharing is a separate, optional step: [shareFile].
     */
    fun export(context: Context, branch: String, planDate: String, items: List<Item>): Result {
        val now = Date()
        val stamp = SimpleDateFormat("yyyy-MM-dd_HHmm", Locale.US).format(now)
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        val name = listOfNotNull("PI", branch.ifBlank { null }, stamp).joinToString("_")
            .replace(Regex("[^A-Za-z0-9._-]"), "-")
        val rows = rows(branch, planDate, items, now)

        // Nothing changed since the last export (same count, same day)? Don't create another file.
        val prefs = context.getSharedPreferences("export", Context.MODE_PRIVATE)
        val fingerprint = rows.hashCode().toString()
        val lastFile = prefs.getString("lastFile", null)?.let { File(dir, it) }
        if (fingerprint == prefs.getString("lastFingerprint", null) && lastFile != null && lastFile.exists()) {
            return Result(lastFile, prefs.getString("lastSaved", null), unchanged = true)
        }

        val file = File(dir, "$name.xlsx")
        write(file, rows)
        val saved = runCatching { saveToDownloads(context, file) }.getOrNull()
        if (saved != null) {
            prefs.edit().putString("lastFingerprint", fingerprint).putString("lastFile", file.name)
                .putString("lastSaved", saved).apply()
        }
        return Result(file, saved)
    }

    class MergeResult(val file: File, val savedTo: String?, val files: Int, val inputRows: Int, val outputRows: Int)

    /**
     * Merges several PI export files (e.g. from 30 PDTs) into one: rows with the same plant,
     * storage location, material, stock type and unit are added together; ITEM is renumbered.
     */
    fun merge(context: Context, uris: List<android.net.Uri>): MergeResult {
        class Group(val plant: String, val sloc: String, val material: String, val stockType: String, val uom: String) {
            var qty = 0L; var zero = false
        }
        val groups = LinkedHashMap<String, Group>()
        var planDate = ""
        var inputRows = 0
        for (uri in uris) {
            val rows = MaterialImport.readRows(context, uri).filter { r -> r.any { it.isNotBlank() } }
            if (rows.isEmpty()) continue
            val header = rows.first().map { it.trim().uppercase() }
            fun idx(name: String) = header.indexOf(name)
            val iPlan = idx("PLAN_DATE"); val iPlant = idx("PLANT"); val iSloc = idx("STGE_LOC")
            val iMat = idx("MATERIAL"); val iType = idx("STOCK_TYPE"); val iQty = idx("ENTRY_QNT")
            val iUom = idx("ENTRY_UOM"); val iZero = idx("ZERO_COUNT")
            require(iMat >= 0 && iQty >= 0) { "Not a stock count export: ${uri.lastPathSegment}" }
            for (r in rows.drop(1)) {
                fun c(i: Int) = if (i >= 0) r.getOrNull(i)?.trim().orEmpty() else ""
                if (c(iMat).isEmpty()) continue
                inputRows++
                if (planDate.isEmpty()) planDate = c(iPlan)
                val key = listOf(c(iPlant), c(iSloc), c(iMat), c(iType), c(iUom)).joinToString("|")
                val g = groups.getOrPut(key) { Group(c(iPlant), c(iSloc), c(iMat), c(iType), c(iUom)) }
                g.qty += c(iQty).toBigDecimalOrNull()?.toLong() ?: 0L
                g.zero = g.zero || c(iZero).equals("X", ignoreCase = true)
            }
        }
        val now = Date()
        val today = dateFormat().format(now)
        val year = SimpleDateFormat("yyyy", Locale.US).format(now)
        val out = groups.values
            .sortedWith(compareBy({ it.plant }, { it.sloc }, { it.material }))
            .mapIndexed { i, g ->
                listOf(
                    today, planDate.ifBlank { today }, year, g.plant, g.sloc, (i + 1).toString(),
                    g.material, g.stockType, g.qty.toString(), g.uom, if (g.zero && g.qty == 0L) "X" else ""
                )
            }
        val plant = groups.values.firstOrNull()?.plant.orEmpty()
        val stamp = SimpleDateFormat("yyyy-MM-dd_HHmm", Locale.US).format(now)
        val name = listOfNotNull("PI_MERGED", plant.ifBlank { null }, stamp).joinToString("_")
            .replace(Regex("[^A-Za-z0-9._-]"), "-")
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        val file = File(dir, "$name.xlsx")
        write(file, out)
        val saved = runCatching { saveToDownloads(context, file) }.getOrNull()
        return MergeResult(file, saved, uris.size, inputRows, out.size)
    }

    /** Opens the share menu (email, WhatsApp, Drive...) for an exported file. */
    fun shareFile(context: Context, file: File) {
        val stamp = file.nameWithoutExtension
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, "Stock count $stamp")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(send, "Share stock count"))
    }

    private const val FOLDER = "StockCount"
    private const val XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    /** Copies [file] to the public Downloads/StockCount folder. Returns the path shown to the user. */
    private fun saveToDownloads(context: Context, file: File): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                put(MediaStore.MediaColumns.MIME_TYPE, XLSX)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER")
            }
            val resolver = context.contentResolver
            val relPath = "${Environment.DIRECTORY_DOWNLOADS}/$FOLDER/"
            // Reuse a file with the same name (same branch and minute) instead of creating "name (1).xlsx".
            val existing = resolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?",
                arrayOf(file.name, relPath), null
            )?.use { c -> if (c.moveToFirst()) ContentUris.withAppendedId(MediaStore.Downloads.EXTERNAL_CONTENT_URI, c.getLong(0)) else null }
            val uri = existing ?: resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: error("Could not create file in Downloads")
            resolver.openOutputStream(uri, "wt")?.use { out -> file.inputStream().use { it.copyTo(out) } }
                ?: error("Could not write file in Downloads")
        } else {
            // Android 9 and older: needs the storage permission (asked for before exporting).
            @Suppress("DEPRECATION")
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), FOLDER)
            dir.mkdirs()
            file.copyTo(File(dir, file.name), overwrite = true)
        }
        return "Downloads/$FOLDER/${file.name}"
    }

    /** One row per item. Values that are whole numbers are written as numbers, like the template. */
    fun rows(branch: String, planDate: String, items: List<Item>, now: Date = Date()): List<List<String>> {
        val today = dateFormat().format(now)
        val plan = if (isValidDate(planDate)) planDate else today
        val year = Calendar.getInstance().apply { time = now }.get(Calendar.YEAR).toString()
        return items.mapIndexed { i, item ->
            listOf(
                today, plan, year, branch, item.storageLoc, (i + 1).toString(),
                item.material.ifBlank { item.barcode }.ifBlank { item.name }, item.stockType, item.quantity.toString(), item.uom,
                if (item.zeroCount) "X" else ""
            )
        }
    }

    fun write(file: File, rows: List<List<String>>) {
        // Lock the file: sheet and workbook are protected with a random password that is not
        // stored anywhere, so the count cannot be changed in Excel (it can still be opened,
        // read, printed and uploaded to SAP).
        val lock = legacyHash(randomPassword())
        ZipOutputStream(file.outputStream()).use { zip ->
            fun put(name: String, text: String) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(text.toByteArray(Charsets.UTF_8))
                zip.closeEntry()
            }
            put("[Content_Types].xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>""")
            put("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>""")
            put("xl/workbook.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<workbookProtection lockStructure="1" lockWindows="1" workbookPassword="$lock"/>
<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
</workbook>""")
            put("xl/_rels/workbook.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>""")
            // Styles: Excel only enforces sheet protection on cells whose style is "locked",
            // so every cell style here is explicitly locked. Style 1 = bold header.
            put("xl/styles.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>
<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="2">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyProtection="1"><protection locked="1" hidden="0"/></xf>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1" applyProtection="1"><protection locked="1" hidden="0"/></xf>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>""")
            put("xl/worksheets/sheet1.xml", sheet(rows, lock))
        }
    }

    private fun sheet(rows: List<List<String>>, lock: String): String {
        val sb = StringBuilder("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<cols><col min="1" max="2" width="12" customWidth="1"/><col min="3" max="6" width="10" customWidth="1"/><col min="7" max="7" width="16" customWidth="1"/><col min="8" max="8" width="12" customWidth="1"/><col min="9" max="10" width="12" customWidth="1"/><col min="11" max="11" width="13" customWidth="1"/></cols>
<sheetData>""")
        (listOf(HEADERS) + rows).forEachIndexed { r, row ->
            sb.append("<row r=\"${r + 1}\">")
            row.forEachIndexed { c, v ->
                if (v.isEmpty()) return@forEachIndexed
                val ref = "${'A' + c}${r + 1}"
                // MATERIAL (column G) always stays text so long codes keep every digit.
                val numeric = r > 0 && c != 6 && Regex("""-?\d{1,9}""").matches(v)
                val style = if (r == 0) 1 else 0   // 1 = bold header; both styles are locked
                if (numeric) sb.append("<c r=\"$ref\" s=\"$style\"><v>$v</v></c>")
                else sb.append("<c r=\"$ref\" s=\"$style\" t=\"inlineStr\"><is><t>").append(esc(v)).append("</t></is></c>")
            }
            sb.append("</row>")
        }
        sb.append("</sheetData>")
        // sheet="1" locks every cell; also block formatting, inserting and deleting rows/columns.
        sb.append(
            "<sheetProtection password=\"$lock\" sheet=\"1\" objects=\"1\" scenarios=\"1\" " +
                "formatCells=\"1\" formatColumns=\"1\" formatRows=\"1\" insertColumns=\"1\" insertRows=\"1\" " +
                "insertHyperlinks=\"1\" deleteColumns=\"1\" deleteRows=\"1\" sort=\"1\" autoFilter=\"1\" pivotTables=\"1\"/>"
        )
        return sb.append("</worksheet>").toString()
    }

    private fun randomPassword(): String {
        val chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
        val rnd = java.security.SecureRandom()
        return (1..15).map { chars[rnd.nextInt(chars.length)] }.joinToString("")
    }

    /** Excel's sheet/workbook protection password hash (legacy 16-bit algorithm). */
    private fun legacyHash(password: String): String {
        var hash = 0
        for (c in password.reversed()) {
            hash = ((hash shr 14) and 1) or ((hash shl 1) and 0x7fff)
            hash = hash xor c.code
        }
        hash = ((hash shr 14) and 1) or ((hash shl 1) and 0x7fff)
        hash = hash xor password.length xor 0xCE4B
        return "%04X".format(hash)
    }

    private fun esc(s: String) = s
        .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
        .filter { it == '\t' || it == '\n' || it == '\r' || it >= ' ' }
}
