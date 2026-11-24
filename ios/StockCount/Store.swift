import Foundation
import SwiftUI

/// The count and the material list, kept in the app's private storage (works offline).
@MainActor
final class Store: ObservableObject {
    @Published private(set) var items: [Item] = []
    @Published private(set) var materialCount = 0

    private var byBarcode: [String: Material] = [:]
    /// "MATERIAL|UOM" -> entry with a base unit (any of the material's barcodes).
    private var unitIndex: [String: Material] = [:]
    private var nextId: Int64 = 1

    private static var dir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private static var itemsFile: URL { dir.appendingPathComponent("items.json") }
    private static var materialsFile: URL { dir.appendingPathComponent("materials.json") }

    init() {
        if let d = try? Data(contentsOf: Self.itemsFile), let list = try? JSONDecoder().decode([Item].self, from: d) {
            items = list
            nextId = (list.map(\.id).max() ?? 0) + 1
        }
        if let d = try? Data(contentsOf: Self.materialsFile), let list = try? JSONDecoder().decode([Material].self, from: d) {
            index(list)
        }
    }

    // MARK: Count lines

    private func persist() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: Self.itemsFile, options: .atomic) }
    }

    /// Adds a new line (id 0) or replaces an existing one.
    func save(_ item: Item) {
        var it = item
        if it.id == 0 {
            it.id = nextId; nextId += 1
            items.append(it)
        } else if let i = items.firstIndex(where: { $0.id == it.id }) {
            items[i] = it
        } else {
            items.append(it)
        }
        persist()
    }

    func delete(_ item: Item) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func deleteAll() {
        items = []
        persist()
    }

    /// Lines for this barcode on this shelf, oldest first.
    func lines(for code: String, shelf: String) -> [Item] {
        items.filter { !$0.barcode.isEmpty && $0.barcode == code && $0.shelf == shelf }.sorted { $0.id < $1.id }
    }

    // MARK: Material list

    private func index(_ list: [Material]) {
        var b: [String: Material] = [:]
        var u: [String: Material] = [:]
        for m in list {
            b[m.barcode] = m
            let k = m.material + "|" + m.uom.uppercased()
            if !m.baseUom.isBlank && u[k] == nil { u[k] = m }
        }
        byBarcode = b
        unitIndex = u
        materialCount = b.count
    }

    func replaceMaterials(_ list: [Material]) {
        index(list)
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: Self.materialsFile, options: .atomic) }
    }

    /// Looks a barcode up. The iPhone camera reads UPC-A codes as 13 digits with a leading 0,
    /// so a code that is not found is also tried with that 0 removed (and 12 digits with a 0 added).
    func material(barcode code: String) -> Material? {
        if let m = byBarcode[code] { return m }
        if code.count == 13 && code.hasPrefix("0"), let m = byBarcode[String(code.dropFirst())] { return m }
        if code.count == 12, let m = byBarcode["0" + code] { return m }
        return nil
    }

    func unitInfo(material: String, uom: String) -> Material? {
        unitIndex[material + "|" + uom.uppercased()]
    }

    /// Fills in base unit + factor from the current material list for lines counted without them,
    /// and saves the fix. Returns the lines and the units that still have no base unit.
    func withBaseUnits() -> ([Item], [String]) {
        var missing: [String] = []
        var changed = false
        let list = items
        let out = list.map { item -> Item in
            if !item.baseUom.isBlank || item.material.isBlank { return item }
            if let m = unitInfo(material: item.material, uom: item.uom) {
                var fixed = item
                fixed.baseUom = m.baseUom
                fixed.factor = m.baseUom.caseInsensitiveCompare(item.uom) == .orderedSame ? 1 : m.factor
                changed = true
                return fixed
            }
            if list.contains(where: { $0.material == item.material && $0.uom.caseInsensitiveCompare(item.uom) != .orderedSame }) {
                let e = "\(item.material) \(item.uom)"
                if !missing.contains(e) { missing.append(e) }
            }
            return item
        }
        if changed { items = out; persist() }
        return (out, missing)
    }
}
