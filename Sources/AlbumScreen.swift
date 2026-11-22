import SwiftUI
import AppKit

// Inside a group: filters, timeline, grid or list, and the floating action bar.

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
