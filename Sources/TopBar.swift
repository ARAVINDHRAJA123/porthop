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
                row("Screen", "rectangle.on.rectangle") { m.selection = "nav_screen" }
                row("Apps", "square.grid.2x2") { m.selection = "nav_apps" }
                if !m.isAndroid { row("Music & ringtones", "music.note") { m.selection = "nav_music" } }
                row("Spyware check", "checkmark.shield") { m.selection = "nav_check" }
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
extension AskContext {
    @MainActor init(_ m: DeviceManager) {
        self.init(isAndroid: m.isAndroid, albums: m.allAlbums.map { ($0.id, $0.title) },
                  userAlbums: m.userAlbums.map { ($0.id, $0.title) }, people: m.peopleAlbums.map { ($0.id, $0.title) },
                  destinations: Destinations.list(m))
    }
}

extension AskParser {
    @MainActor static func parse(_ raw: String, _ m: DeviceManager) -> AskIntent { parse(raw, AskContext(m)) }

    /// Opens what the request describes. Photos open with the filters applied and the destination pre-picked.
    @MainActor static func apply(_ i: AskIntent, _ m: DeviceManager) {
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

/// Shown when GitHub has a newer release.
struct UpdateBadge: View {
    @ObservedObject var m: DeviceManager
    var body: some View {
        if let r = m.update {
            Button { m.offerUpdate() } label: {
                Label(m.updateStatus.isEmpty ? "Update to \(r.version)" : m.updateStatus, systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .toolbarChrome(stroke: Theme.accent.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!m.updateStatus.isEmpty)
            .help("A newer PortHop is available")
        }
    }
}

struct SettingsMenu: View {
    @ObservedObject var m: DeviceManager
    @AppStorage("modernTransitions") private var modern = true
    @AppStorage("autoUpdateCheck") private var autoUpdate = true
    var body: some View {
        Menu {
            Toggle("Animated screen transitions", isOn: $modern)
            Divider()
            Button(m.checkingUpdates ? "Checking for Updates…" : "Check for Updates…") { m.checkForUpdates(manual: true) }.disabled(m.checkingUpdates)
            Toggle("Check for Updates Weekly", isOn: $autoUpdate)
            Divider()
            Button("Open-Source Licences") {
                if let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses"), FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.open(url)
                } else if let url = URL(string: "https://github.com/ARAVINDHRAJA123/porthop") { NSWorkspace.shared.open(url) }
            }
            Toggle("Also Find Phones on Wi-Fi (Slower)", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "includeWiFi") },
                                                                    set: { UserDefaults.standard.set($0, forKey: "includeWiFi") }))   // picked up on the next device check, every few seconds
            Picker("Appearance", selection: Binding(get: { UserDefaults.standard.string(forKey: Appearance.key) ?? "system" },
                                                     set: { UserDefaults.standard.set($0, forKey: Appearance.key); Appearance.apply($0) })) {
                Text("Match System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Button("Command-Line Tool…") {
                let path = (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Helpers/porthop")
                let command = "sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(path)\" /usr/local/bin/porthop"
                let a = NSAlert()
                a.messageText = "Use PortHop from Terminal"
                a.informativeText = "porthop lists devices and groups, copies a group (only what's new), and makes backups, for scripts and automation. To type just “porthop”, run this once in Terminal:\n\n\(command)\n\nThen try: porthop help"
                a.addButton(withTitle: "Copy Command")
                a.addButton(withTitle: "Close")
                if a.runModal() == .alertFirstButtonReturn {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
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
