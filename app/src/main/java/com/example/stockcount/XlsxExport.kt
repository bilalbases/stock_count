package com.example.stockcount

import android.content.Context
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
 * PLANT = branch ID, STGE_LOC = shelf ID, ITEM = running number, MATERIAL = barcode
 * (or the item name if it has no barcode), ZERO_COUNT = "X" when the checkbox is ticked.
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

    fun share(context: Context, branch: String, planDate: String, items: List<Item>) {
        val now = Date()
        val stamp = SimpleDateFormat("yyyy-MM-dd_HHmm", Locale.US).format(now)
        val dir = File(context.cacheDir, "exports").apply { mkdirs() }
        val name = listOfNotNull("PI", branch.ifBlank { null }, stamp).joinToString("_")
            .replace(Regex("[^A-Za-z0-9._-]"), "-")
        val file = File(dir, "$name.xlsx")
        write(file, rows(branch, planDate, items, now))

        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, "Stock count $branch $stamp".replace("  ", " "))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(send, "Export stock count"))
    }

    /** One row per item. Values that are whole numbers are written as numbers, like the template. */
    fun rows(branch: String, planDate: String, items: List<Item>, now: Date = Date()): List<List<String>> {
        val today = dateFormat().format(now)
        val plan = if (isValidDate(planDate)) planDate else today
        val year = Calendar.getInstance().apply { time = now }.get(Calendar.YEAR).toString()
        return items.mapIndexed { i, item ->
            listOf(
                today, plan, year, branch, item.shelf, (i + 1).toString(),
                item.barcode.ifBlank { item.name }, "", item.quantity.toString(), item.uom,
                if (item.zeroCount) "X" else ""
            )
        }
    }

    fun write(file: File, rows: List<List<String>>) {
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
</Types>""")
            put("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>""")
            put("xl/workbook.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
</workbook>""")
            put("xl/_rels/workbook.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>""")
            put("xl/worksheets/sheet1.xml", sheet(rows))
        }
    }

    private fun sheet(rows: List<List<String>>): String {
        val sb = StringBuilder("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>""")
        (listOf(HEADERS) + rows).forEachIndexed { r, row ->
            sb.append("<row r=\"${r + 1}\">")
            row.forEachIndexed { c, v ->
                if (v.isEmpty()) return@forEachIndexed
                val ref = "${'A' + c}${r + 1}"
                // MATERIAL (column G) always stays text so long codes keep every digit.
                val numeric = r > 0 && c != 6 && Regex("""-?\d{1,9}""").matches(v)
                if (numeric) sb.append("<c r=\"$ref\"><v>$v</v></c>")
                else sb.append("<c r=\"$ref\" t=\"inlineStr\"><is><t>").append(esc(v)).append("</t></is></c>")
            }
            sb.append("</row>")
        }
        return sb.append("</sheetData></worksheet>").toString()
    }

    private fun esc(s: String) = s
        .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
        .filter { it == '\t' || it == '\n' || it == '\r' || it >= ' ' }
}
