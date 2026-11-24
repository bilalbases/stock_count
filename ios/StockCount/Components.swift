import SwiftUI
import UIKit

/// Text field with a small label above it, like the Android outlined fields.
struct Field: View {
    let label: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var error = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundColor(error ? .red : .secondary)
            TextField("", text: $text)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemGroupedBackground)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(error ? Color.red : Color(.separator), lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Stock type as a pick list: blank first, then the stock types A-Z.
struct StockTypePicker: View {
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Stock type").font(.caption).foregroundColor(.secondary)
            Menu {
                ForEach(stockTypes, id: \.self) { t in
                    Button(t.isEmpty ? "(none)" : t) { value = t }
                }
            } label: {
                HStack {
                    Text(value.isEmpty ? " " : value).lineLimit(1).foregroundColor(.primary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundColor(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemGroupedBackground)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator), lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct CheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundColor(configuration.isOn ? brand : .secondary)
                    .font(.title3)
                configuration.label.foregroundColor(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct FlowTags: View {
    let tags: [(String, Bool)]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, t in
                    Text(t.0)
                        .font(.caption.weight(t.1 ? .semibold : .regular))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(t.1 ? teal.opacity(0.2) : Color(.tertiarySystemFill)))
                }
            }
        }
    }
}

struct EmptyState: View {
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(brand.opacity(0.12)).frame(width: 88, height: 88)
                Image(systemName: "barcode").font(.system(size: 40)).foregroundColor(brand)
            }
            .padding(.bottom, 8)
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold())
            Text(label).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(brand.opacity(0.12)))
    }
}

struct BarButton: View {
    let title: String
    let icon: String
    let color: Color
    var foreground: Color = .white
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).fontWeight(.semibold).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundColor(foreground)
            .background(RoundedRectangle(cornerRadius: 16).fill(color))
        }
    }
}

/// One line on the Counted page: name and codes, quantity stepper with the unit, zero count and delete.
struct ItemCard: View {
    let item: Item
    @Binding var qtyText: String
    let onStep: (Decimal) -> Void
    let onZero: (Bool) -> Void
    let onDelete: () -> Void
    let onDone: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label()).font(.subheadline.weight(.semibold)).lineLimit(2)
                    let sub = [(!item.material.isEmpty && !item.name.isEmpty) ? item.material : nil,
                               item.barcode.isEmpty ? nil : item.barcode,
                               item.unitHint().isEmpty ? nil : item.unitHint(),
                               item.shelf.isEmpty ? nil : "Shelf \(item.shelf)"].compactMap { $0 }.joined(separator: "  ·  ")
                    if !sub.isEmpty { Text(sub).font(.caption2).foregroundColor(.secondary) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        StepButton(symbol: "minus") { onStep(-1) }
                        TextField("0", text: $qtyText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(qtyText != fmtQty(item.quantity) ? teal : (item.zeroCount ? .secondary : .primary))
                            .frame(width: 64)
                            .onSubmit(onDone)
                        StepButton(symbol: "plus") { onStep(1) }
                    }
                    Text(item.uom).font(.caption.weight(.semibold)).foregroundColor(brand)
                }
            }
            HStack {
                Toggle(isOn: Binding(get: { item.zeroCount }, set: onZero)) { Text("Zero count").font(.caption) }
                    .toggleStyle(CheckboxStyle())
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash").font(.caption)
                }
                .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}

struct StepButton: View {
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(brand))
        }
        .buttonStyle(.plain)
    }
}

/// All fields of a line. Also opens for a barcode that is not in the material list,
/// so it can be corrected (+0 adds a leading zero) and looked up again, or typed in by hand.
struct EditItemView: View {
    @EnvironmentObject var store: Store
    let item: Item
    let title: String
    let notFoundCode: String?
    let onSave: (Item) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var name = ""
    @State private var barcode = ""
    @State private var material = ""
    @State private var shelf = ""
    @State private var uom = ""
    @State private var baseUom = ""
    @State private var factor: Decimal = 1
    @State private var stockType = ""
    @State private var storageLoc = ""
    @State private var qty = ""
    @State private var zeroCount = false
    @State private var lookupMsg: String?
    @State private var confirmDelete = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                if let code = notFoundCode {
                    Section {
                        Text("\(code) is not in the material list. Correct the barcode (for example add a leading 0) and tap Look up, or fill in the details yourself.")
                            .font(.subheadline).foregroundColor(.red)
                    }
                }
                Section {
                    labeled("Material", $material)
                    labeled("Description (optional)", $name)
                    HStack {
                        labeled("Barcode", Binding(get: { barcode }, set: { barcode = $0.trimmed; lookupMsg = nil }), keyboard: .numberPad)
                        Button("+0") { barcode = "0" + barcode; lookupMsg = nil }.buttonStyle(.bordered)
                    }
                    HStack {
                        Button("Look up") { lookUp() }.buttonStyle(.bordered)
                        if let msg = lookupMsg {
                            Text(msg).font(.subheadline).foregroundColor(msg.hasPrefix("✓") ? teal : .red)
                        }
                    }
                }
                Section {
                    labeled("Quantity", Binding(get: { qty }, set: { qty = cleanQty($0); if (parseQty(qty) ?? 0) > 0 { zeroCount = false } }), keyboard: .decimalPad)
                    labeled("Unit (EA, CAR...)", Binding(get: { uom }, set: { uom = $0.uppercased() }))
                    labeled("Shelf ID", $shelf)
                    labeled("Storage location", Binding(get: { storageLoc }, set: {
                        storageLoc = $0.uppercased()
                        if let t = stockTypeFor(storageLoc) { stockType = t }
                    }))
                    Picker("Stock type", selection: $stockType) {
                        ForEach(stockTypes + (stockTypes.contains(stockType) ? [] : [stockType]), id: \.self) { t in
                            Text(t.isEmpty ? "(none)" : t).tag(t)
                        }
                    }
                    Toggle("Zero count", isOn: Binding(get: { zeroCount }, set: { zeroCount = $0; if $0 { qty = "0" } }))
                }
                if let del = onDelete {
                    Section {
                        Button(role: .destructive) { if confirmDelete { del() } else { confirmDelete = true } } label: {
                            Text(confirmDelete ? "Tap again to delete" : "Delete item")
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel).foregroundColor(.white) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .foregroundColor(.white)
                        .disabled((material.isBlank && name.isBlank) || (qty.isEmpty && !zeroCount))
                }
            }
            .toolbarBackground(brand, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = item.name; barcode = item.barcode; material = item.material; shelf = item.shelf
            uom = item.uom; baseUom = item.baseUom; factor = item.factor
            stockType = item.stockType; storageLoc = item.storageLoc
            qty = notFoundCode != nil ? "" : fmtQty(item.quantity)
            zeroCount = item.zeroCount
        }
    }

    private func labeled(_ label: String, _ text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            TextField(label, text: text).keyboardType(keyboard).autocorrectionDisabled()
        }
    }

    private func lookUp() {
        if let m = store.material(barcode: barcode) {
            barcode = m.barcode
            material = m.material
            uom = m.uom
            baseUom = m.baseUom
            factor = m.factor
            if !m.description.isBlank { name = m.description }
            lookupMsg = "✓ Found: \(m.material)"
        } else {
            lookupMsg = "Still not found"
        }
    }

    private func save() {
        var c = item
        c.name = name.trimmed; c.barcode = barcode.trimmed; c.material = material.trimmed; c.shelf = shelf.trimmed
        c.uom = uom.trimmed.ifBlank("EA")
        c.baseUom = baseUom
        c.factor = c.uom.caseInsensitiveCompare(baseUom) == .orderedSame ? 1 : factor
        c.stockType = stockType.trimmed; c.storageLoc = storageLoc.trimmed
        c.quantity = parseQty(qty) ?? 0
        c.zeroCount = zeroCount
        onSave(c)
    }
}

struct UploadSettingsView: View {
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = Uploader.Config.url
    @State private var key = Uploader.Config.key
    @State private var device = Uploader.Config.device

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Counts are sent to the Stock Count server on the store network, which builds one Excel file per branch and storage location. The iPhone must be on the store Wi-Fi. Counting itself works offline.")) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Server URL").font(.caption).foregroundColor(.secondary)
                        TextField("http://…", text: $url).keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Key").font(.caption).foregroundColor(.secondary)
                        SecureField("Key", text: $key)   // shown as dots, like a password
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Device name").font(.caption).foregroundColor(.secondary)
                        TextField("Device name", text: $device).autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }
            }
            .navigationTitle("Upload settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundColor(.white) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Uploader.Config.url = url
                        Uploader.Config.key = key
                        Uploader.Config.device = device.fileSafe
                        onSaved()
                    }
                    .foregroundColor(.white)
                    .disabled(!(url.hasPrefix("http://") || url.hasPrefix("https://")) || key.isBlank || device.isBlank)
                }
            }
            .toolbarBackground(brand, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "barcode.viewfinder").font(.system(size: 36)).foregroundColor(brand)
            Text("Stock Count").font(.title2.bold())
            Text("Version \(appVersion)")
            Text("Powered by GGHL")
            Image("DeveloperPhoto")
                .resizable().scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .overlay(Circle().stroke(brand, lineWidth: 2))
                .padding(.top, 6)
            Text("Developed by Bilal").fontWeight(.semibold)
            Text("© \(copyrightYears) Bilal. All rights reserved.").font(.footnote)
            Button("OK") { dismiss() }.buttonStyle(.borderedProminent).tint(brand).padding(.top, 12)
        }
        .padding(32)
        .presentationDetents([.medium])
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
