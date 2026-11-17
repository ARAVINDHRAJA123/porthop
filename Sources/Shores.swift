import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Destinations

/// A place copies can go: the Pictures folder, an external drive, or a folder used before.
struct Destination: Identifiable, Equatable {
    enum Kind { case pictures, drive, recent }
    let id: String
    let kind: Kind
    let name: String
    let detail: String
    let url: URL
    var free: Int64? = nil
    var readOnly = false
    var isFAT = false
    var symbol: String {
        switch kind {
        case .pictures: return "photo.on.rectangle.angled"
        case .drive: return "externaldrive.fill"
        case .recent: return "folder.fill"
        }
    }
    var tint: Color {
        switch kind {
        case .pictures: return Color(red: 0.20, green: 0.74, blue: 0.86)
        case .drive: return Color(red: 0.98, green: 0.58, blue: 0.24)
        case .recent: return Theme.accent
        }
    }
}

@MainActor
enum Destinations {
    static func folderName(_ m: DeviceManager) -> String {
        "\(m.deviceName) Photos".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    static func list(_ m: DeviceManager) -> [Destination] {
        var out: [Destination] = []
        let folder = folderName(m)
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        out.append(Destination(id: "pictures", kind: .pictures, name: "Pictures", detail: "This Mac",
                               url: pictures.appendingPathComponent(folder), free: VolumeInfo.freeSpace(at: pictures)))
        for v in m.volumes {
            out.append(Destination(id: v.url.path, kind: .drive, name: v.name,
                                   detail: v.readOnly ? "\(v.format) · read-only on a Mac" : v.format,
                                   url: v.url.appendingPathComponent(folder), free: v.free, readOnly: v.readOnly, isFAT: v.isFAT))
        }
        for r in m.recentDestinations where FileManager.default.fileExists(atPath: r) {
            let u = URL(fileURLWithPath: r)
            guard !out.contains(where: { $0.url.path == r || r.hasPrefix($0.url.path + "/") && $0.kind == .drive }) else { continue }
            out.append(Destination(id: "recent:" + r, kind: .recent, name: u.lastPathComponent,
                                   detail: (u.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath, url: u))
            if out.filter({ $0.kind == .recent }).count == 3 { break }
        }
        return out
    }

    static func choose(_ m: DeviceManager) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder on your Mac or an external drive"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Piles

/// One group on the device's shore: a photo album, or a storage folder on Android.
struct Pile: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let color: Color
    let count: Int?
    let bytes: Int64?
    let thumbs: [PhotoAsset]
    let blur: Bool
    let album: AlbumCategory?
    let androidPath: String?

    static let androidFolders: [(String, String, String)] = [
        ("Camera", "camera.fill", "/sdcard/DCIM"), ("Pictures", "photo.on.rectangle", "/sdcard/Pictures"),
        ("Download", "arrow.down.circle.fill", "/sdcard/Download"), ("Movies", "film.fill", "/sdcard/Movies"),
        ("Music", "music.note", "/sdcard/Music"), ("Documents", "doc.fill", "/sdcard/Documents")]

    @MainActor
    static func list(_ m: DeviceManager) -> (main: [Pile], albums: [Pile]) {
        if m.isAndroid {
            let main = androidFolders.map { t in
                Pile(id: "android:" + t.2, title: t.0, symbol: t.1, color: Theme.color(for: ""), count: nil, bytes: nil,
                     thumbs: [], blur: false, album: nil, androidPath: t.2)
            }
            return (main, [])
        }
        func pile(_ a: AlbumCategory, symbol: String) -> Pile {
            let photos = Array(a.assets.lazy.filter { !$0.isVideo }.prefix(3))
            return Pile(id: a.id, title: a.title, symbol: symbol, color: Theme.color(for: a.id), count: a.assets.count,
                        bytes: a.totalBytes, thumbs: photos, blur: a.id == "smart_hidden", album: a, androidPath: nil)
        }
        let order = ["smart_hidden", "smart_all", "smart_videos", "smart_screenshots", "smart_favorites", "smart_live", "smart_selfies", "smart_trashed"]
        let main = order.compactMap { id in m.smartAlbums.first { $0.id == id } }
            .filter { !$0.assets.isEmpty || $0.id == "smart_hidden" }
            .map { pile($0, symbol: $0.icon) }
        return (main, m.userAlbums.map { pile($0, symbol: "rectangle.stack.fill") })
    }
}

/// Positions of piles and destinations, so a hop can fly from one to the other.
struct ShoreFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

private extension View {
    func shoreFrame(_ id: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: ShoreFrames.self, value: [id: g.frame(in: .named("shores"))]) })
    }
}

// MARK: - Shores

struct ShoresView: View {
    @ObservedObject var m: DeviceManager
    @State private var frames: [String: CGRect] = [:]
    @State private var targeted: String?
    @State private var fileDropTargeted = false
    @State private var pendingFlight: (from: String, to: String)?
    @State private var flights: [Flight] = []
    @State private var appChoice: [URL]?

    var body: some View {
        let piles = Pile.list(m)
        let destinations = Destinations.list(m)
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 0) {
                deviceShore(piles).frame(width: max(360, geo.size.width * 0.4))
                ChannelView(m: m, destinationName: destinations.first { $0.url == m.exportDestination }?.name)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                destinationShore(destinations, piles: piles.main + piles.albums).frame(width: max(320, geo.size.width * 0.34))
            }
            .coordinateSpace(name: "shores")
            .overlay {
                ZStack {
                    ForEach(flights) { f in FlightView(flight: f) }
                }
                .allowsHitTesting(false)
            }
        }
        .onPreferenceChange(ShoreFrames.self) { frames = $0 }
        .onChange(of: m.isExporting) { running in if running { launchPendingFlight() } }
        .onChange(of: m.afcBusy) { running in if running { launchPendingFlight() } }
        .onChange(of: m.exportRequest == nil) { closed in if closed && !m.isExporting { pendingFlight = nil } }
        .sheet(isPresented: Binding(get: { appChoice != nil }, set: { if !$0 { appChoice = nil } })) {
            SendToAppSheet(m: m, urls: appChoice ?? [])
        }
    }

    // MARK: Device shore

    private func deviceShore(_ piles: (main: [Pile], albums: [Pile])) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DeviceHero(m: m)
                ShoreLabel(text: m.isAndroid ? "Folders on your \(m.deviceKind)" : "On your \(m.deviceKind)")
                pileGrid(piles.main)
                if m.isAndroid {
                    Button { m.selection = "nav_files" } label: { Label("Browse all storage", systemImage: "folder") }
                        .buttonStyle(SoftButtonStyle())
                }
                if !piles.albums.isEmpty {
                    ShoreLabel(text: "Your albums").padding(.top, 4)
                    pileGrid(piles.albums, compact: true)
                }
                if !m.apps.isEmpty {
                    ShoreLabel(text: "Send files to apps").padding(.top, 4)
                    FlowChips(items: m.apps.map { ($0.id, $0.name) }) { m.selection = "app:\($0)" }
                }
                Text(m.isAndroid ? "Drop files from Finder here to send them to the Download folder."
                                 : (m.apps.isEmpty ? "Click a group to look inside. Drag it across to copy it."
                                                   : "Click a group to look inside. Drag it across to copy it. Drop files here to send them to an app."))
                    .font(.caption).foregroundStyle(Theme.faint)
            }
            .padding(20)
        }
        .overlay {
            if fileDropTargeted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.accent.opacity(0.08)))
                    .overlay(Label("Send to your \(m.deviceKind)", systemImage: "arrow.up.circle.fill").font(.title3.weight(.semibold)).foregroundStyle(Theme.accentLight))
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $fileDropTargeted) { providers in
            loadURLs(providers) { urls in
                if m.isAndroid { m.sendFiles(urls, toApp: nil) }
                else if m.apps.count == 1 { m.sendFiles(urls, toApp: m.apps[0].id) }
                else if !m.apps.isEmpty { appChoice = urls }
            }
            return m.isAndroid || !m.apps.isEmpty
        }
        .animation(.easeOut(duration: 0.15), value: fileDropTargeted)
    }

    private func pileGrid(_ piles: [Pile], compact: Bool = false) -> some View {
        Grid(piles: piles, compact: compact, m: m, open: open)
    }

    private struct Grid: View {
        let piles: [Pile]
        let compact: Bool
        @ObservedObject var m: DeviceManager
        let open: (Pile) -> Void
        var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(piles) { p in
                PileCard(pile: p, compact: compact, device: m.device, tools: m.tools)
                    .shoreFrame(p.id)
                    .onTapGesture { open(p) }
                    .onDrag { NSItemProvider(object: ("porthop-pile:" + p.id) as NSString) }
                    .help(p.androidPath ?? "Click to look inside. Drag onto a place on the right to copy everything in it.")
            }
        }
        .glassGroup()
        }
    }

    private func open(_ p: Pile) {
        if let path = p.androidPath { m.openFolder(path) } else { m.selection = p.id }
    }

    // MARK: Destination shore

    private func destinationShore(_ destinations: [Destination], piles: [Pile]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ShoreLabel(text: "Hop them to").padding(.top, 6)
                ForEach(destinations) { d in
                    DestinationTile(m: m, destination: d, piles: piles, targeted: targeted == d.id) { p in hop(p, to: d.url, destinationID: d.id) }
                    .shoreFrame("dest:" + d.id)
                    .onDrop(of: [UTType.plainText], isTargeted: Binding(get: { targeted == d.id }, set: { targeted = $0 ? d.id : (targeted == d.id ? nil : targeted) })) { providers in
                        guard !d.readOnly else { return false }
                        pileID(providers) { id in
                            if let p = piles.first(where: { $0.id == id }) { hop(p, to: d.url, destinationID: d.id) }
                        }
                        return true
                    }
                }
                Button {
                    if let url = Destinations.choose(m) { m.rememberDestination(url) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 18))
                        Text("Choose another folder…").font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(Theme.secondary)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !m.isAndroid {
                    ShoreLabel(text: "Keep a full copy").padding(.top, 10)
                    BackupsCard(m: m)
                }
            }
            .padding(20)
        }
    }

    // MARK: Hops

    private func hop(_ p: Pile, to url: URL, destinationID: String) {
        guard !m.isExporting, !m.afcBusy else { return }
        pendingFlight = (p.id, "dest:" + destinationID)
        if let path = p.androidPath {
            m.copyFolders([path], to: url)
        } else if let album = p.album {
            m.requestHop(album, to: url)
        }
    }

    private func launchPendingFlight() {
        guard let pf = pendingFlight, let a = frames[pf.from], let b = frames[pf.to] else { return }
        pendingFlight = nil
        let from = CGPoint(x: a.midX, y: a.midY), to = CGPoint(x: b.minX + 40, y: b.midY)
        for i in 0..<3 {
            let f = Flight(from: from, to: to, delay: Double(i) * 0.13)
            flights.append(f)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { flights.removeAll { $0.id == f.id } }
        }
    }

    private func pileID(_ providers: [NSItemProvider], then: @escaping (String) -> Void) {
        guard let p = providers.first else { return }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, s.hasPrefix("porthop-pile:") else { return }
            DispatchQueue.main.async { then(String(s.dropFirst("porthop-pile:".count))) }
        }
    }

    private func loadURLs(_ providers: [NSItemProvider], then: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { DispatchQueue.main.async { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { then(urls) } }
    }
}

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

// MARK: - Channel

/// The water between the shores: shows what is crossing, or how to start.
struct ChannelView: View {
    @ObservedObject var m: DeviceManager
    let destinationName: String?

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 20)
            ChannelArc(active: m.isExporting || m.afcBusy).frame(height: 120)
            if m.isExporting {
                let p = m.progress
                VStack(spacing: 8) {
                    Text(m.isStopping ? "Stopping…" : "Hopping to \(destinationName ?? "your Mac")").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                    Text("\(Fmt.count(p.shownCount)) of \(Fmt.count(p.total))").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                        .monospacedDigit().contentTransition(.numericText())
                    GlowProgressBar(fraction: p.fraction).frame(width: 150)
                    Text(detail(p)).font(.caption).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).monospacedDigit()
                    Button("Stop") { m.stopExport() }.buttonStyle(SoftButtonStyle()).disabled(m.isStopping)
                }
                .padding(18)
                .glassSurface(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if m.afcBusy {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(m.afcMessage).font(.callout).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).lineLimit(3)
                    Button("Stop") { m.stopTransfer() }.buttonStyle(SoftButtonStyle())
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "hand.draw").font(.system(size: 22)).foregroundStyle(Theme.accentLight)
                    Text("Drag a group across").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("or click a place on the right and pick what to copy. Nothing is removed from your \(m.deviceKind).")
                        .font(.caption).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                    if !m.lastHop.isEmpty {
                        Text("Last hop: \(m.lastHop)").font(.caption2).foregroundStyle(Theme.faint).multilineTextAlignment(.center).padding(.top, 6)
                    }
                    if !m.afcMessage.isEmpty && !m.afcBusy {
                        Text(m.afcMessage).font(.caption2).foregroundStyle(m.afcMessageIsError ? Theme.warning : Theme.success).multilineTextAlignment(.center)
                    }
                }
                .transition(.opacity)
            }
            Spacer(minLength: 20)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: 240)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: m.isExporting)
    }

    private func detail(_ p: ExportProgress) -> String {
        var parts: [String] = []
        if p.bytesTotal > 0 { parts.append("\(Fmt.bytes(p.bytesDone)) of \(Fmt.bytes(p.bytesTotal))") }
        if p.bytesPerSecond > 0 {
            parts.append("\(Fmt.bytes(Int64(p.bytesPerSecond)))/s")
            let eta = Fmt.eta(Double(p.bytesTotal - p.bytesDone) / p.bytesPerSecond)
            if !eta.isEmpty { parts.append(eta) }
        }
        if p.skipped > 0 { parts.append("\(Fmt.count(p.skipped)) already there") }
        return parts.isEmpty ? "Keep the device connected and unlocked." : parts.joined(separator: "\n")
    }
}

/// A dotted arc across the water. While something is crossing, small cards hop along it.
struct ChannelArc: View {
    let active: Bool
    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in arc(phase: ctx.date.timeIntervalSinceReferenceDate) }
        } else {
            arc(phase: nil)
        }
    }

    private func arc(phase: Double?) -> some View {
        Canvas { g, size in
            let a = CGPoint(x: 6, y: size.height - 8), b = CGPoint(x: size.width - 6, y: size.height - 8)
            let c = CGPoint(x: size.width / 2, y: -size.height * 0.55)
            var path = Path()
            path.move(to: a)
            path.addQuadCurve(to: b, control: c)
            g.stroke(path, with: .color(Theme.accent.opacity(active ? 0.55 : 0.28)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [1, 9]))
            guard let phase else { return }
            for i in 0..<3 {
                let t = CGFloat((phase * 0.45 + Double(i) / 3).truncatingRemainder(dividingBy: 1))
                let p = CGPoint(x: (1 - t) * (1 - t) * a.x + 2 * (1 - t) * t * c.x + t * t * b.x,
                                y: (1 - t) * (1 - t) * a.y + 2 * (1 - t) * t * c.y + t * t * b.y)
                let r = CGRect(x: p.x - 9, y: p.y - 7, width: 18, height: 14)
                g.fill(Path(roundedRect: r, cornerRadius: 3), with: .linearGradient(Gradient(colors: [Theme.accentLight, Theme.accentDeep]),
                                                                                       startPoint: r.origin, endPoint: CGPoint(x: r.maxX, y: r.maxY)))
            }
        }
    }
}

// MARK: - Hop flight

struct Flight: Identifiable {
    let id = UUID()
    let from: CGPoint
    let to: CGPoint
    let delay: Double
}

private struct ArcPosition: ViewModifier, Animatable {
    var t: CGFloat
    let from: CGPoint
    let to: CGPoint
    var animatableData: CGFloat { get { t } set { t = newValue } }
    func body(content: Content) -> some View {
        let c = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 160)
        let x = (1 - t) * (1 - t) * from.x + 2 * (1 - t) * t * c.x + t * t * to.x
        let y = (1 - t) * (1 - t) * from.y + 2 * (1 - t) * t * c.y + t * t * to.y
        return content
            .rotationEffect(.degrees(Double(t - 0.5) * 50))
            .scaleEffect(1 - 0.25 * t)
            .opacity(t > 0.92 ? Double((1 - t) / 0.08) : 1)
            .position(x: x, y: y)
    }
}

struct FlightView: View {
    let flight: Flight
    @State private var t: CGFloat = 0

    /// A small card that hops across: a drop of tinted glass where Liquid Glass exists.
    @ViewBuilder private var token: some View {
        let icon = Image(systemName: "photo").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
        if #available(macOS 26.0, *) {
            icon.frame(width: 42, height: 34).glassEffect(.regular.tint(Theme.accent.opacity(0.75)), in: .rect(cornerRadius: 11))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.gradient)
                .frame(width: 38, height: 30)
                .overlay(icon)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5))
                .shadow(color: Theme.accent.opacity(0.7), radius: 12)
        }
    }
    var body: some View {
        token
            .modifier(ArcPosition(t: t, from: flight.from, to: flight.to))
            .onAppear { withAnimation(.easeInOut(duration: 0.95).delay(flight.delay)) { t = 1 } }
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
