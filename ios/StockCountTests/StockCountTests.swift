import XCTest
@testable import StockCount

final class StockCountTests: XCTestCase {

    func testNumbers() {
        XCTAssertEqual(fmtQty(Decimal(string: "1.250")!), "1.25")
        XCTAssertEqual(fmtQty(30), "30")
        XCTAssertEqual(fmtQty(0), "0")
        XCTAssertEqual(parseQty("1,5"), Decimal(string: "1.5"))
        XCTAssertNil(parseQty(""))
        XCTAssertNil(parseQty("abc"))
        XCTAssertEqual(cleanQty("1,2345"), "1.234")
        XCTAssertEqual(cleanQty("1.2.3"), "1.23")
        XCTAssertTrue(isValidDate("24.11.2026"))
        XCTAssertFalse(isValidDate("31.02.2026"))
        XCTAssertEqual(stockTypeFor("1004"), "FROZEN")
    }

    func testPiRowsUseBaseUnitAndMerge() {
        let a = Item(id: 1, barcode: "111", material: "M1", shelf: "A", quantity: 3, uom: "OTR", stockType: "WAREHOUSE", storageLoc: "1002", baseUom: "EA", factor: 10, scannedAt: 1)
        let b = Item(id: 2, barcode: "222", material: "M1", shelf: "B", quantity: 5, uom: "EA", stockType: "WAREHOUSE", storageLoc: "1002", baseUom: "EA", factor: 1, scannedAt: 2)
        let z = Item(id: 3, barcode: "333", material: "M2", shelf: "B", quantity: 0, uom: "EA", stockType: "WAREHOUSE", storageLoc: "1002", zeroCount: true, scannedAt: 3)
        let rows = Export.rows(branch: "1090", planDate: "24.11.2026", items: [a, b, z])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][6], "M1")
        XCTAssertEqual(rows[0][8], "35")
        XCTAssertEqual(rows[0][9], "EA")
        XCTAssertEqual(rows[1][10], "X")
        XCTAssertEqual(rows[0][1], "24.11.2026")
        let log = Export.logRows(branch: "1090", items: [b, a])
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log[0][5], "111")
        XCTAssertEqual(log[0][9], "3")
        XCTAssertEqual(log[0][11], "30")
    }

    func testXlsxRoundTripAndMaterialImport() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t.xlsx")
        try Xlsx.write(to: url, rows: [["M1", "08001234567890", "OTR", "EA", "10", "Milk & Co"], ["M1", "123", "EA", "EA", "1", "Milk"]],
                       headers: ["MATERIAL", "BARCODE", "UOM", "BASE_UOM", "FACTOR", "DESCRIPTION"], textCols: [0, 1], widths: [10, 10, 10, 10, 10, 10])
        let rows = try Xlsx.readRows(try Data(contentsOf: url))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1][1], "08001234567890")
        let r = Xlsx.toMaterials(rows)
        XCTAssertEqual(r.materials.count, 2)
        XCTAssertEqual(r.materials[0].factor, 10)
        XCTAssertEqual(r.materials[0].baseUom, "EA")
        XCTAssertEqual(r.materials[0].description, "Milk & Co")
        XCTAssertEqual(r.materials[1].factor, 1)
    }

    func testCsvImport() throws {
        let csv = "MATERIAL;BARCODE;UOM\r\nM1;111;EA\r\n;222;EA\r\n"
        let r = Xlsx.toMaterials(try Xlsx.readRows(Data(csv.utf8)))
        XCTAssertEqual(r.materials.count, 1)
        XCTAssertEqual(r.skipped, 1)
    }

    func testDeflatedZip() throws {
        // A tiny zip made by Python zipfile holding hello.txt = "hello hello hello hello\n" (deflated).
        let b64 = "UEsDBBQAAAAIAPxZeF0AiFkLCwAAABgAAAAJAAAAaGVsbG8udHh0y0jNyclXyEAnuQBQSwECFAMUAAAACAD8WXhdAIhZCwsAAAAYAAAACQAAAAAAAAAAAAAAgAEAAAAAaGVsbG8udHh0UEsFBgAAAAABAAEANwAAADIAAAAAAA=="
        let files = try Zip.read(Data(base64Encoded: b64)!)
        XCTAssertEqual(files["hello.txt"].map { String(decoding: $0, as: UTF8.self) }, "hello hello hello hello\n")
    }

    func testMergeCountsRepeatedScansOnce() throws {
        let a = Item(id: 1, barcode: "111", material: "M1", shelf: "A", quantity: 3, uom: "OTR", storageLoc: "1002", baseUom: "EA", factor: 10, scannedAt: 1_700_000_000_000)
        let rows = Export.logRows(branch: "1090", items: [a])
        let u1 = FileManager.default.temporaryDirectory.appendingPathComponent("log1.xlsx")
        try Xlsx.write(to: u1, rows: rows, headers: Xlsx.logHeaders, textCols: Xlsx.logText, widths: Xlsx.logWidths)
        let d = try Data(contentsOf: u1)
        let unit = Material(barcode: "111", material: "M1", uom: "OTR", baseUom: "EA", factor: 10)
        let res = try Export.merge(files: [("LOG_a.xlsx", d), ("UPLOAD_b.xlsx", d)], planDate: "24.11.2026") { m, u in
            m == "M1" && u.uppercased() == "OTR" ? unit : nil
        }
        XCTAssertEqual(res.outputRows, 1)
        XCTAssertEqual(res.duplicates, 1)
        let out = try Xlsx.readRows(try Data(contentsOf: res.piFiles[0]))
        XCTAssertEqual(out[1][8], "30")
        XCTAssertEqual(out[1][9], "EA")
    }
}
