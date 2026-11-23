import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The cards on Shores: the device, its groups, the places copies go, saved hops, and the small layouts they use.

// MARK: - Device hero

struct DeviceHero: View {
    @ObservedObject var m: DeviceManager
    var body: some View {
        let d = m.details
        Button { m.selection = "nav_device" } label: {
            HStack(spacing: 14) {
                IconTile(symbol: m.isIPad ? "ipad" : (m.isAndroid ? "smartphone" : "iphone"), color: Theme.accent, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(m.deviceName).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Theme.text).lineLimit(1)
                    Text("\(d.modelName) · \(m.osName) \(d.iosVersion) · \(m.device?.isNetwork == true ? "Wi-Fi" : "USB")")
                        .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    if d.totalDiskBytes > 0 {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule().fill(Theme.gradient).frame(width: max(6, g.size.width * d.usedFraction))
                            }
                        }
                        .frame(height: 5)
                        Text("\(Fmt.bytes(d.freeDiskBytes)) free of \(Fmt.bytes(d.totalDiskBytes))").font(.caption2).foregroundStyle(Theme.faint)
                    }
                }
                Spacer(minLength: 6)
                if let b = d.batteryPercent {
                    ZStack {
                        Ring(fraction: Double(b) / 100, color: b < 20 ? Theme.danger : Theme.success, lineWidth: 4)
                        VStack(spacing: 0) {
                            Text("\(b)%").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                            if d.isCharging == true { Image(systemName: "bolt.fill").font(.system(size: 7)).foregroundStyle(Theme.success) }
                        }
                    }
                    .frame(width: 44, height: 44)
                }
            }
            .padding(16)
            .contentSurface(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Battery health, storage and device details")
    }
}

// MARK: - Pile card

struct PileCard: View {
    let pile: Pile
    var compact = false
    let device: Device?
    let tools: Tools?
    @State private var hover = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 10) {
                    IconTile(symbol: pile.symbol, color: pile.color, size: 30)
                    labels
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        IconTile(symbol: pile.symbol, color: pile.color, size: 38)
                        Spacer(minLength: 0)
                        if !pile.thumbs.isEmpty {
                            ThumbFan(assets: pile.thumbs, blur: pile.blur, device: device, tools: tools).frame(width: 58, height: 40)
                        }
                    }
                    labels
                }
            }
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface(RoundedRectangle(cornerRadius: 22, style: .continuous), highlighted: hover)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(pile.color.opacity(hover ? 0.6 : 0), lineWidth: 1.5))
        .shadow(color: .black.opacity(hover && !liquidGlass ? 0.35 : 0), radius: 14, y: 6)
        .scaleEffect(hover ? 1.02 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hover)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(pile.title).font(.system(size: compact ? 13 : 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            if let n = pile.count {
                Text("\(Fmt.count(n)) item\(n == 1 ? "" : "s")\(pile.bytes.map { " · " + Fmt.bytes($0) } ?? "")")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).monospacedDigit().lineLimit(1)
            } else if let path = pile.androidPath {
                Text(path.replacingOccurrences(of: "/sdcard/", with: "")).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
        }
    }
}

/// Three thumbnails fanned out like a small stack of prints. Hidden items stay blurred until opened.
struct ThumbFan: View {
    let assets: [PhotoAsset]
    let blur: Bool
    let device: Device?
    let tools: Tools?
    @State private var images: [Int64: NSImage] = [:]

    var body: some View {
        ZStack {
            ForEach(Array(assets.prefix(3).enumerated().reversed()), id: \.element.id) { i, a in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.raised)
                    .overlay {
                        if let img = images[a.id] { Image(nsImage: img).resizable().scaledToFill().blur(radius: blur ? 6 : 0) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5))
                    .frame(width: 34, height: 34)
                    .rotationEffect(.degrees(Double(i - 1) * 9))
                    .offset(x: CGFloat(i - 1) * 8, y: CGFloat(abs(i - 1)) * 2)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
            }
        }
        .task(id: assets.map(\.id)) {
            guard let device, let tools else { return }
            for a in assets.prefix(3) {
                if let hit = ThumbnailLoader.shared.cached(a.id) { images[a.id] = hit; continue }
                if let img = await ThumbnailLoader.shared.image(for: a, device: device, tools: tools), !Task.isCancelled {
                    withAnimation(.easeOut(duration: 0.25)) { images[a.id] = img }
                }
            }
        }
    }
}

// MARK: - Destination card

/// A destination on the right shore. Click it to pick what to copy there; drop a group on it to copy that group.
struct DestinationTile: View {
    @ObservedObject var m: DeviceManager
    let destination: Destination
    let piles: [Pile]
    let targeted: Bool
    let onHop: (Pile) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            DestinationCard(destination: destination, targeted: targeted,
                            receiving: m.exportDestination == destination.url && m.isExporting, progress: m.progress.fraction)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .leading) { chooser }
        .contextMenu {
            if !destination.readOnly { ForEach(piles) { p in Button("Copy \(p.title) here") { onHop(p) } } }
            Divider()
            Button("Show in Finder") { reveal() }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(destination.readOnly ? destination.name : "Copy to \(destination.name)").font(.system(size: 15, weight: .bold, design: .rounded))
            if destination.readOnly {
                Text("macOS can't write to this drive (\(destination.detail)). Reformat it as exFAT or APFS to use it.")
                    .font(.callout).foregroundStyle(Theme.secondary).frame(width: 260, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(piles) { p in
                            Button { open = false; onHop(p) } label: {
                                HStack(spacing: 10) {
                                    IconTile(symbol: p.symbol, color: p.color, size: 26)
                                    Text(p.title).foregroundStyle(Theme.text)
                                    Spacer()
                                    if let n = p.count { Text(Fmt.count(n)).foregroundStyle(Theme.faint).monospacedDigit() }
                                }
                                .font(.system(size: 13))
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.raised.opacity(0.6)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
                Text(destination.url.path).font(.caption2).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
            }
            Button { open = false; reveal() } label: { Label("Show in Finder", systemImage: "folder") }.buttonStyle(SoftButtonStyle())
        }
        .padding(16)
        .frame(width: 300)
    }

    private func reveal() {
        let u = FileManager.default.fileExists(atPath: destination.url.path) ? destination.url : destination.url.deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }
}

struct DestinationCard: View {
    let destination: Destination
    let targeted: Bool
    let receiving: Bool
    let progress: Double
    @State private var hover = false
    /// Dark ink on the solid cream card; light text on warm-tinted glass.
    private var fg: Color { Theme.text }

    var body: some View {
        let d = destination
        HStack(spacing: 12) {
            IconTile(symbol: d.symbol, color: d.tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(fg).lineLimit(1)
                Text(receiving ? "Receiving… \(Int(progress * 100))%" : [d.free.map { "\(Fmt.bytes($0)) free" }, d.detail.isEmpty ? nil : d.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(fg.opacity(0.65)).lineLimit(1).monospacedDigit()
                if receiving {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(fg.opacity(0.14))
                            Capsule().fill(Theme.gradient).frame(width: max(4, g.size.width * progress))
                        }
                    }
                    .frame(height: 4)
                }
            }
            Spacer(minLength: 0)
            if d.readOnly {
                Text("Read-only").font(.system(size: 10, weight: .semibold)).foregroundStyle(fg.opacity(0.75))
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(fg.opacity(0.1)))
            } else if d.isFAT {
                Text("FAT32: 4 GB limit").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(red: 0.6, green: 0.35, blue: 0.0))
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Theme.warning.opacity(0.25)))
            } else {
                Image(systemName: "arrow.down.to.line.compact").foregroundStyle(fg.opacity(targeted || hover ? 0.75 : 0.3))
            }
        }
        .padding(14)
        .contentSurface(RoundedRectangle(cornerRadius: 22, style: .continuous), highlighted: hover)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.accent.opacity(targeted ? 1 : 0), lineWidth: 3))
        .shadow(color: targeted || receiving ? Theme.accent.opacity(0.55) : .black.opacity(hover ? 0.35 : 0.2), radius: targeted || receiving ? 18 : 10, y: 4)
        .scaleEffect(targeted ? 1.04 : (hover ? 1.015 : 1))
        .opacity(d.readOnly ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hover)
        .help(d.readOnly ? "This drive can't be written to from a Mac." : "Drag a group here to copy it, or click to choose one. \(d.url.path)")
    }
}

// MARK: - Backups card

struct BackupsCard: View {
    @ObservedObject var m: DeviceManager
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { m.selection = "nav_backup" } label: {
                HStack(spacing: 12) {
                    IconTile(symbol: "clock.arrow.circlepath", color: Theme.warning, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.backupRunning ? (m.restoring ? "Restoring…" : "Backing up…") : "Back up \(m.deviceName)")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(backupDetail).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(Theme.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !m.backups.isEmpty {
                Text("Look inside your latest backup").font(.caption).foregroundStyle(Theme.faint)
                FlowChips(items: BackupKind.allCases.map { ($0.rawValue, $0.title) }) { m.selection = "bk:\($0)" }
            }
        }
        .padding(16)
        .contentSurface(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear { m.refreshBackups() }
    }

    private var backupDetail: String {
        if m.backupRunning { return m.backupPercent.map { "\(Int($0 * 100))% · \(m.backupPhase)" } ?? m.backupPhase }
        guard let latest = m.backups.first, let date = latest.date else { return "No backup in the backup folder yet" }
        let rel = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        return "Last backup \(rel)\(latest.encrypted ? " · encrypted" : "")"
    }
}

/// Small rounded buttons that wrap onto as many lines as they need.
struct FlowChips: View {
    let items: [(String, String)]
    let action: (String) -> Void
    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.0) { item in
                Button { action(item.0) } label: {
                    Text(item.1).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.raised))
                        .overlay(Capsule().strokeBorder(Theme.line))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Lays children left to right, wrapping to a new line when the row is full.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

// MARK: - Send to an app

struct SendToAppSheet: View {
    @ObservedObject var m: DeviceManager
    let urls: [URL]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send \(urls.count) item\(urls.count == 1 ? "" : "s") to which app?").font(.system(size: 18, weight: .bold, design: .rounded))
            Text("The files are added to the app's own folder on your \(m.deviceKind). Nothing there is overwritten.")
                .font(.callout).foregroundStyle(Theme.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(m.apps) { app in
                        Button {
                            dismiss()
                            m.sendFiles(urls, toApp: app.id)
                        } label: {
                            HStack {
                                IconTile(symbol: "app.fill", color: Theme.accent, size: 28)
                                Text(app.name).foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.faint)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 300)
            HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(SoftButtonStyle()).keyboardShortcut(.cancelAction) }
        }
        .padding(22)
        .frame(width: 420)
        .background(Theme.bg)
    }
}


/// A saved hop: one click copies whatever is new in that group to that folder.
struct PresetRow: View {
    @ObservedObject var m: DeviceManager
    let preset: DeviceManager.HopPreset
    @State private var hover = false

    var body: some View {
        let album = m.album(for: preset)
        let reachable = FileManager.default.fileExists(atPath: (preset.destination as NSString).deletingLastPathComponent)
        let ready = album != nil && reachable && !m.isExporting
        HStack(spacing: 12) {
            IconTile(symbol: preset.auto ? "bolt.fill" : "arrow.triangle.2.circlepath", color: Color(nsColor: .systemIndigo), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(album == nil ? "Not on this \(m.deviceKind)" : (!reachable ? "Folder not connected"
                     : "\(Fmt.count(album!.assets.count)) items · " + (preset.auto ? "runs when plugged in" : "copies only what's new")))
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { m.runPreset(preset) } label: { Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)) }
                .buttonStyle(PrimaryButtonStyle()).disabled(!ready).help("Hop now")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentSurface(RoundedRectangle(cornerRadius: 18, style: .continuous), highlighted: hover)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Hop Now") { m.runPreset(preset) }.disabled(!ready)
            Toggle("Run by Itself When Plugged In", isOn: Binding(get: { preset.auto }, set: { m.setAuto(preset, $0) }))
            Button("Show Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: preset.destination)]) }
            Divider()
            Button("Remove This Hop", role: .destructive) { m.deletePreset(preset) }
        }
    }
}
