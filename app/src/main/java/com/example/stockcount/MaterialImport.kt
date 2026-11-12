package com.example.stockcount

import android.content.Context
import android.net.Uri
import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import java.io.InputStream
import java.math.BigDecimal
import java.util.zip.ZipInputStream

/**
 * Reads a material list from an Excel (.xlsx) or CSV file.
 *
 * Columns are found by their header names (MATERIAL, BARCODE / EAN, UOM / UNIT, and an optional
 * DESCRIPTION / NAME). If there is no recognisable header row, columns A, B, C, D are read as
 * material, barcode, UoM, description.
 */
object MaterialImport {

    class Result(val materials: List<Material>, val skipped: Int)

    fun read(context: Context, uri: Uri): Result = toMaterials(readRows(context, uri))

    /** Reads the first sheet of an .xlsx (or a CSV) as rows of text. */
    fun readRows(context: Context, uri: Uri): List<List<String>> {
        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: error("Could not open the file")
        val rows = if (bytes.size > 2 && bytes[0] == 'P'.code.toByte() && bytes[1] == 'K'.code.toByte()) {
            readXlsx(bytes.inputStream())
        } else {
            readCsv(String(bytes, Charsets.UTF_8).removePrefix("﻿"))
        }
        return rows
    }

    fun toMaterials(rows: List<List<String>>): Result {
        val nonEmpty = rows.filter { r -> r.any { it.isNotBlank() } }
        if (nonEmpty.isEmpty()) return Result(emptyList(), 0)

        val header = nonEmpty.first().map { it.trim().uppercase() }
        fun find(vararg keys: String, not: String? = null) = header.indexOfFirst { h ->
            keys.any { h.contains(it) } && (not == null || !h.contains(not))
        }
        var mat = find("MATERIAL", "MATNR", "ITEM CODE", not = "DESC")
        var bar = find("BARCODE", "EAN", "GTIN", "UPC")
        var uom = find("UOM", "UNIT", "MEINH", not = "BASE")
        val base = header.indexOfFirst { it.replace('_', ' ') in setOf("BASE UOM", "BASE UNIT", "BUN", "MEINS") }
        val fac = header.indexOfFirst { it.contains("FACTOR") || it.contains("CONVERSION") || it == "UMREZ" }
        var desc = find("DESC", "NAME", "MAKTX")
        val hasHeader = mat >= 0 && bar >= 0
        if (!hasHeader) { mat = 0; bar = 1; uom = 2; desc = 3 }

        var skipped = 0
        val out = LinkedHashMap<String, Material>()
        for (row in if (hasHeader) nonEmpty.drop(1) else nonEmpty) {
            fun col(i: Int) = row.getOrNull(i)?.trim().orEmpty()
            val m = col(mat); val b = col(bar)
            if (m.isEmpty() || b.isEmpty()) { skipped++; continue }
            val unit = col(uom).uppercase().ifEmpty { "EA" }
            val baseUnit = if (hasHeader && base >= 0) col(base).uppercase() else ""
            val factor = if (hasHeader && fac >= 0) col(fac).replace(',', '.').toDoubleOrNull()?.takeIf { it > 0 } ?: 1.0 else 1.0
            out[b] = Material(barcode = b, material = m, uom = unit, description = col(desc),
                baseUom = baseUnit, factor = if (baseUnit.isBlank() || baseUnit == unit) 1.0 else factor)
        }
        return Result(out.values.toList(), skipped)
    }

    // ---------- CSV ----------

    private fun readCsv(text: String): List<List<String>> {
        val firstLine = text.lineSequence().firstOrNull().orEmpty()
        val sep = listOf(',', ';', '\t').maxBy { c -> firstLine.count { it == c } }
        val rows = mutableListOf<List<String>>()
        var row = mutableListOf<String>()
        val cell = StringBuilder()
        var quoted = false
        var i = 0
        while (i < text.length) {
            val ch = text[i]
            when {
                quoted && ch == '"' && i + 1 < text.length && text[i + 1] == '"' -> { cell.append('"'); i++ }
                ch == '"' -> quoted = !quoted
                !quoted && ch == sep -> { row.add(cell.toString()); cell.clear() }
                !quoted && (ch == '\n' || ch == '\r') -> {
                    if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++
                    row.add(cell.toString()); cell.clear(); rows.add(row); row = mutableListOf()
                }
                else -> cell.append(ch)
            }
            i++
        }
        if (cell.isNotEmpty() || row.isNotEmpty()) { row.add(cell.toString()); rows.add(row) }
        return rows
    }

    // ---------- XLSX (first sheet) ----------

    private fun readXlsx(input: InputStream): List<List<String>> {
        var shared: ByteArray? = null
        val sheets = sortedMapOf<String, ByteArray>()
        ZipInputStream(input).use { zip ->
            while (true) {
                val e = zip.nextEntry ?: break
                when {
                    e.name == "xl/sharedStrings.xml" -> shared = zip.readBytes()
                    e.name.startsWith("xl/worksheets/sheet") && e.name.endsWith(".xml") -> sheets[e.name] = zip.readBytes()
                }
            }
        }
        val sheet = sheets["xl/worksheets/sheet1.xml"] ?: sheets.values.firstOrNull() ?: error("No sheet found in the file")
        val strings = shared?.let { parseSharedStrings(it) } ?: emptyList()
        return parseSheet(sheet, strings)
    }

    private fun parser(bytes: ByteArray): XmlPullParser =
        Xml.newPullParser().apply { setInput(bytes.inputStream(), "UTF-8") }

    private fun parseSharedStrings(bytes: ByteArray): List<String> {
        val p = parser(bytes)
        val out = mutableListOf<String>()
        val sb = StringBuilder()
        var inSi = false
        var inT = false
        while (p.next() != XmlPullParser.END_DOCUMENT) {
            when (p.eventType) {
                XmlPullParser.START_TAG -> when (p.name) {
                    "si" -> { inSi = true; sb.clear() }
                    "t" -> inT = inSi
                    "rPh" -> inSi = false.also { /* skip phonetic runs */ }
                }
                XmlPullParser.TEXT -> if (inT) sb.append(p.text)
                XmlPullParser.END_TAG -> when (p.name) {
                    "t" -> inT = false
                    "rPh" -> inSi = true
                    "si" -> { out.add(sb.toString()); inSi = false }
                }
            }
        }
        return out
    }

    private fun parseSheet(bytes: ByteArray, strings: List<String>): List<List<String>> {
        val p = parser(bytes)
        val rows = mutableListOf<List<String>>()
        var row: MutableMap<Int, String>? = null
        var col = 0
        var type = ""
        val value = StringBuilder()
        var inValue = false
        var nextCol = 0
        while (p.next() != XmlPullParser.END_DOCUMENT) {
            when (p.eventType) {
                XmlPullParser.START_TAG -> when (p.name) {
                    "row" -> { row = mutableMapOf(); nextCol = 0 }
                    "c" -> {
                        col = p.getAttributeValue(null, "r")?.let { colIndex(it) } ?: nextCol
                        nextCol = col + 1
                        type = p.getAttributeValue(null, "t") ?: ""
                        value.clear()
                    }
                    "v", "t" -> inValue = true
                }
                XmlPullParser.TEXT -> if (inValue) value.append(p.text)
                XmlPullParser.END_TAG -> when (p.name) {
                    "v", "t" -> inValue = false
                    "c" -> {
                        val raw = value.toString()
                        row?.set(col, when (type) {
                            "s" -> strings.getOrNull(raw.trim().toIntOrNull() ?: -1).orEmpty()
                            "inlineStr", "str" -> raw
                            "b" -> raw
                            else -> plainNumber(raw)
                        })
                    }
                    "row" -> row?.let { r ->
                        val size = (r.keys.maxOrNull() ?: -1) + 1
                        rows.add(List(size) { r[it].orEmpty() })
                    }
                }
            }
        }
        return rows
    }

    /** "1.010000042E9" -> "1010000042", "12.0" -> "12", so codes keep every digit. */
    private fun plainNumber(s: String): String {
        val t = s.trim()
        if (t.isEmpty()) return t
        return runCatching { BigDecimal(t).stripTrailingZeros().toPlainString() }.getOrDefault(t)
    }

    private fun colIndex(ref: String): Int {
        var n = 0
        for (ch in ref) {
            if (!ch.isLetter()) break
            n = n * 26 + (ch.uppercaseChar() - 'A' + 1)
        }
        return n - 1
    }
}
