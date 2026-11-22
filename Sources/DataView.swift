import SwiftUI
import AppKit

struct DataRow {
    let i: Int
    let cells: [String]
}

extension BackupKind {
    var color: Color {
        switch self {
        case .messages: return .green
        case .whatsapp: return .mint
        case .contacts: return .gray
        case .notes: return Color(red: 0.95, green: 0.66, blue: 0.08)   // amber: white stays readable on it
        case .calendar: return .red
        case .calls: return .teal
        case .safari: return .blue
        case .files: return .brown
        }
    }
}

extension DeviceManager {
    var dataGroup: DataGroup? { data?.groups.first { $0.id == dataGroupID } }

    func openData(_ kind: BackupKind) {
        dataKind = kind
        data = nil
        let kept = dataReader
        dataNeedsPassword = false
        dataUnlocking = dataPassword != nil && kept == nil
        dataRows = []
        dataGeneration += 1
        dataSearch = ""
        dataMessage = ""
        dataGroupID = nil
        dataToken += 1
        let token = dataToken
        let folder = backupFolder
        let password = dataPassword
        Task.detached(priority: .userInitiated) {
            let list = Backup.existing(in: folder)
            var result = BackupData()
            var reader: BackupReader?
            var source = ""
            var needs = false, wrong = false
            if let entry = list.first {
                source = "From the \(entry.encrypted ? "encrypted " : "")backup of \(entry.deviceName)"
                    + (entry.date.map { " made \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                if let kept, kept.folder == entry.path { reader = kept }
                else {
                    switch BackupReader.open(folder: entry.path, password: password) {
                    case .ready(let r): reader = r
                    case .needsPassword: needs = true
                    case .wrongPassword: needs = true; wrong = true
                    case .unreadable: result.note = "This backup could not be opened. It may be unfinished: run the backup again."
                    }
                }
                if let reader { result = reader.load(kind) }
            } else {
                result.note = "There is no backup yet. Make one on the Backups screen, then come back here."
            }
            let final = result, finalReader = reader, finalSource = source, finalNeeds = needs, finalWrong = wrong
            await MainActor.run {
                guard token == self.dataToken else { return }
                self.dataUnlocking = false
                self.dataNeedsPassword = finalNeeds
                self.dataPasswordWrong = finalWrong
                if finalNeeds { self.dataPassword = nil }
                self.dataReader = finalReader
                self.dataSource = finalSource
                self.data = final
                self.dataGroupID = final.groups.first?.id
                self.rebuildDataRows()
            }
        }
    }

    func rebuildDataRows() {
        let q = dataSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = dataGroup?.rows ?? []
        var out: [DataRow] = []
        out.reserveCapacity(rows.count)
        for (i, r) in rows.enumerated() where q.isEmpty || r.contains(where: { $0.lowercased().contains(q) }) {
            out.append(DataRow(i: i, cells: r))
        }
        dataRows = out
        dataGeneration += 1
    }

    nonisolated static func safeName(_ s: String) -> String {
        let cleaned = s.map { "/:\\\n\r".contains($0) ? "-" : $0 }
        let name = String(cleaned).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Untitled" : String(name.prefix(80))
    }

    /// Saves the open conversation as a web page with its photos and files, and shows it in Finder.
    func saveWebPage(to folder: URL) {
        guard let group = dataGroup, let reader = dataReader, let kind = dataKind else { return }
        dataMessage = "Saving…"
        Task.detached {
            let page = reader.webPage(group, title: kind.title, into: folder)
            let attached = group.media.values.reduce(0) { $0 + $1.count }
            await MainActor.run {
                if let page {
                    self.dataMessage = attached > 0 ? "Saved, with its attachments that are in the backup." : "Saved."
                    NSWorkspace.shared.activateFileViewerSelecting([page])
                } else { self.dataMessage = "The page could not be written to that folder." }
            }
        }
    }

    /// Writes one sheet, or every sheet, as spreadsheet files. Never overwrites.
    func saveSpreadsheets(all: Bool, to folder: URL) {
        guard let data, let kind = dataKind else { return }
        let groups = all ? data.groups : (dataGroup.map { [$0] } ?? [])
        dataMessage = "Saving…"
        Task.detached {
            var target = folder
            if groups.count > 1 {
                target = Exporter.uniqueURL(for: folder.appendingPathComponent(kind.title), avoiding: [])
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            }
            var written: [URL] = []
            var reserved = Set<String>()
            for g in groups {
                let name = groups.count > 1 ? DeviceManager.safeName(g.title) : "\(kind.title) - \(DeviceManager.safeName(g.title))"
                var url = target.appendingPathComponent(name + ".csv")
                if FileManager.default.fileExists(atPath: url.path) || reserved.contains(url.path) { url = Exporter.uniqueURL(for: url, avoiding: reserved) }
                reserved.insert(url.path)
                // The leading mark makes spreadsheet apps read accents and emoji correctly.
                if (try? Data(("\u{FEFF}" + BackupReader.csv(g)).utf8).write(to: url)) != nil { written.append(url) }
            }
            let done = written, shown = groups.count > 1 ? [target] : written
            await MainActor.run {
                self.dataMessage = done.count == groups.count ? "Saved \(done.count) spreadsheet file\(done.count == 1 ? "" : "s")."
                                                              : "Saved \(done.count) of \(groups.count). The rest could not be written."
                if !done.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(shown) }
            }
        }
    }

    func extractDataSelection(to folder: URL) {
        guard let group = dataGroup, let reader = dataReader, !dataSelection.isEmpty else { return }
        let rows = dataSelection.sorted()
        dataMessage = "Copying \(rows.count) file\(rows.count == 1 ? "" : "s")…"
        Task.detached {
            let written = reader.extract(group, rows: rows, to: folder)
            await MainActor.run {
                self.dataMessage = written.count == rows.count ? "Copied \(written.count) file\(written.count == 1 ? "" : "s") to “\(folder.lastPathComponent)”."
                                                               : "Copied \(written.count) of \(rows.count). The rest could not be copied."
                if !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(written) }
            }
        }
    }
}

struct BackupDataView: View {
    @ObservedObject var m: DeviceManager
    @State private var groupSearch = ""
    @State private var typed = ""

    private func unlock() {
        guard !typed.isEmpty, let kind = m.dataKind else { return }
        m.dataPassword = typed
        typed = ""
        m.openData(kind)
    }

    private var kind: BackupKind { m.dataKind ?? .messages }
    private var groups: [DataGroup] {
        let all = m.data?.groups ?? []
        let q = groupSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }
    private var columns: [FastColumn<DataRow>] {
        let names = m.dataGroup?.columns ?? []
        return names.enumerated().map { n, title in
            let wide = n == names.count - 1 && names.count > 2 || (kind == .files && n == 1)
            return FastColumn(id: "\(n)", title: title, width: wide ? 520 : (title.contains("Date") || title == "Starts" || title == "Ends" ? 150 : 200),
                              minWidth: 80, secondary: n > 0 && !wide, sortable: false, text: { $0.cells.indices.contains(n) ? $0.cells[n] : "" })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                IconTile(symbol: kind.symbol, color: kind.color, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(m.dataSource.isEmpty ? "Read from your latest backup. Nothing on the device or in the backup is changed." : "\(m.dataSource). Nothing in it is changed.")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            Divider()

            if m.data == nil {
                Spacer()
                ProgressView().controlSize(.large)
                Text(m.dataUnlocking ? "Unlocking the backup… this takes a few seconds." : "Reading the backup…")
                    .font(.title3).foregroundStyle(.secondary).padding(.top, 10)
                Spacer()
            } else if m.dataNeedsPassword {
                Spacer()
                Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(Theme.accent)
                Text("This backup is protected by a password").font(.title2.weight(.semibold)).padding(.top, 10)
                Text("Enter the backup password you chose when encrypted backups were turned on for this device. It is not your Apple Account password, and it is not saved by this app.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440).padding(.top, 2)
                HStack(spacing: 10) {
                    SecureField("Backup password", text: $typed).textFieldStyle(.roundedBorder).frame(width: 240).onSubmit { unlock() }
                    Button("Unlock") { unlock() }.buttonStyle(PrimaryButtonStyle()).disabled(typed.isEmpty)
                }
                .padding(.top, 12)
                if m.dataPasswordWrong {
                    Label("That password did not open the backup. Check it and try again.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange).padding(.top, 8)
                }
                Spacer()
            } else if let note = m.data?.note, !note.isEmpty {
                Spacer()
                Image(systemName: "tray").font(.system(size: 44)).foregroundStyle(.tertiary)
                Text(note).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480).padding(.top, 10)
                Button { m.selection = "nav_backup" } label: { Label("Open Backups", systemImage: "clock.arrow.circlepath") }
                    .buttonStyle(SoftButtonStyle()).padding(.top, 14)
                Spacer()
            } else {
                HStack(spacing: 0) {
                    if (m.data?.groups.count ?? 0) > 1 { groupList.frame(width: 250); Divider() }
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search in \(m.dataGroup?.title ?? kind.title)", text: $m.dataSearch).textFieldStyle(.plain)
                            Text("\(Fmt.count(m.dataRows.count)) shown").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        Divider()
                        FastTable(rows: m.dataRows, generation: m.dataGeneration, rowID: { $0.i }, columns: columns, selection: $m.dataSelection,
                                  menu: { rows in
                                      [FastMenuItem(title: "Copy Text", symbol: "doc.on.doc") {
                                          NSPasteboard.general.clearContents()
                                          NSPasteboard.general.setString(rows.map { $0.cells.joined(separator: "\t") }.joined(separator: "\n"), forType: .string)
                                      }]
                                  })
                            .id(m.dataGroup?.columns.count ?? 0)
                    }
                }
                bar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(kind.title)
    }

    private var groupList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Find in \(Fmt.count(m.data?.groups.count ?? 0)) \(kind.groupWord)", text: $groupSearch).textFieldStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(groups) { g in
                        Button { m.dataGroupID = g.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(g.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    if !g.subtitle.isEmpty && g.subtitle != g.title {
                                        Text(g.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 4)
                                Text(Fmt.count(g.rows.count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(m.dataGroupID == g.id ? Theme.accent.opacity(0.22) : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Text(m.dataMessage.isEmpty ? (kind == .files ? (m.dataSelection.isEmpty ? "Select files to copy them out of the backup." : "\(m.dataSelection.count) selected")
                                                         : "Save as a spreadsheet file that opens in Numbers or Excel.")
                                       : m.dataMessage)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if kind == .files {
                Button { pickFolder("Copy Here") { m.extractDataSelection(to: $0) } } label: { Label("Copy \(m.dataSelection.count) to Mac…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(m.dataSelection.isEmpty)
            } else {
                if (m.data?.groups.count ?? 0) > 1 {
                    Button { pickFolder("Save Here") { m.saveSpreadsheets(all: true, to: $0) } } label: { Label("Save All…", systemImage: "square.and.arrow.down.on.square") }
                        .buttonStyle(SoftButtonStyle())
                }
                if kind == .messages || kind == .whatsapp {
                    Button { pickFolder("Save Here") { m.saveWebPage(to: $0) } } label: { Label("Save as Web Page…", systemImage: "doc.richtext") }
                        .buttonStyle(SoftButtonStyle()).disabled(m.dataGroup == nil)
                        .help("A page you can open in any browser, with the photos and files from this chat")
                }
                Button { pickFolder("Save Here") { m.saveSpreadsheets(all: false, to: $0) } } label: { Label("Save This…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(m.dataGroup == nil)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.bgDeep.opacity(liquidGlass ? 0.6 : 0)))
        .glassSurface(RoundedRectangle(cornerRadius: 26, style: .continuous), fallback: Theme.surface.opacity(0.97))
        .shadow(color: .black.opacity(liquidGlass ? 0 : 0.4), radius: 18, y: 6)
        .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 6)
    }

    private func pickFolder(_ prompt: String, then: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = "Choose a folder on your Mac or an external drive."
        if panel.runModal() == .OK, let url = panel.url { then(url) }
    }
}
