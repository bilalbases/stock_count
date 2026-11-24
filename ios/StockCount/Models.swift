import Foundation

/// One counted line. Every scan is its own line (the PI file adds them up; the LOG keeps them apart).
struct Item: Codable, Identifiable, Equatable {
    var id: Int64 = 0
    var name: String = ""
    var barcode: String = ""
    /// Material number (from the material list, or typed in).
    var material: String = ""
    var shelf: String = ""
    /// Counted quantity in `uom`; decimals allowed (e.g. 1.25 KG).
    var quantity: Decimal = 0
    /// Unit as counted, e.g. EA or OTR.
    var uom: String = "EA"
    var stockType: String = ""
    /// STGE_LOC in the export (storage location, separate from the shelf ID).
    var storageLoc: String = ""
    /// Counted and confirmed there are none.
    var zeroCount: Bool = false
    /// SAP base unit from the material list; blank = `uom` is already the base unit.
    var baseUom: String = ""
    /// Base units per `uom` (1 OTR = 10 EA).
    var factor: Decimal = 1
    /// When this line was scanned (epoch millis).
    var scannedAt: Int64 = 0

    /// Unit written to the export: always the base unit when it is known.
    func exportUom() -> String { baseUom.isBlank ? uom : baseUom }

    /// Quantity in the base unit, e.g. 3 OTR x 10 = 30 EA.
    func exportQty() -> Decimal { (baseUom.isBlank || factor == 1) ? quantity : quantity * factor }

    /// "1 OTR = 10 EA" when the counted unit is not the base unit, else empty.
    func unitHint() -> String {
        if baseUom.isBlank || baseUom.caseInsensitiveCompare(uom) == .orderedSame { return "" }
        return "1 \(uom) = \(fmtQty(factor)) \(baseUom)"
    }

    /// Description if there is one, else material, else barcode.
    func label() -> String { name.ifBlank(material).ifBlank(barcode) }
}

/// One row of the material list. A material can have several barcodes (e.g. EA and CAR).
struct Material: Codable, Equatable {
    var barcode: String
    var material: String
    var uom: String
    var description: String = ""
    /// SAP base unit (MEINS), e.g. EA. Blank in old lists = uom is the base unit.
    var baseUom: String = ""
    /// Base units per `uom` (UMREZ / UMREN).
    var factor: Decimal = 1
}

/// Storage location -> stock type. Typing the storage location fills in the stock type.
let slocStockTypes: [(String, String)] = [
    ("1001", "Sales Location"),
    ("1002", "Warehouse"),
    ("1003", "Wholesale Invent"),
    ("1004", "Frozen"),
    ("1005", "Damage & Expiry"),
    ("1006", "Non-Moving & Exs"),
    ("1007", "Dry Container"),
]

/// Stock type for a storage location, in capitals as exported (nil = unknown storage location).
func stockTypeFor(_ sloc: String) -> String? {
    let s = sloc.trimmed
    return slocStockTypes.first { $0.0 == s }?.1.uppercased()
}

/// Stock types to pick from: blank first, then A-Z, in capitals.
let stockTypes: [String] = [""] + slocStockTypes.map { $0.1.uppercased() }.sorted()

// MARK: - Numbers

let posix = Locale(identifier: "en_US_POSIX")

/// 1 -> "1", 1.250 -> "1.25"
func fmtQty(_ q: Decimal) -> String {
    var v = q
    var r = Decimal()
    NSDecimalRound(&r, &v, 6, .plain)
    let s = NSDecimalNumber(decimal: r).description(withLocale: posix)
    return s == "-0" ? "0" : s
}

/// Typed text -> number; accepts "1.5" and "1,5".
func parseQty(_ s: String) -> Decimal? {
    let t = s.trimmed.replacingOccurrences(of: ",", with: ".")
    guard !t.isEmpty, t.range(of: #"^-?\d*\.?\d+$|^-?\d+\.$"#, options: .regularExpression) != nil else { return nil }
    return Decimal(string: t, locale: posix)
}

/// Keeps digits and one decimal point (comma becomes point), max 3 decimals, max 10 characters.
func cleanQty(_ s: String) -> String {
    let t = s.replacingOccurrences(of: ",", with: ".").filter { $0.isASCII && ($0.isNumber || $0 == ".") }
    var out = t
    if let i = t.firstIndex(of: ".") {
        let head = t[..<i]
        let tail = t[t.index(after: i)...].replacingOccurrences(of: ".", with: "").prefix(3)
        out = String(head) + "." + String(tail)
    }
    return String(out.prefix(10))
}

// MARK: - Dates

func dateFormatter(_ pattern: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = posix
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = pattern
    f.isLenient = false
    return f
}

/// dd.MM.yyyy and a real date.
func isValidDate(_ s: String) -> Bool {
    guard s.range(of: #"^\d{2}\.\d{2}\.\d{4}$"#, options: .regularExpression) != nil,
          let d = dateFormatter("dd.MM.yyyy").date(from: s) else { return false }
    return dateFormatter("dd.MM.yyyy").string(from: d) == s
}

func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

let firstYear = 2026
/// "2026" this year, "2026–2027" from next year on.
var copyrightYears: String {
    let now = Calendar(identifier: .gregorian).component(.year, from: Date())
    return now > firstYear ? "\(firstYear)–\(now)" : "\(firstYear)"
}

var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

// MARK: - Strings

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
    func ifBlank(_ other: String) -> String { isBlank ? other : self }
    /// Safe for file names: letters, digits, . _ - only.
    var fileSafe: String {
        String(map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-")) ? c : "-"
        })
    }
}
