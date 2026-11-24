import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Destinations

/// A place copies can go: the Pictures folder, an external drive, or a folder used before.
extension Destination {
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
    static func list(_ m: DeviceManager) -> (main: [Pile], albums: [Pile], people: [Pile]) {
        if m.isAndroid {
            let main = androidFolders.map { t in
                Pile(id: "android:" + t.2, title: t.0, symbol: t.1, color: Theme.color(for: ""), count: nil, bytes: nil,
                     thumbs: [], blur: false, album: nil, androidPath: t.2)
            }
            let albums = m.androidAlbums.prefix(12).map { a in
                Pile(id: "android:" + a.path, title: a.name, symbol: "photo.stack.fill", color: Theme.color(for: ""), count: a.count, bytes: a.bytes,
                     thumbs: [], blur: false, album: nil, androidPath: a.path)
            }
            return (main, Array(albums), [])
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
        return (main, m.userAlbums.map { pile($0, symbol: "rectangle.stack.fill") }, m.peopleAlbums.map { pile($0, symbol: "person.crop.circle.fill") })
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
                destinationShore(destinations, piles: piles.main + piles.albums + piles.people).frame(width: max(320, geo.size.width * 0.34))
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

    private func deviceShore(_ piles: (main: [Pile], albums: [Pile], people: [Pile])) -> some View {
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
                if !piles.people.isEmpty {
                    ShoreLabel(text: "People").padding(.top, 4)
                    pileGrid(piles.people, compact: true)
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
                if let peer = m.androidPeer, !m.isAndroid {
                    AndroidTargetCard(m: m, phone: peer, targeted: targeted == "android")
                        .shoreFrame("dest:android")
                        .onDrop(of: [UTType.plainText], isTargeted: Binding(get: { targeted == "android" }, set: { targeted = $0 ? "android" : (targeted == "android" ? nil : targeted) })) { providers in
                            pileID(providers) { id in
                                guard !m.isExporting, let p = piles.first(where: { $0.id == id }), let album = p.album else { return }
                                pendingFlight = (p.id, "dest:android")
                                m.requestAndroidHop(album, to: peer)
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

                if !m.presets.isEmpty {
                    ShoreLabel(text: "Your hops").padding(.top, 10)
                    VStack(spacing: 8) { ForEach(m.presets) { PresetRow(m: m, preset: $0) } }
                }

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
