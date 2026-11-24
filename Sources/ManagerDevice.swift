import SwiftUI
import AppKit

// Android set-up and Wi-Fi pairing, restart and sleep, backups and restores.

extension DeviceManager {
    // MARK: Android setup


    /// Pairs (when a code is given) and connects an Android phone over Wi-Fi; it then shows up like a plugged-in one.
    func connectAndroidWireless(pair: String, code: String, address: String, done: @escaping (Bool) -> Void) {
        guard let tools, !wirelessBusy else { return }
        wirelessBusy = true
        wirelessMessage = code.isEmpty ? "Connecting…" : "Pairing…"
        Task.detached {
            let problem = Android.wireless(pair: pair, code: code, connect: address, tools: tools)
            await MainActor.run {
                self.wirelessBusy = false
                self.wirelessMessage = problem ?? "Connected."
                if problem == nil { self.connect(silent: true) }
                done(problem == nil)
            }
        }
    }


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

    var isRestarting: Bool { restartingSince.map { Date().timeIntervalSince($0) < 600 } ?? false }

    /// Keeps the Mac from sleeping while a copy, backup or restore runs.
    func updateAwake() {
        let busy = isExporting || afcBusy || backupRunning
        if busy, awakeToken == nil {
            awakeToken = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Copying between this Mac and a device")
        } else if !busy, let token = awakeToken {
            ProcessInfo.processInfo.endActivity(token)
            awakeToken = nil
        }
    }


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

    /// Backs up the connected iPhone, or `target` (an iPhone reached over Wi-Fi in the background).
    func startBackup(automatic: Bool = false, target: Device? = nil) {
        guard let device = target ?? device, let tools, !device.isAndroid, !backupRunning, !isExporting, !afcBusy else { return }
        let keepVersions = UserDefaults.standard.object(forKey: "keepSnapshots") as? Bool ?? true
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
            if keepVersions { Backup.snapshot(udid: device.udid, in: folder) }
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
                let who = target.map { self.deviceNames[$0.udid] ?? "Your iPhone" } ?? self.deviceName
                if automatic { Notify.post(problem == nil ? (target == nil ? "Backup complete" : "Backed up over Wi-Fi") : "The automatic backup didn't finish", problem ?? "\(who) is backed up.") }
                self.refreshBackups()
            }
        }
    }


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
}
