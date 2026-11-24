import Foundation
import AVFoundation
import SQLite3

/// A song, music video or ringtone stored on the iPhone (synced from a computer or downloaded from the iTunes Store).
struct Song: Identifiable, Hashable {
    let id: Int64
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let track: Int
    let disc: Int
    let year: Int
    let seconds: Double
    let size: Int64
    /// Where the file is on the iPhone, like "iTunes_Control/Music/F12/ABCD.m4a"; empty when it is only in the cloud.
    let remotePath: String
    var isRingtone = false

    var ext: String { (remotePath as NSString).pathExtension.lowercased() }
    var onPhone: Bool { !remotePath.isEmpty }
    /// Apple Music downloads are locked to the Music app and cannot be played anywhere else.
    var isProtected: Bool { ext == "m4p" || ext == "movpkg" }
    var canCopy: Bool { onPhone && !isProtected }

    /// Where a copy goes inside the chosen folder: "Artist/Album/01 Title.m4a", or "Ringtones/Name.m4r".
    var savedPath: String {
        func safe(_ s: String, _ fallback: String) -> String { let t = Pattern.safe(s); return t.isEmpty ? fallback : t }
        let name = safe(title, "Track \(id)") + (ext.isEmpty ? "" : "." + ext)
        if isRingtone { return "Ringtones/\(name)" }
        let number = track > 0 ? (disc > 1 ? "\(disc)-" : "") + String(format: "%02d ", track) : ""
        return "\(safe(albumArtist.isEmpty ? artist : albumArtist, "Unknown Artist"))/\(safe(album, "Unknown Album"))/\(number)\(name)"
    }
}

/// Reads the iPhone's own music library database over USB (the files and their details), and copies the files out.
enum MusicLibrary {
    static let database = "iTunes_Control/iTunes/MediaLibrary.sqlitedb"
    static let ringtoneFolder = "iTunes_Control/Ringtones"

    /// The songs and ringtones on the iPhone, or what went wrong.
    static func load(device: Device, tools: Tools) -> (songs: [Song], problem: String?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PortHop-music-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("MediaLibrary.sqlitedb")
        var songs: [Song] = []
        if AFC.get(database, to: db, device: device, tools: tools) {
            let wal = AFC.get(database + "-wal", to: URL(fileURLWithPath: db.path + "-wal"), device: device, tools: tools)
            _ = AFC.get(database + "-shm", to: URL(fileURLWithPath: db.path + "-shm"), device: device, tools: tools)
            songs = read(db.path, immutable: !wal)
        }
        let known = Set(songs.map(\.remotePath))
        var tones = ringtones(device: device, tools: tools, plist: dir.appendingPathComponent("Ringtones.plist"))
        tones.removeAll { known.contains($0.remotePath) }
        let all = songs + tones
        if all.isEmpty && !FileManager.default.fileExists(atPath: db.path) {
            return ([], "The music library could not be read. Unlock the iPhone and try again.")
        }
        return (all, nil)
    }

    /// Reads the library database. Only the columns that exist in this iOS version are used.
    static func read(_ path: String, immutable: Bool = true) -> [Song] {
        guard let db = SQLiteFile(path: path, immutable: immutable) else { return [] }
        let item = db.columns("item"), extra = db.columns("item_extra")
        guard item.contains("item_pid"), extra.contains("location") else { return [] }
        func pick(_ cols: Set<String>, _ expr: String, _ name: String, _ fallback: String) -> String { cols.contains(name) ? expr : fallback }
        var joins = "FROM item i JOIN item_extra e ON e.item_pid = i.item_pid"
        var artist = "''", album = "''", albumArtist = "''", base = "''"
        if db.columns("item_artist").contains("item_artist"), item.contains("item_artist_pid") {
            joins += " LEFT JOIN item_artist ar ON ar.item_artist_pid = i.item_artist_pid"; artist = "COALESCE(ar.item_artist,'')"
        }
        if db.columns("album").contains("album"), item.contains("album_pid") {
            joins += " LEFT JOIN album al ON al.album_pid = i.album_pid"; album = "COALESCE(al.album,'')"
        }
        if db.columns("album_artist").contains("album_artist"), item.contains("album_artist_pid") {
            joins += " LEFT JOIN album_artist aa ON aa.album_artist_pid = i.album_artist_pid"; albumArtist = "COALESCE(aa.album_artist,'')"
        }
        if db.columns("base_location").contains("path"), item.contains("base_location_id") {
            joins += " LEFT JOIN base_location b ON b.base_location_id = i.base_location_id"; base = "COALESCE(b.path,'')"
        }
        let sql = """
            SELECT i.item_pid, \(pick(extra, "COALESCE(e.title,'')", "title", "''")), \(artist), \(album), \(albumArtist),
                   \(pick(item, "COALESCE(i.track_number,0)", "track_number", "0")), \(pick(item, "COALESCE(i.disc_number,0)", "disc_number", "0")),
                   \(pick(extra, "COALESCE(e.year,0)", "year", "0")), \(pick(extra, "COALESCE(e.total_time_ms,0)", "total_time_ms", "0")),
                   \(pick(extra, "COALESCE(e.file_size,0)", "file_size", "0")), \(base), COALESCE(e.location,'')
            \(joins)
            """
        var out: [Song] = []
        db.each(sql) { s in
            let folder = SQLiteFile.text(s, 10), file = SQLiteFile.text(s, 11)
            let remote = (!folder.isEmpty && !file.isEmpty) ? folder.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + file : ""
            out.append(Song(id: sqlite3_column_int64(s, 0), title: SQLiteFile.text(s, 1), artist: SQLiteFile.text(s, 2), album: SQLiteFile.text(s, 3),
                            albumArtist: SQLiteFile.text(s, 4), track: Int(sqlite3_column_int(s, 5)), disc: Int(sqlite3_column_int(s, 6)),
                            year: Int(sqlite3_column_int(s, 7)), seconds: sqlite3_column_double(s, 8) / 1000, size: sqlite3_column_int64(s, 9),
                            remotePath: remote, isRingtone: remote.contains("Ringtones/")))
        }
        return out.sorted {
            let a = ($0.albumArtist.isEmpty ? $0.artist : $0.albumArtist), b = ($1.albumArtist.isEmpty ? $1.artist : $1.albumArtist)
            if a != b { return a.localizedCaseInsensitiveCompare(b) == .orderedAscending }
            if $0.album != $1.album { return $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
            return ($0.disc, $0.track, $0.title) < ($1.disc, $1.track, $1.title)
        }
    }

    /// Ringtones in the iPhone's ringtone folder, named from its list of tones when there is one.
    static func ringtones(device: Device, tools: Tools, plist: URL) -> [Song] {
        var names: [String: String] = [:]
        if AFC.get("iTunes_Control/iTunes/Ringtones.plist", to: plist, device: device, tools: tools),
           let d = try? Data(contentsOf: plist),
           let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any],
           let tones = p["Ringtones"] as? [String: Any] {
            for (file, info) in tones { if let n = (info as? [String: Any])?["Name"] as? String { names[file] = n } }
        }
        return AFC.list(ringtoneFolder, device: device, tools: tools).filter { !$0.isDirectory && $0.name.lowercased().hasSuffix(".m4r") }
            .enumerated().map { i, e in
                Song(id: -Int64(i + 1), title: names[e.name] ?? (e.name as NSString).deletingPathExtension, artist: "", album: "", albumArtist: "",
                     track: 0, disc: 0, year: 0, seconds: 0, size: e.size, remotePath: "\(ringtoneFolder)/\(e.name)", isRingtone: true)
            }
    }

    struct Outcome { var copied = 0; var skipped = 0; var failed: [String] = []; var cancelled = false }

    /// Copies songs into a folder as "Artist/Album/01 Title.ext". A file already there with the same size is skipped.
    static func copy(_ songs: [Song], to folder: URL, device: Device, tools: Tools, job: ExportJob,
                     progress: @escaping (Int, Int, String) -> Void) -> Outcome {
        var o = Outcome()
        let fm = FileManager.default
        for (n, song) in songs.enumerated() {
            if job.isCancelled { o.cancelled = true; break }
            progress(n, songs.count, song.title)
            guard song.canCopy else { o.failed.append(song.title); continue }
            let dest = folder.appendingPathComponent(song.savedPath)
            if fm.fileExists(atPath: dest.path), song.size <= 0 || AFC.fileSize(dest) == song.size { o.skipped += 1; continue }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let part = URL(fileURLWithPath: dest.path + ".porthop-part")
            try? fm.removeItem(at: part)
            _ = Shell.run(tools.afc, device.baseArgs + ["--", "get", song.remotePath, part.path], onStart: { job.track($0) })
            job.clear()
            let size = AFC.fileSize(part)
            if size > 0, song.size <= 0 || size == song.size {
                try? fm.removeItem(at: dest)
                if (try? fm.moveItem(at: part, to: dest)) != nil { o.copied += 1; continue }
            }
            try? fm.removeItem(at: part)
            o.failed.append(song.title)
        }
        return o
    }

    /// Sends songs straight to a connected Android phone (Music/…, ringtones to Ringtones), through a temporary folder.
    static func send(_ songs: [Song], from device: Device, toAndroid phone: Device, tools: Tools, job: ExportJob,
                     progress: @escaping (Int, Int, String) -> Void) -> Outcome {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("PortHop-music-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var o = Outcome()
        for (n, song) in songs.enumerated() {
            if job.isCancelled { o.cancelled = true; break }
            progress(n, songs.count, song.title)
            let one = copy([song], to: staging, device: device, tools: tools, job: job, progress: { _, _, _ in })
            let local = staging.appendingPathComponent(song.savedPath)
            guard one.copied == 1 else { o.failed.append(song.title); continue }
            let dir = song.isRingtone ? Android.storageRoot + "/Ringtones" : Android.storageRoot + "/Music/" + (song.savedPath as NSString).deletingLastPathComponent
            var existing = Set(Android.list(dir, device: phone, tools: tools).map(\.name))
            if existing.contains(local.lastPathComponent) { o.skipped += 1; try? FileManager.default.removeItem(at: local); continue }
            if Android.mkdirs(dir, device: phone, tools: tools),
               Android.push(local, intoDir: dir, existing: &existing, device: phone, tools: tools, onStart: { job.track($0) }) {
                Android.scan([dir + "/" + local.lastPathComponent], device: phone, tools: tools)
                o.copied += 1
            } else { o.failed.append(song.title) }
            job.clear()
            try? FileManager.default.removeItem(at: local)
        }
        return o
    }
}

/// Makes a ringtone (.m4r, at most 40 seconds) from any song or sound file the Mac can play.
enum RingtoneMaker {
    static let maxSeconds = 40.0

    static func duration(of url: URL) async -> Double {
        guard let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric else { return 0 }
        return d.seconds
    }

    private static func run(_ export: AVAssetExportSession, to url: URL) async -> String? {
        if #available(macOS 15.0, *) {
            do { try await export.export(to: url, as: .m4a); return nil } catch { return error.localizedDescription }
        }
        export.outputURL = url
        export.outputFileType = .m4a
        await export.export()
        return export.status == .completed ? nil : "The ringtone could not be made."
    }

    /// Returns nil when the ringtone was saved, or what went wrong.
    static func make(from source: URL, start: Double, length: Double, to dest: URL) async -> String? {
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isExportable)) == true,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return "This file can't be made into a ringtone (it may be protected by Apple Music)."
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PortHop-tone-\(UUID().uuidString).m4a")
        let len = min(max(length, 1), maxSeconds)
        export.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start), preferredTimescale: 600),
                                       duration: CMTime(seconds: len, preferredTimescale: 600))
        let problem = await run(export, to: tmp)
        guard problem == nil, FileManager.default.fileExists(atPath: tmp.path) else {
            try? FileManager.default.removeItem(at: tmp)
            return problem ?? "The ringtone could not be made."
        }
        try? FileManager.default.removeItem(at: dest)
        do { try FileManager.default.moveItem(at: tmp, to: dest) } catch {
            try? FileManager.default.removeItem(at: tmp)
            return "The ringtone could not be saved there."
        }
        return nil
    }
}
