import Foundation

/// PI export in the SAP template, LOG file, upload copies and merging of export files.
enum Export {

    /// Files are kept in the app's Documents folder, visible in the Files app under
    /// On My iPhone > Stock Count (upload copies in its Uploads folder).
    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var uploadsFolder: URL {
        let u = folder.appendingPathComponent("Uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static func fileName(_ parts: [String]) -> String {
        parts.filter { !$0.isBlank }.joined(separator: "_").fileSafe + ".xlsx"
    }

    struct Result { let piFiles: [URL]; let logFile: URL; let slocs: [String]
        var files: [URL] { piFiles + [logFile] }
    }

    /// ONE PI FILE PER STORAGE LOCATION (PI_<branch>_<sloc>_<time>.xlsx) plus one LOG file with every scan.
    /// Exporting again in the same minute replaces those files instead of making duplicates.
    static func export(branch: String, planDate: String, items: [Item]) throws -> Result {
        let now = Date()
        let stamp = dateFormatter("yyyy-MM-dd_HHmm").string(from: now)
        let bySloc = Dictionary(grouping: items) { $0.storageLoc.trimmed }
        var pi: [URL] = []
        for sloc in bySloc.keys.sorted() {
            let url = folder.appendingPathComponent(fileName(["PI", branch, sloc.ifBlank("no-sloc"), stamp]))
            try Xlsx.write(to: url, rows: rows(branch: branch, planDate: planDate, items: bySloc[sloc]!, now: now))
            pi.append(url)
        }
        let log = folder.appendingPathComponent(fileName(["LOG", branch, stamp]))
        try Xlsx.write(to: log, rows: logRows(branch: branch, items: items),
                       headers: Xlsx.logHeaders, textCols: Xlsx.logText, widths: Xlsx.logWidths)
        return Result(piFiles: pi, logFile: log, slocs: bySloc.keys.sorted())
    }

    /// PI rows in the SAP base unit: 3 OTR (1 OTR = 10 EA) is written as 30 EA. The same material
    /// counted on several shelves or in several units becomes one row with the quantities added.
    static func rows(branch: String, planDate: String, items: [Item], now: Date = Date()) -> [[String]] {
        let today = dateFormatter("dd.MM.yyyy").string(from: now)
        let plan = isValidDate(planDate) ? planDate : today
        let year = String(Calendar(identifier: .gregorian).component(.year, from: now))
        struct Row { let sloc, material, stockType, uom: String; var qty: Decimal = 0; var zero = false }
        var order: [String] = []
        var groups: [String: Row] = [:]
        for item in items {
            let mat = item.material.ifBlank(item.barcode).ifBlank(item.name)
            let uom = item.exportUom()
            let key = [item.storageLoc, mat, item.stockType, uom].joined(separator: "|")
            if groups[key] == nil { order.append(key); groups[key] = Row(sloc: item.storageLoc, material: mat, stockType: item.stockType, uom: uom) }
            groups[key]!.qty += item.exportQty()
            groups[key]!.zero = groups[key]!.zero || item.zeroCount
        }
        return order.enumerated().map { i, key in
            let r = groups[key]!
            let zero = r.zero && r.qty == 0
            return [today, plan, year, branch, r.sloc, String(i + 1), r.material, r.stockType,
                    fmtQty(r.qty), r.uom, zero ? "X" : ""]
        }
    }

    /// One line per scan (duplicates kept), oldest scan first, with shelf and scan time.
    static func logRows(branch: String, items: [Item]) -> [[String]] {
        let fmt = dateFormatter("dd.MM.yyyy HH:mm:ss")
        let sorted = items.sorted { ($0.scannedAt, $0.id) < ($1.scannedAt, $1.id) }
        return sorted.enumerated().map { i, it in
            [String(i + 1),
             it.scannedAt > 0 ? fmt.string(from: Date(timeIntervalSince1970: Double(it.scannedAt) / 1000)) : "",
             branch, it.storageLoc, it.shelf, it.barcode,
             it.material.ifBlank(it.barcode).ifBlank(it.name), it.name, it.stockType,
             fmtQty(it.quantity), it.uom, fmtQty(it.exportQty()), it.exportUom(),
             it.zeroCount && it.quantity == 0 ? "X" : ""]
        }
    }

    /// Keeps a copy of exactly what was sent in an upload, e.g.
    /// Uploads/UPLOAD_1090_iPhone-AB12_2026-11-23_153012_SENT.xlsx (or _FAILED). Returns the path shown, or nil.
    static func saveUploadCopy(branch: String, device: String, items: [Item], sent: Bool) -> String? {
        let stamp = dateFormatter("yyyy-MM-dd_HHmmss").string(from: Date())
        let name = fileName(["UPLOAD", branch, device, stamp, sent ? "SENT" : "FAILED"])
        do {
            try Xlsx.write(to: uploadsFolder.appendingPathComponent(name), rows: logRows(branch: branch, items: items),
                           headers: Xlsx.logHeaders, textCols: Xlsx.logText, widths: Xlsx.logWidths)
            return "Files > On My iPhone > Stock Count > Uploads > \(name)"
        } catch { return nil }
    }

    // MARK: - Merge

    struct MergeResult {
        let piFiles: [URL]; let files: Int; let inputRows: Int; let outputRows: Int
        let duplicates: Int; let notConverted: [String]; let mixed: Bool
    }

    /// Merges export files from several devices into PI files ready for SAP, like a normal export:
    /// one PI file per storage location, quantities in the BASE unit (using the loaded material list).
    /// Accepts PI_, LOG_ and UPLOAD_ files; a scan found in several LOG/UPLOAD files is counted once.
    static func merge(files: [(name: String, data: Data)], planDate: String,
                      unitOf: (String, String) -> Material?) throws -> MergeResult {
        var cache: [String: Material?] = [:]
        func unit(_ material: String, _ uom: String) -> Material? {
            let k = material + "|" + uom.uppercased()
            if let c = cache[k] { return c }
            let v = (material.isBlank || uom.isBlank) ? nil : unitOf(material, uom)
            cache[k] = v
            return v
        }
        var notConverted: [String] = []
        var items: [(Item, String)] = []   // line, plant
        var scanOrder: [String] = []
        var scans: [String: (Int, Item, String)] = [:]
        var plan = isValidDate(planDate) ? planDate : ""
        var inputRows = 0
        var anyPi = false, anyLog = false
        for f in files {
            let rows = try Xlsx.readRows(f.data).filter { $0.contains { !$0.isBlank } }
            guard let first = rows.first else { continue }
            let header = first.map { $0.trimmed.uppercased() }
            func idx(_ n: String) -> Int { header.firstIndex(of: n) ?? -1 }
            let iPlan = idx("PLAN_DATE"), iPlant = idx("PLANT"), iSloc = idx("STGE_LOC")
            let iMat = idx("MATERIAL"), iType = idx("STOCK_TYPE"), iQty = idx("ENTRY_QNT")
            let iUom = idx("ENTRY_UOM"), iZero = idx("ZERO_COUNT")
            let iAt = idx("SCANNED_AT"), iShelf = idx("SHELF"), iBc = idx("BARCODE")
            let iCq = idx("COUNTED_QTY"), iCu = idx("COUNTED_UOM")
            guard iMat >= 0 && iQty >= 0 else { throw Zip.ZipError(message: "Not a stock count export: \(f.name)") }
            let isLog = iAt >= 0
            if isLog { anyLog = true } else { anyPi = true }
            var inThisFile: [String: Int] = [:]
            for r in rows.dropFirst() {
                func c(_ i: Int) -> String { i >= 0 && i < r.count ? r[i].trimmed : "" }
                let mat = c(iMat)
                if mat.isEmpty { continue }
                inputRows += 1
                if plan.isEmpty && isValidDate(c(iPlan)) { plan = c(iPlan) }
                var qty = parseQty(c(iQty)) ?? 0
                var uom = c(iUom)
                if let cq = parseQty(c(iCq)), !c(iCu).isEmpty, unit(mat, c(iCu)) != nil { qty = cq; uom = c(iCu) }
                if let m = unit(mat, uom) {
                    if m.baseUom.caseInsensitiveCompare(uom) != .orderedSame { qty *= m.factor; uom = m.baseUom }
                } else if !notConverted.contains("\(mat) \(uom)") {
                    notConverted.append("\(mat) \(uom)")
                }
                let item = Item(barcode: c(iBc), material: mat, shelf: c(iShelf), quantity: qty, uom: uom.uppercased(),
                                stockType: c(iType), storageLoc: c(iSloc), zeroCount: c(iZero).uppercased() == "X")
                let at = c(iAt)
                if isLog && !at.isEmpty {
                    let key = [at, c(iPlant), c(iSloc), c(iShelf), c(iBc), mat, c(iType), c(iCq), c(iCu), c(iQty), c(iUom)].joined(separator: "|")
                    let n = (inThisFile[key] ?? 0) + 1
                    inThisFile[key] = n
                    if let seen = scans[key] {
                        if n > seen.0 { scans[key] = (n, item, c(iPlant)) }
                    } else {
                        scanOrder.append(key); scans[key] = (n, item, c(iPlant))
                    }
                } else {
                    items.append((item, c(iPlant)))
                }
            }
        }
        for k in scanOrder { let (n, item, plant) = scans[k]!; for _ in 0..<n { items.append((item, plant)) } }
        let duplicates = max(0, inputRows - items.count)

        var units: [String: Set<String>] = [:]
        for (it, _) in items { units[it.material, default: []].insert(it.uom.uppercased()) }
        let warn = notConverted.filter { e in (units[String(e.split(separator: " ").first ?? "")]?.count ?? 0) > 1 }

        let now = Date()
        let stamp = dateFormatter("yyyy-MM-dd_HHmm").string(from: now)
        var out: [URL] = []
        var outRows = 0
        let byPlant = Dictionary(grouping: items) { $0.1 }
        for plant in byPlant.keys.sorted() {
            let bySloc = Dictionary(grouping: byPlant[plant]!) { $0.0.storageLoc.trimmed }
            for sloc in bySloc.keys.sorted() {
                let r = rows(branch: plant, planDate: plan, items: bySloc[sloc]!.map { $0.0 }, now: now)
                outRows += r.count
                let url = folder.appendingPathComponent(fileName(["PI_MERGED", plant, sloc.ifBlank("no-sloc"), stamp]))
                try Xlsx.write(to: url, rows: r)
                out.append(url)
            }
        }
        guard !out.isEmpty else { throw Zip.ZipError(message: "No count lines found in the chosen files") }
        return MergeResult(piFiles: out, files: files.count, inputRows: inputRows, outputRows: outRows,
                           duplicates: duplicates, notConverted: warn, mixed: anyPi && anyLog)
    }
}
