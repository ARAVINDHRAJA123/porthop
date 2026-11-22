import SwiftUI
import AppKit

enum Phase: Equatable {
    case searching
    case toolsMissing
    case noDevice
    case needsTrust(String)
    case loading(String)
    case ready
    case catalogError(String)
}

@MainActor
final class DeviceManager: ObservableObject {
    // Connection
    @Published var phase: Phase = .searching
    @Published var deviceName = "iPhone"
    @Published var details = DeviceDetails()
    @Published private(set) var device: Device?
    @Published private(set) var devices: [Device] = []
    @Published private(set) var deviceNames: [String: String] = [:]
    private var preferredUDID: String?
    private(set) var tools: Tools?

    // Catalog
    @Published var smartAlbums: [AlbumCategory] = []
    @Published var userAlbums: [AlbumCategory] = []
    @Published var catalogWarnings: [String] = []
    @Published var schemaLabel = ""
    @Published var apps: [AppInfo] = []

    // Browsing
    @Published var selection: String? = "nav_home" { didSet { if oldValue != selection { selectionChanged() } } }
    @Published var searchText = "" { didSet { if oldValue != searchText { refilter(debounce: true) } } }
    @Published var mediaFilter: MediaFilter = .all { didSet { if oldValue != mediaFilter { refilter() } } }
    @Published private(set) var sortField: SortField = .date
    @Published private(set) var sortAscending = false
    @Published private(set) var visibleAssets: [PhotoAsset] = []
    @Published private(set) var visibleGeneration = 0
    @Published private(set) var visibleBytes: Int64 = 0
    @Published private(set) var visibleVideoCount = 0
    @Published private(set) var isFiltering = false
    @Published var selectedIDs: Set<Int64> = [] { didSet { if oldValue != selectedIDs { updateSelectedBytes() } } }
    private(set) var selectedBytes: Int64 = 0
    @Published var previewAsset: PhotoAsset?
    private var filterToken = 0

    // Export
    @Published var options = ExportOptions()
    /// Android: folders of photos and videos from the phone's media index, shown as albums.
    @Published var androidAlbums: [Android.MediaAlbum] = []
    @Published var exportRequest: ExportRequest?
    @Published var isExporting = false { didSet { updateAwake() } }
    @Published var isStopping = false
    @Published var progress = ExportProgress()
    @Published var summary: ExportSummary?
    private var job: ExportJob?

    // File browser (media area or one app's shared folder)
    @Published private(set) var afcApp: String?
    @Published private(set) var afcRoot = "/"
    @Published var afcPath = "/"
    @Published private(set) var afcEntries: [AFCFileEntry] = []
    @Published private(set) var afcGeneration = 0
    @Published var afcSelection: Set<String> = []
    @Published var afcLoading = false
    @Published var afcBusy = false { didSet { updateAwake() } }
    @Published var afcMessage = ""
    @Published var afcMessageIsError = false
    private var transferJob: ExportJob?
    private var browseToken = 0

    // Backups
    @Published var backupFolder: URL = {
        if uiTestBuild, let test = ProcessInfo.processInfo.environment["IPHONE_BACKUP_DIR"] { return URL(fileURLWithPath: test) }
        if let saved = UserDefaults.standard.string(forKey: "backupFolder")
            ?? UserDefaults(suiteName: "com.local.iPhoneAlbumExtractor.v2")?.string(forKey: "backupFolder") { return URL(fileURLWithPath: saved) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("iPhone Backups")
    }() { didSet { UserDefaults.standard.set(backupFolder.path, forKey: "backupFolder"); refreshBackups() } }
    @Published private(set) var backups: [BackupEntry] = []
    @Published private(set) var backupRunning = false { didSet { updateAwake() } }
    @Published private(set) var backupStopping = false
    @Published private(set) var backupPercent: Double? = nil
    @Published private(set) var backupPhase = ""
    @Published private(set) var backupStarted: Date? = nil
    @Published var backupMessage = ""
    @Published var backupFailed = false
    private var backupJob: ExportJob?

    // Data read out of a backup
    @Published var dataKind: BackupKind?
    @Published var data: BackupData?
    @Published var dataSource = ""
    @Published var dataGroupID: Int? { didSet { if oldValue != dataGroupID { dataSelection.removeAll(); rebuildDataRows() } } }
    @Published var dataSearch = "" { didSet { if oldValue != dataSearch { rebuildDataRows() } } }
    @Published var dataRows: [DataRow] = []
    @Published var dataGeneration = 0
    @Published var dataSelection: Set<Int> = []
    @Published var dataMessage = ""
    var dataReader: BackupReader?
    /// Kept in memory for this run only; never saved.
    var dataPassword: String? = uiTestBuild ? ProcessInfo.processInfo.environment["IPHONE_BACKUP_PASSWORD"] : nil
    @Published var dataNeedsPassword = false
    @Published var dataPasswordWrong = false
    @Published var dataUnlocking = false
    var dataToken = 0

    private var pollTimer: Timer?
    private var busy = false

    struct ExportRequest: Identifiable {
        let id = UUID()
        let assets: [PhotoAsset]
        let title: String
        var destination: URL? = nil
        /// The whole group being copied (set only when every item in it is included), for saved hops and {album}.
        var albumID: String? = nil
        var albumName = ""
    }

    var isReady: Bool { phase == .ready }
    var isIPad: Bool { details.productType.hasPrefix("iPad") }
    var isAndroid: Bool { device?.isAndroid == true }
    var deviceKind: String { isAndroid ? "Android device" : (isIPad ? "iPad" : "iPhone") }
    var osName: String { isAndroid ? "Android" : (isIPad ? "iPadOS" : "iOS") }
    var canPower: Bool { isAndroid ? tools?.adb != nil : tools?.diagnostics != nil }
    var canAddFiles: Bool { afcApp != nil || isAndroid }

    nonisolated static func allDevices(_ tools: Tools) -> [Device] { AFC.findDevices(tools) + Android.findDevices(tools) }
    nonisolated static func label(_ d: Device, _ tools: Tools) -> String {
        d.isAndroid ? (d.unauthorized ? "Android (waiting for Allow)" : Android.name(of: d, tools: tools)) : AFC.name(of: d, tools: tools)
    }
    nonisolated static func listDir(_ path: String, app: String?, device: Device, tools: Tools) -> [AFCFileEntry] {
        device.isAndroid ? Android.list(path, device: device, tools: tools) : AFC.list(path, app: app, device: device, tools: tools)
    }

    /// Opens the file browser at one folder (used by the Android home tiles).
    func openFolder(_ path: String) {
        selection = "nav_files"
        browse(path)
    }
    var currentAlbum: AlbumCategory? {
        guard let id = selection else { return nil }
        return smartAlbums.first { $0.id == id } ?? userAlbums.first { $0.id == id }
    }
    var currentApp: AppInfo? { afcApp.flatMap { id in apps.first { $0.id == id } } }
    var selectedAssets: [PhotoAsset] { visibleAssets.filter { selectedIDs.contains($0.id) } }

    func setSort(_ field: SortField, ascending: Bool) {
        guard field != sortField || ascending != sortAscending else { return }
        sortField = field
        sortAscending = ascending
        refilter()
    }

    private func selectionChanged() {
        selectedIDs.removeAll()
        if selection == "nav_backup" { refreshBackups() }
        else if selection == "nav_files" { openBrowser(app: nil) }
        else if let s = selection, s.hasPrefix("bk:"), let kind = BackupKind(rawValue: String(s.dropFirst(3))) { openData(kind) }
        else if let s = selection, s.hasPrefix("app:") { openBrowser(app: String(s.dropFirst(4))) }
        else { resetLensFilters(); refilter() }
    }

    private func updateSelectedBytes() {
        if selectedIDs.isEmpty { selectedBytes = 0; return }
        let ids = selectedIDs
        selectedBytes = visibleAssets.reduce(0) { ids.contains($1.id) ? $0 + max(0, $1.fileSize) : $0 }
    }

    /// Filtering and sorting run off the main thread for big albums so the window never waits on them.
    private func refilter(debounce: Bool = false) {
        filterToken += 1
        let token = filterToken
        guard let album = currentAlbum else { apply([], token: token); return }
        let source = album.assets
        let filter = mediaFilter, field = sortField, asc = sortAscending, range = dateRange, minB = minBytes
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let compute: @Sendable () -> [PhotoAsset] = {
            var list = source
            if filter != .all { list = list.filter(filter.matches) }
            if !q.isEmpty { list = list.filter { $0.searchKey.contains(q) } }
            if let range { list = list.filter { $0.dateCreated.map(range.contains) ?? false } }
            if minB > 0 { list = list.filter { $0.fileSize >= minB } }
            return SortField.sorted(list, by: field, ascending: asc)
        }
        if source.count < 3000 && !debounce {
            apply(compute(), token: token)
            return
        }
        isFiltering = true
        Task.detached(priority: .userInitiated) {
            if debounce { try? await Task.sleep(nanoseconds: 160_000_000) }
            guard await MainActor.run(body: { self.filterToken == token }) else { return }
            let result = compute()
            await MainActor.run { self.apply(result, token: token) }
        }
    }

    private func apply(_ list: [PhotoAsset], token: Int) {
        guard token == filterToken else { return }
        visibleAssets = list
        visibleBytes = list.reduce(0) { $0 + max(0, $1.fileSize) }
        visibleVideoCount = list.reduce(0) { $0 + ($1.isVideo ? 1 : 0) }
        visibleGeneration += 1
        isFiltering = false
        updateSelectedBytes()
    }

    // MARK: Connection

    func start() {
        BackupReader.purgeTemp()
        connect(silent: false)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func switchDevice(to udid: String) {
        guard udid != device?.udid, !isExporting, !afcBusy, !backupRunning else { return }
        preferredUDID = udid
        connect(silent: false)
    }

    private var pollRunning = false
    private func poll() {
        guard !busy, !isExporting, !afcBusy, !backupRunning, !pollRunning else { return }
        switch phase {
        case .noDevice, .needsTrust, .toolsMissing:
            connect(silent: true)
        case .ready:
            guard let device, let tools else { return }
            let knownNames = deviceNames
            pollRunning = true
            Task.detached {
                let found = DeviceManager.allDevices(tools)
                var names = knownNames.filter { k, _ in found.contains { $0.udid == k } }
                for d in found where names[d.udid] == nil { names[d.udid] = DeviceManager.label(d, tools) }
                let finalNames = names
                await MainActor.run {
                    self.pollRunning = false
                    guard !self.isExporting, !self.afcBusy, !self.backupRunning, self.device == device else { return }
                    if found.contains(device) {
                        if self.devices != found { self.devices = found }
                        if self.deviceNames != finalNames { self.deviceNames = finalNames }
                    } else if found.isEmpty {
                        self.reset(to: .noDevice)
                    } else {
                        self.preferredUDID = nil
                        self.reset(to: .searching)
                        self.connect(silent: false)
                    }
                }
            }
        default: break
        }
    }

    private func reset(to newPhase: Phase) {
        androidAlbums = []
        device = nil
        smartAlbums = []; userAlbums = []; catalogWarnings = []; apps = []
        selectedIDs.removeAll()
        afcEntries = []; afcPath = "/"; afcGeneration += 1
        previewAsset = nil
        refilter()
        phase = newPhase
    }

    func connect(silent: Bool) {
        guard !busy, !isExporting, !afcBusy, !backupRunning else { return }
        busy = true
        if !silent { phase = .searching }
        Task.detached {
            guard let tools = Tools.locate() else {
                await self.finish { self.reset(to: .toolsMissing) }
                return
            }
            let found = DeviceManager.allDevices(tools)
            let preferred = await MainActor.run { self.preferredUDID }
            guard let device = found.first(where: { $0.udid == preferred }) ?? found.first else {
                await self.finish { self.tools = tools; self.devices = []; self.reset(to: .noDevice) }
                return
            }
            var names: [String: String] = [:]
            if found.count > 1 { for d in found { names[d.udid] = DeviceManager.label(d, tools) } }
            let foundNames = names
            if device.isAndroid {
                guard !device.unauthorized, let info = Android.details(device, tools: tools) else {
                    await self.finish {
                        self.tools = tools
                        self.reset(to: .needsTrust(device.unauthorized
                            ? "Unlock the Android device and tap Allow on the “Allow USB debugging?” message."
                            : "The Android device is connected but did not answer. Unlock it and keep it plugged in."))
                    }
                    return
                }
                await self.finish {
                    self.tools = tools
                    self.deviceName = info.name
                    self.details = info.details
                    self.device = device
                    self.devices = found
                    self.deviceNames = foundNames.merging([device.udid: info.name]) { _, new in new }
                    self.smartAlbums = []; self.userAlbums = []; self.catalogWarnings = []; self.apps = []
                    self.selectedIDs.removeAll()
                    self.refilter()
                    self.restartingSince = nil; self.phase = .ready
                    if !["nav_home", "nav_device"].contains(self.selection ?? "") { self.selection = "nav_home" }
                    self.runLaunchAction()
                }
                let albums = Android.mediaAlbums(device, tools: tools)
                await MainActor.run { if self.device?.udid == device.udid { self.androidAlbums = albums } }
                return
            }
            guard let info = AFC.details(device, tools: tools) else {
                await self.finish {
                    self.tools = tools
                    self.reset(to: .needsTrust("Unlock your iPhone or iPad and tap Trust when it asks."))
                }
                return
            }
            await MainActor.run {
                self.tools = tools
                self.deviceName = info.name
                self.details = info.details
                self.phase = .loading("Reading the photo library from \(info.name)…")
            }

            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("iPhoneAlbumExtractor2-db-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            var cmds = ""
            for f in ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"] {
                if let l = AFC.quote(temp.appendingPathComponent(f).path) { cmds += "get \"PhotoData/\(f)\" \(l)\n" }
            }
            _ = Shell.run(tools.afc, device.baseArgs, stdin: cmds + "quit\n", timeout: 600)
            let dbURL = temp.appendingPathComponent("Photos.sqlite")
            guard AFC.fileSize(dbURL) > 0 else {
                await self.finish {
                    self.reset(to: .needsTrust("\(info.name) is connected, but its photo library could not be read. Keep it unlocked and tap Trust if asked."))
                }
                return
            }
            await MainActor.run { self.phase = .loading("Organising albums…") }
            let result = CatalogReader.load(path: dbURL.path)

            await self.finish {
                switch result {
                case .success(let cat):
                    self.device = device
                    self.devices = found
                    self.deviceNames = foundNames.merging([device.udid: info.name]) { _, new in new }
                    self.smartAlbums = cat.smart
                    self.userAlbums = cat.user
                    self.catalogWarnings = cat.warnings
                    self.schemaLabel = cat.schemaLabel
                    self.selectedIDs.removeAll()
                    if self.selection == nil || ((self.selection ?? "").hasPrefix("album_") && self.currentAlbum == nil) { self.selection = "nav_home" }
                    self.refilter()
                    self.restartingSince = nil; self.phase = .ready
                    self.loadApps(device: device, tools: tools)
                    self.runLaunchAction()
                case .failure(.unreadable):
                    self.phase = .catalogError("The photo database was copied from the device but could not be opened. Try Refresh with the device unlocked.")
                case .failure(.unsupported(let why)):
                    self.phase = .catalogError("iOS \(info.details.iosVersion) stores its photo library in a format this app does not understand yet. \(why)")
                }
            }
        }
    }

    private func loadApps(device: Device, tools: Tools) {
        Task.detached(priority: .utility) {
            let list = AFC.apps(device, tools: tools)
            await MainActor.run { if self.device == device { self.apps = list } }
        }
    }

    private nonisolated func finish(_ body: @MainActor @escaping () -> Void) async {
        await MainActor.run {
            body()
            self.busy = false
        }
    }

    /// Developer aid for checking the interface without clicking: IPHONE_UI_TEST=sheet | preview | export:<folder> | select:<id>
    private func runLaunchAction() {
        guard uiTestBuild, let action = ProcessInfo.processInfo.environment["IPHONE_UI_TEST"], !didRunLaunchAction else { return }
        didRunLaunchAction = true
        if action == "sheet" { requestExport(selectedOnly: false) }
        else if action == "preview" { previewAsset = visibleAssets.first }
        else if action.hasPrefix("export:") { startExport(visibleAssets, to: URL(fileURLWithPath: String(action.dropFirst(7)))) }
        else if action.hasPrefix("folder:") { openFolder(String(action.dropFirst(7))) }
        else if action.hasPrefix("power:") { power(String(action.dropFirst(6))) }
        else if action.hasPrefix("hop:") {
            let parts = action.dropFirst(4).split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let album = (smartAlbums + userAlbums).first(where: { $0.id == parts[0] }) {
                startExport(album.assets, to: URL(fileURLWithPath: parts[1]))
            }
        }
        else if action.hasPrefix("ask:") {   // the copy sheet for one group to a folder, as when it is dropped there
            let parts = action.dropFirst(4).split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let album = (smartAlbums + userAlbums).first(where: { $0.id == parts[0] }) {
                options.subfolder = .custom; options.folderPattern = "{album}/{year}/{month} {monthName}"
                requestHop(album, to: URL(fileURLWithPath: parts[1]))
            }
        }
        else if action.hasPrefix("select:") { selection = String(action.dropFirst(7)) }
        else if action.hasPrefix("backup:") { backupFolder = URL(fileURLWithPath: String(action.dropFirst(7))); selection = "nav_backup"; startBackup() }
    }
    private var didRunLaunchAction = false

    // MARK: Shores

    @Published var dateRange: ClosedRange<Date>? { didSet { if oldValue != dateRange { refilter() } } }
    @Published var minBytes: Int64 = 0 { didSet { if oldValue != minBytes { refilter() } } }
    /// Where the next copy goes when the user picked a place first (on Shores, in a group, or by asking).
    @Published var pendingDestination: URL?
    /// Where the running copy is going, so its card on Shores can show it receiving.
    @Published private(set) var exportDestination: URL?
    @Published private(set) var volumes: [VolumeInfo] = VolumeInfo.external()
    @Published private(set) var recentDestinations: [String] = UserDefaults.standard.stringArray(forKey: "recentDestinations") ?? []
    @Published private(set) var lastHop = UserDefaults.standard.string(forKey: "lastHop") ?? ""
    private var pendingUploads: [URL] = []

    func refreshVolumes() { volumes = VolumeInfo.external() }

    func rememberDestination(_ url: URL) {
        var list = recentDestinations.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        recentDestinations = Array(list.prefix(6))
        UserDefaults.standard.set(recentDestinations, forKey: "recentDestinations")
    }

    private func resetLensFilters() {
        if !searchText.isEmpty { searchText = "" }
        if mediaFilter != .all { mediaFilter = .all }
        if dateRange != nil { dateRange = nil }
        if minBytes != 0 { minBytes = 0 }
    }

    /// A whole group dropped on a destination: confirm with the usual copy sheet, destination already chosen.
    func requestHop(_ album: AlbumCategory, to destination: URL) {
        guard !album.assets.isEmpty, !isExporting else { return }
        let n = album.assets.count
        exportRequest = ExportRequest(assets: album.assets, title: "Copy \(Fmt.count(n)) item\(n == 1 ? "" : "s") from \(album.title)",
                                      destination: destination, albumID: album.id, albumName: album.title)
    }

    /// Android storage folders dropped on a destination are copied whole.
    func copyFolders(_ paths: [String], to folder: URL) {
        rememberDestination(folder)
        download(paths.map { AFCFileEntry(name: ($0 as NSString).lastPathComponent, path: $0, isDirectory: true, size: 0, modifiedDate: "") },
                 app: nil, to: folder)
    }

    /// Files dropped from Finder onto the device: opens the app's folder (or Android's Download folder) and adds them there.
    func sendFiles(_ urls: [URL], toApp app: String?) {
        guard !urls.isEmpty, !afcBusy else { return }
        pendingUploads = urls
        if isAndroid { openFolder(Android.storageRoot + "/Download") }
        else if let app { if selection == "app:\(app)" { selectionChanged() } else { selection = "app:\(app)" } }
    }

    private func runPendingUploads() {
        guard !pendingUploads.isEmpty else { return }
        let urls = pendingUploads
        pendingUploads = []
        upload(urls)
    }

    // MARK: Export

    func requestExport(selectedOnly: Bool) {
        let items = selectedOnly ? selectedAssets : visibleAssets
        guard !items.isEmpty else { return }
        let title = selectedOnly ? "Copy \(Fmt.count(items.count)) selected item\(items.count == 1 ? "" : "s")"
                                 : "Copy \(Fmt.count(items.count)) item\(items.count == 1 ? "" : "s") from \(currentAlbum?.title ?? "album")"
        let whole = !selectedOnly && currentAlbum.map { $0.assets.count == items.count } == true
        exportRequest = ExportRequest(assets: items, title: title, destination: pendingDestination,
                                      albumID: whole ? currentAlbum?.id : nil, albumName: currentAlbum?.title ?? "")
    }

    func startExport(_ assets: [PhotoAsset], to destination: URL, albumName: String? = nil, options override: ExportOptions? = nil) {
        guard let device, let tools, !assets.isEmpty, !isExporting else { return }
        UserDefaults.standard.set(destination.path, forKey: "lastDestination")
        rememberDestination(destination)
        exportDestination = destination
        let job = ExportJob()
        self.job = job
        isExporting = true
        isStopping = false
        var p = ExportProgress()
        p.total = assets.count
        progress = p
        var opts = override ?? options
        opts.albumName = albumName ?? currentAlbum?.title ?? ""
        var lastEmit = Date.distantPast
        Task.detached {
            let result = Exporter.run(assets: assets, destination: destination, options: opts, device: device, tools: tools, job: job) { p in
                let now = Date()
                if now.timeIntervalSince(lastEmit) < 0.15 && p.processed < p.total { return }
                lastEmit = now
                Task { @MainActor in if self.isExporting { self.progress = p } }
            }
            await MainActor.run {
                self.isExporting = false
                self.isStopping = false
                self.job = nil
                self.summary = result
                self.exportDestination = nil
                if result.copied > 0 {
                    let f = DateFormatter()
                    f.dateStyle = .medium
                    f.timeStyle = .short
                    self.lastHop = "\(Fmt.count(result.copied)) item\(result.copied == 1 ? "" : "s") to \(destination.lastPathComponent) · \(f.string(from: Date()))"
                    UserDefaults.standard.set(self.lastHop, forKey: "lastHop")
                }
                if result.isClean { NSSound(named: "Glass")?.play() }
            }
        }
    }

    // MARK: Saved hops

    /// A copy saved for one click: a whole group to a folder, with its options. Running it again copies only what is new.
    struct HopPreset: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var albumID: String
        var destination: String
        var editedVersions = false
        var convertHEIC = false
        var includeLiveVideo = false
        var useOriginalNames = false
        var subfolder = SubfolderMode.flat.rawValue
        var folderPattern = "{year}/{month}"
    }

    @Published var presets: [HopPreset] = (try? JSONDecoder().decode([HopPreset].self, from: UserDefaults.standard.data(forKey: "hopPresets") ?? Data())) ?? []

    private func savePresets() { UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: "hopPresets") }

    func savePreset(name: String, albumID: String, destination: URL, options o: ExportOptions) {
        presets.removeAll { $0.albumID == albumID && $0.destination == destination.path }
        presets.append(HopPreset(name: name, albumID: albumID, destination: destination.path, editedVersions: o.editedVersions,
                                 convertHEIC: o.convertHEIC, includeLiveVideo: o.includeLiveVideo, useOriginalNames: o.useOriginalNames,
                                 subfolder: o.subfolder.rawValue, folderPattern: o.folderPattern))
        savePresets()
    }

    func deletePreset(_ p: HopPreset) { presets.removeAll { $0.id == p.id }; savePresets() }

    /// The group a saved hop copies, on the device connected now (nil if it has no such group).
    func album(for p: HopPreset) -> AlbumCategory? { (smartAlbums + userAlbums).first { $0.id == p.albumID } }

    func runPreset(_ p: HopPreset) {
        guard let album = album(for: p), !album.assets.isEmpty else { return }
        var o = ExportOptions()
        o.skipExisting = true
        o.editedVersions = p.editedVersions; o.convertHEIC = p.convertHEIC; o.includeLiveVideo = p.includeLiveVideo
        o.useOriginalNames = p.useOriginalNames; o.subfolder = SubfolderMode(rawValue: p.subfolder) ?? .flat; o.folderPattern = p.folderPattern
        startExport(album.assets, to: URL(fileURLWithPath: p.destination), albumName: album.title, options: o)
    }

    func stopExport() {
        isStopping = true
        job?.cancel()
    }

    func retryFailed(_ summary: ExportSummary) {
        let assets = summary.failures.map(\.asset)
        self.summary = nil
        startExport(assets, to: summary.destination)
    }

    func shutdown() {
        dataReader = nil
        BackupReader.purgeTemp()
        job?.cancel()
        transferJob?.cancel()
        backupJob?.cancel()
        ThumbnailLoader.purgeDiskCache()
    }

    // MARK: Android setup

    @Published var androidSetupMessage = ""
    @Published var androidSettingUp = false

    /// Downloads Google's Android tool on request (it may not be shipped inside other apps).
    func setUpAndroid() {
        guard !androidSettingUp else { return }
        androidSettingUp = true
        androidSetupMessage = "Downloading from Google…"
        Task {
            let problem = await Android.setUp()
            androidSettingUp = false
            androidSetupMessage = problem ?? "Android support is ready. Turn on USB debugging on the phone and plug it in."
            if problem == nil { tools = Tools.locate(); connect(silent: true) }
        }
    }

    // MARK: Power

    /// Set when the device was told to restart, so the app says so instead of asking to connect a device.
    @Published var restartingSince: Date?
    var isRestarting: Bool { restartingSince.map { Date().timeIntervalSince($0) < 600 } ?? false }

    private var awakeToken: NSObjectProtocol?
    /// Keeps the Mac from sleeping while a copy, backup or restore runs.
    private func updateAwake() {
        let busy = isExporting || afcBusy || backupRunning
        if busy, awakeToken == nil {
            awakeToken = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Copying between this Mac and a device")
        } else if !busy, let token = awakeToken {
            ProcessInfo.processInfo.endActivity(token)
            awakeToken = nil
        }
    }

    @Published var powerMessage = ""

    func power(_ action: String) {
        guard let device, let tools, !isExporting, !afcBusy, !backupRunning else { return }
        powerMessage = action == "restart" ? "Asking the \(deviceKind) to restart…" : "Putting the \(deviceKind) to sleep…"
        let kind = deviceKind
        Task.detached {
            let ok = device.isAndroid ? Android.power(action, device: device, tools: tools) : AFC.power(action, device: device, tools: tools)
            await MainActor.run {
                if ok && action == "restart" { self.restartingSince = Date() }
                self.powerMessage = ok ? (action == "restart" ? "The \(kind) is restarting. It will reappear here when it is back." : "The \(kind) is asleep.")
                                       : "The \(kind) did not accept the request. Unlock it and try again."
            }
        }
    }

    // MARK: Backups

    func refreshBackups() {
        let folder = backupFolder
        Task.detached(priority: .utility) {
            let list = Backup.existing(in: folder)
            await MainActor.run { if self.backupFolder == folder { self.backups = list } }
        }
    }

    func startBackup() {
        guard let device, let tools, !device.isAndroid, !backupRunning, !isExporting, !afcBusy else { return }
        let job = ExportJob()
        backupJob = job
        backupRunning = true
        backupStopping = false
        backupPercent = nil
        backupPhase = "Starting… enter the passcode on the \(deviceKind) if it asks."
        backupStarted = Date()
        backupMessage = ""
        let folder = backupFolder
        var last = Date.distantPast
        Task.detached {
            let problem = Backup.run(device: device, tools: tools, folder: folder, job: job) { percent, phase in
                let now = Date()
                if now.timeIntervalSince(last) < 0.25 { return }
                last = now
                Task { @MainActor in
                    guard self.backupRunning else { return }
                    if let percent { self.backupPercent = percent }
                    self.backupPhase = phase
                }
            }
            await MainActor.run {
                self.backupRunning = false
                self.backupStopping = false
                self.backupJob = nil
                self.backupFailed = problem != nil
                self.backupMessage = problem ?? "Backup complete."
                if problem == nil { NSSound(named: "Glass")?.play() }
                self.refreshBackups()
            }
        }
    }

    @Published private(set) var restoring = false

    /// Replaces the connected device's settings and app data with a backup. Only called after the user confirms.
    func startRestore(_ entry: BackupEntry, password: String?) {
        guard let device, let tools, !device.isAndroid, !backupRunning, !isExporting, !afcBusy else { return }
        let job = ExportJob()
        backupJob = job
        backupRunning = true
        restoring = true
        backupStopping = false
        backupPercent = nil
        backupPhase = "Starting the restore… enter the passcode on the \(deviceKind) if it asks."
        backupStarted = Date()
        backupMessage = ""
        let kind = deviceKind
        var last = Date.distantPast
        Task.detached {
            let problem = Backup.restore(entry, to: device, tools: tools, password: password, job: job) { percent, phase in
                let now = Date()
                if now.timeIntervalSince(last) < 0.25 { return }
                last = now
                Task { @MainActor in
                    guard self.backupRunning else { return }
                    if let percent { self.backupPercent = percent }
                    self.backupPhase = phase
                }
            }
            await MainActor.run {
                self.backupRunning = false
                self.restoring = false
                self.backupStopping = false
                self.backupJob = nil
                self.backupFailed = problem != nil
                if problem == nil { self.restartingSince = Date() }
                self.backupMessage = problem ?? "Restore complete. The \(kind) is restarting and will reappear here when it is back."
                if problem == nil { NSSound(named: "Glass")?.play() }
            }
        }
    }

    func stopBackup() {
        backupStopping = true
        backupJob?.cancel()
    }

    // MARK: File browser

    private func openBrowser(app: String?) {
        guard let device, let tools else { return }
        afcApp = app
        afcRoot = device.isAndroid ? Android.storageRoot : "/"
        afcPath = afcRoot
        afcEntries = []
        afcGeneration += 1
        afcSelection.removeAll()
        afcMessage = ""
        afcLoading = true
        browseToken += 1
        let token = browseToken
        Task.detached {
            var root = device.isAndroid ? Android.storageRoot : "/"
            var entries = DeviceManager.listDir(root, app: app, device: device, tools: tools)
            // An app's shared area is a "Documents" folder inside its container; start there.
            if app != nil, entries.contains(where: { $0.isDirectory && $0.name == "Documents" }) {
                root = "/Documents"
                entries = AFC.list(root, app: app, device: device, tools: tools)
            }
            let finalRoot = root, finalEntries = entries
            await MainActor.run {
                guard token == self.browseToken else { return }
                self.afcRoot = finalRoot
                self.afcPath = finalRoot
                self.afcEntries = finalEntries
                self.afcGeneration += 1
                self.afcLoading = false
                self.runPendingUploads()
            }
        }
    }

    func browse(_ path: String, keepMessage: Bool = false) {
        guard let device, let tools else { return }
        afcLoading = true
        browseToken += 1
        let token = browseToken
        let app = afcApp
        Task.detached {
            let entries = DeviceManager.listDir(path, app: app, device: device, tools: tools)
            await MainActor.run {
                guard token == self.browseToken else { return }
                self.afcPath = path
                self.afcEntries = entries
                self.afcGeneration += 1
                self.afcSelection.removeAll()
                self.afcLoading = false
                if !keepMessage { self.afcMessage = "" }
                self.runPendingUploads()
            }
        }
    }

    var canBrowseUp: Bool { afcPath != afcRoot && afcPath != "/" }

    func browseUp() {
        guard canBrowseUp else { return }
        let parent = (afcPath as NSString).deletingLastPathComponent
        browse(parent.isEmpty ? "/" : parent)
    }

    func stopTransfer() { transferJob?.cancel() }

    /// Device → Mac for the selected files and folders.
    func downloadAFCSelection(to folder: URL) {
        download(afcEntries.filter { afcSelection.contains($0.path) }, app: afcApp, to: folder)
    }

    /// Device → Mac for files and folders, never overwriting. Used by the file browser and by Android folder hops.
    func download(_ chosen: [AFCFileEntry], app: String?, to folder: URL) {
        guard let device, let tools, !chosen.isEmpty, !afcBusy else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let job = ExportJob()
        transferJob = job
        afcBusy = true
        afcMessageIsError = false
        afcMessage = "Copying \(chosen.count) item\(chosen.count == 1 ? "" : "s") to your Mac…"
        Task.detached {
            var saved: [URL] = []
            var reserved = Set<String>()
            for (i, entry) in chosen.enumerated() {
                if job.isCancelled { break }
                await MainActor.run { self.afcMessage = "Copying \(i + 1) of \(chosen.count) to your Mac: \(entry.name)" }
                let remote = entry.path.hasPrefix("/") ? String(entry.path.dropFirst()) : entry.path
                var dest = folder.appendingPathComponent(entry.name)
                if FileManager.default.fileExists(atPath: dest.path) || reserved.contains(dest.path) {
                    dest = Exporter.uniqueURL(for: dest, avoiding: reserved)
                }
                reserved.insert(dest.path)
                if device.isAndroid {
                    _ = Android.pull(entry.path, to: dest, device: device, tools: tools, onStart: { job.track($0) })
                } else {
                    let args = device.baseArgs + AFC.container(app) + ["--", "get"] + (entry.isDirectory ? ["-r"] : []) + [remote, dest.path]
                    _ = Shell.run(tools.afc, args, onStart: { job.track($0) })
                }
                job.clear()
                let ok = FileManager.default.fileExists(atPath: dest.path) && (entry.isDirectory || entry.size <= 0 || AFC.fileSize(dest) == entry.size)
                if ok && !job.isCancelled { saved.append(dest) } else if !entry.isDirectory { try? FileManager.default.removeItem(at: dest) }
            }
            let done = saved
            let cancelled = job.isCancelled
            await MainActor.run {
                self.afcBusy = false
                self.transferJob = nil
                let missed = chosen.count - done.count
                self.afcMessageIsError = missed > 0 && !cancelled
                self.afcMessage = cancelled ? "Stopped. \(done.count) of \(chosen.count) copied."
                    : (missed == 0 ? "Copied \(done.count) item\(done.count == 1 ? "" : "s") to “\(folder.lastPathComponent)”."
                                   : "Copied \(done.count) of \(chosen.count). \(missed) could not be copied.")
                if !done.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(done) }
            }
        }
    }

    /// Mac → device: adds files or folders to the folder being shown (apps' shared folders only).
    func upload(_ urls: [URL]) {
        guard let device, let tools, canAddFiles, !urls.isEmpty, !afcBusy else { return }
        let app = afcApp
        let dir = afcPath
        let names = Set(afcEntries.map(\.name))
        let job = ExportJob()
        transferJob = job
        afcBusy = true
        afcMessageIsError = false
        let android = device.isAndroid
        let target = android ? "“\((afcPath as NSString).lastPathComponent)”" : (currentApp?.name ?? "the app")
        let kind = deviceKind
        afcMessage = "Adding \(urls.count) item\(urls.count == 1 ? "" : "s") to \(target)…"
        Task.detached {
            var existing = names
            var added = 0
            for (i, url) in urls.enumerated() {
                if job.isCancelled { break }
                await MainActor.run { self.afcMessage = "Adding \(i + 1) of \(urls.count) to \(target): \(url.lastPathComponent)" }
                let ok = android ? Android.push(url, intoDir: dir, existing: &existing, device: device, tools: tools, onStart: { job.track($0) })
                                 : AFC.put(url, intoDir: dir, existing: &existing, app: app, device: device, tools: tools, onStart: { job.track($0) })
                if ok { added += 1 }
                job.clear()
            }
            let after = DeviceManager.listDir(dir, app: app, device: device, tools: tools)
            let total = added
            let cancelled = job.isCancelled
            await MainActor.run {
                self.afcBusy = false
                self.transferJob = nil
                if self.afcApp == app, self.afcPath == dir {
                    self.afcEntries = after
                    self.afcGeneration += 1
                }
                let missed = urls.count - total
                self.afcMessageIsError = missed > 0 && !cancelled
                self.afcMessage = cancelled ? "Stopped. \(total) of \(urls.count) added."
                    : (missed == 0 ? "Added \(total) item\(total == 1 ? "" : "s") to \(target)." + (android ? "" : " Open the app on the \(kind) to see \(total == 1 ? "it" : "them").")
                                   : "Added \(total) of \(urls.count). \(missed) could not be added.")
                if missed == 0 && !cancelled { NSSound(named: "Glass")?.play() }
            }
        }
    }

    func newFolder(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard let device, let tools, canAddFiles, !clean.isEmpty, !afcBusy else { return }
        let app = afcApp
        let path = afcPath == "/" ? "/\(clean)" : "\(afcPath)/\(clean)"
        let dir = afcPath
        afcLoading = true
        Task.detached {
            let ok = device.isAndroid ? Android.mkdir(path, device: device, tools: tools) : AFC.mkdir(path, app: app, device: device, tools: tools)
            await MainActor.run {
                self.afcMessageIsError = !ok
                self.afcMessage = ok ? "Created “\(clean)”." : "The folder could not be created."
                self.browse(dir, keepMessage: true)
            }
        }
    }
}
