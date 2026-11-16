import Foundation
import AppKit
import SQLite3
import ImageIO
import AVFoundation

// MARK: - Models

enum Fmt {
    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    static let yearMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f
    }()
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, n), countStyle: .file)
    }
    static func count(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    static func eta(_ seconds: Double) -> String {
        if !seconds.isFinite || seconds <= 0 { return "" }
        if seconds < 60 { return "less than a minute left" }
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "about \(m) min left" }
        return "about \(m / 60) h \(m % 60) min left"
    }
}

struct PhotoAsset: Identifiable, Hashable {
    let id: Int64
    let uuid: String
    let directory: String
    let filename: String
    let originalFilename: String
    let fileSize: Int64
    let width: Int
    let height: Int
    let duration: Double
    let isHidden: Bool
    let isFavorite: Bool
    let isTrashed: Bool
    let isVideo: Bool
    let isScreenshot: Bool
    let isSelfie: Bool
    let isLivePhoto: Bool
    let dateCreated: Date?
    let dateText: String
    let searchKey: String

    static func == (a: PhotoAsset, b: PhotoAsset) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var sortType: Int { isVideo ? 2 : (isLivePhoto ? 1 : 0) }
    var sortDate: Double { dateCreated?.timeIntervalSinceReferenceDate ?? 0 }
    var sortPixels: Int { width * height }

    var remotePath: String {
        let dir = directory.hasPrefix("/") ? String(directory.dropFirst()) : directory
        return "\(dir)/\(filename)"
    }
    var livePhotoVideoRemotePath: String {
        (remotePath as NSString).deletingPathExtension + ".MOV"
    }
    var fileExtension: String { (filename as NSString).pathExtension.uppercased() }
    var isHEIC: Bool { fileExtension == "HEIC" || fileExtension == "HEIF" }
    var sizeText: String { fileSize > 0 ? Fmt.bytes(fileSize) : "—" }
    var dimensionsText: String { (width > 0 && height > 0) ? "\(width) × \(height)" : "—" }
    var durationText: String { (isVideo && duration > 0) ? Fmt.duration(duration) : "" }
    var kindText: String { isVideo ? "Video" : (isLivePhoto ? "Live Photo" : (isScreenshot ? "Screenshot" : "Photo")) }
    var yearMonthFolder: String { dateCreated.map { Fmt.yearMonth.string(from: $0) } ?? "Unknown Date" }
}

struct AlbumCategory: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let isSmart: Bool
    var assets: [PhotoAsset]
    let totalBytes: Int64

    init(id: String, title: String, icon: String, isSmart: Bool, assets: [PhotoAsset]) {
        self.id = id; self.title = title; self.icon = icon; self.isSmart = isSmart; self.assets = assets
        self.totalBytes = assets.reduce(0) { $0 + max(0, $1.fileSize) }
    }
    static func == (a: AlbumCategory, b: AlbumCategory) -> Bool { a.id == b.id && a.assets.count == b.assets.count }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct AFCFileEntry: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: String
    var sizeText: String { isDirectory ? "—" : (size > 0 ? Fmt.bytes(size) : "—") }
}

struct AppInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

struct InfoRow: Identifiable, Hashable {
    var id: String { label }
    let label: String
    let value: String
    let symbol: String
}

struct DeviceDetails {
    var modelName = "iPhone"
    var productType = "—"
    var iosVersion = "—"
    var buildVersion = "—"
    var serialNumber = "—"
    var totalDiskBytes: Int64 = 0
    var freeDiskBytes: Int64 = 0
    var batteryPercent: Int? = nil
    var isCharging: Bool? = nil
    var cycleCount: Int? = nil
    var batteryHealth: Int? = nil
    var info: [InfoRow] = []
    var usedFraction: Double {
        totalDiskBytes > 0 ? Double(max(0, totalDiskBytes - freeDiskBytes)) / Double(totalDiskBytes) : 0
    }
}

enum MediaFilter: String, CaseIterable, Identifiable {
    case all = "All", photos = "Photos", videos = "Videos", live = "Live Photos"
    case screenshots = "Screenshots", favorites = "Favorites", heic = "HEIC"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .photos: return "photo"
        case .videos: return "video"
        case .live: return "livephoto"
        case .screenshots: return "camera.viewfinder"
        case .favorites: return "heart"
        case .heic: return "doc"
        }
    }
    func matches(_ a: PhotoAsset) -> Bool {
        switch self {
        case .all: return true
        case .photos: return !a.isVideo
        case .videos: return a.isVideo
        case .live: return a.isLivePhoto
        case .screenshots: return a.isScreenshot
        case .favorites: return a.isFavorite
        case .heic: return a.isHEIC
        }
    }
}

enum SortField: String, CaseIterable, Identifiable {
    case date = "Date", size = "File Size", name = "Filename", originalName = "Original Name"
    case folder = "iPhone Folder", resolution = "Resolution", kind = "Kind"
    var id: String { rawValue }
    /// Strict "a before b" for an ascending sort; ties fall back to the catalog order (Z_PK).
    func ascending(_ a: PhotoAsset, _ b: PhotoAsset) -> Bool? {
        switch self {
        case .date: return a.sortDate == b.sortDate ? nil : a.sortDate < b.sortDate
        case .size: return a.fileSize == b.fileSize ? nil : a.fileSize < b.fileSize
        case .name: return a.filename == b.filename ? nil : a.filename.localizedStandardCompare(b.filename) == .orderedAscending
        case .originalName: return a.originalFilename == b.originalFilename ? nil : a.originalFilename.localizedStandardCompare(b.originalFilename) == .orderedAscending
        case .folder: return a.directory == b.directory ? nil : a.directory < b.directory
        case .resolution: return a.sortPixels == b.sortPixels ? nil : a.sortPixels < b.sortPixels
        case .kind: return a.sortType == b.sortType ? nil : a.sortType < b.sortType
        }
    }

    static func sorted(_ list: [PhotoAsset], by field: SortField, ascending: Bool) -> [PhotoAsset] {
        list.sorted { a, b in
            if let r = field.ascending(a, b) { return ascending ? r : !r }
            return a.id < b.id
        }
    }
}

enum SubfolderMode: String, CaseIterable, Identifiable {
    case flat = "One folder"
    case yearMonth = "By month (2026-11)"
    case iphoneFolder = "By iPhone folder (100APPLE)"
    var id: String { rawValue }
}

struct ExportOptions {
    var convertHEIC = false
    var skipExisting = true
    var useOriginalNames = false
    var setDates = true
    var includeLiveVideo = false
    var subfolder: SubfolderMode = .flat
}

struct ExportManifestEntry: Codable {
    let preferredPath: String
    let exportedPath: String
    let sourceRemotePath: String
    let sourceSize: Int64
    let exportedSize: Int64
}

struct ExportFailure: Identifiable {
    var id: Int64 { asset.id }
    let asset: PhotoAsset
    let reason: String
}

struct ExportProgress {
    var total = 0
    var copied = 0
    var skipped = 0
    var failed = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var bytesPerSecond: Double = 0
    var inFlight = 0
    var processed: Int { copied + skipped + failed }
    var shownCount: Int { min(total, processed + inFlight) }
    var fraction: Double {
        if bytesTotal > 0 { return min(1, Double(bytesDone) / Double(bytesTotal)) }
        return total > 0 ? Double(processed) / Double(total) : 0
    }
}

struct ExportSummary: Identifiable {
    let id = UUID()
    var destination: URL
    var total = 0
    var copied = 0
    var skipped = 0
    var liveVideos = 0
    var failures: [ExportFailure] = []
    var notAttempted = 0
    var cancelled = false
    var disconnected = false
    var stalled = false
    var fatalError: String? = nil
    var bytesCopied: Int64 = 0
    var elapsed: TimeInterval = 0
    var isClean: Bool { failures.isEmpty && !cancelled && !disconnected && !stalled && fatalError == nil }
}

// MARK: - Subprocess

enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    /// Runs a tool, draining its output while it runs so a chatty process can never block on a full pipe.
    static func run(_ path: String, _ args: [String], stdin: String? = nil,
                    timeout: TimeInterval? = nil, onStart: ((Process) -> Void)? = nil) -> Result? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let inPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inPipe { p.standardInput = inPipe } else { p.standardInput = FileHandle.nullDevice }
        do { try p.run() } catch { return nil }
        onStart?(p)
        if let inPipe, let stdin {
            DispatchQueue.global(qos: .userInitiated).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
        }
        var killer: DispatchWorkItem?
        if let timeout {
            let w = DispatchWorkItem { if p.isRunning { p.terminate() } }
            killer = w
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: w)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer?.cancel()
        return Result(status: p.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

extension Shell {
    /// Runs a tool and hands over its output as it arrives (for long jobs that report progress).
    static func stream(_ path: String, _ args: [String], environment: [String: String] = [:], onStart: ((Process) -> Void)? = nil,
                       onOutput: @escaping (String) -> Void) -> Int32? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if !environment.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { onOutput(String(decoding: d, as: UTF8.self)) }
        }
        do { try p.run() } catch { out.fileHandleForReading.readabilityHandler = nil; return nil }
        onStart?(p)
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        let rest = out.fileHandleForReading.availableData
        if !rest.isEmpty { onOutput(String(decoding: rest, as: UTF8.self)) }
        return p.terminationStatus
    }
}

struct Tools {
    let ideviceId: String
    let ideviceInfo: String
    let afc: String
    var applist: String? = nil
    var backup: String? = nil
    var diagnostics: String? = nil
    var adb: String? = nil

    static func locate() -> Tools? {
        var dirs = [Bundle.main.bundlePath + "/Contents/Helpers", "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
                    NSHomeDirectory() + "/.local/bin", Android.toolsDir]
        if let override = ProcessInfo.processInfo.environment["IPHONE_TOOLS_DIR"], !override.isEmpty {
            dirs.insert(override, at: 0)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        func find(_ name: String) -> String? {
            for d in dirs {
                let candidate = (d as NSString).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
            return nil
        }
        guard let a = find("idevice_id"), let b = find("ideviceinfo"), let c = find("afcclient") else { return nil }
        return Tools(ideviceId: a, ideviceInfo: b, afc: c, applist: find("applist"), backup: find("idevicebackup2"), diagnostics: find("idevicediagnostics"), adb: find("adb"))
    }
}

struct Device: Equatable {
    let udid: String
    let isNetwork: Bool
    var isAndroid = false
    var unauthorized = false
    var baseArgs: [String] { isNetwork ? ["-u", udid, "-n"] : ["-u", udid] }
}

enum AFC {
    /// Quotes one argument for afcclient's interactive tokenizer. Returns nil for names it cannot represent.
    static func quote(_ s: String) -> String? {
        if s.contains("\n") || s.contains("\r") || s.contains("\0") { return nil }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func findDevices(_ tools: Tools) -> [Device] {
        func all(_ flag: String) -> [String] {
            guard let r = Shell.run(tools.ideviceId, [flag], timeout: 8), r.ok else { return [] }
            return r.output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.contains("ERROR") && !$0.contains(" ") }
        }
        var seen = Set<String>()
        var out: [Device] = []
        for u in all("-l") where seen.insert(u).inserted { out.append(Device(udid: u, isNetwork: false)) }
        for u in all("-n") where seen.insert(u).inserted { out.append(Device(udid: u, isNetwork: true)) }
        return out
    }

    static func findDevice(_ tools: Tools) -> Device? { findDevices(tools).first }

    static func name(of device: Device, tools: Tools) -> String {
        let r = Shell.run(tools.ideviceInfo, device.baseArgs + ["-k", "DeviceName"], timeout: 8)
        let n = r?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (r?.ok == true && !n.isEmpty && !n.contains("ERROR")) ? n : "Device \(device.udid.suffix(4))"
    }

    static func isConnected(_ device: Device, tools: Tools) -> Bool {
        guard let r = Shell.run(tools.ideviceId, [device.isNetwork ? "-n" : "-l"], timeout: 8) else { return false }
        return r.output.contains(device.udid)
    }

    static func get(_ remote: String, to local: URL, device: Device, tools: Tools) -> Bool {
        _ = Shell.run(tools.afc, device.baseArgs + ["--", "get", remote, local.path])
        return fileSize(local) > 0
    }

    /// Extra arguments that point afcclient at one app's shared folder instead of the media area.
    static func container(_ app: String?) -> [String] { app.map { ["--documents", $0] } ?? [] }

    static func apps(_ device: Device, tools: Tools) -> [AppInfo] {
        guard let helper = tools.applist, let r = Shell.run(helper, [device.udid], timeout: 30), r.ok else { return [] }
        return r.output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return AppInfo(id: parts[0], name: parts[1])
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Copies one Mac file or folder into a device folder. Never overwrites: an existing name gets " (2)" etc.
    static func put(_ local: URL, intoDir dir: String, existing: inout Set<String>, app: String?, device: Device, tools: Tools,
                    onStart: ((Process) -> Void)? = nil) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDir) else { return false }
        var name = local.lastPathComponent
        if existing.contains(name) {
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            var i = 2
            repeat { name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"; i += 1 } while existing.contains(name)
        }
        let clean = dir.hasPrefix("/") ? String(dir.dropFirst()) : dir
        let remote = clean.isEmpty ? name : "\(clean)/\(name)"
        let args = device.baseArgs + container(app) + ["--", "put"] + (isDir.boolValue ? ["-r"] : []) + [local.path, remote]
        let r = Shell.run(tools.afc, args, onStart: onStart)
        let ok = r?.ok == true && !(r?.output.contains("Error:") ?? true)
        if ok { existing.insert(name) }
        return ok
    }

    static func mkdir(_ path: String, app: String?, device: Device, tools: Tools) -> Bool {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let r = Shell.run(tools.afc, device.baseArgs + container(app) + ["--", "mkdir", clean], timeout: 20)
        return r?.ok == true && !(r?.output.contains("Error:") ?? true)
    }

    static func remoteSize(_ remote: String, device: Device, tools: Tools) -> Int64? {
        guard let r = Shell.run(tools.afc, device.baseArgs + ["--", "info", remote], timeout: 20) else { return nil }
        // Newer afcclient prints JSON ("st_size": 123,), older ones print "st_size: 123".
        guard let range = r.output.range(of: #"st_size"?\s*[:=]\s*(\d+)"#, options: .regularExpression) else { return nil }
        return Int64(r.output[range].filter(\.isNumber))
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func list(_ dirPath: String, app: String? = nil, device: Device, tools: Tools) -> [AFCFileEntry] {
        let clean = dirPath == "/" ? "." : (dirPath.hasPrefix("/") ? String(dirPath.dropFirst()) : dirPath)
        // "--" stops afcclient's own option parser from swallowing "-l".
        guard let r = Shell.run(tools.afc, device.baseArgs + container(app) + ["--", "ls", "-l", clean], timeout: 60), r.ok else { return [] }
        var entries: [AFCFileEntry] = []
        for raw in r.output.split(separator: "\n") {
            // drwxr-xr-x    2 mobile mobile      27264 10 Nov 2026 18:34:48 109APPLE
            let parts = raw.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 10, let kind = parts[0].first, "d-l".contains(kind), parts[0].count >= 10 else { continue }
            let name = parts[9].trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name == "." || name == ".." { continue }
            let full = dirPath == "/" ? "/\(name)" : "\(dirPath)/\(name)"
            entries.append(AFCFileEntry(name: name, path: full, isDirectory: kind == "d", size: Int64(parts[4]) ?? 0,
                                        modifiedDate: "\(parts[5]) \(parts[6]) \(parts[7])"))
        }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return entries
    }

    /// Asks the device to restart or sleep. Returns true when the device accepted the request.
    static func power(_ action: String, device: Device, tools: Tools) -> Bool {
        guard let diag = tools.diagnostics, ["restart", "sleep"].contains(action) else { return false }
        return Shell.run(diag, device.baseArgs + [action], timeout: 20)?.ok == true
    }

    static func details(_ device: Device, tools: Tools) -> (name: String, details: DeviceDetails)? {
        func kv(_ extra: [String]) -> [String: String]? {
            guard let r = Shell.run(tools.ideviceInfo, device.baseArgs + extra, timeout: 12), r.ok,
                  !r.output.hasPrefix("ERROR") else { return nil }
            var d: [String: String] = [:]
            for line in r.output.split(separator: "\n") {
                if line.first == " " || line.first == "\t" { continue }   // nested values, not top-level facts
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    d[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            return d
        }
        guard let main = kv([]), main["ProductType"] != nil || main["DeviceName"] != nil else { return nil }
        var d = DeviceDetails()
        d.productType = main["ProductType"] ?? "—"
        d.modelName = main["MarketName"] ?? main["DeviceClass"] ?? "iPhone"
        d.iosVersion = main["ProductVersion"] ?? "—"
        d.buildVersion = main["BuildVersion"] ?? "—"
        d.serialNumber = main["SerialNumber"] ?? "—"
        if let disk = kv(["-q", "com.apple.disk_usage"]) {
            d.totalDiskBytes = Int64(disk["TotalDiskCapacity"] ?? "") ?? 0
            d.freeDiskBytes = Int64(disk["AmountDataAvailable"] ?? "") ?? 0
        }
        if let bat = kv(["-q", "com.apple.mobile.battery"]) {
            d.batteryPercent = Int(bat["BatteryCurrentCapacity"] ?? "")
            d.isCharging = bat["BatteryIsCharging"].map { $0 == "true" }
        }
        if let diag = tools.diagnostics,
           let r = Shell.run(diag, device.baseArgs + ["ioregentry", "AppleSmartBattery"], timeout: 12), r.ok {
            func int(_ key: String) -> Int? {
                guard let range = r.output.range(of: "<key>\(key)</key>\\s*<integer>(\\d+)</integer>", options: .regularExpression) else { return nil }
                let text = r.output[range]
                guard let open = text.range(of: "<integer>"), let close = text.range(of: "</integer>") else { return nil }
                return Int(text[open.upperBound..<close.lowerBound])
            }
            d.cycleCount = int("CycleCount")
            if let design = int("DesignCapacity"), design > 0, let now = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") {
                d.batteryHealth = min(100, Int((Double(now) / Double(design) * 100).rounded()))
            }
        }
        func row(_ label: String, _ key: String, _ symbol: String, _ map: (String) -> String = { $0 }) {
            if let v = main[key], !v.isEmpty { d.info.append(InfoRow(label: label, value: map(v), symbol: symbol)) }
        }
        row("Model", "ProductType", "cpu")
        row("Model number", "ModelNumber", "tag")
        row("Serial number", "SerialNumber", "barcode")
        row("Software", "ProductVersion", "gearshape") { "\(main["ProductName"] ?? "iOS") \($0) (\(main["BuildVersion"] ?? ""))" }
        row("Identifier (UDID)", "UniqueDeviceID", "number")
        row("Phone number", "PhoneNumber", "phone")
        row("IMEI", "InternationalMobileEquipmentIdentity", "simcard")
        row("Wi-Fi address", "WiFiAddress", "wifi")
        row("Bluetooth address", "BluetoothAddress", "dot.radiowaves.left.and.right")
        row("Processor", "CPUArchitecture", "memorychip")
        row("Modem firmware", "BasebandVersion", "antenna.radiowaves.left.and.right")
        row("Activation", "ActivationState", "checkmark.seal") { $0 == "Activated" ? "Activated" : $0 }
        row("Passcode", "PasswordProtected", "lock") { $0 == "true" ? "Set" : "None" }
        row("Time zone", "TimeZone", "clock")
        return (main["DeviceName"] ?? "iPhone", d)
    }
}

// MARK: - Photos.sqlite catalog

struct Catalog {
    var smart: [AlbumCategory] = []
    var user: [AlbumCategory] = []
    var warnings: [String] = []
    var assetCount = 0
    var schemaLabel = ""
}

enum CatalogError: Error {
    case unreadable
    case unsupported(String)
}

enum CatalogReader {
    static func load(path: String) -> Result<Catalog, CatalogError> {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return .failure(.unreadable)
        }
        defer { sqlite3_close(db) }

        let assetTable: String
        if tableExists(db, "ZASSET") { assetTable = "ZASSET" }
        else if tableExists(db, "ZGENERICASSET") { assetTable = "ZGENERICASSET" }
        else { return .failure(.unsupported("The photo database has no asset table this app recognises (ZASSET).")) }

        let cols = columns(db, assetTable)
        let missing = ["Z_PK", "ZDIRECTORY", "ZFILENAME"].filter { !cols.contains($0) }
        guard missing.isEmpty else {
            return .failure(.unsupported("The asset table is missing \(missing.joined(separator: ", ")), which this app needs to locate files."))
        }
        let hasAttr = tableExists(db, "ZADDITIONALASSETATTRIBUTES")
        let attrCols = hasAttr ? columns(db, "ZADDITIONALASSETATTRIBUTES") : []
        let joinAttr = hasAttr && attrCols.contains("ZASSET")

        var warnings: [String] = []
        func col(_ name: String, _ fallback: String, warn: String? = nil) -> String {
            if cols.contains(name) { return "COALESCE(a.\(name), \(fallback))" }
            if let warn { warnings.append(warn) }
            return fallback
        }
        let origExpr = (joinAttr && attrCols.contains("ZORIGINALFILENAME")) ? "COALESCE(attr.ZORIGINALFILENAME, a.ZFILENAME)" : "a.ZFILENAME"
        let sizeExpr: String
        if joinAttr && attrCols.contains("ZORIGINALFILESIZE") {
            sizeExpr = "COALESCE(attr.ZORIGINALFILESIZE, 0)"
        } else {
            sizeExpr = "0"
            warnings.append("File sizes are not available in this iOS version's photo database, so size sorting and size verification are limited.")
        }
        let hiddenExpr = col("ZHIDDEN", "0", warn: "This iOS version does not mark hidden items the way this app expects, so the Hidden album cannot be identified.")
        let trashedExpr = col("ZTRASHEDSTATE", "0")
        let screenshotExpr = cols.contains("ZISDETECTEDSCREENSHOT") ? "COALESCE(a.ZISDETECTEDSCREENSHOT, 0)"
            : (cols.contains("Z1_ISDETECTEDSCREENSHOT") ? "COALESCE(a.Z1_ISDETECTEDSCREENSHOT, 0)" : "0")
        let orderExpr = cols.contains("ZDATECREATED") ? "a.ZDATECREATED DESC" : "a.Z_PK DESC"

        let sql = """
        SELECT a.Z_PK, \(col("ZUUID", "''")), a.ZDIRECTORY, a.ZFILENAME, \(origExpr), \(sizeExpr),
               \(hiddenExpr), \(col("ZFAVORITE", "0")), \(trashedExpr), \(col("ZKIND", "0")),
               \(col("ZDATECREATED", "0")), \(col("ZWIDTH", "0")), \(col("ZHEIGHT", "0")),
               \(col("ZDURATION", "0.0")), \(screenshotExpr), \(col("ZCAMERACAPTUREDEVICE", "0")),
               \(col("ZKINDSUBTYPE", "0"))
        FROM \(assetTable) a
        \(joinAttr ? "LEFT JOIN ZADDITIONALASSETATTRIBUTES attr ON attr.ZASSET = a.Z_PK" : "")
        WHERE a.ZFILENAME IS NOT NULL AND a.ZDIRECTORY IS NOT NULL AND a.ZFILENAME != ''
        ORDER BY \(orderExpr);
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            return .failure(.unsupported("The photo database could not be queried (\(msg))."))
        }
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }

        var ordered: [PhotoAsset] = []
        var byPK: [Int64: PhotoAsset] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let pk = sqlite3_column_int64(stmt, 0)
            let dir = text(2), fn = text(3), orig = text(4)
            let ts = sqlite3_column_double(stmt, 10)
            let date: Date? = ts != 0 ? Date(timeIntervalSinceReferenceDate: ts) : nil
            let dateText = date.map { Fmt.date.string(from: $0) } ?? "—"
            let subtype = sqlite3_column_int(stmt, 16)
            let kind = sqlite3_column_int(stmt, 9)
            let asset = PhotoAsset(
                id: pk, uuid: text(1), directory: dir, filename: fn, originalFilename: orig,
                fileSize: sqlite3_column_int64(stmt, 5),
                width: Int(sqlite3_column_int(stmt, 11)), height: Int(sqlite3_column_int(stmt, 12)),
                duration: sqlite3_column_double(stmt, 13),
                isHidden: sqlite3_column_int(stmt, 6) != 0,
                isFavorite: sqlite3_column_int(stmt, 7) != 0,
                isTrashed: sqlite3_column_int(stmt, 8) != 0,
                isVideo: kind == 1,
                isScreenshot: sqlite3_column_int(stmt, 14) != 0 || subtype == 10,
                isSelfie: sqlite3_column_int(stmt, 15) == 1,
                isLivePhoto: kind == 0 && subtype == 2,
                dateCreated: date, dateText: dateText,
                searchKey: "\(fn) \(orig) \(dir) \(dateText)".lowercased()
            )
            ordered.append(asset)
            byPK[pk] = asset
        }
        sqlite3_finalize(stmt)

        var user: [AlbumCategory] = []
        if tableExists(db, "ZGENERICALBUM") {
            let albumCols = columns(db, "ZGENERICALBUM")
            if albumCols.contains("ZTITLE") {
                let trashClause = albumCols.contains("ZTRASHEDSTATE") ? "AND COALESCE(alb.ZTRASHEDSTATE, 0) = 0" : ""
                for jt in joinTables(db) {
                    let jc = columns(db, jt)
                    guard let albumCol = jc.sorted().first(where: { $0.hasSuffix("ALBUMS") }),
                          let assetCol = jc.sorted().first(where: { $0.hasSuffix("ASSETS") && !$0.hasPrefix("Z_FOK") }) else { continue }
                    let q = """
                    SELECT alb.Z_PK, alb.ZTITLE, j.\(assetCol) FROM ZGENERICALBUM alb
                    INNER JOIN \(jt) j ON alb.Z_PK = j.\(albumCol)
                    WHERE alb.ZTITLE IS NOT NULL AND alb.ZTITLE != '' \(trashClause);
                    """
                    var s: OpaquePointer?
                    guard sqlite3_prepare_v2(db, q, -1, &s, nil) == SQLITE_OK else { continue }
                    var map: [Int64: (String, [PhotoAsset])] = [:]
                    while sqlite3_step(s) == SQLITE_ROW {
                        let apk = sqlite3_column_int64(s, 0)
                        guard let t = sqlite3_column_text(s, 1), let asset = byPK[sqlite3_column_int64(s, 2)],
                              !asset.isTrashed, !asset.isHidden else { continue }
                        map[apk, default: (String(cString: t), [])].1.append(asset)
                    }
                    sqlite3_finalize(s)
                    for (apk, v) in map where !v.1.isEmpty {
                        user.append(AlbumCategory(id: "album_\(apk)", title: v.0, icon: "rectangle.stack.fill", isSmart: false,
                                                  assets: v.1.sorted { $0.sortDate > $1.sortDate }))
                    }
                }
            }
        }
        user.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let live = ordered.filter { !$0.isTrashed }
        func smart(_ id: String, _ title: String, _ icon: String, _ items: [PhotoAsset]) -> AlbumCategory {
            AlbumCategory(id: id, title: title, icon: icon, isSmart: true, assets: items)
        }
        // Like the Photos app: a hidden item appears only in Hidden, never in other albums.
        let shown = live.filter { !$0.isHidden }
        var cat = Catalog()
        cat.smart = [
            smart("smart_hidden", "Hidden", "eye.slash.fill", live.filter { $0.isHidden }),
            smart("smart_all", "Library", "photo.on.rectangle.angled", shown),
            smart("smart_favorites", "Favorites", "heart.fill", shown.filter { $0.isFavorite }),
            smart("smart_videos", "Videos", "video.fill", shown.filter { $0.isVideo }),
            smart("smart_live", "Live Photos", "livephoto", shown.filter { $0.isLivePhoto }),
            smart("smart_screenshots", "Screenshots", "camera.viewfinder", shown.filter { $0.isScreenshot }),
            smart("smart_selfies", "Selfies", "person.crop.square.fill", shown.filter { $0.isSelfie }),
            smart("smart_trashed", "Recently Deleted", "trash.fill", ordered.filter { $0.isTrashed })
        ]
        cat.user = user
        cat.warnings = warnings
        cat.assetCount = ordered.count
        cat.schemaLabel = assetTable
        return .success(cat)
    }

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;", -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private static func columns(_ db: OpaquePointer, _ table: String) -> Set<String> {
        var result = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1) { result.insert(String(cString: c)) }
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    private static func joinTables(_ db: OpaquePointer) -> [String] {
        var list: [String] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z\\_%ASSETS' ESCAPE '\\';", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    let name = String(cString: c)
                    if name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { list.append(name) }
                }
            }
        }
        sqlite3_finalize(stmt)
        return list
    }
}

// MARK: - Export engine

final class ExportJob {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [Process] = []

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock(); cancelled = true; let ps = processes; lock.unlock()
        for p in ps where p.isRunning { p.terminate() }
    }

    func track(_ p: Process) {
        lock.lock(); processes.append(p); let c = cancelled; lock.unlock()
        if c, p.isRunning { p.terminate() }
    }

    func clear() { lock.lock(); processes.removeAll(); lock.unlock() }

    /// Stops the running transfers without cancelling the export (used when the device stops responding).
    func interrupt() {
        lock.lock(); let ps = processes; lock.unlock()
        for p in ps where p.isRunning { p.terminate() }
    }
}

enum Exporter {
    static let manifestName = ".iPhoneAlbumExtractor-manifest.json"
    static let stagingPrefix = ".iPhoneAlbumExtractor-staging-"
    static var stallLimit: TimeInterval = 75

    private struct Pending {
        let asset: PhotoAsset
        let raw: URL
        let final: URL
        let preferredRel: String
        let liveRaw: URL?
        let command: String
    }

    static func run(assets: [PhotoAsset], destination: URL, options: ExportOptions, device: Device, tools: Tools,
                    job: ExportJob, progress: @escaping (ExportProgress) -> Void) -> ExportSummary {
        let fm = FileManager.default
        let started = Date()
        var summary = ExportSummary(destination: destination)
        summary.total = assets.count

        do { try fm.createDirectory(at: destination, withIntermediateDirectories: true) } catch {
            summary.fatalError = "The folder could not be created: \(error.localizedDescription)"
            return summary
        }
        for name in (try? fm.contentsOfDirectory(atPath: destination.path)) ?? [] where name.hasPrefix(stagingPrefix) {
            try? fm.removeItem(at: destination.appendingPathComponent(name))
        }
        let staging = destination.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        do { try fm.createDirectory(at: staging, withIntermediateDirectories: true) } catch {
            summary.fatalError = "This folder is not writable: \(error.localizedDescription)"
            return summary
        }
        defer { try? fm.removeItem(at: staging) }

        let manifestURL = destination.appendingPathComponent(manifestName)
        var manifest = (try? JSONDecoder().decode([String: ExportManifestEntry].self, from: Data(contentsOf: manifestURL))) ?? [:]
        func saveManifest() {
            if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: manifestURL, options: .atomic) }
        }

        var state = ExportProgress()
        state.total = assets.count
        state.bytesTotal = assets.reduce(0) { $0 + max(0, $1.fileSize) }
        var settledBytes: Int64 = 0
        var transferredBytes: Int64 = 0
        func emit(staged: Int64 = 0, files: Int = 0) {
            var s = state
            s.inFlight = files
            s.bytesDone = settledBytes + staged
            let elapsed = Date().timeIntervalSince(started)
            s.bytesPerSecond = elapsed > 1 ? Double(transferredBytes + staged) / elapsed : 0
            progress(s)
        }
        func fail(_ asset: PhotoAsset, _ reason: String) {
            summary.failures.append(ExportFailure(asset: asset, reason: reason))
            state.failed += 1
            settledBytes += max(0, asset.fileSize)
        }
        emit()

        var streamCount = 3
        let chunkSize = 60
        var index = 0
        var reserved = Set<String>()

        outer: while index < assets.count {
            if job.isCancelled { break }
            let chunk = assets[index..<min(index + chunkSize, assets.count)]
            index += chunk.count
            var streams = [String](repeating: "", count: streamCount)
            var pending: [Pending] = []

            for asset in chunk {
                var targetDir = destination
                switch options.subfolder {
                case .flat: break
                case .yearMonth: targetDir = destination.appendingPathComponent(asset.yearMonthFolder, isDirectory: true)
                case .iphoneFolder:
                    let sub = asset.directory.split(separator: "/").last.map(String.init) ?? "DCIM"
                    targetDir = destination.appendingPathComponent(sub, isDirectory: true)
                }
                try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

                let chosen = (options.useOriginalNames && !asset.originalFilename.isEmpty) ? asset.originalFilename : asset.filename
                let safeName = URL(fileURLWithPath: chosen).lastPathComponent.replacingOccurrences(of: ":", with: "-")
                guard !safeName.isEmpty, safeName != ".", safeName != "..", safeName != "/" else {
                    fail(asset, "The filename in the catalog is not usable.")
                    continue
                }
                guard let remoteQuoted = AFC.quote(asset.remotePath) else {
                    fail(asset, "The iPhone path contains characters that cannot be transferred safely.")
                    continue
                }
                let willConvert = options.convertHEIC && asset.isHEIC
                let preferred = targetDir.appendingPathComponent(safeName)
                var final = willConvert ? preferred.deletingPathExtension().appendingPathExtension("jpg") : preferred
                let preferredRel = relativePath(of: final, inside: destination)
                let key = asset.uuid.isEmpty ? String(asset.id) : asset.uuid

                if options.skipExisting {
                    if let prev = manifest[key], prev.preferredPath == preferredRel,
                       prev.sourceRemotePath == asset.remotePath, prev.sourceSize == asset.fileSize {
                        let size = AFC.fileSize(destination.appendingPathComponent(prev.exportedPath))
                        if size > 0, size == prev.exportedSize {
                            state.skipped += 1; summary.skipped += 1
                            settledBytes += max(0, asset.fileSize)
                            continue
                        }
                    }
                    // A same-name file whose byte size equals the iPhone's recorded size is the same file
                    // from an earlier export (including the original app's): adopt it instead of duplicating.
                    if !willConvert, asset.fileSize > 0, !reserved.contains(final.path), AFC.fileSize(final) == asset.fileSize {
                        manifest[key] = ExportManifestEntry(preferredPath: preferredRel, exportedPath: preferredRel,
                                                            sourceRemotePath: asset.remotePath, sourceSize: asset.fileSize,
                                                            exportedSize: asset.fileSize)
                        reserved.insert(final.path)
                        state.skipped += 1; summary.skipped += 1
                        settledBytes += asset.fileSize
                        continue
                    }
                }
                if fm.fileExists(atPath: final.path) || reserved.contains(final.path) {
                    final = uniqueURL(for: final, avoiding: reserved)
                }
                reserved.insert(final.path)

                let ext = asset.fileExtension.isEmpty ? "bin" : asset.fileExtension.lowercased()
                let raw = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                guard let rawQuoted = AFC.quote(raw.path) else {
                    fail(asset, "The destination path contains characters that cannot be used.")
                    continue
                }
                var command = "get \(remoteQuoted) \(rawQuoted)\n"
                var liveRaw: URL? = nil
                if options.includeLiveVideo, asset.isLivePhoto {
                    let lr = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                    if let rq = AFC.quote(asset.livePhotoVideoRemotePath), let lq = AFC.quote(lr.path) {
                        command += "get \(rq) \(lq)\n"
                        liveRaw = lr
                    }
                }
                streams[pending.count % streamCount] += command
                pending.append(Pending(asset: asset, raw: raw, final: final, preferredRel: preferredRel, liveRaw: liveRaw, command: command))
            }

            if pending.isEmpty { emit(); saveManifest(); continue }

            let pollQueue = DispatchQueue(label: "export.poll")
            let timer = DispatchSource.makeTimerSource(queue: pollQueue)
            timer.schedule(deadline: .now() + 0.4, repeating: 0.4)
            var lastStaged: Int64 = -1
            var lastGrowth = Date()
            var stalledNow = false
            timer.setEventHandler {
                let names = (try? fm.contentsOfDirectory(atPath: staging.path)) ?? []
                let staged = names.reduce(Int64(0)) { $0 + AFC.fileSize(staging.appendingPathComponent($1)) }
                // Nothing arriving for a long time means the device stopped answering (often: it locked).
                if staged != lastStaged { lastStaged = staged; lastGrowth = Date() }
                else if Date().timeIntervalSince(lastGrowth) > stallLimit { stalledNow = true; lastGrowth = Date(); job.interrupt() }
                emit(staged: staged, files: max(0, names.count - streamCount))
            }
            timer.resume()
            let active = streams.filter { !$0.isEmpty }
            DispatchQueue.concurrentPerform(iterations: active.count) { i in
                _ = Shell.run(tools.afc, device.baseArgs, stdin: active[i] + "quit\n", onStart: { job.track($0) })
            }
            // Anything a parallel stream missed gets one calm, single-stream retry before it is called a failure.
            let missed = pending.filter { AFC.fileSize($0.raw) <= 0 }
            if !missed.isEmpty, !job.isCancelled, !stalledNow, AFC.isConnected(device, tools: tools) {
                for m in missed { try? fm.removeItem(at: m.raw) }
                _ = Shell.run(tools.afc, device.baseArgs, stdin: missed.map(\.command).joined() + "quit\n", onStart: { job.track($0) })
                let recovered = missed.filter { AFC.fileSize($0.raw) > 0 }.count
                if streamCount > 1, recovered * 2 > missed.count, missed.count > 2 { streamCount = 1 }
            }
            job.clear()
            timer.cancel()
            pollQueue.sync {}

            let cancelledNow = job.isCancelled
            let anyMissing = pending.contains { AFC.fileSize($0.raw) <= 0 }
            pollQueue.sync {}
            let stalled = stalledNow && !cancelledNow
            let disconnected = !cancelledNow && (stalled || (anyMissing && !AFC.isConnected(device, tools: tools)))

            for (n, item) in pending.enumerated() {
                let asset = item.asset
                let received = AFC.fileSize(item.raw)
                let sizeKnown = asset.fileSize > 0
                var problem: String? = nil
                if received <= 0 {
                    problem = "Could not be read from the device. The original may be stored only in iCloud."
                } else if sizeKnown && received != asset.fileSize {
                    if cancelledNow || disconnected {
                        problem = "Transfer was interrupted."
                    } else if let remote = AFC.remoteSize(asset.remotePath, device: device, tools: tools) {
                        if remote != received {
                            problem = "Incomplete transfer (\(Fmt.bytes(received)) of \(Fmt.bytes(remote)))."
                        }
                    } else if !decodes(item.raw, isVideo: asset.isVideo) {
                        problem = "The size differs from the catalog and the file could not be validated."
                    }
                } else if !sizeKnown && (cancelledNow || disconnected) && n == pending.count - 1 {
                    problem = "Transfer was interrupted."
                }

                if let problem {
                    try? fm.removeItem(at: item.raw)
                    if let lr = item.liveRaw { try? fm.removeItem(at: lr) }
                    if cancelledNow { summary.notAttempted += 1; continue }
                    fail(asset, stalled ? "The device stopped responding. Unlock it and try again." : (disconnected ? "The device was disconnected." : problem))
                    continue
                }

                var saved = false
                var reason = "The file could not be saved to the folder."
                if options.convertHEIC && asset.isHEIC {
                    let converted = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
                    let r = Shell.run("/usr/bin/sips", ["-s", "format", "jpeg", "-s", "formatOptions", "90", item.raw.path, "--out", converted.path])
                    if r?.ok == true, AFC.fileSize(converted) > 0 {
                        do { try fm.moveItem(at: converted, to: item.final); saved = true } catch { reason = error.localizedDescription }
                    } else {
                        reason = "HEIC to JPEG conversion failed."
                    }
                    try? fm.removeItem(at: converted)
                } else {
                    do { try fm.moveItem(at: item.raw, to: item.final); saved = true } catch { reason = error.localizedDescription }
                }
                try? fm.removeItem(at: item.raw)

                let outSize = saved ? AFC.fileSize(item.final) : 0
                guard saved, outSize > 0 else {
                    if saved { try? fm.removeItem(at: item.final) }
                    if let lr = item.liveRaw { try? fm.removeItem(at: lr) }
                    fail(asset, reason)
                    continue
                }
                var dateAttrs: [FileAttributeKey: Any] = [:]
                if options.setDates, let d = asset.dateCreated { dateAttrs = [.creationDate: d, .modificationDate: d] }
                if !dateAttrs.isEmpty { try? fm.setAttributes(dateAttrs, ofItemAtPath: item.final.path) }

                let key = asset.uuid.isEmpty ? String(asset.id) : asset.uuid
                manifest[key] = ExportManifestEntry(preferredPath: item.preferredRel,
                                                    exportedPath: relativePath(of: item.final, inside: destination),
                                                    sourceRemotePath: asset.remotePath, sourceSize: asset.fileSize, exportedSize: outSize)
                state.copied += 1; summary.copied += 1
                summary.bytesCopied += outSize
                settledBytes += max(0, asset.fileSize)
                transferredBytes += received

                if let lr = item.liveRaw {
                    if AFC.fileSize(lr) > 0 {
                        var liveFinal = item.final.deletingPathExtension().appendingPathExtension("MOV")
                        if fm.fileExists(atPath: liveFinal.path) || reserved.contains(liveFinal.path) {
                            liveFinal = uniqueURL(for: liveFinal, avoiding: reserved)
                        }
                        reserved.insert(liveFinal.path)
                        if (try? fm.moveItem(at: lr, to: liveFinal)) != nil {
                            if !dateAttrs.isEmpty { try? fm.setAttributes(dateAttrs, ofItemAtPath: liveFinal.path) }
                            summary.liveVideos += 1
                        }
                    }
                    try? fm.removeItem(at: lr)
                }
            }

            saveManifest()
            emit()
            if stalled { summary.stalled = true; break outer }
            if disconnected { summary.disconnected = true; break outer }
            if cancelledNow { break outer }
        }

        summary.cancelled = job.isCancelled
        summary.notAttempted = max(0, summary.total - summary.copied - summary.skipped - summary.failures.count)
        summary.elapsed = Date().timeIntervalSince(started)
        return summary
    }

    static func decodes(_ url: URL, isVideo: Bool) -> Bool {
        if isVideo { return AVURLAsset(url: url).isPlayable }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return false }
        return CGImageSourceGetStatus(src) == .statusComplete
    }

    static func uniqueURL(for preferred: URL, avoiding reserved: Set<String> = []) -> URL {
        let dir = preferred.deletingLastPathComponent()
        let base = preferred.deletingPathExtension().lastPathComponent
        let ext = preferred.pathExtension
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) && !reserved.contains(candidate.path) { return candidate }
            i += 1
        }
    }

    static func relativePath(of url: URL, inside root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : url.lastPathComponent
    }
}

// MARK: - Thumbnails

actor Limiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { available = n }
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeLast().resume() }
    }
}

final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    static let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("iPhoneAlbumExtractor2-cache", isDirectory: true)

    private let cache = NSCache<NSNumber, NSImage>()
    private let limiter = Limiter(3)

    init() { cache.countLimit = 4000 }

    static func purgeDiskCache() { try? FileManager.default.removeItem(at: cacheRoot) }

    func cached(_ id: Int64) -> NSImage? { cache.object(forKey: NSNumber(value: id)) }

    func image(for asset: PhotoAsset, device: Device, tools: Tools) async -> NSImage? {
        if let hit = cached(asset.id) { return hit }
        await limiter.acquire()
        if Task.isCancelled { await limiter.release(); return nil }
        let img: NSImage? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Self.fetch(asset, device: device, tools: tools))
            }
        }
        await limiter.release()
        if let img { cache.setObject(img, forKey: NSNumber(value: asset.id)) }
        return img
    }

    private static func fetch(_ asset: PhotoAsset, device: Device, tools: Tools) -> NSImage? {
        let dir = cacheRoot.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // iOS keeps small pre-rendered JPEGs beside the library; use them when present so the
        // multi-megabyte original is only fetched as a fallback.
        let small = dir.appendingPathComponent("\(asset.id)_a.jpg")
        let smaller = dir.appendingPathComponent("\(asset.id)_b.jpg")
        if AFC.fileSize(small) <= 0, AFC.fileSize(smaller) <= 0,
           let r1 = AFC.quote("PhotoData/Thumbnails/V2/\(asset.remotePath)/5005.JPG"),
           let r2 = AFC.quote("PhotoData/Thumbnails/V2/\(asset.remotePath)/5003.JPG"),
           let l1 = AFC.quote(small.path), let l2 = AFC.quote(smaller.path) {
            _ = Shell.run(tools.afc, device.baseArgs, stdin: "get \(r1) \(l1)\nget \(r2) \(l2)\nquit\n", timeout: 30)
        }
        for url in [small, smaller] where AFC.fileSize(url) > 0 {
            if let img = downsample(url, max: 420) { return img }
        }
        guard !asset.isVideo, asset.fileSize < 60_000_000 else { return nil }
        let full = dir.appendingPathComponent("\(asset.id)_full.\(asset.fileExtension.lowercased())")
        if AFC.fileSize(full) <= 0 { _ = AFC.get(asset.remotePath, to: full, device: device, tools: tools) }
        let img = downsample(full, max: 420)
        try? FileManager.default.removeItem(at: full)
        return img
    }

    static func downsample(_ url: URL, max: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Mac volumes (external drives)

struct VolumeInfo: Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let free: Int64
    let format: String
    let readOnly: Bool
    var isFAT: Bool { let f = format.lowercased(); return f.contains("fat32") || f.contains("ms-dos") }

    static func external() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeIsBrowsableKey,
                                      .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsInternal != true, v.volumeIsBrowsable == true,
                  url.path.hasPrefix("/Volumes/") else { return nil }
            let format = v.volumeLocalizedFormatDescription ?? ""
            let readOnly = v.volumeIsReadOnly ?? false
            // Read-only volumes are hidden (installer disk images), except NTFS drives, which are worth explaining.
            if readOnly && !format.uppercased().contains("NTFS") { return nil }
            return VolumeInfo(url: url, name: v.volumeName ?? url.lastPathComponent, free: Int64(v.volumeAvailableCapacity ?? 0),
                              format: format, readOnly: readOnly)
        }
    }

    /// Free space for a folder that may not exist yet (walks up to the nearest existing parent).
    static func freeSpace(at url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
        guard let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        if let a = v.volumeAvailableCapacityForImportantUsage, a > 0 { return a }
        return v.volumeAvailableCapacity.map(Int64.init)
    }

    static func format(at url: URL) -> String {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]))?.volumeLocalizedFormatDescription ?? ""
    }
}

// MARK: - Device backups (same format Finder and iTunes use)

struct BackupEntry: Identifiable {
    var id: String { path.path }
    let path: URL
    let deviceName: String
    let date: Date?
    let encrypted: Bool
    let iosVersion: String
}

enum Backup {
    static func existing(in folder: URL) -> [BackupEntry] {
        let subs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
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
                               iosVersion: (info["Product Version"] as? String) ?? "")
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
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
