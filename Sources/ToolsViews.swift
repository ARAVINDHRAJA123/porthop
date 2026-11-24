import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - The tools card on the device screen

struct PhoneToolsCard: View {
    @ObservedObject var m: DeviceManager
    @State private var reportBusy = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Phone tools").font(.headline)
                WrapLayout(spacing: 10) {
                    tool("Screen", "rectangle.on.rectangle", "nav_screen")
                    tool("Apps", "square.grid.2x2", "nav_apps")
                    if !m.isAndroid { tool("Music & Ringtones", "music.note", "nav_music") }
                    tool("Spyware Check", "checkmark.shield", "nav_check")
                    Button { saveReport() } label: { Label("Save Phone Report…", systemImage: "doc.richtext") }.buttonStyle(SoftButtonStyle())
                }
            }
        }
    }

    private func tool(_ title: String, _ symbol: String, _ route: String) -> some View {
        Button { m.selection = route } label: { Label(title, systemImage: symbol) }.buttonStyle(SoftButtonStyle())
    }

    private func saveReport() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.pdf]
        p.nameFieldStringValue = "\(m.deviceName) report.pdf"
        guard p.runModal() == .OK, let url = p.url else { return }
        m.savePhoneReport(to: url)
    }
}

// MARK: - Phone screen

@MainActor
final class ScreenModel: ObservableObject {
    @Published var size = CGSize.zero
    @Published var live = false
    @Published var message = ""
    @Published var recordingSince: Date?
    @Published var layer: CALayer?
    private var android: AndroidScreen?
    private var iphone: IPhoneScreen?
    private(set) var device: Device?
    private var tools: Tools?
    private var sizeTimer: Timer?

    func start(device: Device, tools: Tools, name: String) {
        stop()
        self.device = device
        self.tools = tools
        if device.isAndroid {
            let s = AndroidScreen(device: device, tools: tools)
            s.onSize = { [weak self] size in self?.size = size; self?.live = true; self?.message = "" }
            s.onEnded = { [weak self] why in self?.live = false; self?.message = why }
            android = s
            layer = s.layer
            message = "Waiting for the phone's screen… unlock it if it is locked."
            s.start()
        } else {
            IPhoneScreen.allowScreenCaptureDevices()
            message = "Looking for the iPhone's screen… keep it unlocked."
            AVCaptureDevice.requestAccess(for: .video) { ok in
                Task { @MainActor in
                    if ok { self.findIPhone(udid: device.udid, name: name, tries: 20) }
                    else { self.message = "macOS treats an iPhone's screen like a camera. Allow PortHop in System Settings › Privacy & Security › Camera, then open this again." }
                }
            }
        }
    }

    private func findIPhone(udid: String, name: String, tries: Int) {
        guard device?.udid == udid, iphone == nil else { return }
        if let d = IPhoneScreen.find(udid: udid, name: name) {
            let s = IPhoneScreen()
            guard s.start(d) else { message = "The iPhone's screen is in use by another app (QuickTime Player, say). Close it and open this again."; return }
            iphone = s
            layer = s.preview
            live = true
            message = ""
            sizeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in if let s = self?.iphone, s.size != .zero, s.size != self?.size { self?.size = s.size } }
            }
        } else if tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.findIPhone(udid: udid, name: name, tries: tries - 1) }
        } else {
            message = "The iPhone's screen didn't appear. Unlock it, tap Trust if it asks, close QuickTime Player if it is showing the iPhone, then open this again. Showing the screen needs a USB cable."
        }
    }

    func stop() {
        sizeTimer?.invalidate()
        sizeTimer = nil
        if recordingSince != nil { toggleRecording() }
        android?.stop()
        iphone?.stop()
        android = nil
        iphone = nil
        layer = nil
        live = false
    }

    private func folder(_ kind: FileManager.SearchPathDirectory) -> URL {
        let base = FileManager.default.urls(for: kind, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("PortHop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f.string(from: Date())
    }

    func screenshot() {
        guard let device, let tools else { return }
        let url = folder(.picturesDirectory).appendingPathComponent("Screenshot \(stamp()).png")
        if let iphone {
            if iphone.screenshot(to: url) { NSWorkspace.shared.activateFileViewerSelecting([url]); message = "Screenshot saved in Pictures › PortHop." }
            else { message = "The screenshot could not be saved." }
            return
        }
        message = "Taking a screenshot…"
        Task.detached {
            let ok = AndroidScreen.screenshot(device: device, tools: tools, to: url)
            await MainActor.run {
                self.message = ok ? "Screenshot saved in Pictures › PortHop." : "The phone did not send a screenshot."
                if ok { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    func toggleRecording() {
        let done: (URL?) -> Void = { [weak self] url in
            self?.recordingSince = nil
            if let url { self?.message = "Recording saved in Movies › PortHop."; NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { self?.message = "The recording could not be saved." }
        }
        if recordingSince != nil {
            android?.stopRecording(done)
            iphone?.stopRecording(done)
            return
        }
        let url = folder(.moviesDirectory).appendingPathComponent("Screen Recording \(stamp()).\(iphone != nil ? "mov" : "mp4")")
        let ok = android?.startRecording(to: url) ?? iphone?.startRecording(to: url) ?? false
        recordingSince = ok ? Date() : nil
        if !ok { message = "Recording could not start yet. Wait for the screen to appear." }
    }

    func tap(_ x: Double, _ y: Double) {
        guard let device, let tools, android != nil, size != .zero else { return }
        let picture = size
        Task.detached { AndroidScreen.tap(x, y, picture: picture, device: device, tools: tools) }
    }

    func swipe(_ a: (Double, Double), _ b: (Double, Double)) {
        guard let device, let tools, android != nil, size != .zero else { return }
        let picture = size
        Task.detached { AndroidScreen.swipe(from: a, to: b, picture: picture, device: device, tools: tools) }
    }

    func key(_ code: Int) {
        guard let device, let tools, android != nil else { return }
        Task.detached { AndroidScreen.key(code, device: device, tools: tools) }
    }
}

/// Shows a Core Animation layer (the phone's picture) filling the view.
struct LayerView: NSViewRepresentable {
    let layer: CALayer?

    final class Host: NSView {
        var shown: CALayer?
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shown?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Host {
        let v = Host()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        return v
    }

    func updateNSView(_ v: Host, context: Context) {
        guard v.shown !== layer else { return }
        v.shown?.removeFromSuperlayer()
        v.shown = layer
        if let layer {
            layer.frame = v.bounds
            v.layer?.addSublayer(layer)
        }
    }
}

struct ScreenView: View {
    @ObservedObject var m: DeviceManager
    @StateObject private var model = ScreenModel()
    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(m.deviceName) screen").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(m.isAndroid ? "Live over USB. Click to tap, drag to swipe." : "Live over USB, the way QuickTime Player shows it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if m.isAndroid {
                    Button { model.key(4) } label: { Label("Back", systemImage: "chevron.backward").labelStyle(.iconOnly) }.help("Back").buttonStyle(SoftButtonStyle())
                    Button { model.key(3) } label: { Label("Home", systemImage: "circle").labelStyle(.iconOnly) }.help("Home").buttonStyle(SoftButtonStyle())
                    Button { model.key(187) } label: { Label("Recent apps", systemImage: "square.on.square").labelStyle(.iconOnly) }.help("Recent apps").buttonStyle(SoftButtonStyle())
                }
                Button { model.screenshot() } label: { Label("Screenshot", systemImage: "camera") }.buttonStyle(SoftButtonStyle()).disabled(!model.live)
                Button { model.toggleRecording() } label: {
                    if let since = model.recordingSince {
                        TimelineView(.periodic(from: since, by: 1)) { ctx in
                            Label("Stop " + Fmt.duration(ctx.date.timeIntervalSince(since)), systemImage: "stop.circle.fill")
                        }
                    } else { Label("Record", systemImage: "record.circle") }
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(!model.live)
            }
            GeometryReader { geo in
                let ratio = model.size == .zero ? 9.0 / 19.5 : model.size.width / model.size.height
                let fit = CGSize(width: min(geo.size.width, geo.size.height * ratio), height: min(geo.size.height, geo.size.width / ratio))
                ZStack {
                    LayerView(layer: model.layer)
                        .frame(width: fit.width, height: fit.height)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in if dragStart == nil { dragStart = v.startLocation } }.onEnded { v in
                            let a = (Double(v.startLocation.x / fit.width), Double(v.startLocation.y / fit.height))
                            let b = (Double(v.location.x / fit.width), Double(v.location.y / fit.height))
                            if hypot(v.translation.width, v.translation.height) < 6 { model.tap(a.0, a.1) } else { model.swipe(a, b) }
                            dragStart = nil
                        })
                    if !model.live {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large).opacity(model.message.hasPrefix("Looking") || model.message.hasPrefix("Waiting") ? 1 : 0)
                            Text(model.message).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.9)).frame(maxWidth: 280)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(model.live ? model.message : " ").font(.callout).foregroundStyle(.secondary)
        }
        .padding(24)
        .navigationTitle("Screen")
        .onAppear { if let d = m.device, let t = m.tools { model.start(device: d, tools: t, name: m.deviceName) } }
        .onDisappear { model.stop() }
    }
}

// MARK: - Apps

struct AppsView: View {
    @ObservedObject var m: DeviceManager
    @State private var search = ""
    @State private var removing: InstalledApp?

    private var shown: [InstalledApp] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? m.installedApps : m.installedApps.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apps on \(m.deviceName)").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(m.appsLoaded ? "\(Fmt.count(m.installedApps.count)) apps you installed" : "Reading the app list…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search apps", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                Button { m.loadApps() } label: { Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly) }.help("Refresh").buttonStyle(SoftButtonStyle()).disabled(m.appsBusy)
                Button { install() } label: { Label("Install App…", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle()).disabled(m.appsBusy)
            }
            if !m.appsMessage.isEmpty {
                HStack(spacing: 8) {
                    if m.appsBusy { ProgressView().controlSize(.small) }
                    Text(m.appsMessage).foregroundStyle(m.appsMessageIsError ? Theme.danger : Theme.secondary)
                }
                .font(.callout)
            }
            List(shown) { app in
                HStack(spacing: 12) {
                    Text(String(app.name.prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.color(for: app.id)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.system(size: 13, weight: .medium))
                        Text(app.version.isEmpty ? app.id : "\(app.id) · \(app.version)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if app.bytes > 0 { Text(Fmt.bytes(app.bytes)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    Button("Remove…") { removing = app }.buttonStyle(.link).disabled(m.appsBusy)
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(m.isAndroid ? "Installs .apk files. Removing an app deletes everything it stores on the phone."
                             : "Installs .ipa files that are signed for this iPhone: your own builds, ad-hoc and company apps. App Store apps can't be installed this way. Removing an app deletes everything it stores on the iPhone.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .navigationTitle("Apps")
        .onAppear { if !m.appsLoaded || m.installedApps.isEmpty { m.loadApps() } }
        .confirmationDialog("Remove \(removing?.name ?? "this app")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove App and Its Data", role: .destructive) { if let a = removing { m.removeApp(a) }; removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("This deletes \(removing?.name ?? "the app") and everything it stores on \(m.deviceName). It can't be undone from PortHop.")
        }
    }

    private func install() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: m.isAndroid ? "apk" : "ipa") ?? .data]
        p.message = m.isAndroid ? "Choose an Android app (.apk)" : "Choose an iPhone app (.ipa) signed for this iPhone"
        guard p.runModal() == .OK, let url = p.url else { return }
        m.installApp(url)
    }
}

// MARK: - Music and ringtones

struct MusicView: View {
    @ObservedObject var m: DeviceManager
    @State private var selection = Set<Int64>()
    @State private var search = ""
    @State private var makingTone = false

    private var shown: [Song] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? m.songs : m.songs.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Music & Ringtones").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                Button { makingTone = true } label: { Label("Make a Ringtone…", systemImage: "bell.badge") }.buttonStyle(SoftButtonStyle())
            }
            HStack(spacing: 10) {
                Button { copy(selected: false) } label: { Label("Copy All to Mac…", systemImage: "square.and.arrow.down") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(m.musicBusy || m.songs.isEmpty)
                Button { copy(selected: true) } label: { Label("Copy Selected…", systemImage: "square.and.arrow.down.on.square") }
                    .buttonStyle(SoftButtonStyle()).disabled(m.musicBusy || selection.isEmpty)
                if let peer = m.androidPeer {
                    Button { m.copyMusic(chosen(selection.isEmpty ? nil : selection), toAndroid: peer) } label: {
                        Label("Send \(selection.isEmpty ? "All" : "Selected") to \(m.deviceNames[peer.udid] ?? "Android")", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(SoftButtonStyle()).disabled(m.musicBusy || m.songs.isEmpty)
                }
                if m.musicBusy && m.musicJob != nil { Button("Stop") { m.stopMusic() }.buttonStyle(SoftButtonStyle()) }
                Spacer()
            }
            if !m.musicMessage.isEmpty {
                HStack(spacing: 8) {
                    if m.musicBusy { ProgressView().controlSize(.small) }
                    Text(m.musicMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
            Table(shown, selection: $selection) {
                TableColumn("Title") { s in Label(s.title, systemImage: s.isRingtone ? "bell" : "music.note").labelStyle(.titleAndIcon) }
                TableColumn("Artist") { s in Text(s.albumArtist.isEmpty ? s.artist : s.albumArtist) }
                TableColumn("Album", value: \.album)
                TableColumn("Time") { s in Text(s.seconds > 0 ? Fmt.duration(s.seconds) : "").monospacedDigit() }.width(60)
                TableColumn("Size") { s in Text(s.size > 0 ? Fmt.bytes(s.size) : "").monospacedDigit() }.width(70)
                TableColumn("") { s in
                    Text(!s.onPhone ? "In the cloud" : (s.isProtected ? "Apple Music" : "")).font(.caption).foregroundStyle(.secondary)
                }.width(90)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text("Copies songs synced from a computer or bought in the iTunes Store, and ringtones. Apple Music downloads play only in the Music app, and songs not downloaded to the iPhone stay in the cloud; both are listed but not copied. Adding music to an iPhone needs Finder.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .navigationTitle("Music")
        .onAppear { if !m.musicLoaded { m.loadMusic() } }
        .sheet(isPresented: $makingTone) { RingtoneSheet(m: m) }
    }

    private var summary: String {
        guard m.musicLoaded else { return "Reading the music library…" }
        let tones = m.songs.filter(\.isRingtone).count
        return "\(Fmt.count(m.songs.count - tones)) songs and videos · \(Fmt.count(tones)) ringtones on \(m.deviceName)"
    }

    private func chosen(_ ids: Set<Int64>?) -> [Song] { ids.map { set in m.songs.filter { set.contains($0.id) } } ?? m.songs }

    private func copy(selected: Bool) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Copy Here"
        p.message = "Songs go into Artist › Album folders; ringtones into Ringtones."
        guard p.runModal() == .OK, let url = p.url else { return }
        m.copyMusic(chosen(selected ? selection : nil), to: url)
    }
}

struct RingtoneSheet: View {
    @ObservedObject var m: DeviceManager
    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var length = 0.0
    @State private var start = 0.0
    @State private var seconds = 30.0
    @State private var toAndroid = true
    @State private var player: AVAudioPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Make a Ringtone").font(.title2.bold())
            Text("Pick a song or sound file on this Mac (songs from the iPhone can be copied over first). Ringtones are up to 40 seconds.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(source == nil ? "Choose a File…" : "Choose Another…") { choose() }.buttonStyle(SoftButtonStyle())
                Text(source?.lastPathComponent ?? "No file chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            if source != nil && length > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Starts at \(Fmt.duration(start)) of \(Fmt.duration(length))").font(.callout)
                    Slider(value: $start, in: 0...max(0, length - 1))
                    Text("Lasts \(Int(seconds)) seconds").font(.callout)
                    Slider(value: $seconds, in: 5...min(RingtoneMaker.maxSeconds, max(5, length)), step: 1)
                }
                Button(player?.isPlaying == true ? "Stop" : "Play This Part") { preview() }.buttonStyle(SoftButtonStyle())
            }
            if let peer = m.androidPeer {
                Toggle("Also put it on \(m.deviceNames[peer.udid] ?? "the Android phone")", isOn: $toAndroid)
            }
            HStack {
                Spacer()
                Button("Cancel") { player?.stop(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Ringtone…") { save() }.buttonStyle(PrimaryButtonStyle()).disabled(source == nil || length <= 0).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .movie]
        guard p.runModal() == .OK, let url = p.url else { return }
        source = url
        start = 0
        Task {
            length = await RingtoneMaker.duration(of: url)
            seconds = min(30, max(5, length))
        }
    }

    private func preview() {
        if player?.isPlaying == true { player?.stop(); player = nil; return }
        guard let source, let p = try? AVAudioPlayer(contentsOf: source) else { return }
        p.currentTime = start
        p.play()
        player = p
        let until = seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + until) { if p.isPlaying { p.stop() } }
    }

    private func save() {
        guard let source else { return }
        player?.stop()
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: "m4r") ?? .audio]
        p.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + " ringtone.m4r"
        guard p.runModal() == .OK, let url = p.url else { return }
        m.makeRingtone(from: source, start: start, length: seconds, to: url, sendTo: toAndroid ? m.androidPeer : nil)
        dismiss()
    }
}

// MARK: - Spyware check

struct SpywareView: View {
    @ObservedObject var m: DeviceManager
    @State private var password = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Spyware check").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Looks for traces of known spyware: the websites, programs, accounts and apps that investigators at Amnesty International, Citizen Lab and others have published for Pegasus, Predator, stalkerware and more. "
                         + (m.isAndroid ? "An Android phone is checked live over USB; nothing is installed or changed on it." : "An iPhone is checked through its newest backup, so nothing on the iPhone is touched."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                indicatorsCard
                checkCard
                if let r = m.spyReport { results(r) }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Spyware Check")
        .onAppear {
            m.loadSpySources()
            if !m.isAndroid { m.refreshBackups() }
        }
    }

    private var indicatorsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Known spyware indicators").font(.headline)
                    Spacer()
                    Button { addFile() } label: { Label("Add File…", systemImage: "doc.badge.plus") }.buttonStyle(.link)
                    Button { m.downloadIndicators() } label: { Label(m.spySources.isEmpty ? "Download" : "Update", systemImage: "arrow.down.circle") }
                        .buttonStyle(SoftButtonStyle()).disabled(m.spyBusy)
                }
                if m.spySources.isEmpty {
                    Text("None yet. Download the public list (about 2 MB from GitHub), or add a file an investigator sent you.").foregroundStyle(.secondary)
                } else {
                    let total = m.spySources.reduce(0) { $0 + $1.count }
                    let newest = m.spySources.compactMap(\.updated).max()
                    Text("\(Fmt.count(total)) indicators from \(m.spySources.count) investigation\(m.spySources.count == 1 ? "" : "s")" + (newest.map { ", updated \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                        .foregroundStyle(.secondary)
                    WrapLayout(spacing: 6) {
                        ForEach(m.spySources, id: \.file) { s in
                            Text(s.name.replacingOccurrences(of: " Indicators of Compromise", with: "")).font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Theme.raised))
                        }
                    }
                }
                Text("From the Mobile Verification Toolkit project's public index. Downloaded only when you ask; nothing about you or your phone is sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var checkCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Check \(m.deviceName)").font(.headline)
                if m.isAndroid {
                    Text("Reads the installed apps, the programs running now, and which apps have powerful access.").foregroundStyle(.secondary)
                } else if let b = m.spyBackup {
                    Text("Reads the backup made \(b.date?.formatted(date: .abbreviated, time: .shortened) ?? "earlier")\(b.encrypted ? " (encrypted)" : ""). For the most complete check, make an encrypted backup first: it includes more.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("There is no backup of \(m.deviceName) yet. The check reads a backup, so make one first.").foregroundStyle(.secondary)
                        Button("Go to Backups") { m.selection = "nav_backup" }.buttonStyle(.link)
                    }
                }
                if m.spyNeedsPassword {
                    HStack {
                        SecureField("Backup password", text: $password).textFieldStyle(.roundedBorder).frame(width: 240)
                        Button("Unlock and Check") { m.runSpywareCheck(password: password) }.buttonStyle(PrimaryButtonStyle()).disabled(password.isEmpty || m.spyBusy)
                    }
                }
                HStack(spacing: 10) {
                    Button { m.runSpywareCheck() } label: { Label("Check Now", systemImage: "checkmark.shield") }
                        .buttonStyle(PrimaryButtonStyle()).disabled(m.spyBusy || m.spySources.isEmpty || (!m.isAndroid && m.spyBackup == nil))
                    if m.spyBusy { ProgressView().controlSize(.small) }
                    if !m.spyMessage.isEmpty { Text(m.spyMessage).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func results(_ r: Spyware.Report) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: r.findings.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 34)).foregroundStyle(r.findings.isEmpty ? Theme.success : Theme.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.findings.isEmpty ? "No known spyware found" : "\(r.findings.count) match\(r.findings.count == 1 ? "" : "es") with known spyware")
                            .font(.title3.bold())
                        Text(r.findings.isEmpty ? "Checked against \(Fmt.count(r.indicatorCount)) indicators. This finds only spyware that has been publicly documented."
                                                : "A match can be a false alarm, but take it seriously and get expert help.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { save() } label: { Label("Save Report…", systemImage: "square.and.arrow.down") }.buttonStyle(SoftButtonStyle())
                }
                ForEach(Array(r.findings.enumerated()), id: \.offset) { _, f in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.found).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                            Text("\(f.area) · linked to \(f.indicator.malware) (\(f.indicator.source))" + (f.when.isEmpty ? "" : " · \(f.when)"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !r.findings.isEmpty {
                    HStack(spacing: 14) {
                        Link("Amnesty Security Lab", destination: URL(string: "https://securitylab.amnesty.org/get-help/")!)
                        Link("Access Now Helpline", destination: URL(string: "https://www.accessnow.org/help/")!)
                    }
                    .font(.callout)
                }
                ForEach(r.warnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.circle").foregroundStyle(Theme.warning) }
                ForEach(r.review, id: \.title) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(g.title).font(.system(size: 13, weight: .semibold))
                        Text(g.detail + " Check you recognise each one.").font(.caption).foregroundStyle(.secondary)
                        Text(g.apps.joined(separator: ", ")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Text("Checked: \(r.checked.joined(separator: ", "))." + (r.missing.isEmpty ? "" : " Not in this \(m.isAndroid ? "check" : "backup"): \(r.missing.joined(separator: ", ")).")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func addFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "stix2") ?? .json, .json]
        p.message = "Choose an indicator file (.stix2)"
        guard p.runModal() == .OK, let url = p.url else { return }
        m.addIndicatorFile(url)
    }

    private func save() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.pdf]
        p.nameFieldStringValue = "Spyware check \(m.spyReportFor).pdf"
        guard p.runModal() == .OK, let url = p.url else { return }
        m.saveSpyReport(to: url)
    }
}

// MARK: - Removing what was copied from an Android phone

/// After Android folders were copied to the Mac: removes from the phone the files whose copy matches, after asking.
struct RemoveCopiedButton: View {
    @ObservedObject var m: DeviceManager
    @State private var asking = false

    var body: some View {
        if m.isAndroid && !m.androidCopied.isEmpty && !m.afcBusy {
            Button { asking = true } label: {
                if m.cleanupBusy { ProgressView().controlSize(.small) } else { Label("Remove from Phone…", systemImage: "trash") }
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(m.cleanupBusy)
            .help("Removes the copied files from the phone, only where the copy on this Mac is complete")
            .confirmationDialog("Remove the copied files from \(m.deviceName)?", isPresented: $asking, titleVisibility: .visible) {
                Button("Remove from Phone", role: .destructive) { m.removeCopiedFromAndroid { m.afcMessage = $0; m.afcMessageIsError = false } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Each file is checked against its copy on this Mac first; files whose copy is missing or incomplete stay on the phone. Removed files can't be brought back by PortHop.")
            }
        }
    }
}

// MARK: - The Android phone as a place to hop to

/// Shown on Shores when an Android phone is plugged in next to the iPhone: drop a group on it to send it straight across.
struct AndroidTargetCard: View {
    @ObservedObject var m: DeviceManager
    let phone: Device
    let targeted: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "smartphone", color: Color(red: 0.24, green: 0.73, blue: 0.45), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.deviceNames[phone.udid] ?? "Android phone").font(.system(size: 14, weight: .semibold))
                Text("Android phone · drop a group here to send it straight across").font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
        .padding(14)
        .contentSurface(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent, lineWidth: targeted ? 2 : 0))
        .scaleEffect(targeted ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: targeted)
        .help("Photos and videos go into the phone's DCIM › PortHop folder, where its Gallery shows them.")
    }
}
