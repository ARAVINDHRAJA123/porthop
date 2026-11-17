import SwiftUI
import AppKit

// MARK: - Device pill

struct DevicePill: View {
    @ObservedObject var m: DeviceManager
    @State private var open = false
    private var loading: Bool { if case .loading = m.phase { return true }; return false }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 7) {
                Circle().fill(m.isReady ? Theme.success : (loading ? Theme.warning : Theme.faint)).frame(width: 7, height: 7)
                Text(m.isReady || loading ? m.deviceName : "No device").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .toolbarChrome()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!m.isReady)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if m.devices.count > 1 {
                    Text("Connected devices").font(.caption.weight(.semibold)).foregroundStyle(Theme.faint).padding(.horizontal, 8)
                    ForEach(m.devices, id: \.udid) { d in
                        row(m.deviceNames[d.udid] ?? "Device", d.udid == m.device?.udid ? "checkmark.circle.fill" : "circle") { m.switchDevice(to: d.udid) }
                    }
                    Divider().padding(.vertical, 4)
                }
                row("Battery and device details", "heart.text.square") { m.selection = "nav_device" }
                if !m.isAndroid { row("Backups", "clock.arrow.circlepath") { m.selection = "nav_backup" } }
                row(m.isAndroid ? "Phone storage" : "Media files", "folder") { m.selection = "nav_files" }
                Divider().padding(.vertical, 4)
                row("Refresh", "arrow.clockwise") { m.connect(silent: false) }.disabled(m.isExporting)
            }
            .padding(10)
            .frame(width: 250)
        }
    }

    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button { open = false; action() } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(Theme.accentLight)
                Text(title).foregroundStyle(Theme.text)
                Spacer()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Ask

/// What a typed request asks for. Everything is optional; whatever is recognised is shown back as chips.
struct AskIntent {
    var route: String?
    var album: String?
    var filter: MediaFilter?
    var range: ClosedRange<Date>?
    var minBytes: Int64 = 0
    var destination: Destination?
    var parts: [String] = []
    var isEmpty: Bool { route == nil && album == nil && filter == nil && range == nil && minBytes == 0 && destination == nil }
}

@MainActor
enum AskParser {
    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    static func parse(_ raw: String, _ m: DeviceManager) -> AskIntent {
        var i = AskIntent()
        let text = " " + raw.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }

        // Where it should go: "to T7", "into pictures".
        var body = text
        if let r = text.range(of: " (to|into|onto) ", options: [.regularExpression, .backwards]) {
            let target = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
            let options = Destinations.list(m)
            let hit = options.first { $0.name.lowercased() == target }
                ?? options.first { !target.isEmpty && ($0.name.lowercased().contains(target) || target.contains($0.name.lowercased())) }
                ?? (["mac", "this mac", "my mac", "pictures", "computer"].contains(target) ? options.first { $0.kind == .pictures } : nil)
            if let hit, !hit.readOnly {
                i.destination = hit
                body = String(text[..<r.lowerBound]) + " "
            }
        }
        func says(_ words: String...) -> Bool { words.contains { body.contains($0) } }

        // Things that are places in the app rather than photos.
        let routes: [(String, [String])] = [
            ("bk:whatsapp", ["whatsapp"]), ("bk:messages", ["message", "imessage", " sms", "texts"]), ("bk:contacts", ["contact"]),
            ("bk:notes", [" note"]), ("bk:calendar", ["calendar", "event"]), ("bk:calls", ["call log", "calls", "call history"]),
            ("bk:safari", ["safari", "bookmark", "browsing"]), ("nav_backup", ["back up", "backup", "restore"]),
            ("nav_device", ["battery", "health", "storage", "serial", "imei", "details"]), ("nav_files", ["files", "apps", "documents"])]

        // Which group of photos.
        let albumWords: [(String, [String])] = [
            ("smart_hidden", ["hidden"]), ("smart_screenshots", ["screenshot"]), ("smart_favorites", ["favorite", "favourite"]),
            ("smart_selfies", ["selfie"]), ("smart_live", ["live photo"]), ("smart_trashed", ["deleted", "trash"]),
            ("smart_all", ["everything", "all photos", "library", "all my"])]
        if !m.isAndroid {
            for (id, words) in albumWords where words.contains(where: { body.contains($0) }) { i.album = id; break }
            if i.album == nil, let a = m.userAlbums.first(where: { $0.title.count >= 3 && body.contains($0.title.lowercased()) }) { i.album = a.id }
        }
        if says("video", "movie", "clip") { if i.album == nil { i.album = "smart_videos" } else { i.filter = .videos } }
        if says("photo", "picture", "pic ") && !says("live photo") && i.album != nil { i.filter = i.filter ?? .photos }
        if says("heic") { i.filter = .heic }

        // When: "2024", "march 2025", "2023 to 2024", "last year", "this month".
        let cal = Calendar.current
        let now = Date()
        func year(_ y: Int) -> ClosedRange<Date>? {
            guard let s = cal.date(from: DateComponents(year: y, month: 1, day: 1)), let e = cal.date(from: DateComponents(year: y + 1, month: 1, day: 1)) else { return nil }
            return s...e.addingTimeInterval(-1)
        }
        func month(_ y: Int, _ mo: Int) -> ClosedRange<Date>? {
            guard let s = cal.date(from: DateComponents(year: y, month: mo, day: 1)), let e = cal.date(byAdding: .month, value: 1, to: s) else { return nil }
            return s...e.addingTimeInterval(-1)
        }
        let years = matches(#"\b(19|20)\d{2}\b"#, in: body).compactMap(Int.init)
        let thisYear = cal.component(.year, from: now)
        if let mi = months.firstIndex(where: { body.contains(" " + $0) || body.contains(" " + $0.prefix(3) + " ") }) {
            var y = years.first ?? thisYear
            if years.isEmpty, mi + 1 > cal.component(.month, from: now) { y -= 1 }
            i.range = month(y, mi + 1)
        } else if years.count >= 2, let a = year(min(years[0], years[1])), let b = year(max(years[0], years[1])) {
            i.range = a.lowerBound...b.upperBound
        } else if let y = years.first {
            i.range = year(y)
        } else if says("last year") {
            i.range = year(thisYear - 1)
        } else if says("this year") {
            i.range = year(thisYear)
        } else if says("last month"), let d = cal.date(byAdding: .month, value: -1, to: now) {
            i.range = month(cal.component(.year, from: d), cal.component(.month, from: d))
        } else if says("this month") {
            i.range = month(thisYear, cal.component(.month, from: now))
        }

        // How big: "over 100 MB", "bigger than 1 GB".
        if let s = firstGroups(#"(?:over|above|bigger than|larger than|more than|at least|>)\s*(\d+(?:\.\d+)?)\s*(kb|mb|gb)"#, in: body),
           let n = Double(s[0]) {
            let unit: Double = s[1] == "gb" ? 1_000_000_000 : (s[1] == "mb" ? 1_000_000 : 1_000)
            i.minBytes = Int64(n * unit)
        }

        let photoRequest = i.album != nil || i.filter != nil || i.range != nil || i.minBytes > 0
        if !photoRequest, let r = routes.first(where: { $0.1.contains(where: { body.contains($0) }) }) {
            if r.0.hasPrefix("bk:") || r.0 == "nav_backup" { if !m.isAndroid { i.route = r.0 } } else { i.route = r.0 }
        }
        if photoRequest && i.album == nil && !m.isAndroid { i.album = "smart_all" }

        // What was understood, in plain words.
        if let r = i.route { i.parts.append(routeName(r, m)) }
        if let a = i.album { i.parts.append((m.smartAlbums + m.userAlbums).first { $0.id == a }?.title ?? "Library") }
        if let f = i.filter { i.parts.append(f.rawValue) }
        if let r = i.range { i.parts.append(rangeText(r)) }
        if i.minBytes > 0 { i.parts.append("over \(Fmt.bytes(i.minBytes))") }
        if let d = i.destination { i.parts.append("to \(d.name)") }
        return i
    }

    static func rangeText(_ r: ClosedRange<Date>) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        let a = f.string(from: r.lowerBound), b = f.string(from: r.upperBound)
        return a == b ? a : "\(a) – \(b)"
    }

    private static func routeName(_ r: String, _ m: DeviceManager) -> String {
        switch r {
        case "nav_backup": return "Backups"
        case "nav_device": return "Device details"
        case "nav_files": return m.isAndroid ? "Phone Storage" : "Media Files"
        default: return BackupKind(rawValue: String(r.dropFirst(3)))?.title ?? r
        }
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    private static func firstGroups(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }

    /// Opens what the request describes. Photos open with the filters applied and the destination pre-picked.
    static func apply(_ i: AskIntent, _ m: DeviceManager) {
        if let r = i.route { m.selection = r; return }
        guard let album = i.album else { return }
        m.selection = album
        if let f = i.filter { m.mediaFilter = f }
        m.dateRange = i.range
        m.minBytes = i.minBytes
        if let d = i.destination { m.pendingDestination = d.url }
    }
}

struct AskField: View {
    @ObservedObject var m: DeviceManager
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Theme.accentLight)
            TextField("Ask PortHop: hidden videos from 2024 to T7", text: $text)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit {
                    let intent = AskParser.parse(text, m)
                    if !intent.isEmpty { AskParser.apply(intent, m); text = ""; focused.wrappedValue = false }
                }
                .onExitCommand { text = ""; focused.wrappedValue = false }
            if text.isEmpty {
                Text("⌘K").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
            } else {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }.buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(width: 400)
        .toolbarChrome(stroke: focused.wrappedValue ? Theme.accent.opacity(0.8) : Theme.line)
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(liquidGlass && focused.wrappedValue ? 0.7 : 0)))
        .disabled(!m.isReady)
    }
}

/// Appears under the ask field while typing: what was understood, and examples to try.
struct AskPanel: View {
    @ObservedObject var m: DeviceManager
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    private var examples: [String] {
        m.isAndroid ? ["battery", "files"] :
            ["hidden photos", "videos over 500 MB", "screenshots from \(Calendar.current.component(.year, from: Date()))",
             "favourites from last year to Pictures", "messages", "back up my iPhone"]
    }

    var body: some View {
        let intent = AskParser.parse(text, m)
        VStack(alignment: .leading, spacing: 10) {
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Try").font(.caption.weight(.semibold)).foregroundStyle(Theme.faint)
                FlowChips(items: examples.map { ($0, $0) }) { e in
                    text = e
                    let i = AskParser.parse(e, m)
                    if !i.isEmpty { AskParser.apply(i, m); text = ""; focused.wrappedValue = false }
                }
            } else if intent.isEmpty {
                Text("Not sure what to open. Try an album (hidden, videos, screenshots), a year, a size like “over 100 MB”, or “to” a drive.")
                    .font(.callout).foregroundStyle(Theme.secondary)
            } else {
                WrapLayout(spacing: 6) {
                    ForEach(intent.parts, id: \.self) { p in
                        Text(p).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.gradient))
                    }
                }
                Text("Press Return to open it").font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .padding(14)
        .frame(width: 520, alignment: .leading)
        // The panel floats over busy content, so the glass gets a dark backing to keep its text readable.
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.bgDeep.opacity(liquidGlass ? 0.6 : 0)))
        .glassSurface(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(liquidGlass ? 0.25 : 0.45), radius: 24, y: 10)
    }
}

// MARK: - Activity and settings

/// A small indicator in the top bar while something is copying, so it is visible from any screen.
struct ActivityBadge: View {
    @ObservedObject var m: DeviceManager
    var body: some View {
        if m.isExporting || m.backupRunning || m.afcBusy {
            Button {
                m.selection = m.backupRunning ? "nav_backup" : (m.isExporting ? "nav_home" : m.selection)
            } label: {
                HStack(spacing: 6) {
                    if m.isExporting {
                        ZStack {
                            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
                            Circle().trim(from: 0, to: m.progress.fraction).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                        }
                        .frame(width: 14, height: 14)
                        Text("\(Int(m.progress.fraction * 100))%").monospacedDigit()
                    } else if m.backupRunning, let p = m.backupPercent {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("\(Int(p * 100))%").monospacedDigit()
                    } else {
                        ProgressView().controlSize(.mini)
                        Text(m.backupRunning ? (m.restoring ? "Restoring" : "Backing up") : "Copying")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .toolbarChrome(stroke: Theme.accent.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("See what is copying")
        }
    }
}

struct SettingsMenu: View {
    @AppStorage("modernTransitions") private var modern = true
    var body: some View {
        Menu {
            Toggle("Animated screen transitions", isOn: $modern)
            Divider()
            Button("Open-Source Licences") {
                if let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses"), FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.open(url)
                } else if let url = URL(string: "https://github.com/ARAVINDHRAJA123/porthop") { NSWorkspace.shared.open(url) }
            }
            Picker("Appearance", selection: Binding(get: { UserDefaults.standard.string(forKey: Appearance.key) ?? "system" },
                                                     set: { UserDefaults.standard.set($0, forKey: Appearance.key); Appearance.apply($0) })) {
                Text("Match System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Divider()
            Button("PortHop on GitHub") {
                if let url = URL(string: "https://github.com/ARAVINDHRAJA123/porthop") { NSWorkspace.shared.open(url) }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 30, height: 26)
        .help("Settings and licences")
    }
}
