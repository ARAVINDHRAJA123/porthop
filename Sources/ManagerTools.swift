import Foundation
import AppKit

/// The phone tools: spyware check, apps, music and ringtones, sending to an Android phone, removing copied items from the
/// phone, Wi-Fi backups, the phone report and installing updates.
extension DeviceManager {
    /// What the tools read from one phone (its apps, music, last spyware check) is dropped when another phone takes its place.
    func clearDeviceTools() {
        installedApps = []; appsLoaded = false; appsMessage = ""; appsMessageIsError = false
        songs = []; musicLoaded = false; musicMessage = ""
        spyReport = nil; spyMessage = ""; spyNeedsPassword = false
        androidCopied = []; phoneWiFiSync = nil
    }

    // MARK: Spyware check

    func loadSpySources() { spySources = Spyware.sources(in: Spyware.folder) }

    func downloadIndicators() {
        guard !spyBusy else { return }
        spyBusy = true
        spyMessage = "Downloading the latest indicator files…"
        Task {
            let problem = await Spyware.download(to: Spyware.folder)
            spyBusy = false
            loadSpySources()
            spyMessage = problem ?? "Indicators updated: \(Fmt.count(spySources.reduce(0) { $0 + $1.count })) from \(spySources.count) investigations."
        }
    }

    func addIndicatorFile(_ url: URL) {
        let problem = Spyware.add(file: url, to: Spyware.folder)
        loadSpySources()
        spyMessage = problem ?? "Added “\(url.lastPathComponent)”."
    }

    /// The newest finished backup of the connected iPhone (the check reads that, never the phone itself).
    var spyBackup: BackupEntry? {
        guard let d = device else { return nil }
        return backups.filter { !$0.isSnapshot && $0.path.lastPathComponent == d.udid }.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    func runSpywareCheck(password: String? = nil) {
        guard let device, let tools, !spyBusy else { return }
        let set = Spyware.load(from: Spyware.folder)
        guard !set.isEmpty else { spyMessage = "Download the indicators first."; return }
        spyBusy = true
        spyNeedsPassword = false
        spyReport = nil
        spyMessage = device.isAndroid ? "Checking \(deviceName)…" : "Reading the backup…"
        let name = deviceName
        let entry = spyBackup
        Task.detached(priority: .userInitiated) {
            var report: Spyware.Report?
            var message = ""
            var needs = false
            if device.isAndroid {
                report = Spyware.scan(android: device, tools: tools, with: set)
            } else if let entry {
                switch BackupReader.open(folder: entry.path, password: password) {
                case .ready(let r): report = Spyware.scan(backup: r, with: set)
                case .needsPassword: needs = true; message = "This backup is encrypted. Enter its password to check it."
                case .wrongPassword: needs = true; message = "That password didn't open the backup."
                case .unreadable: message = "The backup could not be opened. Make a new one and try again."
                }
            } else {
                message = "Make a backup of \(name) first: the check reads the backup, so nothing on the iPhone changes."
            }
            let final = report, finalMessage = message, finalNeeds = needs
            await MainActor.run {
                self.spyBusy = false
                self.spyNeedsPassword = finalNeeds
                self.spyReport = final
                self.spyReportFor = name
                self.spyMessage = final == nil ? finalMessage : ""
            }
        }
    }

    func saveSpyReport(to url: URL) {
        guard let r = spyReport else { return }
        let source = isAndroid ? "checked live over USB" : (spyBackup?.date.map { "from the backup made \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "from a backup")
        savePage(Spyware.html(r, device: spyReportFor, source: source), as: url) { self.spyMessage = $0 }
    }

    /// Saves a web page as a PDF (or as the page itself when the name ends in .html).
    func savePage(_ html: String, as url: URL, report: @escaping (String) -> Void) {
        if url.pathExtension.lowercased() == "html" {
            report((try? html.write(to: url, atomically: true, encoding: .utf8)) != nil ? "Saved “\(url.lastPathComponent)”." : "It could not be saved there.")
            return
        }
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("PortHop-page-\(UUID().uuidString).html")
        guard (try? html.write(to: page, atomically: true, encoding: .utf8)) != nil else { report("It could not be saved."); return }
        PagePrinter.pdf(from: page, to: url) { ok in
            try? FileManager.default.removeItem(at: page)
            report(ok ? "Saved “\(url.lastPathComponent)”." : "The PDF could not be made.")
            if ok { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    // MARK: Phone report

    func savePhoneReport(to url: URL) {
        savePage(PhoneReport.html(name: deviceName, details: details, isAndroid: isAndroid), as: url) { self.powerMessage = $0 }
    }

    // MARK: Apps

    func loadApps() {
        guard let device, let tools, !appsBusy else { return }
        appsBusy = true
        appsMessage = ""
        Task.detached {
            let list = AppManager.list(device: device, tools: tools)
            await MainActor.run {
                self.appsBusy = false
                self.appsLoaded = true
                self.installedApps = list ?? []
                self.appsMessageIsError = list == nil
                self.appsMessage = list == nil ? "The app list could not be read. Unlock the phone and try again." : ""
            }
        }
    }

    func installApp(_ file: URL) {
        guard let device, let tools, !appsBusy else { return }
        appsBusy = true
        appsMessageIsError = false
        appsMessage = "Installing \(file.lastPathComponent)…"
        Task.detached {
            let problem = AppManager.install(file, device: device, tools: tools) { p in
                Task { @MainActor in self.appsMessage = "Installing \(file.lastPathComponent)… \(p)%" }
            }
            let list = AppManager.list(device: device, tools: tools)
            await MainActor.run {
                self.appsBusy = false
                if let list { self.installedApps = list }
                self.appsMessageIsError = problem != nil
                self.appsMessage = problem ?? "Installed \(file.deletingPathExtension().lastPathComponent)."
            }
        }
    }

    func removeApp(_ app: InstalledApp) {
        guard let device, let tools, !appsBusy else { return }
        appsBusy = true
        appsMessageIsError = false
        appsMessage = "Removing \(app.name)…"
        Task.detached {
            let problem = AppManager.uninstall(app.id, device: device, tools: tools)
            await MainActor.run {
                self.appsBusy = false
                if problem == nil { self.installedApps.removeAll { $0.id == app.id } }
                self.appsMessageIsError = problem != nil
                self.appsMessage = problem ?? "Removed \(app.name) and its data."
            }
        }
    }

    // MARK: Music and ringtones

    func loadMusic() {
        guard let device, let tools, !device.isAndroid, !musicBusy else { return }
        musicBusy = true
        musicMessage = "Reading the music library…"
        Task.detached {
            let (list, problem) = MusicLibrary.load(device: device, tools: tools)
            await MainActor.run {
                self.musicBusy = false
                self.musicLoaded = true
                self.songs = list
                self.musicMessage = problem ?? ""
            }
        }
    }

    /// The Android phone plugged in alongside the iPhone, if there is one.
    var androidPeer: Device? { devices.first { $0.isAndroid && !$0.unauthorized && $0.udid != device?.udid } }

    func copyMusic(_ chosen: [Song], to folder: URL? = nil, toAndroid phone: Device? = nil) {
        guard let device, let tools, !musicBusy, !chosen.isEmpty, folder != nil || phone != nil else { return }
        let job = ExportJob()
        musicJob = job
        musicBusy = true
        let peerName = phone.map { deviceNames[$0.udid] ?? "the Android phone" } ?? ""
        Task.detached {
            let report: (Int, Int, String) -> Void = { n, total, title in
                Task { @MainActor in self.musicMessage = "\(phone == nil ? "Copying" : "Sending") \(n + 1) of \(total): \(title)" }
            }
            var outcome = MusicLibrary.Outcome()
            if let phone { outcome = MusicLibrary.send(chosen, from: device, toAndroid: phone, tools: tools, job: job, progress: report) }
            else if let folder { outcome = MusicLibrary.copy(chosen, to: folder, device: device, tools: tools, job: job, progress: report) }
            let o = outcome
            await MainActor.run {
                self.musicBusy = false
                self.musicJob = nil
                var parts = ["\(phone == nil ? "Copied" : "Sent") \(Fmt.count(o.copied))"]
                if o.skipped > 0 { parts.append("\(Fmt.count(o.skipped)) already there") }
                if !o.failed.isEmpty { parts.append("\(Fmt.count(o.failed.count)) couldn't be copied (protected by Apple Music, or only in the cloud)") }
                self.musicMessage = (o.cancelled ? "Stopped. " : "") + parts.joined(separator: ", ") + (phone == nil ? "." : " to \(peerName).")
                if let folder, o.copied > 0 { NSWorkspace.shared.open(folder) }
            }
        }
    }

    func stopMusic() { musicJob?.cancel() }

    func makeRingtone(from source: URL, start: Double, length: Double, to dest: URL, sendTo phone: Device?) {
        guard let tools else { return }
        musicBusy = true
        musicMessage = "Making the ringtone…"
        Task {
            let problem = await RingtoneMaker.make(from: source, start: start, length: length, to: dest)
            var note = problem ?? "Ringtone saved as “\(dest.lastPathComponent)”."
            if problem == nil, let phone {
                let sent: Bool = await Task.detached {
                    var existing = Set(Android.list(Android.storageRoot + "/Ringtones", device: phone, tools: tools).map(\.name))
                    guard Android.mkdirs(Android.storageRoot + "/Ringtones", device: phone, tools: tools),
                          Android.push(dest, intoDir: Android.storageRoot + "/Ringtones", existing: &existing, device: phone, tools: tools) else { return false }
                    Android.scan([Android.storageRoot + "/Ringtones/" + dest.lastPathComponent], device: phone, tools: tools)
                    return true
                }.value
                note += sent ? " It's on the Android phone too: pick it in Settings › Sound › Ringtone." : " It couldn't be sent to the Android phone."
            } else if problem == nil {
                note += " To put it on the iPhone, drag it onto the iPhone in Finder's sidebar (General tab), then pick it in Settings › Sounds & Haptics."
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }
            musicBusy = false
            musicMessage = note
        }
    }

    // MARK: Sending a group straight to an Android phone

    /// Copies the items from the iPhone into a temporary folder, sends them to the Android phone's DCIM/PortHop/<group>,
    /// and lets its Gallery know. Items already on the phone (same name and size) are skipped.
    func startAndroidHop(_ assets: [PhotoAsset], to phone: Device, albumName: String, options override: ExportOptions) {
        guard let device, let tools, !assets.isEmpty, !isExporting else { return }
        let job = ExportJob()
        self.job = job
        isExporting = true
        isStopping = false
        var p = ExportProgress()
        p.total = assets.count
        progress = p
        var opts = override
        opts.albumName = albumName
        opts.deviceName = deviceName
        opts.saveReport = false
        opts.skipExisting = false
        let folderName = Pattern.safe(albumName).isEmpty ? "From iPhone" : Pattern.safe(albumName)
        let remoteRoot = Android.storageRoot + "/DCIM/PortHop/" + folderName
        let phoneName = deviceNames[phone.udid] ?? "Android phone"
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("PortHop-hop-" + UUID().uuidString, isDirectory: true)
        var lastEmit = Date.distantPast
        Task.detached {
            defer { try? FileManager.default.removeItem(at: staging) }
            var result = Exporter.run(assets: assets, destination: staging, options: opts, device: device, tools: tools, job: job) { p in
                let now = Date()
                if now.timeIntervalSince(lastEmit) < 0.15 && p.processed < p.total { return }
                lastEmit = now
                Task { @MainActor in if self.isExporting { self.progress = p } }
            }
            // Then send each file, keeping the folder layout the copy options made.
            let sent = Android.sendFolder(staging, to: remoteRoot, phone: phone, tools: tools, job: job) { done, total in
                Task { @MainActor in var q = self.progress; q.total = total; q.copied = done; q.skipped = 0; q.failed = 0; q.inFlight = 1; self.progress = q }
            }
            if job.isCancelled { result.cancelled = true }
            result.sentTo = "\(phoneName) › DCIM/PortHop/\(folderName)"
            result.sentCount = sent.sent
            result.sentAlready = sent.already
            result.sendFailures = sent.failed
            let final = result
            await MainActor.run {
                self.isExporting = false
                self.isStopping = false
                self.job = nil
                self.summary = final
                if final.isClean && final.sendFailures.isEmpty { NSSound(named: "Glass")?.play() }
            }
        }
    }

    // MARK: Removing copied items from the phone

    /// After a copy with "Remove from the iPhone after copying": removes the confirmed items through the camera interface.
    func removeCopiedFromIPhone(_ s: ExportSummary, options: ExportOptions, done: @escaping (String) -> Void) {
        guard let device, !device.isAndroid, !cleanupBusy else { return }
        let assets = Cleanup.confirmed(s, options: options)
        guard !assets.isEmpty else { done("Nothing was removed: no copy could be confirmed."); return }
        cleanupBusy = true
        let deleter = IPhoneCameraDeleter(udid: device.udid, name: deviceName)
        deleter.run(choose: { files in Cleanup.deletable(assets, files: files, liveVideos: options.includeLiveVideo) }) { result in
            self.cleanupBusy = false
            switch result {
            case .success(let r):
                let missed = assets.count - r.removed
                done(r.removed == 0 ? "Nothing was removed. The iPhone didn't offer these items (Hidden album and iCloud-only items can't be removed this way)."
                     : "Removed \(Fmt.count(r.removed)) item\(r.removed == 1 ? "" : "s") from the iPhone." + (missed > 0 ? " \(Fmt.count(missed)) stayed (Hidden album, iCloud-only, or not offered by the iPhone)." : ""))
                self.connect(silent: true)
            case .failure(let e): done(e.message)
            }
        }
    }

    /// Removes from the Android phone the files of the folders just copied whose copies are confirmed (same size).
    func removeCopiedFromAndroid(done: @escaping (String) -> Void) {
        guard let device, let tools, device.isAndroid, !cleanupBusy, !androidCopied.isEmpty else { return }
        cleanupBusy = true
        let pairs = androidCopied
        Task.detached {
            let confirmed = Cleanup.androidConfirmed(pairs, device: device, tools: tools)
            let gone = Android.delete(confirmed.map(\.path), device: device, tools: tools)
            await MainActor.run {
                self.cleanupBusy = false
                self.androidCopied = []
                done(gone.isEmpty ? "Nothing was removed: no copy could be confirmed." : "Removed \(Fmt.count(gone.count)) file\(gone.count == 1 ? "" : "s") from the phone (only ones whose copy matched).")
                self.connect(silent: true)
            }
        }
    }

    // MARK: Wi-Fi backups

    func readPhoneWiFiSync() {
        guard let device, let tools, !device.isAndroid else { phoneWiFiSync = nil; return }
        Task.detached {
            let on = WiFiSync.state(device: device, tools: tools)
            await MainActor.run { self.phoneWiFiSync = on }
        }
    }

    /// Turns Wi-Fi backups on or off: the iPhone's own setting (while it is on USB) and PortHop's daily check.
    func setWiFiBackups(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "wifiBackup")
        if let device, let tools, !device.isAndroid {
            Task.detached {
                let state = WiFiSync.state(device: device, tools: tools, set: on ? true : nil)
                await MainActor.run { self.phoneWiFiSync = state }
            }
        }
        startWiFiBackupWatch()
    }

    /// Every ten minutes, while the setting is on: an iPhone that was backed up here before, now on the same Wi-Fi and not on
    /// USB, gets its daily backup over Wi-Fi. The screen keeps showing whatever it showed.
    func startWiFiBackupWatch() {
        wifiTimer?.invalidate()
        wifiTimer = nil
        guard UserDefaults.standard.bool(forKey: "wifiBackup"), !uiTestBuild else { return }
        wifiTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkWiFiBackups() }
        }
    }

    func checkWiFiBackups() {
        guard let tools, tools.backup != nil, !backupRunning, !isExporting, !afcBusy else { return }
        let folder = backupFolder
        let usb = Set(devices.filter { !$0.isNetwork }.map(\.udid))
        let tried = wifiTried
        Task.detached {
            let online = (Shell.run(tools.ideviceId, ["-n"], timeout: 10)?.output ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains(" ") }
            let known = Backup.existing(in: folder).filter { !$0.isSnapshot }
            for udid in online where !usb.contains(udid) {
                let last = known.filter { $0.path.lastPathComponent == udid }.compactMap(\.date).max()
                guard let last, Date().timeIntervalSince(last) > 20 * 3600 else { continue }
                if let t = tried[udid], Date().timeIntervalSince(t) < 6 * 3600 { continue }
                await MainActor.run {
                    self.wifiTried[udid] = Date()
                    self.startBackup(automatic: true, target: Device(udid: udid, isNetwork: true))
                }
                return
            }
        }
    }

    // MARK: Updates

    func installUpdate() {
        guard let r = update, updateStatus.isEmpty else { return }
        guard !isExporting, !backupRunning, !afcBusy, !musicBusy, !appsBusy else {
            inform("Finish what's running first", "PortHop restarts to install the update. Wait for the current copy or backup to finish, or stop it, then try again.")
            return
        }
        updateStatus = "Starting…"
        Task {
            let problem = await Updates.install(r) { self.updateStatus = $0 }
            updateStatus = ""
            if let problem { inform("The update wasn't installed", problem + " Nothing was changed.") }
        }
    }
}
