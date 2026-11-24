import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: Store

    // Header details, remembered between launches
    @AppStorage("branch") private var branch = ""
    @AppStorage("shelf") private var shelf = ""
    @AppStorage("storageLoc") private var storageLoc = ""
    @AppStorage("stockType") private var stockType = ""
    @AppStorage("planDate") private var planDate = ""
    @AppStorage("theme") private var theme = "system"

    @State private var page = 0
    @State private var detailsOpen = false
    @State private var search = ""

    // The item just scanned, waiting for its quantity (not saved yet)
    @State private var current: Item?
    @State private var currentQty = ""
    @State private var currentZero = false
    @State private var alreadyCounted: Decimal?
    @FocusState private var qtyFocused: Bool

    // Quantities typed on the Counted page but not saved yet (line id -> text)
    @State private var drafts: [Int64: String] = [:]

    @State private var scanning = false
    @State private var typing = false
    @State private var typedCode = ""
    @State private var editing: Item?
    @State private var notFound: Item?
    @State private var deleting: Item?
    @State private var confirmClear = false
    @State private var showSettings = false
    @State private var showAbout = false

    enum Picking { case materials, merge }
    @State private var picking: Picking?
    @State private var pickerOpen = false

    @State private var uploading = false
    @State private var resultBox: ResultBox?
    @State private var shareFiles: ShareFiles?
    @State private var toast: String?
    @State private var toastId = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $page) {
                    Text("Count").tag(0)
                    Text("Counted (\(store.items.count))").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)

                TabView(selection: $page) {
                    countPage.tag(0)
                    countedPage.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomBar
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarBackground(brand, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .tint(brand)
        .overlay(alignment: .bottom) { toastView }
        .overlay { if uploading { uploadingView } }
        .onAppear { if branch.isBlank { detailsOpen = true } }
        .fullScreenCover(isPresented: $scanning) {
            ScannerView(onResult: { code in scanning = false; handleScan(code) }, onClose: { scanning = false })
        }
        .sheet(item: $editing) { item in
            EditItemView(item: item, title: "Edit item", notFoundCode: nil,
                         onSave: { changed in
                             editing = nil
                             var c = changed
                             if c.quantity > 0 { c.zeroCount = false }
                             store.save(c)
                             notify("✓ Saved \(c.label())  →  \(fmtQty(c.quantity)) \(c.uom)")
                         },
                         onDelete: { editing = nil; deleting = item },
                         onCancel: { editing = nil })
                .environmentObject(store)
        }
        .sheet(item: $notFound) { item in
            EditItemView(item: item, title: "Barcode not found", notFoundCode: item.barcode,
                         onSave: { newItem in
                             notFound = nil
                             var n = newItem
                             n.id = 0
                             n.scannedAt = nowMillis()
                             store.save(n)
                             notify("✓ Added \(n.label())  →  \(fmtQty(n.quantity)) \(n.uom)")
                         },
                         onDelete: nil,
                         onCancel: { notFound = nil })
                .environmentObject(store)
        }
        .sheet(isPresented: $showSettings) { UploadSettingsView { showSettings = false; notify("Upload settings saved") } }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(item: $shareFiles) { s in ShareSheet(items: s.urls) }
        .fileImporter(isPresented: $pickerOpen,
                      allowedContentTypes: picking == .merge ? [xlsxType] : [xlsxType, .commaSeparatedText, .plainText, .data],
                      allowsMultipleSelection: picking == .merge) { result in
            handlePicked(result)
        }
        .alert("Type barcode", isPresented: $typing) {
            TextField("Barcode", text: $typedCode).keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Look up") {
                let code = typedCode.filter { !$0.isWhitespace }
                if !code.isEmpty { handleScan(code) }
            }
        }
        .alert("Start a new count?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Delete all", role: .destructive) { store.deleteAll(); drafts = [:] }
        } message: {
            Text("This deletes all \(store.items.count) items on this iPhone. Export first if you need them.\n\nCounts already uploaded stay on the server. Only the administrator can clear them on the server.")
        }
        .alert("Delete item?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { item in
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { drafts[item.id] = nil; store.delete(item); deleting = nil }
        } message: { item in
            Text("\(item.label()) (\(fmtQty(item.quantity)) \(item.uom)) will be removed from this count.")
        }
        // Results (upload, export, merge) stay on screen until OK is tapped.
        .alert(resultBox?.title ?? "", isPresented: Binding(get: { resultBox != nil }, set: { if !$0 { resultBox = nil } }), presenting: resultBox) { box in
            if !box.files.isEmpty {
                Button("Share") { let f = box.files; resultBox = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { shareFiles = ShareFiles(urls: f) } }
            }
            Button("OK", role: .cancel) { resultBox = nil }
        } message: { box in
            Text(box.text)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("Stock Count").font(.headline).foregroundColor(.white)
                    Text("v\(appVersion)").font(.caption).foregroundColor(.white.opacity(0.75))
                }
                let sub = [branch.isBlank ? nil : "Branch \(branch)", storageLoc.isBlank ? nil : "SLoc \(storageLoc)"]
                    .compactMap { $0 }.joined(separator: " · ")
                if !sub.isEmpty { Text(sub).font(.caption2).foregroundColor(.white.opacity(0.8)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button { exportExcel() } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Export Excel")
            Menu {
                Button { pick(.materials) } label: { Label("Upload material list", systemImage: "tray.and.arrow.down") }
                Button { exportExcel() } label: { Label("Export to Excel", systemImage: "square.and.arrow.up") }
                Button { upload() } label: { Label("Upload to server", systemImage: "icloud.and.arrow.up") }
                Button { pick(.merge) } label: { Label("Merge export files", systemImage: "arrow.triangle.merge") }
                Button { showSettings = true } label: { Label("Upload settings", systemImage: "gearshape") }
                Button {
                    theme = theme == "system" ? "light" : theme == "light" ? "dark" : "system"
                } label: { Label("Theme: \(theme == "light" ? "Light" : theme == "dark" ? "Dark" : "System")", systemImage: "circle.lefthalf.filled") }
                Divider()
                Button(role: .destructive) { confirmClear = true } label: { Label("Start new count", systemImage: "trash") }
                Button { showAbout = true } label: { Label("About", systemImage: "info.circle") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    // MARK: - Count page

    private var countPage: some View {
        ScrollView {
            VStack(spacing: 10) {
                headerCard
                Field(label: "Current shelf", text: $shelf)
                if let item = current {
                    currentCard(item)
                } else {
                    EmptyState(title: "Scan a barcode",
                               text: store.items.isEmpty ? "Tap Scan to start.\nUpload your material list first."
                                                         : "Tap Scan to count.\nSwipe left to see the \(store.items.count) counted items.")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation { detailsOpen.toggle() } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Header Details").font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                        if !detailsOpen {
                            Text("Branch \(branch.ifBlank("–"))  ·  Plan \(planDate.ifBlank("today"))  ·  SLoc \(storageLoc.ifBlank("–"))  ·  Type \(stockType.ifBlank("–"))")
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: detailsOpen ? "chevron.up" : "chevron.down").foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if detailsOpen {
                HStack(spacing: 10) {
                    Field(label: "Branch ID (Plant)", text: $branch)
                    Field(label: "Plan date (dd.mm.yyyy)", text: Binding(
                        get: { planDate },
                        set: { v in planDate = String(v.filter { $0.isNumber || $0 == "." }.prefix(10)) }),
                          keyboard: .decimalPad, error: !planDate.isEmpty && !isValidDate(planDate))
                }
                HStack(spacing: 10) {
                    Field(label: "Storage location", text: Binding(
                        get: { storageLoc },
                        set: { v in
                            storageLoc = v.uppercased()
                            if let t = stockTypeFor(storageLoc) { stockType = t }
                        }))
                    StockTypePicker(value: $stockType)
                }
                HStack {
                    Image(systemName: "shippingbox").foregroundColor(.secondary)
                    Text(store.materialCount == 0 ? "No material list loaded" : "Material list: \(store.materialCount) barcodes")
                        .font(.caption).foregroundColor(store.materialCount == 0 ? .red : .secondary)
                    Spacer()
                    Button { pick(.materials) } label: { Label("Upload materials", systemImage: "tray.and.arrow.down") }
                        .buttonStyle(.bordered).font(.caption)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func currentCard(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scanned").font(.subheadline.weight(.semibold)).foregroundColor(brand)
            Text(item.label()).font(.title3.weight(.semibold))
            let sub = [(!item.material.isEmpty && !item.name.isEmpty) ? item.material : nil, item.barcode.isEmpty ? nil : item.barcode]
                .compactMap { $0 }.joined(separator: "  ·  ")
            if !sub.isEmpty { Text(sub).font(.subheadline).foregroundColor(.secondary) }
            FlowTags(tags: [
                (item.uom, true),
                (item.unitHint(), false),
                (item.shelf.isEmpty ? "" : "Shelf \(item.shelf)", false),
                (item.storageLoc.isEmpty ? "" : "SLoc \(item.storageLoc)", false),
                (item.stockType.isEmpty ? "" : "Type \(item.stockType)", false),
            ].filter { !$0.0.isEmpty })
            if let a = alreadyCounted {
                Text("Already counted on this shelf: \(fmtQty(a)) \(item.uom). This count is saved as a separate line.")
                    .font(.caption).foregroundColor(teal)
            }
            TextField("Quantity (\(item.uom))", text: Binding(
                get: { currentQty },
                set: { v in currentQty = cleanQty(v); if (parseQty(currentQty) ?? 0) > 0 { currentZero = false } }))
                .font(.system(size: 28, weight: .bold))
                .keyboardType(.decimalPad)
                .focused($qtyFocused)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).stroke(qtyFocused ? brand : Color(.separator), lineWidth: qtyFocused ? 2 : 1))
            HStack {
                Toggle(isOn: Binding(get: { currentZero }, set: { v in currentZero = v; if v { currentQty = "0" } })) {
                    Text("Zero count")
                }
                .toggleStyle(CheckboxStyle())
                Spacer()
                Button("Cancel") { clearCurrent() }
                Button { if saveCurrent() { qtyFocused = false } } label: { Text("Save").bold().padding(.horizontal, 8) }
                    .buttonStyle(.borderedProminent).tint(brand)
                    .disabled(currentQty.isEmpty && !currentZero)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)).shadow(color: .black.opacity(0.08), radius: 4, y: 2))
    }

    // MARK: - Counted page

    private var countedPage: some View {
        let counted = store.items.sorted { $0.id > $1.id }   // newest first
        let shown = counted.filter { i in
            search.isBlank || i.name.localizedCaseInsensitiveContains(search) || i.barcode.contains(search) ||
                i.material.localizedCaseInsensitiveContains(search) || i.shelf.localizedCaseInsensitiveContains(search)
        }
        return ScrollView {
            LazyVStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Search counted items", text: $search)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) } }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
                HStack(spacing: 10) {
                    StatTile(label: "Items", value: String(shown.count))
                    StatTile(label: "Units", value: fmtQty(shown.reduce(Decimal(0)) { $0 + $1.quantity }))
                    StatTile(label: "Zero count", value: String(shown.filter(\.zeroCount).count))
                }
                if counted.isEmpty {
                    EmptyState(title: "Nothing counted yet", text: "Items appear here after you save their quantity.")
                }
                ForEach(shown) { item in
                    ItemCard(item: item,
                             qtyText: Binding(get: { drafts[item.id] ?? fmtQty(item.quantity) },
                                              set: { drafts[item.id] = cleanQty($0) }),
                             onStep: { step(item, $0) },
                             onZero: { checked in
                                 drafts[item.id] = nil
                                 var c = item
                                 c.zeroCount = checked
                                 if checked { c.quantity = 0 }
                                 store.save(c)
                             },
                             onDelete: { deleting = item },
                             onDone: { saveAll() },
                             onOpen: { drafts[item.id] = nil; editing = item })
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func step(_ item: Item, _ delta: Decimal) {
        let base = drafts[item.id].flatMap(parseQty) ?? item.quantity
        drafts[item.id] = nil
        var c = item
        c.quantity = max(0, base + delta)
        if c.quantity > 0 { c.zeroCount = false }
        store.save(c)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                let pending = drafts.count + (current != nil ? 1 : 0)
                BarButton(title: pending == 0 ? "Save" : "Save (\(pending))", icon: "checkmark", color: teal) { saveAll() }
                BarButton(title: "Lookup", icon: "magnifyingglass", color: Color(red: 0.87, green: 0.88, blue: 1), foreground: Color(red: 0.06, green: 0.08, blue: 0.31)) {
                    typedCode = ""; typing = true
                }
                BarButton(title: "Scan", icon: "barcode.viewfinder", color: brand) { scanning = true }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            Text("Powered by GGHL  ·  Developed by Bilal  ·  © \(copyrightYears) Bilal")
                .font(.caption2).foregroundColor(footerGrey)
                .padding(.bottom, 4)
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Actions

    private func notify(_ msg: String) {
        toastId += 1
        let id = toastId
        withAnimation { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { if toastId == id { withAnimation { toast = nil } } }
    }

    private var toastView: some View {
        Group {
            if let t = toast {
                Text(t).font(.subheadline).foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85)))
                    .padding(.horizontal, 16).padding(.bottom, 110)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { toast = nil }
            }
        }
    }

    private var uploadingView: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().scaleEffect(1.4)
                Text(uploadStatus).font(.subheadline).multilineTextAlignment(.center)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
        }
    }
    @State private var uploadStatus = ""

    private func clearCurrent() {
        current = nil; alreadyCounted = nil; currentQty = ""; currentZero = false; qtyFocused = false
    }

    /// Saves the scanned item with the typed quantity. Returns false if no quantity was entered.
    @discardableResult
    private func saveCurrent() -> Bool {
        guard let item = current else { return true }
        let q = parseQty(currentQty)
        if q == nil && !currentZero {
            notify("Enter the quantity for \(item.label())")
            return false
        }
        let qty = q ?? 0
        var line = item
        line.id = 0
        line.quantity = qty
        line.zeroCount = currentZero && qty == 0
        line.scannedAt = nowMillis()
        clearCurrent()
        store.save(line)
        notify("✓ Saved \(item.label())  →  \(fmtQty(qty)) \(item.uom)")
        return true
    }

    private func saveAll() {
        if current != nil {
            if !saveCurrent() { return }
            if drafts.isEmpty { hideKeyboard(); return }
        }
        var changed = 0
        for (id, text) in drafts {
            guard var item = store.items.first(where: { $0.id == id }), let q = parseQty(text) else { continue }
            if q != item.quantity {
                item.quantity = q
                if q > 0 { item.zeroCount = false }
                store.save(item)
                changed += 1
            }
        }
        drafts = [:]
        hideKeyboard()
        notify(changed > 0 ? "Saved · \(changed) quantities updated" : "Saved")
    }

    private func hideKeyboard() {
        qtyFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func handleScan(_ code: String) {
        // A previous scan still waiting: keep it if a quantity was typed, otherwise drop it.
        if current != nil {
            if !currentQty.isEmpty || currentZero { saveCurrent() } else { clearCurrent() }
        }
        let s = shelf.trimmed
        let m = store.material(barcode: code)
        let barcode = m?.barcode ?? code
        let lines = store.lines(for: barcode, shelf: s)
        let existing = lines.last
        if m != nil || existing != nil {
            var item: Item
            if let m = m {
                item = Item(name: m.description, barcode: barcode, material: m.material, shelf: s, quantity: 0, uom: m.uom,
                            stockType: stockType.trimmed, storageLoc: storageLoc.trimmed, baseUom: m.baseUom, factor: m.factor)
            } else {
                item = existing!
                item.id = 0; item.quantity = 0; item.zeroCount = false; item.scannedAt = 0
                item.shelf = s; item.stockType = stockType.trimmed; item.storageLoc = storageLoc.trimmed
            }
            current = item
            alreadyCounted = existing == nil ? nil : lines.reduce(Decimal(0)) { $0 + $1.quantity }
            currentQty = ""
            currentZero = false
            page = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { qtyFocused = true }
            return
        }
        // Unknown barcode -> the item page, so the barcode can be corrected or the details typed in.
        notFound = Item(barcode: code, shelf: s, stockType: stockType.trimmed, storageLoc: storageLoc.trimmed)
    }

    private func unitWarning(_ missing: [String]) -> String {
        if missing.isEmpty { return "" }
        return "\n\n⚠ No base unit in the material list for \(missing.prefix(3).joined(separator: ", "))" +
            (missing.count > 3 ? " +\(missing.count - 3) more" : "") + ". Import the list with BASE_UOM and FACTOR."
    }

    private func exportExcel() {
        if branch.isBlank || planDate.isBlank {
            detailsOpen = true; page = 0
            notify("Enter Branch ID and Plan date before exporting")
            return
        }
        if store.items.isEmpty { notify("Nothing counted yet, no file created"); return }
        let (list, missing) = store.withBaseUnits()
        do {
            let r = try Export.export(branch: branch.trimmed, planDate: planDate.trimmed, items: list)
            let slocs = r.slocs.map { $0.ifBlank("no SLoc") }.joined(separator: ", ")
            resultBox = ResultBox(title: "Exported",
                                  text: "\(r.piFiles.count) PI file\(r.piFiles.count > 1 ? "s" : "") (\(slocs)) + log saved in Files > On My iPhone > Stock Count." + unitWarning(missing),
                                  files: r.files)
        } catch {
            resultBox = ResultBox(title: "Export failed", text: error.localizedDescription, files: [])
        }
    }

    private func upload() {
        if !Uploader.Config.isSet { showSettings = true; return }
        if uploading { return }
        if branch.isBlank || planDate.isBlank {
            detailsOpen = true; page = 0
            notify("Enter Branch ID and Plan date before uploading")
            return
        }
        if store.items.isEmpty { notify("Nothing counted yet, nothing uploaded"); return }
        let (list, missing) = store.withBaseUnits()
        let b = branch.trimmed, p = planDate.trimmed
        uploading = true
        uploadStatus = "Uploading \(list.count) lines to the server…"
        Task {
            var sent = false
            var msg = ""
            // A busy server or a Wi-Fi hiccup: try up to 3 times before reporting a failure.
            for attempt in 1...3 {
                if attempt > 1 { uploadStatus = "Trying again (\(attempt) of 3)…" }
                do {
                    let n = try await Uploader.upload(planDate: p, branch: b, items: list)
                    sent = true
                    msg = "\(n) items uploaded to the server as \(Uploader.Config.device)." + unitWarning(missing)
                    break
                } catch {
                    msg = Uploader.describe(error) + (attempt > 1 ? "\n\n(Tried \(attempt) times.)" : "")
                    if !Uploader.retryable(error) || attempt == 3 { break }
                    try? await Task.sleep(nanoseconds: UInt64(5_000_000_000) * UInt64(attempt))
                }
            }
            // Keep a copy on this iPhone of exactly what was sent, whether the upload worked or not.
            let copy = Export.saveUploadCopy(branch: b, device: Uploader.Config.device, items: list, sent: sent)
            uploading = false
            resultBox = ResultBox(title: sent ? "Uploaded to server" : "Upload failed",
                                  text: msg + "\n\n" + (copy.map { "Copy saved on this iPhone:\n\($0)" } ?? "⚠ Could not save a copy on this iPhone."),
                                  files: [])
        }
    }

    private func pick(_ p: Picking) {
        picking = p
        DispatchQueue.main.async { pickerOpen = true }
    }

    private func handlePicked(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        func load(_ u: URL) throws -> Data {
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: u)
        }
        if picking == .merge {
            do {
                let files = try urls.map { (name: $0.lastPathComponent, data: try load($0)) }
                let res = try Export.merge(files: files, planDate: planDate.trimmed) { store.unitInfo(material: $0, uom: $1) }
                var text = "\(res.files) files, \(res.inputRows) lines → \(res.outputRows) PI lines in the base unit."
                if res.duplicates > 0 { text += "\n\(res.duplicates) lines were in more than one file and were counted once." }
                text += "\n\nSaved in Files > On My iPhone > Stock Count:\n" + res.piFiles.map(\.lastPathComponent).joined(separator: "\n")
                if !res.notConverted.isEmpty {
                    text += "\n\n⚠ Not converted (no base unit in the material list): " + res.notConverted.prefix(5).joined(separator: ", ") +
                        (res.notConverted.count > 5 ? " +\(res.notConverted.count - 5) more" : "") + ". These lines stay in the unit they were counted in."
                }
                if res.mixed { text += "\n\n⚠ You chose PI files and LOG/UPLOAD files together. If they come from the same device, its count is added twice." }
                resultBox = ResultBox(title: "Files merged", text: text, files: res.piFiles)
            } catch {
                notify("Merge failed: \(error.localizedDescription)")
            }
        } else {
            do {
                let r = Xlsx.toMaterials(try Xlsx.readRows(try load(urls[0])))
                if r.materials.isEmpty {
                    notify("No materials found. The file needs MATERIAL, BARCODE and UOM columns.")
                } else {
                    store.replaceMaterials(r.materials)
                    var msg = "Imported \(r.materials.count) barcodes"
                    if r.skipped > 0 { msg += " (\(r.skipped) rows skipped, missing material or barcode)" }
                    if !r.materials.contains(where: { !$0.baseUom.isBlank }) {
                        msg += ". ⚠ No BASE_UOM/FACTOR columns: OTR, CAR etc. cannot be converted to the base unit"
                    }
                    notify(msg)
                }
            } catch {
                notify("Import failed: \(error.localizedDescription)")
            }
        }
    }
}

let xlsxType = UTType(filenameExtension: "xlsx") ?? .spreadsheet

struct ResultBox: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let files: [URL]
}

struct ShareFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
}
