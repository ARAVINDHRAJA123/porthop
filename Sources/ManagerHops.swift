import SwiftUI
import AppKit

// Saved hops, the hops that run by themselves when a device is plugged in, and update checks.

extension DeviceManager {
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
        var namePattern = ""
        var removeLocation = false
        var saveReport = true
        /// Runs by itself whenever `deviceID` is plugged in (never for another phone).
        var auto = false
        var deviceID: String? = nil

        init(name: String, albumID: String, destination: String, options o: ExportOptions, auto: Bool = false, deviceID: String? = nil) {
            self.name = name; self.albumID = albumID; self.destination = destination
            editedVersions = o.editedVersions; convertHEIC = o.convertHEIC; includeLiveVideo = o.includeLiveVideo
            useOriginalNames = o.useOriginalNames; subfolder = o.subfolder.rawValue; folderPattern = o.folderPattern
            namePattern = o.namePattern; removeLocation = o.removeLocation; saveReport = o.saveReport
            self.auto = auto; self.deviceID = deviceID
        }

        // Hops saved by earlier versions lack the newer settings; they load with the defaults.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try c.decode(String.self, forKey: .name)
            albumID = try c.decode(String.self, forKey: .albumID)
            destination = try c.decode(String.self, forKey: .destination)
            editedVersions = try c.decodeIfPresent(Bool.self, forKey: .editedVersions) ?? false
            convertHEIC = try c.decodeIfPresent(Bool.self, forKey: .convertHEIC) ?? false
            includeLiveVideo = try c.decodeIfPresent(Bool.self, forKey: .includeLiveVideo) ?? false
            useOriginalNames = try c.decodeIfPresent(Bool.self, forKey: .useOriginalNames) ?? false
            subfolder = try c.decodeIfPresent(String.self, forKey: .subfolder) ?? SubfolderMode.flat.rawValue
            folderPattern = try c.decodeIfPresent(String.self, forKey: .folderPattern) ?? "{year}/{month}"
            namePattern = try c.decodeIfPresent(String.self, forKey: .namePattern) ?? ""
            removeLocation = try c.decodeIfPresent(Bool.self, forKey: .removeLocation) ?? false
            saveReport = try c.decodeIfPresent(Bool.self, forKey: .saveReport) ?? true
            auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
            deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        }

        var options: ExportOptions {
            var o = ExportOptions()
            o.skipExisting = true
            o.editedVersions = editedVersions; o.convertHEIC = convertHEIC; o.includeLiveVideo = includeLiveVideo
            o.useOriginalNames = useOriginalNames; o.subfolder = SubfolderMode(rawValue: subfolder) ?? .flat; o.folderPattern = folderPattern
            o.namePattern = namePattern; o.removeLocation = removeLocation; o.saveReport = saveReport
            return o
        }
    }


    func savePresets() { UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: "hopPresets") }

    func savePreset(name: String, albumID: String, destination: URL, options o: ExportOptions, auto: Bool = false) {
        presets.removeAll { $0.albumID == albumID && $0.destination == destination.path }
        presets.append(HopPreset(name: name, albumID: albumID, destination: destination.path, options: o, auto: auto, deviceID: device?.udid))
        savePresets()
        if auto { Notify.requestPermission() }
    }

    /// Turns "run by itself when plugged in" on or off for a saved hop; it belongs to the device connected now.
    func setAuto(_ p: HopPreset, _ on: Bool) {
        guard let i = presets.firstIndex(where: { $0.id == p.id }) else { return }
        presets[i].auto = on
        if on { presets[i].deviceID = device?.udid ?? presets[i].deviceID; Notify.requestPermission() }
        savePresets()
    }

    func deletePreset(_ p: HopPreset) { presets.removeAll { $0.id == p.id }; savePresets() }

    /// The group a saved hop copies, on the device connected now (nil if it has no such group).
    func album(for p: HopPreset) -> AlbumCategory? { allAlbums.first { $0.id == p.albumID } }

    func runPreset(_ p: HopPreset) {
        guard let album = album(for: p), !album.assets.isEmpty else { return }
        startExport(album.assets, to: URL(fileURLWithPath: p.destination), albumName: album.title, options: p.options)
    }

    // MARK: Hops that run by themselves


    /// After the hops that run by themselves: a backup, when this device has none from the last 20 hours ("Back up
    /// automatically", off until turned on). iOS asks for the passcode on the device to start it.
    func runAutoBackupIfDue() {
        guard UserDefaults.standard.bool(forKey: "autoBackup"), let d = device, !d.isAndroid, tools?.backup != nil,
              !backupRunning, !isExporting, autoBackupRanFor != d.udid, !uiTestBuild else { return }
        autoBackupRanFor = d.udid
        let latest = Backup.existing(in: backupFolder).filter { !$0.isSnapshot && $0.path.lastPathComponent == d.udid }.compactMap(\.date).max()
        if let latest, Date().timeIntervalSince(latest) < 20 * 3600 { return }
        startBackup(automatic: true)
    }

    /// Once per plug-in: every hop marked to run by itself for this device, whose folder is connected, one after another.
    func runAutoHops() {
        guard let d = device, autoRanFor != d.udid, !uiTestBuild || testEnv("AUTO_HOPS") != nil else { runAutoBackupIfDue(); return }
        autoRanFor = d.udid
        autoQueue = presets.filter { p in
            p.auto && p.deviceID == d.udid && album(for: p)?.assets.isEmpty == false
                && FileManager.default.fileExists(atPath: (p.destination as NSString).deletingLastPathComponent)
        }
        runNextAutoHop()
    }

    func runNextAutoHop() {
        guard !isExporting else { return }
        guard !autoQueue.isEmpty else { runAutoBackupIfDue(); return }
        let p = autoQueue.removeFirst()
        autoHopRunning = p.name
        runPreset(p)
        if !isExporting { autoHopRunning = nil; runNextAutoHop() }
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

    // MARK: Updates


    func checkForUpdatesIfDue() {
        guard !uiTestBuild, UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 7 * 86_400 else { return }   // at most once a week
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.checkForUpdates(manual: false) }
    }

    func checkForUpdates(manual: Bool) {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        Task {
            let outcome = await Updates.check()
            checkingUpdates = false
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            switch outcome {
            case .newer(let r):
                update = r
                if manual { offerUpdate() }
            case .upToDate, .noneYet:
                update = nil
                if manual { inform("PortHop \(Updates.current) is the latest version.", "There is nothing to update.") }
            case .failed(let why):
                if manual { inform("Couldn’t check for updates", why) }
            }
        }
    }

    func offerUpdate() {
        guard let r = update else { return }
        let a = NSAlert()
        a.messageText = "PortHop \(r.version) is available"
        a.informativeText = "You have \(Updates.current). " + (r.notes.isEmpty ? "" : String(r.notes.prefix(600)))
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.url) }
    }

    func inform(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
