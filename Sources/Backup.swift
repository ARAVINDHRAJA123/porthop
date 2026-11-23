import Foundation
import AppKit
import SQLite3
import ImageIO
import AVFoundation

// Making and restoring full device backups (the format Finder uses).

// MARK: - Device backups (same format Finder and iTunes use)

struct BackupEntry: Identifiable {
    var id: String { path.path }
    let path: URL
    let deviceName: String
    let date: Date?
    let encrypted: Bool
    let iosVersion: String
    /// An earlier version kept by "Keep earlier versions" (see Backup.snapshot).
    var isSnapshot = false
}

enum Backup {
    static let snapshotsFolder = "PortHop Snapshots"

    static func existing(in folder: URL) -> [BackupEntry] {
        let fm = FileManager.default
        func dirs(_ u: URL) -> [URL] { (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] }
        // Earlier versions live in "PortHop Snapshots/<device>/<date>/<device>", so a restore finds them like any backup.
        let snapshots = Set(dirs(folder.appendingPathComponent(snapshotsFolder)).flatMap(dirs).flatMap(dirs).map(\.path))
        let subs = dirs(folder) + snapshots.map { URL(fileURLWithPath: $0) }
        return subs.compactMap { dir -> BackupEntry? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("Info.plist")),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
            var encrypted = false
            if let md = try? Data(contentsOf: dir.appendingPathComponent("Manifest.plist")),
               let man = (try? PropertyListSerialization.propertyList(from: md, format: nil)) as? [String: Any] {
                encrypted = (man["IsEncrypted"] as? Bool) ?? false
            }
            return BackupEntry(path: dir, deviceName: (info["Device Name"] as? String) ?? dir.lastPathComponent,
                               date: info["Last Backup Date"] as? Date, encrypted: encrypted,
                               iosVersion: (info["Product Version"] as? String) ?? "", isSnapshot: snapshots.contains(dir.path))
        }
        .sorted { a, b in a.date == b.date ? (!a.isSnapshot && b.isSnapshot) : (a.date ?? .distantPast) > (b.date ?? .distantPast) }
    }

    /// Before a new backup replaces the last one, keeps it as an earlier version. APFS clones it (copy-on-write), so a
    /// snapshot takes almost no space; on drives without clones (exFAT, HFS+) no snapshot is made rather than a full copy.
    /// Keeps the newest `keep` per device. Returns the snapshot, or nil.
    @discardableResult
    static func snapshot(udid: String, in folder: URL, keep: Int = 7) -> URL? {
        let fm = FileManager.default
        let current = folder.appendingPathComponent(udid)
        guard fm.fileExists(atPath: current.appendingPathComponent("Manifest.db").path) else { return nil }
        let info = (try? Data(contentsOf: current.appendingPathComponent("Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH.mm"
        let parent = folder.appendingPathComponent(snapshotsFolder).appendingPathComponent(udid)
        let stamp = parent.appendingPathComponent(f.string(from: info?["Last Backup Date"] as? Date ?? Date()))
        let target = stamp.appendingPathComponent(udid)
        if fm.fileExists(atPath: target.path) { return target }   // this version is already kept
        guard (try? fm.createDirectory(at: stamp, withIntermediateDirectories: true)) != nil else { return nil }
        guard clonefile(current.path, target.path, 0) == 0 else { try? fm.removeItem(at: stamp); return nil }
        let all = ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for old in all.dropLast(keep) { try? fm.removeItem(at: parent.appendingPathComponent(old)) }
        return target
    }

    /// The most recent "NN% Finished" the tool printed, as 0…1.
    static func lastPercent(in text: String) -> Double? {
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,3})% Finished"#),
              let m = re.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let r = Range(m.range(at: 1), in: text), let v = Double(text[r]) else { return nil }
        return min(1, v / 100)
    }

    /// Puts a backup back onto a device, replacing its settings and app data. Returns nil on success, otherwise a plain-language reason.
    /// The password, when the backup has one, is handed to the tool privately (not on its command line).
    static func restore(_ entry: BackupEntry, to device: Device, tools: Tools, password: String?, job: ExportJob,
                        progress: @escaping (Double?, String) -> Void) -> String? {
        guard let tool = tools.backup else { return "The backup tool is missing from this copy of the app." }
        if entry.encrypted && (password ?? "").isEmpty { return "This backup is protected by a password. Enter it to restore." }
        var tail = ""
        var success = false
        let lock = NSLock()
        let args = device.baseArgs + ["--source", entry.path.lastPathComponent, "restore", "--system", "--settings", "--reboot",
                                      entry.path.deletingLastPathComponent().path]
        let status = Shell.stream(tool, args, environment: password.map { ["BACKUP_PASSWORD": $0] } ?? [:], onStart: { job.track($0) }) { chunk in
            lock.lock(); defer { lock.unlock() }
            tail = String((tail + chunk).suffix(4000))
            if chunk.contains("Restore Successful") { success = true }
            let percent = Backup.lastPercent(in: tail)
            progress(percent, "Restoring… do not unplug the device.")
        }
        job.clear()
        lock.lock(); let text = tail; lock.unlock()
        if success && status == 0 { return nil }
        if job.isCancelled { return "Restore stopped part-way. The device may be incomplete: run the restore again to finish it." }
        let lower = text.lowercased()
        if lower.contains("find my") { return "Find My is turned on. On the device, open Settings, tap your name, Find My, and turn Find My off, then try again." }
        if lower.contains("password") { return "The backup password was not accepted." }
        // Otherwise show what the device itself said, and name the usual cause.
        if let said = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ErrorCode ") }) {
            return "The device refused the restore (\(said.trimmingCharacters(in: .whitespaces))). The usual cause is Find My being on: turn it off in Settings, your name, Find My, then try again."
        }
        if lower.contains("passcode") || lower.contains("locked") { return "The device is locked. Unlock it, enter the passcode if it asks, and try again." }
        let lastError = text.split(separator: "\n").last { $0.contains("ERROR") || $0.contains("Error") }
        return lastError.map { "The restore did not finish: \($0.trimmingCharacters(in: .whitespaces))" } ?? "The restore did not finish. Keep the device unlocked and connected, then try again."
    }

    /// Returns nil on success, otherwise a plain-language reason.
    static func run(device: Device, tools: Tools, folder: URL, job: ExportJob,
                    progress: @escaping (Double?, String) -> Void) -> String? {
        guard let tool = tools.backup else { return "The backup tool is missing from this copy of the app." }
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { return "The backup folder could not be created: \(error.localizedDescription)" }
        var tail = ""
        var success = false
        let lock = NSLock()
        let status = Shell.stream(tool, device.baseArgs + ["backup", folder.path], onStart: { job.track($0) }) { chunk in
            lock.lock(); defer { lock.unlock() }
            tail = String((tail + chunk).suffix(4000))
            if chunk.contains("Backup Successful") { success = true }
            let percent = Backup.lastPercent(in: tail)
            let line = tail.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last.map(String.init) ?? ""
            let phase = line.contains("Receiving") ? "Receiving files…" : (line.contains("Sending") ? "Preparing…" : "Backing up…")
            progress(percent, phase)
        }
        job.clear()
        if job.isCancelled { return "Backup stopped. Run it again to continue; finished files are kept." }
        if success && status == 0 { return nil }
        lock.lock(); let text = tail; lock.unlock()
        let lower = text.lowercased()
        if lower.contains("passcode") || lower.contains("password protected") || lower.contains("locked") {
            return "The device is locked. Unlock it, enter the passcode if it asks, and try again."
        }
        if lower.contains("no space") || lower.contains("disk full") { return "The backup folder's disk is full." }
        let lastError = text.split(separator: "\n").last { $0.contains("ERROR") || $0.contains("Error") }
        return lastError.map { "The backup did not finish: \($0.trimmingCharacters(in: .whitespaces))" } ?? "The backup did not finish. Keep the device unlocked and connected, then try again."
    }
}
