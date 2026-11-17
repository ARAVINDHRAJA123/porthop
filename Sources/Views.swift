import SwiftUI
import AppKit
import Quartz

// MARK: - Root

struct RootView: View {
    @StateObject private var m = DeviceManager()
    @AppStorage("modernTransitions") private var modernTransitions = true
    @State private var askText = ""
    @FocusState private var askFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            ShoreBackground()
            ZStack {
                if !m.isReady {
                    StatusView(m: m).transition(.opacity)
                } else {
                    route
                        .id(m.selection ?? "nav_home")
                        .transition(modernTransitions ? .glide : .opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if m.isReady && (askFocused || (uiTestBuild && !askText.isEmpty)) {
                AskPanel(m: m, text: $askText, focused: $askFocused)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: m.isReady)
        .animation(modernTransitions ? .spring(response: 0.42, dampingFraction: 0.86) : .easeInOut(duration: 0.15), value: m.selection)
        .animation(.easeOut(duration: 0.15), value: askFocused)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if m.isReady && (m.selection ?? "nav_home") != "nav_home" {
                    Button { m.selection = "nav_home" } label: { Label("Shores", systemImage: "chevron.left") }
                        .help("Back to Shores (⌘[)")
                        .keyboardShortcut("[", modifiers: .command)
                }
                DevicePill(m: m)
            }
            ToolbarItem(placement: .principal) { AskField(m: m, text: $askText, focused: $askFocused) }
            ToolbarItemGroup(placement: .primaryAction) {
                ActivityBadge(m: m)
                SettingsMenu()
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .tint(Theme.accent)
        .frame(minWidth: 1020, minHeight: 680)
        .background(Button("") { askFocused = true }.keyboardShortcut("k", modifiers: .command).opacity(0))
        .sheet(item: $m.exportRequest) { ExportSheet(m: m, request: $0) }
        .sheet(item: $m.summary) { SummarySheet(m: m, summary: $0) }
        .sheet(isPresented: Binding(get: { m.previewAsset != nil }, set: { if !$0 { m.previewAsset = nil } })) {
            PreviewSheet(m: m)
        }
        .onAppear {
            m.start()
            if uiTestBuild, let ask = ProcessInfo.processInfo.environment["IPHONE_UI_ASK"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { askFocused = true; askText = ask }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in m.refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in m.refreshVolumes() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in m.shutdown() }
    }

    @ViewBuilder private var route: some View {
        let s = m.selection ?? "nav_home"
        if s == "nav_home" {
            ShoresView(m: m)
        } else if s == "nav_device" {
            DeviceView(m: m)
        } else if s == "nav_backup" {
            BackupView(m: m)
        } else if s.hasPrefix("bk:") {
            BackupDataView(m: m)
        } else if s == "nav_files" || s.hasPrefix("app:") {
            FilesView(m: m)
        } else {
            AlbumView(m: m)
        }
    }
}

// MARK: - Album

struct AssetMenu: View {
    @ObservedObject var m: DeviceManager
    let ids: Set<Int64>

    var body: some View {
        if let id = ids.first, ids.count == 1, let a = m.visibleAssets.first(where: { $0.id == id }) {
            Button { m.previewAsset = a } label: { Label("Quick Look", systemImage: "eye") }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(a.filename, forType: .string)
            } label: { Label("Copy Filename", systemImage: "doc.on.doc") }
            Divider()
        }
        if !ids.isEmpty {
            Button {
                m.selectedIDs = ids
                m.requestExport(selectedOnly: true)
            } label: { Label("Copy \(Fmt.count(ids.count)) Item\(ids.count == 1 ? "" : "s")…", systemImage: "square.and.arrow.down") }
        }
    }
}

struct AssetGrid: View {
    @ObservedObject var m: DeviceManager
    let cell: Double
    @State private var anchor: Int64?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cell, maximum: cell * 1.4), spacing: 12)], spacing: 14) {
                ForEach(m.visibleAssets) { a in
                    GridCell(asset: a, selected: m.selectedIDs.contains(a.id), device: m.device, tools: m.tools)
                        .onTapGesture { click(a) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { m.previewAsset = a })
                        .contextMenu {
                            AssetMenu(m: m, ids: m.selectedIDs.contains(a.id) ? m.selectedIDs : [a.id])
                        }
                }
            }
            .padding(16)
        }
    }

    private func click(_ a: PhotoAsset) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if m.selectedIDs.contains(a.id) { m.selectedIDs.remove(a.id) } else { m.selectedIDs.insert(a.id) }
        } else if flags.contains(.shift), let anchor,
                  let i = m.visibleAssets.firstIndex(where: { $0.id == anchor }),
                  let j = m.visibleAssets.firstIndex(where: { $0.id == a.id }) {
            m.selectedIDs.formUnion(m.visibleAssets[min(i, j)...max(i, j)].map(\.id))
            return
        } else {
            m.selectedIDs = (m.selectedIDs == [a.id]) ? [] : [a.id]
        }
        anchor = a.id
    }
}

struct GridCell: View {
    let asset: PhotoAsset
    let selected: Bool
    let device: Device?
    let tools: Tools?
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.primary.opacity(0.06)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill().transition(.opacity.combined(with: .scale(scale: 1.04)))
                    } else {
                        Image(systemName: asset.isVideo ? "video.fill" : "photo.fill")
                            .font(.system(size: 26)).foregroundStyle(.quaternary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        if asset.isVideo {
                            badge(asset.durationText.isEmpty ? "Video" : asset.durationText, "video.fill")
                        } else if asset.isLivePhoto {
                            badge(nil, "livephoto")
                        }
                        if asset.isFavorite { badge(nil, "heart.fill") }
                    }
                    .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Theme.accent)
                            .shadow(radius: 2).padding(6)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : Color.primary.opacity(hovering ? 0.25 : 0.06), lineWidth: selected ? 3 : 1))
                .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: 8, y: 3)
            Text(asset.filename).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Text(asset.sizeText).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .scaleEffect(hovering ? 1.025 : 1)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: selected)
        .task(id: asset.id) {
            if let hit = ThumbnailLoader.shared.cached(asset.id) { image = hit; return }
            image = nil
            guard let device, let tools else { return }
            let loaded = await ThumbnailLoader.shared.image(for: asset, device: device, tools: tools)
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.25)) { image = loaded } }
        }
    }

    private func badge(_ text: String?, _ symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            if let text { Text(text).font(.system(size: 10, weight: .semibold)).monospacedDigit() }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.55)))
    }
}

// MARK: - Quick Look

struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        if v.previewItem?.previewItemURL != url { v.previewItem = url as NSURL }
    }
}

struct PreviewSheet: View {
    @ObservedObject var m: DeviceManager
    @State private var localURL: URL?
    @State private var failed = false

    private var index: Int? { m.previewAsset.flatMap { a in m.visibleAssets.firstIndex { $0.id == a.id } } }

    var body: some View {
        VStack(spacing: 0) {
            if let a = m.previewAsset {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.filename).font(.headline)
                        Text([a.kindText, a.sizeText, a.dimensionsText, a.dateText].filter { $0 != "—" }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .keyboardShortcut(.leftArrow, modifiers: []).disabled((index ?? 0) <= 0)
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .keyboardShortcut(.rightArrow, modifiers: []).disabled((index ?? Int.max - 1) + 1 >= m.visibleAssets.count)
                    Button {
                        m.selectedIDs = [a.id]
                        m.previewAsset = nil
                        m.requestExport(selectedOnly: true)
                    } label: { Label("Copy…", systemImage: "square.and.arrow.down") }
                    .disabled(m.isExporting)
                    Button("Done") { m.previewAsset = nil }.keyboardShortcut(.cancelAction)
                }
                .padding(14)
                Divider()
                ZStack {
                    Color.black.opacity(0.9)
                    if let localURL {
                        QuickLookView(url: localURL)
                    } else if failed {
                        VStack(spacing: 8) {
                            Image(systemName: "icloud.slash").font(.system(size: 36))
                            Text("This item could not be read from the iPhone.")
                            Text("The original may be stored only in iCloud.").font(.caption)
                        }
                        .foregroundStyle(.white.opacity(0.8))
                    } else {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.large).colorScheme(.dark)
                            Text("Loading \(a.sizeText) from iPhone…").foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                .task(id: a.id) { await load(a) }
            }
        }
        .frame(width: 900, height: 660)
        .background(Theme.bg)
    }

    private func step(_ d: Int) {
        guard let i = index, m.visibleAssets.indices.contains(i + d) else { return }
        m.previewAsset = m.visibleAssets[i + d]
    }

    private func load(_ a: PhotoAsset) async {
        localURL = nil
        failed = false
        guard let device = m.device, let tools = m.tools else { failed = true; return }
        let dir = ThumbnailLoader.cacheRoot.appendingPathComponent("preview/\(a.id)", isDirectory: true)
        let url = dir.appendingPathComponent(a.filename)
        let ok: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let size = AFC.fileSize(url)
                if size > 0 && (a.fileSize <= 0 || size == a.fileSize) { cont.resume(returning: true); return }
                try? FileManager.default.removeItem(at: url)
                cont.resume(returning: AFC.get(a.remotePath, to: url, device: device, tools: tools))
            }
        }
        guard !Task.isCancelled, m.previewAsset?.id == a.id else { return }
        if ok { localURL = url } else { failed = true }
    }
}

