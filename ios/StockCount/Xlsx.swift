import Foundation

/// Reads the first sheet of an .xlsx (or a CSV) as rows of text, and writes locked .xlsx files.
enum Xlsx {

    // MARK: - Reading

    static func readRows(_ data: Data) throws -> [[String]] {
        if data.count > 2 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4b {
            let files = try Zip.read(data)
            let sheetNames = files.keys.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }.sorted()
            guard let sheet = files["xl/worksheets/sheet1.xml"] ?? sheetNames.first.flatMap({ files[$0] }) else {
                throw Zip.ZipError(message: "No sheet found in the file")
            }
            let strings = files["xl/sharedStrings.xml"].map(parseSharedStrings) ?? []
            return parseSheet(sheet, strings: strings)
        }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return readCsv(text)
    }

    private final class SharedStrings: NSObject, XMLParserDelegate {
        var out: [String] = []
        var sb = ""
        var inSi = false, inT = false, inPhonetic = false
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch e {
            case "si": inSi = true; sb = ""
            case "t": inT = inSi && !inPhonetic
            case "rPh": inPhonetic = true
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inT { sb += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            switch e {
            case "t": inT = false
            case "rPh": inPhonetic = false
            case "si": out.append(sb); inSi = false
            default: break
            }
        }
    }

    private static func parseSharedStrings(_ data: Data) -> [String] {
        let d = SharedStrings()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.out
    }

    private final class Sheet: NSObject, XMLParserDelegate {
        let strings: [String]
        init(strings: [String]) { self.strings = strings }
        var rows: [[String]] = []
        var row: [Int: String]? = nil
        var col = 0, nextCol = 0
        var type = ""
        var value = ""
        var inValue = false
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch e {
            case "row": row = [:]; nextCol = 0
            case "c":
                col = a["r"].map(Xlsx.colIndex) ?? nextCol
                nextCol = col + 1
                type = a["t"] ?? ""
                value = ""
            case "v", "t": inValue = true
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inValue { value += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            switch e {
            case "v", "t": inValue = false
            case "c":
                let v: String
                switch type {
                case "s": v = Int(value.trimmed).flatMap { $0 >= 0 && $0 < strings.count ? strings[$0] : nil } ?? ""
                case "inlineStr", "str", "b": v = value
                default: v = Xlsx.plainNumber(value)
                }
                row?[col] = v
            case "row":
                if let r = row {
                    let size = (r.keys.max() ?? -1) + 1
                    rows.append((0..<size).map { r[$0] ?? "" })
                }
                row = nil
            default: break
            }
        }
    }

    private static func parseSheet(_ data: Data, strings: [String]) -> [[String]] {
        let d = Sheet(strings: strings)
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.rows
    }

    /// "1.010000042E9" -> "1010000042", "12.0" -> "12", so codes keep every digit.
    static func plainNumber(_ s: String) -> String {
        let t = s.trimmed
        if t.isEmpty { return t }
        guard let d = Decimal(string: t, locale: posix), t.range(of: #"^-?[0-9.]+([eE][-+]?\d+)?$"#, options: .regularExpression) != nil else { return t }
        return NSDecimalNumber(decimal: d).description(withLocale: posix)
    }

    static func colIndex(_ ref: String) -> Int {
        var n = 0
        for ch in ref.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
        }
        return n - 1
    }

    private static func readCsv(_ text: String) -> [[String]] {
        let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let seps: [Character] = [",", ";", "\t"]
        let sep: Character = seps.max { a, b in
            firstLine.filter { $0 == a }.count < firstLine.filter { $0 == b }.count
        } ?? ","
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quoted && ch == "\"" && i + 1 < chars.count && chars[i + 1] == "\"" { cell.append("\""); i += 1 }
            else if ch == "\"" { quoted.toggle() }
            else if !quoted && ch == sep { row.append(cell); cell = "" }
            else if !quoted && (ch == "\n" || ch == "\r" || ch == "\r\n") {
                if ch == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                row.append(cell); cell = ""; rows.append(row); row = []
            } else { cell.append(ch) }
            i += 1
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }

    // MARK: - Material list

    struct ImportResult { let materials: [Material]; let skipped: Int }

    /// Columns found by header name (MATERIAL, BARCODE, UOM, BASE_UOM, FACTOR, DESCRIPTION);
    /// without a header row, columns A-D are material, barcode, unit, description.
    static func toMaterials(_ rows: [[String]]) -> ImportResult {
        let nonEmpty = rows.filter { $0.contains { !$0.isBlank } }
        guard let first = nonEmpty.first else { return ImportResult(materials: [], skipped: 0) }
        let header = first.map { $0.trimmed.uppercased() }
        func find(_ keys: [String], not: String? = nil) -> Int {
            header.firstIndex { h in keys.contains { h.contains($0) } && (not == nil || !h.contains(not!)) } ?? -1
        }
        var mat = find(["MATERIAL", "MATNR", "ITEM CODE"], not: "DESC")
        var bar = find(["BARCODE", "EAN", "GTIN", "UPC"])
        var uom = find(["UOM", "UNIT", "MEINH"], not: "BASE")
        let base = header.firstIndex { ["BASE UOM", "BASE UNIT", "BUN", "MEINS"].contains($0.replacingOccurrences(of: "_", with: " ")) } ?? -1
        let fac = header.firstIndex { $0.contains("FACTOR") || $0.contains("CONVERSION") || $0 == "UMREZ" } ?? -1
        var desc = find(["DESC", "NAME", "MAKTX"])
        let hasHeader = mat >= 0 && bar >= 0
        if !hasHeader { mat = 0; bar = 1; uom = 2; desc = 3 }

        var skipped = 0
        var order: [String] = []
        var out: [String: Material] = [:]
        for row in (hasHeader ? Array(nonEmpty.dropFirst()) : nonEmpty) {
            func col(_ i: Int) -> String { i >= 0 && i < row.count ? row[i].trimmed : "" }
            let m = col(mat), b = col(bar)
            if m.isEmpty || b.isEmpty { skipped += 1; continue }
            let unit = col(uom).uppercased().ifBlank("EA")
            let baseUnit = hasHeader && base >= 0 ? col(base).uppercased() : ""
            var factor: Decimal = 1
            if hasHeader && fac >= 0, let f = parseQty(col(fac)), f > 0 { factor = f }
            if out[b] == nil { order.append(b) }
            out[b] = Material(barcode: b, material: m, uom: unit, description: col(desc),
                              baseUom: baseUnit, factor: (baseUnit.isBlank || baseUnit == unit) ? 1 : factor)
        }
        return ImportResult(materials: order.compactMap { out[$0] }, skipped: skipped)
    }

    // MARK: - Writing

    static let piHeaders = ["DATE", "PLAN_DATE", "GJAHR", "PLANT", "STGE_LOC", "ITEM",
                            "MATERIAL", "STOCK_TYPE", "ENTRY_QNT", "ENTRY_UOM", "ZERO_COUNT"]
    static let piText: Set<Int> = [6]
    static let piWidths = [12, 12, 10, 10, 10, 10, 16, 12, 12, 12, 13]

    static let logHeaders = ["NO", "SCANNED_AT", "PLANT", "STGE_LOC", "SHELF", "BARCODE", "MATERIAL", "DESCRIPTION",
                             "STOCK_TYPE", "COUNTED_QTY", "COUNTED_UOM", "ENTRY_QNT", "ENTRY_UOM", "ZERO_COUNT"]
    static let logText: Set<Int> = [4, 5, 6]
    static let logWidths = [6, 20, 8, 10, 10, 16, 14, 36, 11, 13, 13, 11, 11, 12]

    /// Writes a locked workbook: sheet and workbook are protected with a random password that is
    /// not stored anywhere, so the count cannot be changed in Excel (it can still be opened and uploaded to SAP).
    static func write(to url: URL, rows: [[String]], headers: [String] = piHeaders,
                      textCols: Set<Int> = piText, widths: [Int] = piWidths) throws {
        let lock = legacyHash(randomPassword())
        let files: [(String, String)] = [
            ("[Content_Types].xml", """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>
"""),
            ("_rels/.rels", """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
"""),
            ("xl/workbook.xml", """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<workbookProtection lockStructure="1" lockWindows="1" workbookPassword="\(lock)"/>
<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
</workbook>
"""),
            ("xl/_rels/workbook.xml.rels", """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
"""),
            ("xl/styles.xml", """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
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
</styleSheet>
"""),
            ("xl/worksheets/sheet1.xml", sheet(headers: headers, rows: rows, lock: lock, textCols: textCols, widths: widths)),
        ]
        let zip = Zip.write(files.map { ($0.0, Data($0.1.utf8)) })
        try zip.write(to: url, options: .atomic)
    }

    private static func columnName(_ i: Int) -> String {
        var n = i + 1
        var s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    private static func sheet(headers: [String], rows: [[String]], lock: String, textCols: Set<Int>, widths: [Int]) -> String {
        let cols = widths.enumerated().map { "<col min=\"\($0.offset + 1)\" max=\"\($0.offset + 1)\" width=\"\($0.element)\" customWidth=\"1\"/>" }.joined()
        var sb = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\n<cols>\(cols)</cols>\n<sheetData>"
        for (r, row) in ([headers] + rows).enumerated() {
            sb += "<row r=\"\(r + 1)\">"
            for (c, v) in row.enumerated() where !v.isEmpty {
                let ref = "\(columnName(c))\(r + 1)"
                // Codes (material, barcode, shelf) always stay text so long codes keep every digit.
                let numeric = r > 0 && !textCols.contains(c) && v.range(of: #"^-?\d{1,9}$"#, options: .regularExpression) != nil
                let style = r == 0 ? 1 : 0
                if numeric { sb += "<c r=\"\(ref)\" s=\"\(style)\"><v>\(v)</v></c>" }
                else { sb += "<c r=\"\(ref)\" s=\"\(style)\" t=\"inlineStr\"><is><t>\(esc(v))</t></is></c>" }
            }
            sb += "</row>"
        }
        sb += "</sheetData>"
        sb += "<sheetProtection password=\"\(lock)\" sheet=\"1\" objects=\"1\" scenarios=\"1\" formatCells=\"1\" formatColumns=\"1\" formatRows=\"1\" insertColumns=\"1\" insertRows=\"1\" insertHyperlinks=\"1\" deleteColumns=\"1\" deleteRows=\"1\" sort=\"1\" autoFilter=\"1\" pivotTables=\"1\"/>"
        return sb + "</worksheet>"
    }

    private static func randomPassword() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        return String((0..<15).map { _ in chars.randomElement()! })
    }

    /// Excel's sheet/workbook protection password hash (legacy 16-bit algorithm).
    private static func legacyHash(_ password: String) -> String {
        var hash = 0
        for c in password.unicodeScalars.reversed() {
            hash = ((hash >> 14) & 1) | ((hash << 1) & 0x7fff)
            hash ^= Int(c.value)
        }
        hash = ((hash >> 14) & 1) | ((hash << 1) & 0x7fff)
        hash ^= password.unicodeScalars.count ^ 0xCE4B
        return String(format: "%04X", hash)
    }

    private static func esc(_ s: String) -> String {
        let filtered = String(s.unicodeScalars.filter { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0.value >= 0x20 }.map(Character.init))
        return filtered.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
