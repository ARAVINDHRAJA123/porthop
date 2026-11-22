import SwiftUI
import AppKit

// The copy sheet before a copy and the summary after it.

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
    @State private var editedCount = 0
    @State private var cloudCount = 0
    @State private var saveHop = false
    @State private var hopName = ""
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
                if editedCount > 0 {
                    option("Copy edited versions", "\(Fmt.count(editedCount)) item\(editedCount == 1 ? " was" : "s were") edited in Photos. Copy the edited look instead of the original where the edit is on the device.", $m.options.editedVersions)
                }
                if cloudCount > 0 {
                    notice("\(Fmt.count(cloudCount)) item\(cloudCount == 1 ? " is" : "s are") stored only in iCloud, not on the \(m.deviceKind), so \(cloudCount == 1 ? "it" : "they") can't be copied over USB. Turn off “Optimise Storage” in the \(m.deviceKind)'s Photos settings to bring \(cloudCount == 1 ? "it" : "them") back first.",
                           "icloud.slash", .orange)
                }
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
                        if m.options.subfolder == .custom {
                            VStack(alignment: .leading, spacing: 5) {
                                TextField("{year}/{month}", text: $m.options.folderPattern).textFieldStyle(.roundedBorder)
                                Text("Use \(SubfolderMode.patternTokens); “/” makes a folder inside a folder.")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let first = request.assets.first {
                                    Text("Example: \(SubfolderMode.folder(m.options.folderPattern, first, album: request.albumName).isEmpty ? "(one folder)" : SubfolderMode.folder(m.options.folderPattern, first, album: request.albumName))/\(first.filename)")
                                        .font(.caption.monospaced()).foregroundStyle(Theme.accent).lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if let albumID = request.albumID, destination != nil {
                VStack(alignment: .leading, spacing: 6) {
                    option("Save as a one-click hop", "Shows on the home screen; next time it copies only what's new.", $saveHop)
                    if saveHop { TextField("Name", text: $hopName).textFieldStyle(.roundedBorder) }
                }
                .onAppear { if hopName.isEmpty { hopName = "\(request.albumName) → \(destination?.lastPathComponent ?? "")" } }
                .onChange(of: destination) { d in hopName = "\(request.albumName) → \(d?.lastPathComponent ?? "")"; _ = albumID }
            }

            Text(m.options.editedVersions && editedCount > 0
                 ? "Edited items come out with their edits; everything else is the original file. Files already in the folder are never replaced."
                 : "You get the original file for each item. Files already in the folder are never replaced.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SoftButtonStyle()).keyboardShortcut(.cancelAction)
                Button {
                    guard let destination else { return }
                    let assets = request.assets
                    if saveHop, let id = request.albumID {
                        m.savePreset(name: hopName.isEmpty ? request.albumName : hopName, albumID: id, destination: destination, options: m.options)
                    }
                    dismiss()
                    m.startExport(assets, to: destination, albumName: request.albumName)
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
                if a.isEdited { editedCount += 1 }
                if a.isCloudOnly { cloudCount += 1 }
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
