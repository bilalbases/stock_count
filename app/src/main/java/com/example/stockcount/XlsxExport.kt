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

    /** Log file: every scan as its own line, in the order scanned. */
    private val LOG_HEADERS = listOf(
        "NO", "SCANNED_AT", "PLANT", "STGE_LOC", "SHELF", "BARCODE", "MATERIAL", "DESCRIPTION",
        "STOCK_TYPE", "COUNTED_QTY", "COUNTED_UOM", "ENTRY_QNT", "ENTRY_UOM", "ZERO_COUNT"
    )
    private val LOG_TEXT = setOf(4, 5, 6)
    private val LOG_WIDTHS = listOf(6, 20, 8, 10, 10, 16, 14, 36, 11, 13, 13, 11, 11, 12)

    private fun dateFormat() = SimpleDateFormat("dd.MM.yyyy", Locale.US).apply { isLenient = false }

    fun isValidDate(s: String): Boolean =
        Regex("""\d{2}\.\d{2}\.\d{4}""").matches(s) && runCatching { dateFormat().parse(s) }.isSuccess

    /**
     * Writes the export, keeps a copy in Downloads/StockCount, then opens the share menu.
     * Returns where the copy was saved (or null if saving to Downloads failed).
     */
    class Result(val piFiles: List<File>, val savedTo: String?, val unchanged: Boolean = false, val logFile: File? = null) {
        val file get() = piFiles.first()
        val files get() = piFiles + listOfNotNull(logFile)
    }

    /**
     * Creates the export and saves it to Downloads/StockCount: ONE PI FILE PER STORAGE LOCATION
     * (e.g. PI_1090_1001_<time>.xlsx and PI_1090_1005_<time>.xlsx) plus one log file with every scan.
     * Exporting again in the same minute replaces those files instead of making duplicates.
     * Sharing is a separate, optional step: [shareFiles].
     */
    fun export(context: Context, branch: String, planDate: String, items: List<Item>): Result {
        val now = Date()
        val stamp = SimpleDateFormat("yyyy-MM-dd_HHmm", Locale.US).format(now)
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        fun fileName(vararg parts: String?) = parts.filterNot { it.isNullOrBlank() }.joinToString("_")
            .replace(Regex("[^A-Za-z0-9._-]"), "-") + ".xlsx"
        val bySloc = items.groupBy { it.storageLoc.trim() }.toSortedMap()
        val piRows = bySloc.mapValues { (_, list) -> rows(branch, planDate, list, now) }
        val log = logRows(branch, items)

        // Nothing changed since the last export (same count, same day)? Don't create more files.
        val prefs = context.getSharedPreferences("export", Context.MODE_PRIVATE)
        val fingerprint = (piRows.toString() + log.hashCode()).hashCode().toString()
        val lastFiles = prefs.getString("lastFiles", null)?.split('|')?.filter { it.isNotEmpty() }?.map { File(dir, it) }.orEmpty()
        val lastLog = prefs.getString("lastLog", null)?.let { File(dir, it) }?.takeIf { it.exists() }
        if (fingerprint == prefs.getString("lastFingerprint", null) && lastFiles.isNotEmpty() && lastFiles.all { it.exists() }) {
            return Result(lastFiles, prefs.getString("lastSaved", null), unchanged = true, logFile = lastLog)
        }

        val piFiles = piRows.map { (sloc, rows) ->
            File(dir, fileName("PI", branch, sloc.ifBlank { "no-sloc" }, stamp)).also { write(it, rows) }
        }
        val logFile = File(dir, fileName("LOG", branch, stamp))
        write(logFile, log, LOG_HEADERS, LOG_TEXT, LOG_WIDTHS)
        val saved = piFiles.mapNotNull { f -> runCatching { saveToDownloads(context, f) }.getOrNull() }
        val logSaved = runCatching { saveToDownloads(context, logFile) }.getOrNull()
        val savedTo = if (saved.isEmpty()) null else
            "Downloads/StockCount: ${piFiles.size} PI file" + (if (piFiles.size > 1) "s" else "") +
                " (" + piRows.keys.joinToString(", ") { it.ifBlank { "no SLoc" } } + ")" + (if (logSaved != null) " + log" else "")
        if (savedTo != null) {
            prefs.edit().putString("lastFingerprint", fingerprint).putString("lastFiles", piFiles.joinToString("|") { it.name })
                .putString("lastLog", logFile.name).putString("lastSaved", savedTo).apply()
        }
        return Result(piFiles, savedTo, logFile = logFile)
    }

    class MergeResult(
        val piFiles: List<File>, val savedTo: String?, val files: Int, val inputRows: Int, val outputRows: Int,
        val duplicates: Int, val notConverted: List<String>, val mixed: Boolean,
    )

    /**
     * Merges export files from several PDTs into PI files ready for SAP, exactly like a normal export:
     * one PI file per storage location, quantities in the BASE unit (3 OTR -> 30 EA, using the loaded
     * material list) and merged into the base-unit line.
     *
     * Accepts PI files (PI_...), log files (LOG_...) and upload copies (UPLOAD_..._SENT/FAILED).
     * Log and upload copies list every scan; a scan that appears in several of the chosen files
     * (e.g. two upload copies of the same PDT) is counted once. [unitOf] returns the material list
     * entry for a material + unit (base unit and factor), or null if the list has none.
     */
    suspend fun merge(
        context: Context, uris: List<android.net.Uri>, planDate: String,
        unitOf: suspend (material: String, uom: String) -> Material?,
    ): MergeResult {
        val cache = HashMap<String, Material?>()
        suspend fun unit(material: String, uom: String) =
            cache.getOrPut(material + "|" + uom.uppercase()) { if (material.isBlank() || uom.isBlank()) null else unitOf(material, uom) }
        val notConverted = linkedSetOf<String>()
        val items = ArrayList<Item>()
        // Scan lines from log/upload files: key -> (most times seen in any ONE file, the line)
        val scans = LinkedHashMap<String, Pair<Int, Item>>()
        var plan = if (isValidDate(planDate)) planDate else ""
        var inputRows = 0
        var anyPi = false; var anyLog = false
        for (uri in uris) {
            val rows = MaterialImport.readRows(context, uri).filter { r -> r.any { it.isNotBlank() } }
            if (rows.isEmpty()) continue
            val header = rows.first().map { it.trim().uppercase() }
            fun idx(name: String) = header.indexOf(name)
            val iPlan = idx("PLAN_DATE"); val iPlant = idx("PLANT"); val iSloc = idx("STGE_LOC")
            val iMat = idx("MATERIAL"); val iType = idx("STOCK_TYPE"); val iQty = idx("ENTRY_QNT")
            val iUom = idx("ENTRY_UOM"); val iZero = idx("ZERO_COUNT")
            val iAt = idx("SCANNED_AT"); val iShelf = idx("SHELF"); val iBc = idx("BARCODE")
            val iCq = idx("COUNTED_QTY"); val iCu = idx("COUNTED_UOM")
            require(iMat >= 0 && iQty >= 0) { "Not a stock count export: ${uri.lastPathSegment}" }
            val isLog = iAt >= 0
            if (isLog) anyLog = true else anyPi = true
            val inThisFile = HashMap<String, Int>()
            for (r in rows.drop(1)) {
                fun c(i: Int) = if (i >= 0) r.getOrNull(i)?.trim().orEmpty() else ""
                fun num(v: String) = v.replace(',', '.').toBigDecimalOrNull()
                val mat = c(iMat)
                if (mat.isEmpty()) continue
                inputRows++
                if (plan.isEmpty() && isValidDate(c(iPlan))) plan = c(iPlan)
                // Prefer the counted quantity and unit (log/upload files) and convert it with the
                // material list; otherwise the file's ENTRY_QNT/ENTRY_UOM, converted if possible.
                var qty = num(c(iQty)) ?: java.math.BigDecimal.ZERO
                var uom = c(iUom)
                val cq = num(c(iCq)); val cu = c(iCu)
                if (cq != null && cu.isNotEmpty() && unit(mat, cu) != null) { qty = cq; uom = cu }
                val m = unit(mat, uom)
                if (m != null && !m.baseUom.equals(uom, true)) {
                    qty = qty.multiply(java.math.BigDecimal.valueOf(m.factor)); uom = m.baseUom
                } else if (m == null) {
                    notConverted += "$mat $uom"
                }
                val item = Item(
                    name = "", barcode = c(iBc), material = mat, shelf = c(iShelf),
                    quantity = qty.toDouble(), uom = uom.uppercase(), stockType = c(iType), storageLoc = c(iSloc),
                    zeroCount = c(iZero).equals("X", true), baseUom = "", factor = 1.0,
                ).let { it to c(iPlant) }
                val at = c(iAt)
                if (isLog && at.isNotEmpty()) {
                    val key = listOf(at, c(iPlant), c(iSloc), c(iShelf), c(iBc), mat, c(iType), c(iCq), c(iCu), c(iQty), c(iUom)).joinToString("|")
                    val n = (inThisFile[key] ?: 0) + 1
                    inThisFile[key] = n
                    val seen = scans[key]
                    if (seen == null || n > seen.first) scans[key] = n to item.first.copy(name = item.second)
                } else {
                    items += item.first.copy(name = item.second)   // name carries the plant here
                }
            }
        }
        for ((n, item) in scans.values) repeat(n) { items += item }
        val duplicates = (inputRows - items.size).coerceAtLeast(0)

        // Only materials whose unit is not the base unit matter: an unknown unit that is the only unit
        // counted for that material is written as it is (like the normal export).
        val units = items.groupBy { it.material }.mapValues { (_, l) -> l.map { it.uom.uppercase() }.toSet() }
        val warn = notConverted.filter { e -> val mat = e.substringBefore(' '); (units[mat]?.size ?: 0) > 1 }

        val now = Date()
        val stamp = SimpleDateFormat("yyyy-MM-dd_HHmm", Locale.US).format(now)
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        val out = ArrayList<File>()
        var outRows = 0
        for ((plant, byPlant) in items.groupBy { it.name }.toSortedMap()) {
            for ((sloc, list) in byPlant.groupBy { it.storageLoc.trim() }.toSortedMap()) {
                val rows = rows(plant, plan, list.map { it.copy(name = "") }, now)
                outRows += rows.size
                val name = listOf("PI_MERGED", plant.ifBlank { null }, sloc.ifBlank { "no-sloc" }, stamp).filterNotNull()
                    .joinToString("_").replace(Regex("[^A-Za-z0-9._-]"), "-")
                out += File(dir, "$name.xlsx").also { write(it, rows) }
            }
        }
        require(out.isNotEmpty()) { "No count lines found in the chosen files" }
        val saved = out.mapNotNull { runCatching { saveToDownloads(context, it) }.getOrNull() }
        val savedTo = if (saved.isEmpty()) null else
            "Downloads/StockCount: ${out.size} PI file" + (if (out.size > 1) "s" else "") + " (" + out.joinToString(", ") { it.name } + ")"
        return MergeResult(out, savedTo, uris.size, inputRows, outRows, duplicates, warn, anyPi && anyLog)
    }

    /** Opens the share menu for several files at once (the PI file and its log file). */
    fun shareFiles(context: Context, files: List<File>) {
        if (files.size <= 1) { files.firstOrNull()?.let { shareFile(context, it) }; return }
        val uris = ArrayList(files.map { FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", it) })
        val send = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = XLSX
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            putExtra(Intent.EXTRA_SUBJECT, "Stock count ${files.first().nameWithoutExtension}")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(send, "Share stock count"))
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

    /**
     * Keeps a copy of exactly what was sent in an upload to the server (every scan line, in the
     * log layout, locked like the export files) in Downloads/StockCount/Uploads on this PDT, e.g.
     * UPLOAD_1090_TC21-AB12_2026-11-23_153012_SENT.xlsx (or ..._FAILED.xlsx when the upload failed).
     * It proves what the PDT sent and when, and can be given to the administrator if the server lacks it.
     * Returns the path shown to the user, or null if no copy could be saved.
     */
    fun saveUploadCopy(context: Context, branch: String, device: String, items: List<Item>, sent: Boolean): String? {
        val stamp = SimpleDateFormat("yyyy-MM-dd_HHmmss", Locale.US).format(Date())
        val name = listOf("UPLOAD", branch, device, stamp, if (sent) "SENT" else "FAILED")
            .filter { it.isNotBlank() }.joinToString("_").replace(Regex("[^A-Za-z0-9._-]"), "-") + ".xlsx"
        val dir = File(context.cacheDir, "uploads").apply { mkdirs() }
        val file = File(dir, name)
        return runCatching {
            write(file, logRows(branch, items), LOG_HEADERS, LOG_TEXT, LOG_WIDTHS)
            runCatching { saveToDownloads(context, file, "$FOLDER/Uploads") }.getOrElse {
                // No access to Downloads (e.g. storage permission refused on an old PDT):
                // keep it in the app's own folder on the PDT storage instead.
                val own = File(context.getExternalFilesDir(null) ?: context.filesDir, "Uploads").apply { mkdirs() }
                file.copyTo(File(own, name), overwrite = true)
                "Android/data/${context.packageName}/files/Uploads/$name"
            }
        }.also { file.delete() }.getOrNull()
    }

    /** Copies [file] to the public Downloads/StockCount folder (or [folder]). Returns the path shown to the user. */
    private fun saveToDownloads(context: Context, file: File, folder: String = FOLDER): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                put(MediaStore.MediaColumns.MIME_TYPE, XLSX)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$folder")
            }
            val resolver = context.contentResolver
            val relPath = "${Environment.DIRECTORY_DOWNLOADS}/$folder/"
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
            val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), folder)
            dir.mkdirs()
            file.copyTo(File(dir, file.name), overwrite = true)
        }
        return "Downloads/$folder/${file.name}"
    }

    /**
     * PI rows in the SAP base unit: 3 OTR (1 OTR = 10 EA) is written as 30 EA. The same material
     * counted on several shelves or in several units becomes one row with the quantities added.
     */
    fun rows(branch: String, planDate: String, items: List<Item>, now: Date = Date()): List<List<String>> {
        val today = dateFormat().format(now)
        val plan = if (isValidDate(planDate)) planDate else today
        val year = Calendar.getInstance().apply { time = now }.get(Calendar.YEAR).toString()
        class Row(val sloc: String, val material: String, val stockType: String, val uom: String) {
            var qty = java.math.BigDecimal.ZERO; var zero = false
        }
        val groups = LinkedHashMap<String, Row>()
        for (item in items) {
            val mat = item.material.ifBlank { item.barcode }.ifBlank { item.name }
            val uom = item.exportUom()
            val r = groups.getOrPut(listOf(item.storageLoc, mat, item.stockType, uom).joinToString("|")) {
                Row(item.storageLoc, mat, item.stockType, uom)
            }
            r.qty = r.qty.add(item.exportQty())
            r.zero = r.zero || item.zeroCount
        }
        return groups.values.mapIndexed { i, r ->
            val zero = r.zero && r.qty.signum() == 0
            listOf(
                today, plan, year, branch, r.sloc, (i + 1).toString(),
                r.material, r.stockType, r.qty.stripTrailingZeros().toPlainString(), r.uom, if (zero) "X" else ""
            )
        }
    }

    /**
     * Log rows: one line per scan (duplicates kept), oldest scan first, with shelf and scan time.
     * Lines saved before v1.40 have no scan time; they come first, in the order they were saved.
     */
    fun logRows(branch: String, items: List<Item>): List<List<String>> {
        val fmt = SimpleDateFormat("dd.MM.yyyy HH:mm:ss", Locale.US)
        return items.sortedWith(compareBy({ it.scannedAt }, { it.id })).mapIndexed { i, it ->
            listOf(
                (i + 1).toString(),
                if (it.scannedAt > 0) fmt.format(Date(it.scannedAt)) else "",
                branch, it.storageLoc, it.shelf, it.barcode,
                it.material.ifBlank { it.barcode }.ifBlank { it.name }, it.name, it.stockType,
                fmtQty(it.quantity), it.uom,
                it.exportQty().toPlainString(), it.exportUom(),
                if (it.zeroCount && it.quantity == 0.0) "X" else ""
            )
        }
    }

    private val PI_WIDTHS = listOf(12, 12, 10, 10, 10, 10, 16, 12, 12, 12, 13)

    fun write(
        file: File, rows: List<List<String>>, headers: List<String> = HEADERS,
        textCols: Set<Int> = setOf(6), widths: List<Int> = PI_WIDTHS,
    ) {
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
            put("xl/worksheets/sheet1.xml", sheet(headers, rows, lock, textCols, widths))
        }
    }

    private fun sheet(headers: List<String>, rows: List<List<String>>, lock: String, textCols: Set<Int>, widths: List<Int>): String {
        val cols = widths.mapIndexed { i, w -> "<col min=\"${i + 1}\" max=\"${i + 1}\" width=\"$w\" customWidth=\"1\"/>" }.joinToString("")
        val sb = StringBuilder("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<cols>$cols</cols>
<sheetData>""")
        (listOf(headers) + rows).forEachIndexed { r, row ->
            sb.append("<row r=\"${r + 1}\">")
            row.forEachIndexed { c, v ->
                if (v.isEmpty()) return@forEachIndexed
                val ref = "${'A' + c}${r + 1}"
                // Codes (material, barcode, shelf) always stay text so long codes keep every digit.
                val numeric = r > 0 && c !in textCols && Regex("""-?\d{1,9}""").matches(v)
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
