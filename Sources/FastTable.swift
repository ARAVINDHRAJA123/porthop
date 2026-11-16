import SwiftUI
import AppKit
import UniformTypeIdentifiers

// A native table that only builds the rows on screen, so 100,000 items scroll as easily as 100.
// (SwiftUI's own Table creates a view per row up front and locks the app on large albums.)

struct FastColumn<Row> {
    let id: String
    let title: String
    var width: CGFloat = 120
    var minWidth: CGFloat = 60
    var secondary = false
    var digits = false
    var sortable = true
    let text: (Row) -> String
    var icon: ((Row) -> (symbol: String, color: NSColor))? = nil
}

struct FastMenuItem {
    let title: String
    let symbol: String
    let action: () -> Void
}

final class KeyTableView: NSTableView {
    var onSpace: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { onSpace?() } else { super.keyDown(with: event) }
    }
}

struct FastTable<Row, ID: Hashable>: NSViewRepresentable {
    let rows: [Row]
    let generation: Int
    let rowID: (Row) -> ID
    let columns: [FastColumn<Row>]
    @Binding var selection: Set<ID>
    var sortColumn: String? = nil
    var sortAscending = true
    var onSort: ((String, Bool) -> Void)? = nil
    var onOpen: ((Row) -> Void)? = nil
    var onSpace: ((Row) -> Void)? = nil
    var menu: (([Row]) -> [FastMenuItem])? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.rowHeight = 26
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for c in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.minWidth
            if c.sortable { col.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: true) }
            table.addTableColumn(col)
        }
        let coord = context.coordinator
        table.dataSource = coord
        table.delegate = coord
        table.target = coord
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.onSpace = { [weak coord] in coord?.spacePressed() }
        let menu = NSMenu()
        menu.delegate = coord
        table.menu = menu
        coord.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FastTable
        weak var table: NSTableView?
        private var rows: [Row] = []
        private var index: [ID: Int] = [:]
        private var generation = Int.min
        private var applied: Set<ID>? = nil
        private var updating = false
        private var menuActions: [() -> Void] = []
        private var symbols: [String: NSImage] = [:]
        private lazy var columnMap: [String: FastColumn<Row>] = Dictionary(parent.columns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        init(_ parent: FastTable) { self.parent = parent }

        func update(_ new: FastTable) {
            parent = new
            guard let table else { return }
            updating = true
            defer { updating = false }
            if new.generation != generation {
                generation = new.generation
                rows = new.rows
                index.removeAll(keepingCapacity: true)
                index.reserveCapacity(rows.count)
                for (i, r) in rows.enumerated() { index[new.rowID(r)] = i }
                table.reloadData()
                applied = nil
            }
            if let key = new.sortColumn {
                let cur = table.sortDescriptors.first
                if cur?.key != key || cur?.ascending != new.sortAscending {
                    table.sortDescriptors = [NSSortDescriptor(key: key, ascending: new.sortAscending)]
                }
            }
            if applied != new.selection {
                var set = IndexSet()
                for id in new.selection { if let i = index[id] { set.insert(i) } }
                table.selectRowIndexes(set, byExtendingSelection: false)
                applied = new.selection
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < rows.count, let col = columnMap[tableColumn.identifier.rawValue] else { return nil }
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSTableCellView) ?? makeCell(col, id: tableColumn.identifier)
            let item = rows[row]
            cell.textField?.stringValue = col.text(item)
            if let icon = col.icon {
                let (name, color) = icon(item)
                cell.imageView?.image = symbol(name)
                cell.imageView?.contentTintColor = color
            }
            return cell
        }

        private func symbol(_ name: String) -> NSImage? {
            if let hit = symbols[name] { return hit }
            let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            symbols[name] = img
            return img
        }

        private func makeCell(_ col: FastColumn<Row>, id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = col.icon != nil ? .byTruncatingMiddle : .byTruncatingTail
            text.font = col.digits ? .monospacedDigitSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 13)
            text.textColor = col.secondary ? .secondaryLabelColor : .labelColor
            cell.addSubview(text)
            cell.textField = text
            var leading = cell.leadingAnchor
            var gap: CGFloat = 2
            if col.icon != nil {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyDown
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 18),
                    image.heightAnchor.constraint(equalToConstant: 16)
                ])
                leading = image.trailingAnchor
                gap = 6
            }
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: leading, constant: gap),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            var ids = Set<ID>()
            for i in table.selectedRowIndexes where i < rows.count { ids.insert(parent.rowID(rows[i])) }
            applied = ids
            if parent.selection != ids { parent.selection = ids }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let d = tableView.sortDescriptors.first, let key = d.key else { return }
            parent.onSort?(key, d.ascending)
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            parent.onOpen?(rows[table.clickedRow])
        }

        func spacePressed() {
            guard let table, let i = table.selectedRowIndexes.first, i < rows.count else { return }
            (parent.onSpace ?? parent.onOpen)?(rows[i])
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            menuActions = []
            guard let table, let build = parent.menu, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            let target = table.selectedRowIndexes.contains(table.clickedRow) ? table.selectedRowIndexes : IndexSet(integer: table.clickedRow)
            for item in build(target.filter { $0 < rows.count }.map { rows[$0] }) {
                let mi = NSMenuItem(title: item.title, action: #selector(menuAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = menuActions.count
                mi.image = symbol(item.symbol)
                menuActions.append(item.action)
                menu.addItem(mi)
            }
        }

        @objc func menuAction(_ sender: NSMenuItem) {
            if sender.tag < menuActions.count { menuActions[sender.tag]() }
        }
    }
}

// MARK: - Photo list

struct AssetTable: View {
    @ObservedObject var m: DeviceManager

    private static let columns: [FastColumn<PhotoAsset>] = [
        FastColumn(id: SortField.name.rawValue, title: "Name", width: 200, minWidth: 140,
                   text: { $0.isFavorite ? "\($0.filename)  ♥" : $0.filename },
                   icon: { ($0.isVideo ? "video.fill" : ($0.isLivePhoto ? "livephoto" : "photo.fill"), $0.isVideo ? .systemPurple : .systemBlue) }),
        FastColumn(id: SortField.kind.rawValue, title: "Kind", width: 110, secondary: true,
                   text: { $0.durationText.isEmpty ? $0.kindText : "\($0.kindText) · \($0.durationText)" }),
        FastColumn(id: SortField.size.rawValue, title: "Size", width: 84, digits: true, text: { $0.sizeText }),
        FastColumn(id: SortField.resolution.rawValue, title: "Dimensions", width: 110, secondary: true, digits: true, text: { $0.dimensionsText }),
        FastColumn(id: SortField.date.rawValue, title: "Date", width: 185, minWidth: 120, digits: true, text: { $0.dateText }),
        FastColumn(id: SortField.originalName.rawValue, title: "Original Name", width: 150, secondary: true, text: { $0.originalFilename }),
        FastColumn(id: SortField.folder.rawValue, title: "iPhone Folder", width: 130, secondary: true, text: { $0.directory })
    ]

    var body: some View {
        FastTable(rows: m.visibleAssets, generation: m.visibleGeneration, rowID: { $0.id }, columns: Self.columns,
                  selection: $m.selectedIDs, sortColumn: m.sortField.rawValue, sortAscending: m.sortAscending,
                  onSort: { key, asc in if let f = SortField(rawValue: key) { m.setSort(f, ascending: asc) } },
                  onOpen: { m.previewAsset = $0 },
                  menu: { rows in
                      var items: [FastMenuItem] = []
                      if rows.count == 1, let a = rows.first {
                          items.append(FastMenuItem(title: "Quick Look", symbol: "eye") { m.previewAsset = a })
                          items.append(FastMenuItem(title: "Copy Filename", symbol: "doc.on.doc") {
                              NSPasteboard.general.clearContents()
                              NSPasteboard.general.setString(a.filename, forType: .string)
                          })
                      }
                      if !rows.isEmpty {
                          items.append(FastMenuItem(title: "Export \(Fmt.count(rows.count)) Item\(rows.count == 1 ? "" : "s")…", symbol: "square.and.arrow.down") {
                              m.selectedIDs = Set(rows.map(\.id))
                              m.requestExport(selectedOnly: true)
                          })
                      }
                      return items
                  })
    }
}

// MARK: - File browser (media area and apps' shared folders)

struct FilesView: View {
    @ObservedObject var m: DeviceManager
    @State private var dropTargeted = false
    @State private var askFolderName = false
    @State private var folderName = ""

    private var isApp: Bool { m.canAddFiles }
    private var title: String { m.isAndroid ? "Phone Storage" : (m.currentApp?.name ?? "Media Files") }

    private var crumbs: [(name: String, path: String)] {
        var out: [(String, String)] = [(isApp && !m.isAndroid ? title : m.deviceKind, m.afcRoot)]
        let rel = m.afcPath.hasPrefix(m.afcRoot) ? String(m.afcPath.dropFirst(m.afcRoot.count)) : m.afcPath
        var acc = m.afcRoot == "/" ? "" : m.afcRoot
        for part in rel.split(separator: "/") {
            acc += "/\(part)"
            out.append((String(part), acc))
        }
        return out
    }

    private static let columns: [FastColumn<AFCFileEntry>] = [
        FastColumn(id: "name", title: "Name", width: 380, minWidth: 200, sortable: false, text: { $0.name },
                   icon: { ($0.isDirectory ? "folder.fill" : "doc", $0.isDirectory ? .systemBlue : .secondaryLabelColor) }),
        FastColumn(id: "size", title: "Size", width: 100, secondary: true, digits: true, sortable: false, text: { $0.sizeText }),
        FastColumn(id: "date", title: "Modified", width: 190, secondary: true, digits: true, sortable: false, text: { $0.modifiedDate })
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconTile(symbol: isApp && !m.isAndroid ? "app.fill" : "folder.fill", color: m.isAndroid ? .green : (isApp ? .mint : .gray), size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(m.isAndroid ? "Everything in the device's shared storage: Camera (DCIM), Pictures, Download and more. Drag files in, or copy them out to your Mac."
                         : isApp ? "Files you add here appear inside \(title) on your \(m.deviceKind). Drag files in, or copy them out to your Mac."
                               : "The media area iOS shares over USB. You can copy from here to your Mac, but not add to it. For photos, use the albums on the left.")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            HStack(spacing: 6) {
                Button { m.browseUp() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).disabled(!m.canBrowseUp)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                            if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
                            Button(c.name) { m.browse(c.path) }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: i == crumbs.count - 1 ? .semibold : .regular))
                                .foregroundStyle(i == crumbs.count - 1 ? Color.primary : Color.secondary)
                        }
                    }
                }
                Spacer()
                if m.afcLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()

            ZStack {
                FastTable(rows: m.afcEntries, generation: m.afcGeneration, rowID: { $0.path }, columns: Self.columns,
                          selection: $m.afcSelection,
                          onOpen: { if $0.isDirectory { m.browse($0.path) } },
                          menu: { rows in
                              var items: [FastMenuItem] = []
                              if rows.count == 1, let e = rows.first, e.isDirectory {
                                  items.append(FastMenuItem(title: "Open", symbol: "folder") { m.browse(e.path) })
                              }
                              items.append(FastMenuItem(title: "Copy \(rows.count) to Mac…", symbol: "square.and.arrow.down") {
                                  m.afcSelection = Set(rows.map(\.path))
                                  copyToMac()
                              })
                              return items
                          })
                if m.afcEntries.isEmpty && !m.afcLoading {
                    VStack(spacing: 8) {
                        Image(systemName: isApp ? "tray.and.arrow.down" : "folder").font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text("This folder is empty").font(.title3.weight(.semibold))
                        if isApp { Text("Drag files here from Finder, or click Add Files.").font(.callout).foregroundStyle(.secondary) }
                    }
                    .transition(.opacity)
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accent.opacity(0.12)))
                        .overlay(Label("Drop to add to \(title)", systemImage: "arrow.down.circle.fill")
                            .font(.title2.weight(.semibold)).foregroundStyle(Theme.accent))
                        .padding(12)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.15), value: dropTargeted)
            .onDrop(of: [UTType.fileURL], isTargeted: isApp ? $dropTargeted : .constant(false)) { providers in
                guard isApp, !m.afcBusy else { return false }
                var urls: [URL] = []
                let group = DispatchGroup()
                for p in providers {
                    group.enter()
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { urls.append(url) } }
                        DispatchQueue.main.async { group.leave() }
                    }
                }
                group.notify(queue: .main) { m.upload(urls) }
                return true
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bar }
        .navigationTitle(m.deviceName)
        .navigationSubtitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { m.browse(m.afcPath) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(m.afcBusy)
            }
        }
        .alert("New Folder", isPresented: $askFolderName) {
            TextField("Name", text: $folderName)
            Button("Create") { m.newFolder(named: folderName); folderName = "" }
            Button("Cancel", role: .cancel) { folderName = "" }
        } message: {
            Text(m.isAndroid ? "Creates a folder here on your \(m.deviceKind)." : "Creates a folder inside \(title) on your \(m.deviceKind).")
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            if m.afcBusy { ProgressView().controlSize(.small) }
            else if !m.afcMessage.isEmpty {
                Image(systemName: m.afcMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(m.afcMessageIsError ? Color.orange : Color.green)
            }
            Text(m.afcMessage.isEmpty ? (m.afcSelection.isEmpty ? "Select items to copy them to your Mac." : "\(m.afcSelection.count) selected")
                                      : m.afcMessage)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            if m.afcBusy {
                Button("Stop") { m.stopTransfer() }.buttonStyle(SoftButtonStyle())
            } else {
                if isApp {
                    Button { askFolderName = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                        .buttonStyle(SoftButtonStyle())
                    Button { addFiles() } label: { Label("Add Files…", systemImage: "plus") }
                        .buttonStyle(m.afcSelection.isEmpty ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SoftButtonStyle()))
                }
                if !m.afcSelection.isEmpty || !isApp {
                    Button { copyToMac() } label: { Label("Copy \(m.afcSelection.count) to Mac…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(m.afcSelection.isEmpty || m.isExporting)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
            .shadow(color: .black.opacity(0.22), radius: 18, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
        .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: m.afcBusy)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: m.afcSelection.isEmpty)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose files or folders to add to \(title)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { m.upload(panel.urls) }
    }

    private func copyToMac() {
        let panel = NSOpenPanel()
        panel.title = "Choose where to save on your Mac"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        if panel.runModal() == .OK, let url = panel.url { m.downloadAFCSelection(to: url) }
    }
}

struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
