import Foundation

/// Sends the counted lines to the Stock Count server on the local network (local-server/StockCountServer.ps1).
/// Each upload carries this device's lines; sending the same count again is safe.
enum Uploader {

    static let defaultURL = "http://192.168.11.162:8080/upload"

    /// Upload settings, remembered on the phone. The key defaults to the one built into the app.
    struct Config {
        static var url: String {
            get { UserDefaults.standard.string(forKey: "uploadUrl").flatMap { $0.isBlank ? nil : $0 } ?? defaultURL }
            set { UserDefaults.standard.set(newValue.trimmed, forKey: "uploadUrl") }
        }
        static var key: String {
            get {
                UserDefaults.standard.string(forKey: "uploadKey").flatMap { $0.isBlank ? nil : $0 }
                    ?? (Bundle.main.object(forInfoDictionaryKey: "UploadKey") as? String ?? "")
            }
            set { UserDefaults.standard.set(newValue.trimmed, forKey: "uploadKey") }
        }
        static var device: String {
            get { UserDefaults.standard.string(forKey: "device") ?? defaultDevice() }
            set { UserDefaults.standard.set(newValue.trimmed, forKey: "device") }
        }
        static var isSet: Bool { (url.hasPrefix("http://") || url.hasPrefix("https://")) && !key.isBlank }
    }

    static func defaultDevice() -> String {
        // A random id kept on this iPhone (like the Android ID on the PDTs).
        let id: String
        if let saved = UserDefaults.standard.string(forKey: "deviceId") { id = saved } else {
            id = String(UUID().uuidString.suffix(4)).uppercased()
            UserDefaults.standard.set(id, forKey: "deviceId")
        }
        return "iPhone-\(id)".fileSafe
    }

    enum UploadError: LocalizedError {
        /// The server answered with an error (wrong key etc.): trying again will not help.
        case server(String)
        var errorDescription: String? { if case .server(let m) = self { return m }; return nil }
    }

    /// Worth trying again at once? Not after a server error or a 5-minute wait for a busy server.
    static func retryable(_ e: Error) -> Bool {
        if e is UploadError { return false }
        guard let u = e as? URLError else { return false }
        return u.code != .timedOut
    }

    /// Plain-language reason for a failed upload.
    static func describe(_ e: Error) -> String {
        if case UploadError.server(let m) = e { return "The server answered: \(m)" }
        if let u = e as? URLError {
            switch u.code {
            case .timedOut:
                return "The server did not answer in time. Your count is safe on this iPhone. Wait a few minutes, then upload again."
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed:
                return "Server not reachable. Check that this iPhone is on the store Wi-Fi, that Local Network is allowed for Stock Count in Settings, and that the server PC is on."
            default:
                return "Connection problem (\(u.localizedDescription)). Check Wi-Fi, then upload again."
            }
        }
        return e.localizedDescription
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5 * 60     // a busy server answers late, not never
        c.timeoutIntervalForResource = 6 * 60
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Uploads all lines. Returns the number of rows the server received. Throws on failure.
    static func upload(planDate: String, branch: String, items: [Item]) async throws -> Int {
        let fmt = dateFormatter("dd.MM.yyyy HH:mm:ss")
        let rows: [[String: Any]] = items.sorted { ($0.scannedAt, $0.id) < ($1.scannedAt, $1.id) }.map { i in
            [
                "line": i.id,
                "scannedAt": i.scannedAt > 0 ? fmt.string(from: Date(timeIntervalSince1970: Double(i.scannedAt) / 1000)) : "",
                "scannedMs": i.scannedAt,
                "planDate": planDate,
                "plant": branch,
                "storageLoc": i.storageLoc,
                "shelf": i.shelf,
                "material": i.material.ifBlank(i.barcode),
                "barcode": i.barcode,
                "description": i.name,
                "stockType": i.stockType,
                "quantity": fmtQty(i.exportQty()),   // in the base unit (3 OTR -> 30 EA)
                "uom": i.exportUom(),
                "countedQty": fmtQty(i.quantity),
                "countedUom": i.uom,
                "zeroCount": i.zeroCount,
            ]
        }
        let body: [String: Any] = ["key": Config.key, "device": Config.device, "rows": rows]
        guard let url = URL(string: Config.url) else { throw UploadError.server("the server URL in Upload settings is not valid") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let j = json, (j["ok"] as? Bool) != true { throw UploadError.server(j["error"] as? String ?? "Upload failed") }
        if code >= 400 { throw UploadError.server("HTTP error \(code)") }
        guard let j = json else { throw UploadError.server("unexpected answer. Check the URL in Upload settings.") }
        return (j["rows"] as? Int) ?? items.count
    }
}
