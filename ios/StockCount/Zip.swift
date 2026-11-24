import Foundation
import Compression

/// Minimal zip support for .xlsx files (no third-party library, works offline).
enum Zip {
    struct ZipError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Reading

    /// Returns every file in the zip by name. Supports stored and deflated entries.
    static func read(_ data: Data) throws -> [String: Data] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 3 < b.count ? u16(o) | u16(o + 2) << 16 : 0 }

        // End of central directory record: last 0x06054b50 signature.
        var eocd = -1
        var i = b.count - 22
        let stop = max(0, b.count - 22 - 65_535)
        while i >= stop {
            if b[i] == 0x50 && b[i + 1] == 0x4b && b[i + 2] == 0x05 && b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError(message: "Not an Excel (.xlsx) file") }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [String: Data] = [:]
        for _ in 0..<count {
            guard u32(p) == 0x02014b50 else { break }
            let method = u16(p + 10)
            let compSize = u32(p + 20)
            let size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<min(b.count, p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            guard u32(local) == 0x04034b50 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compSize <= b.count else { continue }
            let raw = Array(b[start..<(start + compSize)])
            switch method {
            case 0: out[name] = Data(raw)
            case 8: out[name] = try inflate(raw, size: size)
            default: continue
            }
        }
        return out
    }

    private static func inflate(_ src: [UInt8], size: Int) throws -> Data {
        if size == 0 { return Data() }
        var dst = [UInt8](repeating: 0, count: size)
        let n = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, size, s.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { throw ZipError(message: "Could not unpack the Excel file") }
        return Data(dst.prefix(n))
    }

    // MARK: Writing

    /// Writes a zip with stored (uncompressed) entries, in the given order.
    static func write(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        func le16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff)) }
        func le32(_ v: UInt32, _ d: inout Data) { for s in [0, 8, 16, 24] { d.append(UInt8((v >> UInt32(s)) & 0xff)) } }
        // 1 Jan 2026, 00:00 in DOS format (date of entries does not matter to Excel).
        let dosTime = 0, dosDate = ((2026 - 1980) << 9) | (1 << 5) | 1
        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)
            le32(0x04034b50, &out); le16(20, &out); le16(0x0800, &out); le16(0, &out)
            le16(dosTime, &out); le16(dosDate, &out)
            le32(crc, &out); le32(UInt32(data.count), &out); le32(UInt32(data.count), &out)
            le16(nameBytes.count, &out); le16(0, &out)
            out.append(nameBytes); out.append(data)

            le32(0x02014b50, &central); le16(20, &central); le16(20, &central); le16(0x0800, &central); le16(0, &central)
            le16(dosTime, &central); le16(dosDate, &central)
            le32(crc, &central); le32(UInt32(data.count), &central); le32(UInt32(data.count), &central)
            le16(nameBytes.count, &central); le16(0, &central); le16(0, &central); le16(0, &central); le16(0, &central)
            le32(0, &central); le32(offset, &central)
            central.append(nameBytes)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        le32(0x06054b50, &out); le16(0, &out); le16(0, &out)
        le16(entries.count, &out); le16(entries.count, &out)
        le32(UInt32(central.count), &out); le32(cdOffset, &out); le16(0, &out)
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffffffff
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffffffff
    }
}
