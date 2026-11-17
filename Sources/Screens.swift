import SwiftUI
import AppKit

// MARK: - Shared pieces

struct StorageBar: View {
    let fraction: Double
    @State private var shown = false
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Theme.gradient)
                    .frame(width: max(4, geo.size.width * (shown ? min(1, max(0, fraction)) : 0)))
            }
        }
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.15)) { shown = true } }
    }
}

struct GlowProgressBar: View {
    let fraction: Double
    @State private var sweep = false
    var body: some View {
        GeometryReader { geo in
            let w = max(8, geo.size.width * min(1, max(0, fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Theme.gradient).frame(width: w)
                    .overlay(alignment: .leading) {
                        LinearGradient(colors: [.clear, .white.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 70).offset(x: sweep ? w : -70)
                    }
                    .clipShape(Capsule())
                    .animation(.easeOut(duration: 0.35), value: fraction)
            }
        }
        .frame(height: 6)
        .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { sweep = true } }
    }
}

struct Pill: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Sidebar

struct StatusView: View {
    @ObservedObject var m: DeviceManager
    @State private var pulse = false
    @State private var stepsShown = false

    private var phaseKey: String {
        switch m.phase {
        case .searching: return "searching"
        case .toolsMissing: return "tools"
        case .noDevice: return "none"
        case .needsTrust: return "trust"
        case .loading: return "loading"
        case .ready: return "ready"
        case .catalogError: return "error"
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 22) { content }
                .padding(40)
                .id(phaseKey)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: phaseKey)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { m.connect(silent: false) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Look for a device again")
            }
        }
        .navigationTitle("PortHop")
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    @ViewBuilder private var content: some View {
        switch m.phase {
        case .searching:
            ProgressView().controlSize(.large)
            Text("Looking for your device…").font(.title3).foregroundStyle(.secondary)
        case .loading(let msg):
            LinkLoader(device: m.deviceName, symbol: m.isIPad ? "ipad" : "iphone", organising: msg.hasPrefix("Organising"))
        case .noDevice where m.isRestarting:
            hero("arrow.clockwise", rings: true)
            Text("\(m.deviceName) is restarting").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("It will appear here again by itself in a minute or two. If it asks, unlock it and tap Trust.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            waiting("Waiting for it to come back")
        case .noDevice:
            hero("cable.connector", rings: true)
            VStack(spacing: 6) {
                Text(m.tools?.adb != nil ? "Connect your iPhone, iPad or Android" : "Connect your iPhone or iPad").font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Copy photos and videos to your Mac or an external drive over USB.").font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                step(1, "cable.connector.horizontal", "Plug in", "Use a USB cable that carries data.")
                step(2, "lock.open.fill", "Unlock & Trust", "Unlock the device and tap Trust if it asks.")
                step(3, "arrow.right.circle.fill", "Hop it across", "Drag a group of photos onto a folder or drive.")
            }
            .frame(maxWidth: 720)
            .onAppear { stepsShown = true }
            if m.tools?.adb == nil { AndroidSetupRow(m: m) }
            waiting("Waiting for a device — it will appear here automatically")
        case .needsTrust(let msg):
            hero("lock.iphone", rings: true)
            Text("Unlock and Trust").font(.system(size: 30, weight: .bold, design: .rounded))
            Text(msg).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            waiting("Checking again every few seconds")
        case .toolsMissing:
            hero("shippingbox.fill", rings: false)
            Text("A part of the app is missing").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("The built-in device tools were not found. Rebuild the app, or install them with Homebrew in Terminal:")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            HStack(spacing: 10) {
                Text("brew install libimobiledevice").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install libimobiledevice", forType: .string)
                } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
            waiting("Checking again every few seconds")
        case .catalogError(let msg):
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 52)).foregroundStyle(.orange)
            Text("Can't read this photo library").font(.system(size: 30, weight: .bold, design: .rounded))
            Text(msg).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            Text("Nothing on the device was changed.").font(.callout).foregroundStyle(.secondary)
            Button("Try Again") { m.connect(silent: false) }.buttonStyle(PrimaryButtonStyle())
        case .ready:
            EmptyView()
        }
    }

    private func hero(_ symbol: String, rings: Bool) -> some View {
        ZStack {
            if rings {
                ForEach(0..<3, id: \.self) { i in
                    Circle().stroke(Theme.accent.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 112, height: 112)
                        .scaleEffect(pulse ? 2.1 : 1)
                        .opacity(pulse ? 0 : 0.7)
                        .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8), value: pulse)
                }
            }
            Circle().fill(Theme.gradient).frame(width: 112, height: 112)
                .shadow(color: Theme.accent.opacity(0.45), radius: 26, y: 10)
            Image(systemName: symbol).font(.system(size: 46, weight: .medium)).foregroundStyle(.white)
        }
        .frame(height: 150)
    }

    private func step(_ n: Int, _ symbol: String, _ title: String, _ text: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.gradient)
                    Spacer()
                    Text("\(n)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).background(Circle().fill(Color.primary.opacity(0.08)))
                }
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        }
        .opacity(stepsShown ? 1 : 0)
        .offset(y: stepsShown ? 0 : 18)
        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.12 * Double(n)), value: stepsShown)
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }
}

// MARK: - Album screen

struct AlbumView: View {
    @ObservedObject var m: DeviceManager
    @AppStorage("gridMode") private var gridMode = true
    @AppStorage("thumbSize") private var thumbSize = 150.0
    @Namespace private var chipSpace

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            TimelineStrip(m: m)
            ForEach(m.catalogWarnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Theme.warning)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warning.opacity(0.1))
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            ZStack {
                if m.visibleAssets.isEmpty {
                    emptyState.transition(.opacity)
                } else if gridMode {
                    AssetGrid(m: m, cell: thumbSize).transition(.opacity)
                } else {
                    AssetTable(m: m).transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: gridMode)
            .animation(.easeInOut(duration: 0.22), value: m.visibleAssets.isEmpty)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { ActionBar(m: m) }
        .background(
            Button("") { if let a = m.selectedAssets.first { m.previewAsset = a } }
                .keyboardShortcut("y", modifiers: .command).opacity(0).frame(width: 0, height: 0)
        )
    }

    private var header: some View {
        HStack(spacing: 14) {
            IconTile(symbol: m.currentAlbum?.icon ?? "photo", color: Theme.color(for: m.currentAlbum?.id ?? ""), size: 46)
                .shadow(color: Theme.color(for: m.currentAlbum?.id ?? "").opacity(0.45), radius: 12, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.currentAlbum?.title ?? "Photos").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                Text("\(Fmt.count(m.visibleAssets.count)) item\(m.visibleAssets.count == 1 ? "" : "s") · \(Fmt.bytes(m.visibleBytes))\(m.visibleVideoCount > 0 ? " · \(Fmt.count(m.visibleVideoCount)) video\(m.visibleVideoCount == 1 ? "" : "s")" : "")")
                    .font(.callout).foregroundStyle(Theme.secondary).monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer()
            if m.isFiltering { ProgressView().controlSize(.small) }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                TextField("Search name, folder or date", text: $m.searchText).textFieldStyle(.plain)
                if !m.searchText.isEmpty {
                    Button { m.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }.buttonStyle(.plain)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .frame(width: 230)
            .glassSurface(Capsule(), fallback: Theme.raised)
            Picker("View", selection: $gridMode) {
                Image(systemName: "square.grid.2x2").tag(true)
                Image(systemName: "list.bullet").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 76)
            .help("Thumbnails or a detailed list")
            Menu {
                Picker("Sort by", selection: Binding(get: { m.sortField }, set: { m.setSort($0, ascending: m.sortAscending) })) {
                    ForEach(SortField.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Order", selection: Binding(get: { m.sortAscending }, set: { m.setSort(m.sortField, ascending: $0) })) {
                    Text(ascendingLabel).tag(true)
                    Text(descendingLabel).tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down").foregroundStyle(Theme.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Sorted by \(m.sortField.rawValue)")
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    private var ascendingLabel: String {
        switch m.sortField {
        case .date: return "Oldest First"
        case .size, .resolution: return "Smallest First"
        default: return "A to Z"
        }
    }
    private var descendingLabel: String {
        switch m.sortField {
        case .date: return "Newest First"
        case .size, .resolution: return "Largest First"
        default: return "Z to A"
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MediaFilter.allCases) { f in
                        let on = m.mediaFilter == f
                        Button {
                            m.mediaFilter = f
                        } label: {
                            Label(f.rawValue, systemImage: f.icon)
                                .font(.system(size: 12, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .foregroundStyle(on ? Color.white : Theme.secondary)
                                .background {
                                    if liquidGlass {
                                        Capsule().fill(on ? Theme.accent.opacity(0.9) : Color.white.opacity(0.0001))
                                    } else {
                                        ZStack {
                                            Capsule().fill(Theme.raised.opacity(0.7))
                                            if on { Capsule().fill(Theme.gradient).matchedGeometryEffect(id: "chip", in: chipSpace) }
                                        }
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                    if m.minBytes > 0 {
                        Button { m.minBytes = 0 } label: {
                            Label("Over \(Fmt.bytes(m.minBytes))", systemImage: "xmark")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .background(Capsule().fill(Theme.color(for: "smart_videos")))
                        }
                        .buttonStyle(.plain).help("Remove the size filter")
                    }
                }
            }
            .padding(liquidGlass ? 4 : 0)
            .glassSurface(Capsule(), fallback: .clear, stroke: .clear)
            Spacer(minLength: 8)
            Button {
                m.setSort(m.sortField, ascending: !m.sortAscending)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up").rotationEffect(.degrees(m.sortAscending ? 0 : 180))
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: m.sortAscending)
                    Text("\(m.sortField.rawValue): \(m.sortAscending ? ascendingLabel : descendingLabel)")
                }
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Click to reverse the order")
            if gridMode {
                Slider(value: $thumbSize, in: 100...260).frame(width: 90).controlSize(.small).help("Thumbnail size")
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.2), value: gridMode)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: m.mediaFilter)
    }

    private var emptyState: some View {
        let unfiltered = m.searchText.isEmpty && m.mediaFilter == .all && m.dateRange == nil && m.minBytes == 0
        return VStack(spacing: 10) {
            Spacer()
            Image(systemName: unfiltered ? "photo.on.rectangle.angled" : "magnifyingglass")
                .font(.system(size: 44)).foregroundStyle(Theme.faint)
            Text(unfiltered ? "This group is empty" : "Nothing matches").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
            if !unfiltered {
                Button("Clear Filters") { m.searchText = ""; m.mediaFilter = .all; m.dateRange = nil; m.minBytes = 0 }.buttonStyle(SoftButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Where the next copy goes; picked here or by asking ("… to T7").
struct DestinationPicker: View {
    @ObservedObject var m: DeviceManager
    var body: some View {
        let list = Destinations.list(m).filter { !$0.readOnly }
        let name = m.pendingDestination.map { u in list.first { $0.url == u }?.name ?? u.lastPathComponent }
        Menu {
            ForEach(list) { d in
                Button { m.pendingDestination = d.url } label: {
                    if d.url == m.pendingDestination { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                }
            }
            Divider()
            Button("Choose another folder…") {
                if let u = Destinations.choose(m) { m.rememberDestination(u); m.pendingDestination = u }
            }
            if m.pendingDestination != nil { Button("Ask each time") { m.pendingDestination = nil } }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(Theme.accentLight)
                Text(name.map { "To \($0)" } ?? "Choose where").foregroundStyle(Theme.text)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
            }
            .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Where the copies go")
    }
}

// MARK: - Floating action bar

struct ActionBar: View {
    @ObservedObject var m: DeviceManager

    var body: some View {
        ZStack {
            if m.isExporting {
                progress.transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            } else {
                idle.transition(.asymmetric(insertion: .opacity, removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.bgDeep.opacity(liquidGlass ? 0.6 : 0)))
        .glassSurface(RoundedRectangle(cornerRadius: 26, style: .continuous), fallback: Theme.surface.opacity(0.97))
        .shadow(color: .black.opacity(liquidGlass ? 0 : 0.4), radius: 18, y: 6)
        .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 6)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: m.isExporting)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: m.selectedIDs.isEmpty)
    }

    private var idle: some View {
        HStack(spacing: 10) {
            if m.selectedIDs.isEmpty {
                Image(systemName: "hand.tap").foregroundStyle(.secondary)
                Text("Select items to copy just those, or copy everything shown.")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                Text("\(Fmt.count(m.selectedIDs.count)) selected · \(Fmt.bytes(m.selectedBytes))")
                    .font(.callout.weight(.medium)).monospacedDigit().contentTransition(.numericText())
                Button("Deselect") { m.selectedIDs.removeAll() }.buttonStyle(.link)
            }
            Spacer()
            DestinationPicker(m: m)
            if !m.visibleAssets.isEmpty && m.selectedIDs.count < m.visibleAssets.count {
                Button("Select All") { m.selectedIDs = Set(m.visibleAssets.map(\.id)) }
                    .buttonStyle(.link).keyboardShortcut("a", modifiers: [.command, .shift])
            }
            if m.selectedIDs.isEmpty {
                Button { m.requestExport(selectedOnly: false) } label: {
                    Label("Copy All \(Fmt.count(m.visibleAssets.count))…", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(m.visibleAssets.isEmpty)
                .keyboardShortcut("e", modifiers: .command)
            } else {
                Button("Copy All \(Fmt.count(m.visibleAssets.count))…") { m.requestExport(selectedOnly: false) }
                    .buttonStyle(SoftButtonStyle())
                Button { m.requestExport(selectedOnly: true) } label: {
                    Label("Copy \(Fmt.count(m.selectedIDs.count)) Selected…", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("e", modifiers: .command)
            }
        }
    }

    private var progress: some View {
        let p = m.progress
        return HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 4)
                Circle().trim(from: 0, to: p.fraction).stroke(Theme.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).animation(.linear(duration: 0.3), value: p.fraction)
                Text("\(Int(p.fraction * 100))").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(m.isStopping ? "Stopping…" : "Copying to your Mac").font(.callout.weight(.semibold))
                    Text("\(Fmt.count(p.shownCount)) of \(Fmt.count(p.total))").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    if p.failed > 0 {
                        Label("\(p.failed) failed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                GlowProgressBar(fraction: p.fraction)
                Text(detail(p)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Stop") { m.stopExport() }.buttonStyle(SoftButtonStyle()).disabled(m.isStopping)
        }
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
        return parts.isEmpty ? "Keep the device connected and unlocked." : parts.joined(separator: " · ")
    }
}

// MARK: - Export sheet

struct ExportSheet: View {
    @ObservedObject var m: DeviceManager
    let request: DeviceManager.ExportRequest
    @Environment(\.dismiss) private var dismiss
    @State private var destination: URL?
    @State private var volumes: [VolumeInfo] = []
    @State private var showMore = false

    @State private var totalBytes: Int64 = 0
    @State private var liveCount = 0
    @State private var heicCount = 0
    @State private var hugeCount = 0
    @State private var freeBytes: Int64? = nil
    @State private var destinationFormat = ""
    private var lowSpace: Bool { if let f = freeBytes { return f < totalBytes + 500_000_000 }; return false }
    private var fatProblem: Bool {
        guard destination != nil, hugeCount > 0 else { return false }
        let f = destinationFormat.lowercased()
        return f.contains("fat32") || f.contains("ms-dos")
    }
    private var folderName: String { "\(m.deviceName) Photos".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                IconTile(symbol: "square.and.arrow.down.fill", color: Theme.accent, size: 46)
                    .shadow(color: Theme.accent.opacity(0.4), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title).font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("\(Fmt.bytes(totalBytes)) to copy. Nothing is removed from your \(m.deviceKind).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            sectionTitle("1", "Where should the copies go?")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: destination == nil ? "folder.badge.questionmark" : "folder.fill")
                            .font(.title2).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(destination?.lastPathComponent ?? "No folder chosen yet").font(.headline)
                            if let destination {
                                Text((destination.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Button(destination == nil ? "Choose Folder…" : "Change…") { choose() }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            quick("photo.on.rectangle", "Pictures", nil, enabled: true) {
                                destination = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent(folderName)
                            }
                            ForEach(volumes) { v in
                                quick("externaldrive.fill", v.name, v.readOnly ? "read-only" : "\(Fmt.bytes(v.free)) free", enabled: !v.readOnly) {
                                    destination = v.url.appendingPathComponent(folderName)
                                }
                                .help(v.readOnly ? "This drive can't be written to from a Mac (\(v.format)). Reformat it as exFAT or APFS to use it."
                                                 : "\(v.format) · a “\(folderName)” folder will be created on this drive")
                            }
                        }
                    }
                    if let free = freeBytes {
                        notice(lowSpace ? "Not enough room: \(Fmt.bytes(free)) free, about \(Fmt.bytes(totalBytes)) needed."
                                        : "\(Fmt.bytes(free)) free here — enough room.",
                               lowSpace ? "exclamationmark.triangle.fill" : "checkmark.circle.fill", lowSpace ? .orange : .green)
                    }
                    if fatProblem {
                        notice("\(hugeCount) item\(hugeCount == 1 ? " is" : "s are") larger than 4 GB, which this drive's format (FAT32) can't hold. Use an exFAT or APFS drive.",
                               "exclamationmark.triangle.fill", .orange)
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: destination)

            sectionTitle("2", "Options")
            VStack(alignment: .leading, spacing: 12) {
                option("Skip items already in this folder", "Safe to run again: anything copied before is left alone, not duplicated.", $m.options.skipExisting)
                if liveCount > 0 {
                    option("Include Live Photo videos", "Also saves the short motion clip for \(Fmt.count(liveCount)) Live Photo\(liveCount == 1 ? "" : "s").", $m.options.includeLiveVideo)
                }
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showMore.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(showMore ? 90 : 0))
                        Text("More options")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if showMore {
                    VStack(alignment: .leading, spacing: 12) {
                        option("Show the date taken in Finder", "Sets each file's date to when the photo was taken.", $m.options.setDates)
                        if heicCount > 0 {
                            option("Convert HEIC photos to JPEG", "Only needed for apps that can't open HEIC. Slower.", $m.options.convertHEIC)
                        }
                        option("Use original camera filenames", "The name the photo had when it was taken or imported.", $m.options.useOriginalNames)
                        HStack {
                            Text("Arrange in")
                            Spacer()
                            Picker("", selection: $m.options.subfolder) {
                                ForEach(SubfolderMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden().frame(width: 230)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            Text("You get the original file for each item. Edits made in the Photos app are not included. Files already in the folder are never replaced.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SoftButtonStyle()).keyboardShortcut(.cancelAction)
                Button {
                    guard let destination else { return }
                    let assets = request.assets
                    dismiss()
                    m.startExport(assets, to: destination)
                } label: { Label("Copy \(Fmt.count(request.assets.count)) Item\(request.assets.count == 1 ? "" : "s")", systemImage: "arrow.down.circle.fill") }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(destination == nil || lowSpace)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.bg)
        .onChange(of: destination) { d in
            freeBytes = d.flatMap(VolumeInfo.freeSpace)
            destinationFormat = d.map(VolumeInfo.format) ?? ""
        }
        .onAppear {
            for a in request.assets {
                totalBytes += max(0, a.fileSize)
                if a.isLivePhoto { liveCount += 1 }
                if a.isHEIC { heicCount += 1 }
                if a.fileSize > 4_294_967_295 { hugeCount += 1 }
            }
            volumes = VolumeInfo.external()
            if let preset = request.destination ?? m.pendingDestination {
                destination = preset
            } else if let last = UserDefaults.standard.string(forKey: "lastDestination"),
               FileManager.default.fileExists(atPath: last) {
                destination = URL(fileURLWithPath: last)
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            withAnimation { volumes = VolumeInfo.external() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            withAnimation { volumes = VolumeInfo.external() }
            if let d = destination, !FileManager.default.fileExists(atPath: d.deletingLastPathComponent().path) { destination = nil }
        }
    }

    private func sectionTitle(_ n: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(n).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(Theme.gradient))
            Text(text).font(.system(size: 13, weight: .semibold))
        }
    }

    private func quick(_ symbol: String, _ name: String, _ detail: String?, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .transition(.scale.combined(with: .opacity))
    }

    private func notice(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func option(_ title: String, _ caption: String, _ value: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder on your Mac or an external drive"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if let destination, FileManager.default.fileExists(atPath: destination.path) { panel.directoryURL = destination }
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
}

// MARK: - Summary sheet

struct SummarySheet: View {
    @ObservedObject var m: DeviceManager
    let summary: ExportSummary
    @Environment(\.dismiss) private var dismiss
    @State private var shown = false

    private var title: String {
        if summary.fatalError != nil { return "The export couldn't start" }
        if summary.stalled { return "The \(m.deviceKind) stopped responding" }
        if summary.disconnected { return "The \(m.deviceKind) was disconnected" }
        if summary.cancelled { return "Export stopped" }
        if !summary.failures.isEmpty { return "Done, but \(Fmt.count(summary.failures.count)) item\(summary.failures.count == 1 ? "" : "s") couldn't be copied" }
        return "All done"
    }
    private var subtitle: String {
        if let e = summary.fatalError { return e }
        if summary.stalled { return "Everything copied so far is safe. It usually means the \(m.deviceKind) locked itself: unlock it, then export to the same folder to continue." }
        if summary.disconnected { return "Everything copied so far is safe. Plug it back in and export to the same folder to continue where it stopped." }
        if summary.cancelled { return "Everything copied so far is safe. Export to the same folder again to continue where it stopped." }
        var s = "\(Fmt.bytes(summary.bytesCopied)) saved to “\(summary.destination.lastPathComponent)”"
        if summary.elapsed >= 1 { s += " in \(Fmt.duration(summary.elapsed))" }
        return s + "."
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                let color: Color = summary.isClean ? .green : .orange
                Circle().fill(color.opacity(0.14)).frame(width: 92, height: 92).scaleEffect(shown ? 1 : 0.4)
                Circle().trim(from: 0, to: shown ? 1 : 0).stroke(color.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 72, height: 72).rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: shown)
                Image(systemName: summary.isClean ? "checkmark" : "exclamationmark")
                    .font(.system(size: 32, weight: .bold)).foregroundStyle(color.gradient)
                    .scaleEffect(shown ? 1 : 0.2).opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.35), value: shown)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: shown)
            VStack(spacing: 5) {
                Text(title).font(.system(size: 22, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if summary.fatalError == nil {
                HStack(spacing: 10) {
                    stat(summary.copied, "Copied", .green, 0)
                    stat(summary.skipped, "Already there", .blue, 1)
                    stat(summary.failures.count, "Couldn't copy", summary.failures.isEmpty ? .secondary : .orange, 2)
                    if summary.notAttempted > 0 { stat(summary.notAttempted, "Not started", .secondary, 3) }
                }
                if summary.liveVideos > 0 {
                    Label("\(Fmt.count(summary.liveVideos)) Live Photo video\(summary.liveVideos == 1 ? "" : "s") included", systemImage: "livephoto")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !summary.failures.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(summary.failures.prefix(500)) { f in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.asset.filename).font(.system(size: 12, weight: .medium))
                                Text(f.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6).padding(.horizontal, 10)
                            Divider()
                        }
                    }
                }
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
            HStack {
                if summary.fatalError == nil {
                    Button { NSWorkspace.shared.open(summary.destination) } label: { Label("Show in Finder", systemImage: "folder") }
                        .buttonStyle(SoftButtonStyle())
                }
                Spacer()
                if !summary.failures.isEmpty && !summary.disconnected && m.isReady {
                    Button("Try Those Again") { m.retryFailed(summary) }.buttonStyle(SoftButtonStyle())
                }
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 500)
        .background(Theme.bg)
        .onAppear { shown = true }
    }

    private func stat(_ n: Int, _ label: String, _ color: Color, _ order: Int) -> some View {
        VStack(spacing: 2) {
            Text(Fmt.count(shown ? n : 0)).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(color)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.7).delay(0.25 + 0.08 * Double(order)), value: shown)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        .opacity(shown ? 1 : 0).offset(y: shown ? 0 : 10)
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15 + 0.07 * Double(order)), value: shown)
    }
}

/// Offers to download Google's Android tool, which may not be shipped inside the app.
struct AndroidSetupRow: View {
    @ObservedObject var m: DeviceManager
    var body: some View {
        HStack(spacing: 12) {
            Button { m.setUpAndroid() } label: {
                Label(m.androidSettingUp ? "Downloading…" : "Set Up Android Support", systemImage: "arrow.down.circle")
            }
            .buttonStyle(SoftButtonStyle()).disabled(m.androidSettingUp)
            Text(m.androidSetupMessage.isEmpty ? "Android needs Google's free connection tool (about 15 MB, downloaded from Google)." : m.androidSetupMessage)
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 420, alignment: .leading)
        }
    }
}


// MARK: - Loading

/// The screen while a library is read: the phone and the Mac with photos hopping between them, and the steps so far.
struct LinkLoader: View {
    let device: String
    let symbol: String
    let organising: Bool

    var body: some View {
        VStack(spacing: 28) {
            HStack(spacing: 0) {
                IconTile(symbol: symbol, color: Theme.accent, size: 76)
                HopLane().frame(width: 230, height: 90)
                IconTile(symbol: "laptopcomputer", color: Color(nsColor: .systemIndigo), size: 76)
            }
            VStack(spacing: 6) {
                Text(organising ? "Almost there" : "Reading \(device)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .contentTransition(.opacity)
                Text("Large libraries can take a minute. Keep \(device) unlocked — nothing on it is changed.")
                    .font(.callout).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 14) {
                row(.done, "Connected over USB")
                row(organising ? .done : .active, "Reading the photo library")
                row(organising ? .active : .waiting, "Sorting it into albums")
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(width: 340, alignment: .leading)
            .contentSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: organising)
    }

    private enum StepState { case done, active, waiting }

    private func row(_ state: StepState, _ text: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.success)
                case .active: ProgressView().controlSize(.small)
                case .waiting: Circle().strokeBorder(Theme.faint, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).frame(width: 17, height: 17)
                }
            }
            .frame(width: 20)
            Text(text).font(.system(size: 14, weight: state == .active ? .semibold : .regular))
                .foregroundStyle(state == .waiting ? Theme.faint : Theme.text)
        }
    }
}

/// Little photos hopping along an arc from the phone to the Mac, over and over.
private struct HopLane: View {
    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let w = size.width, base = size.height * 0.62, lift = size.height * 0.5
                var dots = Path()
                for i in stride(from: 0.0, through: 1.0, by: 0.05) {
                    let x = 14 + (w - 28) * i, y = base - lift * sin(.pi * i)
                    dots.addEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                }
                ctx.fill(dots, with: .color(Theme.faint))
                let t = tl.date.timeIntervalSinceReferenceDate
                let colours: [Color] = [Color(nsColor: .systemPink), Color(nsColor: .systemOrange), Color(nsColor: .systemTeal)]
                for k in 0..<3 {
                    let p = (t / 1.8 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                    let x = 14 + (w - 28) * p, y = base - lift * sin(.pi * p)
                    let fade = min(1, min(p, 1 - p) * 6)
                    var card = ctx
                    card.opacity = fade
                    card.translateBy(x: x, y: y)
                    card.rotate(by: .degrees((p - 0.5) * 40))
                    let r = CGRect(x: -11, y: -9, width: 22, height: 18)
                    card.fill(Path(roundedRect: r, cornerRadius: 4), with: .linearGradient(Gradient(colors: [colours[k].opacity(0.95), colours[k].opacity(0.65)]),
                                                                                       startPoint: CGPoint(x: 0, y: -9), endPoint: CGPoint(x: 0, y: 9)))
                    card.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(.white.opacity(0.85)), lineWidth: 1.5)
                }
            }
        }
    }
}
