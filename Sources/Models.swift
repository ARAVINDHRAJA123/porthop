import Foundation
import AppKit
import SQLite3
import ImageIO
import AVFoundation

// Photos, albums, options and results: the data the rest of the app passes around.

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
    /// Edited in the Photos app (the edit is a separate rendered file next to the library).
    var isEdited = false
    /// Synced with iCloud Photos and its original is not on the device ("Optimise iPhone Storage").
    var isCloudOnly = false
    /// When exporting the edited version: where the rendered file is on the device, and its size.
    var renderPath: String? = nil
    var renderSize: Int64 = 0

    static func == (a: PhotoAsset, b: PhotoAsset) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var sortType: Int { isVideo ? 2 : (isLivePhoto ? 1 : 0) }
    var sortDate: Double { dateCreated?.timeIntervalSinceReferenceDate ?? 0 }
    var sortPixels: Int { width * height }

    var remotePath: String {
        if let renderPath { return renderPath }
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

    /// Where iOS keeps the rendered edit of this photo or video: PhotoData/Mutations/<folder>/<name>/Adjustments/FullSizeRender.*
    var renderCandidates: [String] {
        let dir = directory.hasPrefix("/") ? String(directory.dropFirst()) : directory
        let base = "PhotoData/Mutations/\(dir)/\((filename as NSString).deletingPathExtension)/Adjustments/FullSizeRender"
        return isVideo ? [base + ".mov"] : [base + ".heic", base + ".jpg"]
    }

    /// This photo, pointed at its rendered edit: same record, the edit's file, size and extension.
    func editedVersion(path: String, size: Int64) -> PhotoAsset {
        let ext = (path as NSString).pathExtension
        func renamed(_ n: String) -> String { n.isEmpty ? n : (n as NSString).deletingPathExtension + "." + ext }
        var a = PhotoAsset(id: id, uuid: uuid, directory: directory, filename: renamed(filename), originalFilename: renamed(originalFilename),
                           fileSize: size, width: width, height: height, duration: duration, isHidden: isHidden, isFavorite: isFavorite,
                           isTrashed: isTrashed, isVideo: isVideo, isScreenshot: isScreenshot, isSelfie: isSelfie, isLivePhoto: isLivePhoto,
                           dateCreated: dateCreated, dateText: dateText, searchKey: searchKey)
        a.isEdited = true; a.isCloudOnly = isCloudOnly; a.renderPath = path; a.renderSize = size
        return a
    }
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
    case custom = "Custom pattern…"
    var id: String { rawValue }

    static var patternTokens: String { Pattern.tokens }

    /// The folder a pattern gives for one item, made safe for any drive ("/" or "\\" separates levels).
    static func folder(_ pattern: String, _ asset: PhotoAsset, album: String, device: String = "") -> String {
        let out = Pattern.render(pattern, asset, album: album, device: device, name: (asset.filename as NSString).deletingPathExtension)
        return out.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map { Pattern.safe(String($0)) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }.joined(separator: "/")
    }
}

/// Folder and file-name patterns, shared with the Windows edition (Tests/golden/patterns.json checks both).
enum Pattern {
    static let tokens = "{year} {month} {monthName} {day} {hour} {minute} {second} {album} {folder} {device} {kind} {name}"
    private static let formatters: [String: DateFormatter] = Dictionary(uniqueKeysWithValues: ["yyyy", "MM", "MMMM", "dd", "HH", "mm", "ss"].map { f in
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = f
        return (f, df)
    })

    /// Replaces every token; a value never adds a folder level of its own ("/" inside a value becomes "-").
    static func render(_ pattern: String, _ asset: PhotoAsset, album: String, device: String, name: String) -> String {
        func date(_ f: String) -> String { asset.dateCreated.map { formatters[f]!.string(from: $0) } ?? "Unknown" }
        let folder = asset.directory.split(separator: "/").last.map(String.init) ?? "DCIM"
        let kind = asset.isVideo ? "Videos" : (asset.isScreenshot ? "Screenshots" : "Photos")
        var out = pattern
        for (k, v) in [("{year}", date("yyyy")), ("{month}", date("MM")), ("{monthName}", date("MMMM")), ("{day}", date("dd")),
                       ("{hour}", date("HH")), ("{minute}", date("mm")), ("{second}", date("ss")),
                       ("{album}", album.isEmpty ? "Photos" : album), ("{folder}", folder), ("{device}", device.isEmpty ? "iPhone" : device),
                       ("{kind}", kind), ("{name}", name)] where out.contains(k) {
            out = out.replacingOccurrences(of: k, with: v.replacingOccurrences(of: "/", with: "-"))
        }
        return out
    }

    /// One folder or file name, safe on Mac, Windows and exFAT drives alike.
    static func safe(_ s: String) -> String {
        var out = String(s.unicodeScalars.map { c -> Character in
            ("\\/:*?\"<>|".unicodeScalars.contains(c) || c.value < 0x20) ? "-" : Character(c)
        }).trimmingCharacters(in: .whitespaces)
        while out.hasSuffix(".") || out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// The new name (without extension) a file-name pattern gives one item; nil keeps the device's name.
    static func fileStem(_ pattern: String, _ asset: PhotoAsset, album: String, device: String, original: String) -> String? {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        let s = safe(render(p, asset, album: album, device: device, name: (original as NSString).deletingPathExtension)
            .replacingOccurrences(of: "/", with: "-"))
        return s.isEmpty || s == "." || s == ".." ? nil : s
    }
}

struct ExportOptions {
    var convertHEIC = false
    var skipExisting = true
    var useOriginalNames = false
    var setDates = true
    var includeLiveVideo = false
    var subfolder: SubfolderMode = .flat
    /// Copy the version edited in the Photos app, where there is one, instead of the original.
    var editedVersions = false
    /// For SubfolderMode.custom, e.g. "{year}/{month} {monthName}" or "{album}/{year}-{month}".
    var folderPattern = "{year}/{month}"
    /// The group being copied, for {album} in a pattern.
    var albumName = ""
    /// Renames each copy, e.g. "{year}-{month}-{day} {hour}.{minute}.{second}"; empty keeps the device's names.
    var namePattern = ""
    /// Wipes the GPS position from photos and videos as they land (no re-encoding).
    var removeLocation = false
    /// Writes "PortHop Reports/<date> <group>.csv" listing what was copied and what was not.
    var saveReport = true
    /// For {device} in a pattern.
    var deviceName = ""
}

/// One line of a copy report.
struct ReportLine {
    enum Status: String { case copied = "Copied", skipped = "Already in the folder", failed = "Failed", cloud = "Only in iCloud", notCopied = "Not copied" }
    let status: Status
    let asset: PhotoAsset
    let savedAs: String
    let note: String
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
    var report: [ReportLine] = []
    var reportURL: URL? = nil
    var isClean: Bool { failures.isEmpty && !cancelled && !disconnected && !stalled && fatalError == nil }
}
