import Foundation
import SQLite3

/// One sheet of rows read out of a backup, for example one conversation or the contact list.
struct DataGroup: Identifiable {
    let id: Int
    var title: String
    var subtitle = ""
    var columns: [String]
    var rows: [[String]] = []
    /// Backup file ids, one per row, when the rows are files that can be copied out.
    var fileIDs: [String] = []
    /// Chats: files attached to a row (photos, videos, documents), as places in the backup.
    var media: [Int: [BackupFileRef]] = [:]
}

/// One file inside a backup, by the domain and path the device gave it.
struct BackupFileRef: Equatable { let domain: String; let path: String; var name: String { (path as NSString).lastPathComponent } }

struct BackupData {
    var groups: [DataGroup] = []
    /// Plain-language reason when there is nothing to show.
    var note = ""
}

enum BackupKind: String, CaseIterable, Identifiable {
    case messages, whatsapp, contacts, notes, calendar, calls, safari, photos, voiceMemos, files
    var id: String { rawValue }
    var title: String {
        switch self {
        case .messages: return "Messages"
        case .whatsapp: return "WhatsApp"
        case .contacts: return "Contacts"
        case .notes: return "Notes"
        case .calendar: return "Calendar"
        case .calls: return "Call Log"
        case .safari: return "Safari"
        case .photos: return "Photos & Videos"
        case .voiceMemos: return "Voice Memos"
        case .files: return "Backup Files"
        }
    }
    var symbol: String {
        switch self {
        case .messages: return "message.fill"
        case .whatsapp: return "phone.bubble.fill"
        case .contacts: return "person.crop.circle.fill"
        case .notes: return "note.text"
        case .calendar: return "calendar"
        case .calls: return "phone.fill"
        case .safari: return "safari.fill"
        case .photos: return "photo.on.rectangle.angled"
        case .voiceMemos: return "waveform"
        case .files: return "archivebox.fill"
        }
    }
    var groupWord: String {
        switch self {
        case .messages, .whatsapp: return "conversations"
        case .files: return "areas"
        case .photos: return "folders"
        default: return "lists"
        }
    }
    /// Apple leaves these out of backups that are not encrypted.
    var needsEncryptedBackup: Bool { self == .calls }
}

/// A read-only SQLite file.
final class SQLiteFile {
    private var db: OpaquePointer?

    init?(path: String, immutable: Bool) {
        var handle: OpaquePointer?
        let ok: Bool
        if immutable {
            let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            ok = sqlite3_open_v2("file:\(escaped)?immutable=1", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        } else {
            ok = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
        }
        guard ok, let h = handle else { sqlite3_close(handle); return nil }
        db = h
    }

    deinit { sqlite3_close(db) }

    func columns(_ table: String) -> Set<String> {
        var out = Set<String>()
        each("PRAGMA table_info(\"\(table)\")") { s in out.insert(SQLiteFile.text(s, 1)) }
        return out
    }

    static func text(_ s: OpaquePointer?, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
    static func data(_ s: OpaquePointer?, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(s, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(s, i)))
    }

    @discardableResult
    func each(_ sql: String, bind: [String] = [], _ row: (OpaquePointer?) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in bind.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient) }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        return true
    }
}

/// Reads a standard device backup (the format Finder and this app's Backups screen make). Never writes into it.
final class BackupReader {
    let folder: URL
    private let manifest: SQLiteFile
    private let temp: URL
    /// Class keys, when the backup is password-protected.
    private let keys: [UInt32: Data]?
    private let lock = NSLock()

    enum Opened { case ready(BackupReader), needsPassword, wrongPassword, unreadable }

    /// Opens any backup. A password-protected one needs its password; nothing is written into the backup either way.
    static func open(folder: URL, password: String?) -> Opened {
        guard isEncrypted(folder) else { return BackupReader(folder: folder).map { .ready($0) } ?? .unreadable }
        guard let password, !password.isEmpty else { return .needsPassword }
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("Manifest.plist")),
              let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any],
              let bag = p["BackupKeyBag"] as? Data, let manifestKey = p["ManifestKey"] as? Data, manifestKey.count > 4 else { return .unreadable }
        let keys: [UInt32: Data]
        switch BackupCrypto.unlock(keyBag: bag, password: password) {
        case .keys(let k): keys = k
        case .wrongPassword: return .wrongPassword
        case .unreadable: return .unreadable
        }
        guard let classKey = keys[BackupCrypto.classID(manifestKey)], let key = BackupCrypto.unwrap(manifestKey.dropFirst(4), with: classKey) else { return .unreadable }
        purgeTemp()
        let temp = newTemp()
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let plain = temp.appendingPathComponent("Manifest.db")
        guard BackupCrypto.decrypt(folder.appendingPathComponent("Manifest.db"), to: plain, key: key, size: nil),
              let m = SQLiteFile(path: plain.path, immutable: true), m.columns("Files").contains("fileID") else {
            try? FileManager.default.removeItem(at: temp)
            return .unreadable
        }
        return .ready(BackupReader(folder: folder, manifest: m, temp: temp, keys: keys))
    }

    private static let tempPrefix = "PortHop-bk-"
    private static let legacyTempPrefixes = ["iPhoneAlbumExtractor2-bk-"]
    private static func newTemp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(tempPrefix + UUID().uuidString, isDirectory: true) }
    /// Removes decrypted working copies left behind by an earlier run.
    static func purgeTemp() {
        let dir = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(tempPrefix) || legacyTempPrefixes.contains(where: { name.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private init(folder: URL, manifest: SQLiteFile, temp: URL, keys: [UInt32: Data]) {
        self.folder = folder; self.manifest = manifest; self.temp = temp; self.keys = keys
    }

    static func isEncrypted(_ folder: URL) -> Bool {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("Manifest.plist")),
              let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { return false }
        return (p["IsEncrypted"] as? Bool) ?? false
    }

    init?(folder: URL) {
        guard !BackupReader.isEncrypted(folder),
              let m = SQLiteFile(path: folder.appendingPathComponent("Manifest.db").path, immutable: true),
              m.columns("Files").contains("fileID") else { return nil }
        self.folder = folder
        manifest = m
        temp = BackupReader.newTemp()
        keys = nil
    }

    /// A readable copy of one stored file: the file itself, or a decrypted working copy for protected backups.
    func plain(_ fileID: String) -> URL? {
        guard let keys else { return stored(fileID) }
        lock.lock(); defer { lock.unlock() }
        let dir = temp.appendingPathComponent("plain", isDirectory: true)
        let out = dir.appendingPathComponent(fileID)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        var blob: Data?
        manifest.each("SELECT file FROM Files WHERE fileID=? LIMIT 1", bind: [fileID]) { blob = SQLiteFile.data($0, 0) }
        guard let blob, let record = BackupCrypto.fileRecord(blob), let classKey = keys[record.clas],
              let key = BackupCrypto.unwrap(record.wrappedKey, with: classKey) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard BackupCrypto.decrypt(stored(fileID), to: out, key: key, size: record.size) else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    deinit { try? FileManager.default.removeItem(at: temp) }

    func stored(_ fileID: String) -> URL { folder.appendingPathComponent(String(fileID.prefix(2))).appendingPathComponent(fileID) }

    func fileID(domain: String, path: String) -> String? {
        var id: String?
        manifest.each("SELECT fileID FROM Files WHERE domain=? AND relativePath=? LIMIT 1", bind: [domain, path]) { id = SQLiteFile.text($0, 0) }
        guard let id, FileManager.default.fileExists(atPath: stored(id).path) else { return nil }
        return id
    }

    /// Every file in the backup, as its domain and path (folders are left out).
    func eachFile(_ body: (_ domain: String, _ path: String) -> Void) {
        manifest.each("SELECT domain, relativePath FROM Files WHERE flags = 1") { s in body(SQLiteFile.text(s, 0), SQLiteFile.text(s, 1)) }
    }

    /// The contents of one small file in the backup (a settings file, say), decrypted when needed.
    func contents(domain: String, path: String) -> Data? {
        guard let id = fileID(domain: domain, path: path), let url = plain(id) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Opens a database held in the backup. Unsaved changes kept beside it (a "-wal" file) are included by working on a copy.
    func database(domain: String, path: String) -> SQLiteFile? {
        guard let id = fileID(domain: domain, path: path) else { return nil }
        guard let main = plain(id) else { return nil }
        guard let walID = fileID(domain: domain, path: path + "-wal"), let wal = plain(walID), AFC.fileSize(wal) > 0 else {
            return SQLiteFile(path: main.path, immutable: true)
        }
        let dir = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("db.sqlite")
        guard (try? FileManager.default.copyItem(at: main, to: copy)) != nil else { return nil }
        try? FileManager.default.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
        return SQLiteFile(path: copy.path, immutable: false)
    }

    // MARK: Helpers

    static let appleEpoch: TimeInterval = 978_307_200
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Seconds (or nanoseconds, on newer systems) since 2001.
    static func date(_ raw: Double) -> String {
        guard raw > 0 else { return "" }
        let secs = raw > 100_000_000_000 ? raw / 1_000_000_000 : raw
        return stamp.string(from: Date(timeIntervalSince1970: secs + appleEpoch))
    }

    /// The comparable part of a phone number or email address.
    static func key(_ address: String) -> String {
        if address.contains("@") { return address.lowercased() }
        let digits = address.filter(\.isNumber)
        return String(digits.suffix(10))
    }

    /// Newer systems keep the message text inside an archived object instead of the plain text column.
    static func text(fromArchive blob: Data) -> String? {
        guard let marker = blob.range(of: Data("NSString".utf8)) else { return nil }
        var i = marker.upperBound + 5
        guard i < blob.count else { return nil }
        var length = Int(blob[i]); i += 1
        if length == 0x81 {
            guard i + 2 <= blob.count else { return nil }
            length = Int(blob[i]) | Int(blob[i + 1]) << 8
            i += 2
        } else if length == 0x82 {
            // Very long messages: the length is the next four bytes.
            guard i + 4 <= blob.count else { return nil }
            length = Int(blob[i]) | Int(blob[i + 1]) << 8 | Int(blob[i + 2]) << 16 | Int(blob[i + 3]) << 24
            i += 4
        }
        guard length > 0, i + length <= blob.count else { return nil }
        return String(data: blob.subdata(in: i..<(i + length)), encoding: .utf8)
    }

    func contactNames() -> [String: String] {
        guard let db = database(domain: "HomeDomain", path: "Library/AddressBook/AddressBook.sqlitedb") else { return [:] }
        var names: [String: String] = [:]
        db.each("""
            SELECT TRIM(COALESCE(p.First,'') || ' ' || COALESCE(p.Last,'')), COALESCE(p.Organization,''), v.value
            FROM ABMultiValue v JOIN ABPerson p ON p.ROWID = v.record_id WHERE v.property IN (3, 4) AND v.value IS NOT NULL
            """) { s in
            let name = SQLiteFile.text(s, 0).isEmpty ? SQLiteFile.text(s, 1) : SQLiteFile.text(s, 0)
            let k = BackupReader.key(SQLiteFile.text(s, 2))
            if !name.isEmpty, !k.isEmpty { names[k] = name }
        }
        return names
    }

    // MARK: Data

    func load(_ kind: BackupKind) -> BackupData {
        let data: BackupData
        switch kind {
        case .messages: data = messages()
        case .whatsapp: data = whatsapp()
        case .contacts: data = contacts()
        case .notes: data = notes()
        case .calendar: data = calendar()
        case .calls: data = calls()
        case .safari: data = safari()
        case .photos: data = photos()
        case .voiceMemos: data = voiceMemos()
        case .files: data = files()
        }
        if data.groups.allSatisfy({ $0.rows.isEmpty }) && data.note.isEmpty {
            return BackupData(note: kind.needsEncryptedBackup
                ? (keys == nil ? "\(kind.title) is only saved in encrypted backups, and this backup is not encrypted." : "This backup has no \(kind.title) data.")
                : "This backup has no \(kind.title) data.")
        }
        return data
    }

    private func messages() -> BackupData {
        guard let db = database(domain: "HomeDomain", path: "Library/SMS/sms.db") else { return BackupData() }
        let names = contactNames()
        func who(_ address: String) -> String { names[BackupReader.key(address)] ?? address }
        let archive = db.columns("message").contains("attributedBody") ? "m.attributedBody" : "NULL"
        var groups: [DataGroup] = []
        var index: [Int64: Int] = [:]
        var place: [Int64: (Int, Int)] = [:]   // message → (conversation, row), for attachments
        db.each("""
            SELECT c.ROWID, COALESCE(c.display_name,''), COALESCE(c.chat_identifier,''), m.date, m.is_from_me, COALESCE(h.id,''),
                   m.text, \(archive), COALESCE(m.cache_has_attachments, 0), m.ROWID
            FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id JOIN chat c ON c.ROWID = j.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id ORDER BY m.date
            """) { s in
            let chat = sqlite3_column_int64(s, 0)
            if index[chat] == nil {
                index[chat] = groups.count
                let named = SQLiteFile.text(s, 1), ident = SQLiteFile.text(s, 2)
                groups.append(DataGroup(id: Int(chat), title: named.isEmpty ? who(ident) : named, subtitle: ident, columns: ["Date", "From", "Message"]))
            }
            var body = SQLiteFile.text(s, 6)
            if body.isEmpty, let blob = SQLiteFile.data(s, 7) { body = BackupReader.text(fromArchive: blob) ?? "" }
            body = body.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { body = sqlite3_column_int(s, 8) != 0 ? "(attachment)" : "(no text)" }
            let from = sqlite3_column_int(s, 4) != 0 ? "Me" : who(SQLiteFile.text(s, 5))
            groups[index[chat]!].rows.append([BackupReader.date(sqlite3_column_double(s, 3)), from, body])
            place[sqlite3_column_int64(s, 9)] = (index[chat]!, groups[index[chat]!].rows.count - 1)
        }
        // Attachments live in MediaDomain under the path the message gives ("~/Library/SMS/Attachments/…").
        if db.columns("attachment").contains("filename"), !db.columns("message_attachment_join").isEmpty {
            db.each("SELECT j.message_id, COALESCE(a.filename,'') FROM message_attachment_join j JOIN attachment a ON a.ROWID = j.attachment_id") { s in
                guard let (g, r) = place[sqlite3_column_int64(s, 0)] else { return }
                var path = SQLiteFile.text(s, 1)
                if path.hasPrefix("~/") { path.removeFirst(2) } else if let i = path.range(of: "/Library/SMS/") { path = String(path[path.index(after: i.lowerBound)...]) }
                if !path.isEmpty { groups[g].media[r, default: []].append(BackupFileRef(domain: "MediaDomain", path: path)) }
            }
        }
        return BackupData(groups: BackupReader.newestFirst(groups))
    }

    private func whatsapp() -> BackupData {
        guard let db = database(domain: "AppDomainGroup-group.net.whatsapp.WhatsApp.shared", path: "ChatStorage.sqlite") else {
            return BackupData(note: "WhatsApp is not in this backup. It is included only when WhatsApp is installed on the device.")
        }
        var groups: [DataGroup] = []
        var index: [Int64: Int] = [:]
        db.each("SELECT Z_PK, COALESCE(ZPARTNERNAME,''), COALESCE(ZCONTACTJID,'') FROM ZWACHATSESSION") { s in
            index[sqlite3_column_int64(s, 0)] = groups.count
            let jid = SQLiteFile.text(s, 2)
            let number = jid.split(separator: "@").first.map(String.init) ?? jid
            groups.append(DataGroup(id: Int(sqlite3_column_int64(s, 0)), title: SQLiteFile.text(s, 1).isEmpty ? number : SQLiteFile.text(s, 1),
                                    subtitle: jid.hasSuffix("@g.us") ? "Group" : number, columns: ["Date", "From", "Message"]))
        }
        let msgCols = db.columns("ZWAMESSAGE")
        let push = msgCols.contains("ZPUSHNAME") ? "COALESCE(ZPUSHNAME,'')" : "''"
        // Photos, videos and documents: the media item's path, under Message/ in WhatsApp's shared group.
        let hasMedia = msgCols.contains("ZMEDIAITEM") && db.columns("ZWAMEDIAITEM").contains("ZMEDIALOCALPATH")
        let mediaCol = hasMedia ? "COALESCE((SELECT ZMEDIALOCALPATH FROM ZWAMEDIAITEM WHERE Z_PK = ZWAMESSAGE.ZMEDIAITEM),'')" : "''"
        let waDomain = "AppDomainGroup-group.net.whatsapp.WhatsApp.shared"
        db.each("SELECT ZCHATSESSION, ZMESSAGEDATE, ZISFROMME, COALESCE(ZFROMJID,''), ZTEXT, \(push), \(mediaCol) FROM ZWAMESSAGE ORDER BY ZMESSAGEDATE") { s in
            guard let g = index[sqlite3_column_int64(s, 0)] else { return }
            let text = SQLiteFile.text(s, 4)
            var from = "Me"
            if sqlite3_column_int(s, 2) == 0 {
                let pushName = SQLiteFile.text(s, 5)
                from = groups[g].subtitle == "Group" ? (pushName.isEmpty ? "Member" : pushName) : groups[g].title
            }
            groups[g].rows.append([BackupReader.date(sqlite3_column_double(s, 1)), from, text.isEmpty ? "(photo, video or other attachment)" : text])
            let media = SQLiteFile.text(s, 6)
            if !media.isEmpty { groups[g].media[groups[g].rows.count - 1] = [BackupFileRef(domain: waDomain, path: "Message/" + (media.hasPrefix("/") ? String(media.dropFirst()) : media))] }
        }
        return BackupData(groups: BackupReader.newestFirst(groups.filter { !$0.rows.isEmpty }))
    }

    private static func newestFirst(_ groups: [DataGroup]) -> [DataGroup] {
        groups.sorted { ($0.rows.last?.first ?? "") > ($1.rows.last?.first ?? "") }
    }

    private func contacts() -> BackupData {
        guard let db = database(domain: "HomeDomain", path: "Library/AddressBook/AddressBook.sqlitedb") else { return BackupData() }
        var phones: [Int64: [String]] = [:], mails: [Int64: [String]] = [:]
        db.each("SELECT record_id, property, value FROM ABMultiValue WHERE property IN (3, 4) AND value IS NOT NULL") { s in
            let id = sqlite3_column_int64(s, 0)
            if sqlite3_column_int(s, 1) == 3 { phones[id, default: []].append(SQLiteFile.text(s, 2)) }
            else { mails[id, default: []].append(SQLiteFile.text(s, 2)) }
        }
        var g = DataGroup(id: 0, title: "All Contacts", columns: ["Name", "Company", "Phone", "Email"])
        db.each("SELECT ROWID, TRIM(COALESCE(First,'') || ' ' || COALESCE(Last,'')), COALESCE(Organization,'') FROM ABPerson ORDER BY 2 COLLATE NOCASE") { s in
            let id = sqlite3_column_int64(s, 0)
            g.rows.append([SQLiteFile.text(s, 1), SQLiteFile.text(s, 2), (phones[id] ?? []).joined(separator: ", "), (mails[id] ?? []).joined(separator: ", ")])
        }
        return BackupData(groups: [g])
    }

    private func notes() -> BackupData {
        guard let db = database(domain: "AppDomainGroup-group.com.apple.notes", path: "NoteStore.sqlite") else { return BackupData() }
        let cols = db.columns("ZICCLOUDSYNCINGOBJECT")
        guard let title = ["ZTITLE1", "ZTITLE"].first(where: cols.contains) else { return BackupData() }
        let snippet = cols.contains("ZSNIPPET") ? "COALESCE(ZSNIPPET,'')" : "''"
        let modified = ["ZMODIFICATIONDATE1", "ZMODIFICATIONDATE"].first(where: cols.contains) ?? "0"
        let live = cols.contains("ZMARKEDFORDELETION") ? "AND COALESCE(n.ZMARKEDFORDELETION, 0) = 0" : ""
        // The whole text is in ZICNOTEDATA.ZDATA (compressed); some layouts point from the note to it, others back.
        let dataCols = db.columns("ZICNOTEDATA")
        let join = !dataCols.contains("ZDATA") ? "" : (cols.contains("ZNOTEDATA") ? "LEFT JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA"
            : (dataCols.contains("ZNOTE") ? "LEFT JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK" : ""))
        let preview = snippet.replacingOccurrences(of: "ZSNIPPET", with: "n.ZSNIPPET")
        let changed = modified == "0" ? "0" : "n." + modified
        var g = DataGroup(id: 0, title: "All Notes", columns: ["Title", "Text", "Last changed"])
        db.each("SELECT n.\(title), \(preview), \(changed), \(join.isEmpty ? "NULL" : "d.ZDATA") FROM ZICCLOUDSYNCINGOBJECT n \(join) WHERE n.\(title) IS NOT NULL \(live) ORDER BY 3 DESC") { s in
            let full = SQLiteFile.data(s, 3).flatMap(BackupReader.noteText)
            g.rows.append([SQLiteFile.text(s, 0), full ?? SQLiteFile.text(s, 1), BackupReader.date(sqlite3_column_double(s, 2))])
        }
        return BackupData(groups: [g])
    }

    /// Note text from ZICNOTEDATA.ZDATA: gzip-compressed protobuf, the text at NoteStoreProto.document(2).note(3).note_text(2).
    /// Locked notes stay unreadable (they are encrypted on the device) and fall back to the short preview.
    static func noteText(_ blob: Data) -> String? {
        guard let raw = inflate(blob), let doc = protoField(raw, 2), let note = protoField(doc, 3), let text = protoField(note, 2) else { return nil }
        return String(data: text, encoding: .utf8)
    }

    static func inflate(_ d: Data) -> Data? {
        let b = [UInt8](d)
        let body: Data
        if b.count > 18, b[0] == 0x1f, b[1] == 0x8b {   // gzip: skip the header's optional parts, drop the 8-byte trailer
            let flags = b[3]
            var o = 10
            if flags & 4 != 0, o + 2 <= b.count { o += 2 + (Int(b[o]) | Int(b[o + 1]) << 8) }
            if flags & 8 != 0 { while o < b.count, b[o] != 0 { o += 1 }; o += 1 }
            if flags & 16 != 0 { while o < b.count, b[o] != 0 { o += 1 }; o += 1 }
            if flags & 2 != 0 { o += 2 }
            guard o < b.count - 8 else { return nil }
            body = Data(b[o..<(b.count - 8)])
        } else if b.count > 6, b[0] == 0x78 {             // zlib
            body = Data(b[2..<(b.count - 4)])
        } else { return nil }
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }

    /// The first length-delimited field `number` in a protobuf message.
    static func protoField(_ d: Data, _ number: Int) -> Data? {
        let b = [UInt8](d)
        var o = 0
        func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while o < b.count {
                let x = b[o]; o += 1
                v |= UInt64(x & 0x7f) << shift
                if x & 0x80 == 0 { return v }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while o < b.count {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0: guard varint() != nil else { return nil }
            case 1: o += 8
            case 2:
                guard let len = varint(), len <= UInt64(b.count - o) else { return nil }
                if Int(key >> 3) == number { return Data(b[o..<(o + Int(len))]) }
                o += Int(len)
            case 5: o += 4
            default: return nil
            }
        }
        return nil
    }

    private func calendar() -> BackupData {
        guard let db = database(domain: "HomeDomain", path: "Library/Calendar/Calendar.sqlitedb") else { return BackupData() }
        var groups: [DataGroup] = []
        var index: [String: Int] = [:]
        db.each("""
            SELECT COALESCE(c.title,'Calendar'), COALESCE(i.summary,''), i.start_date, i.end_date, COALESCE(i.all_day, 0)
            FROM CalendarItem i LEFT JOIN Calendar c ON c.ROWID = i.calendar_id ORDER BY i.start_date DESC
            """) { s in
            let cal = SQLiteFile.text(s, 0)
            if index[cal] == nil {
                index[cal] = groups.count
                groups.append(DataGroup(id: groups.count, title: cal, columns: ["Event", "Starts", "Ends"]))
            }
            let allDay = sqlite3_column_int(s, 4) != 0
            let start = BackupReader.date(sqlite3_column_double(s, 2)), end = BackupReader.date(sqlite3_column_double(s, 3))
            groups[index[cal]!].rows.append([SQLiteFile.text(s, 1), allDay ? String(start.prefix(10)) : start, allDay ? "All day" : end])
        }
        return BackupData(groups: groups)
    }

    private func calls() -> BackupData {
        guard let db = database(domain: "HomeDomain", path: "Library/CallHistoryDB/CallHistory.storedata") else { return BackupData() }
        let names = contactNames()
        var g = DataGroup(id: 0, title: "All Calls", columns: ["Who", "Number", "Date", "Length", "Kind"])
        db.each("SELECT ZADDRESS, ZDATE, ZDURATION, ZORIGINATED, ZANSWERED FROM ZCALLRECORD ORDER BY ZDATE DESC") { s in
            let number = SQLiteFile.text(s, 0)
            let secs = Int(sqlite3_column_double(s, 2))
            let out = sqlite3_column_int(s, 3) != 0, answered = sqlite3_column_int(s, 4) != 0
            g.rows.append([names[BackupReader.key(number)] ?? "", number, BackupReader.date(sqlite3_column_double(s, 1)),
                           String(format: "%d:%02d", secs / 60, secs % 60), out ? "Outgoing" : (answered ? "Incoming" : "Missed")])
        }
        return BackupData(groups: [g])
    }

    private func safari() -> BackupData {
        var groups: [DataGroup] = []
        if let db = database(domain: "HomeDomain", path: "Library/Safari/Bookmarks.db") {
            var g = DataGroup(id: 0, title: "Bookmarks", columns: ["Title", "Address"])
            db.each("SELECT COALESCE(title,''), url FROM bookmarks WHERE url IS NOT NULL AND url != '' ORDER BY title COLLATE NOCASE") { s in
                g.rows.append([SQLiteFile.text(s, 0), SQLiteFile.text(s, 1)])
            }
            groups.append(g)
        }
        if let db = database(domain: "AppDomain-com.apple.mobilesafari", path: "Library/Safari/History.db") {
            var g = DataGroup(id: 1, title: "History", columns: ["Title", "Address", "Visited"])
            db.each("SELECT COALESCE(v.title,''), i.url, v.visit_time FROM history_visits v JOIN history_items i ON i.id = v.history_item ORDER BY v.visit_time DESC") { s in
                g.rows.append([SQLiteFile.text(s, 0), SQLiteFile.text(s, 1), BackupReader.date(sqlite3_column_double(s, 2))])
            }
            groups.append(g)
        }
        return BackupData(groups: groups.filter { !$0.rows.isEmpty })
    }

    /// Photos and videos in the camera roll part of the backup, by device folder (100APPLE…). Useful when the phone is gone.
    private func photos() -> BackupData {
        var groups: [DataGroup] = []
        var index: [String: Int] = [:]
        manifest.each("SELECT relativePath, fileID FROM Files WHERE domain = 'CameraRollDomain' AND flags = 1 AND relativePath LIKE 'Media/DCIM/%' ORDER BY relativePath") { s in
            let path = SQLiteFile.text(s, 0) as NSString
            let folder = (path.deletingLastPathComponent as NSString).lastPathComponent
            if index[folder] == nil {
                index[folder] = groups.count
                groups.append(DataGroup(id: groups.count, title: folder, subtitle: "Camera roll", columns: ["File", "Kind"]))
            }
            let ext = path.pathExtension.uppercased()
            let kind = ["MOV", "MP4", "M4V"].contains(ext) ? "Video" : (ext == "AAE" ? "Edit settings" : "Photo")
            groups[index[folder]!].rows.append([path.lastPathComponent, kind])
            groups[index[folder]!].fileIDs.append(SQLiteFile.text(s, 1))
        }
        return BackupData(groups: groups)
    }

    /// Voice Memos: the recordings list (newer iOS keeps it in the app's shared group, older iOS in Media) and the audio files.
    private func voiceMemos() -> BackupData {
        let places: [(domain: String, db: String, table: String, folder: String)] = [
            ("AppDomainGroup-group.com.apple.VoiceMemos.shared", "Recordings/CloudRecordings.db", "ZCLOUDRECORDING", "Recordings/"),
            ("MediaDomain", "Media/Recordings/Recordings.db", "ZRECORDING", "Media/Recordings/")]
        var g = DataGroup(id: 0, title: "All Recordings", columns: ["File", "Recorded", "Length"])
        var used = Set<String>()
        for p in places {
            guard let db = database(domain: p.domain, path: p.db) else { continue }
            let cols = db.columns(p.table)
            guard cols.contains("ZPATH") else { continue }
            let names = ["ZCUSTOMLABEL", "ZENCRYPTEDTITLE"].filter(cols.contains).map { "NULLIF(TRIM(\($0)), '')" }
            let title = names.isEmpty ? "NULL" : (names.count == 1 ? names[0] : "COALESCE(\(names.joined(separator: ", ")))")
            let when = cols.contains("ZDATE") ? "ZDATE" : "0", length = cols.contains("ZDURATION") ? "ZDURATION" : "0"
            db.each("SELECT \(title), ZPATH, \(when), \(length) FROM \(p.table) ORDER BY 3 DESC") { s in
                let stored = SQLiteFile.text(s, 1)
                let file = (stored as NSString).lastPathComponent
                guard !file.isEmpty, let id = fileID(domain: p.domain, path: p.folder + file) else { return }
                let ext = (file as NSString).pathExtension.isEmpty ? "m4a" : (file as NSString).pathExtension
                var label = SQLiteFile.text(s, 0)
                if label.isEmpty { label = (file as NSString).deletingPathExtension }
                var name = Pattern.safe(label) + "." + ext
                if used.contains(name.lowercased()) { name = Pattern.safe(label) + " " + String(id.prefix(6)) + "." + ext }
                used.insert(name.lowercased())
                let secs = Int(sqlite3_column_double(s, 3).rounded())
                g.rows.append([name, BackupReader.date(sqlite3_column_double(s, 2)), String(format: "%d:%02d", secs / 60, secs % 60)])
                g.fileIDs.append(id)
            }
        }
        return BackupData(groups: [g])
    }

    // MARK: Standard formats

    /// The contact list as a vCard 3.0 file, which Contacts, Outlook, Gmail and Android all import.
    func vCard() -> String? {
        guard let db = database(domain: "HomeDomain", path: "Library/AddressBook/AddressBook.sqlitedb") else { return nil }
        var phones: [Int64: [String]] = [:], mails: [Int64: [String]] = [:]
        db.each("SELECT record_id, property, value FROM ABMultiValue WHERE property IN (3, 4) AND value IS NOT NULL") { s in
            let id = sqlite3_column_int64(s, 0)
            if sqlite3_column_int(s, 1) == 3 { phones[id, default: []].append(SQLiteFile.text(s, 2)) } else { mails[id, default: []].append(SQLiteFile.text(s, 2)) }
        }
        var out = ""
        db.each("SELECT ROWID, COALESCE(First,''), COALESCE(Last,''), COALESCE(Organization,'') FROM ABPerson ORDER BY ROWID") { s in
            let id = sqlite3_column_int64(s, 0)
            let first = SQLiteFile.text(s, 1), last = SQLiteFile.text(s, 2), org = SQLiteFile.text(s, 3)
            let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            var card = ["BEGIN:VCARD", "VERSION:3.0", "N:\(BackupReader.vEsc(last));\(BackupReader.vEsc(first));;;", "FN:\(BackupReader.vEsc(full.isEmpty ? org : full))"]
            if !org.isEmpty { card.append("ORG:\(BackupReader.vEsc(org))") }
            card += (phones[id] ?? []).map { "TEL;TYPE=VOICE:\(BackupReader.vEsc($0))" }
            card += (mails[id] ?? []).map { "EMAIL;TYPE=INTERNET:\(BackupReader.vEsc($0))" }
            card.append("END:VCARD")
            out += card.map(BackupReader.fold).joined(separator: "\r\n") + "\r\n"
        }
        return out.isEmpty ? nil : out
    }

    /// The calendars as one iCalendar (.ics) file for Calendar, Outlook or Google Calendar.
    func iCalendar() -> String? {
        guard let db = database(domain: "HomeDomain", path: "Library/Calendar/Calendar.sqlitedb") else { return nil }
        let utc = DateFormatter(); utc.locale = Locale(identifier: "en_US_POSIX"); utc.timeZone = TimeZone(identifier: "UTC"); utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = TimeZone(identifier: "UTC"); day.dateFormat = "yyyyMMdd"
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//PortHop//Backup export//EN", "CALSCALE:GREGORIAN"]
        let stamp = utc.string(from: Date())
        let sql = "SELECT i.ROWID, COALESCE(i.summary,''), i.start_date, i.end_date, COALESCE(i.all_day, 0), COALESCE(c.title,'Calendar') "
            + "FROM CalendarItem i LEFT JOIN Calendar c ON c.ROWID = i.calendar_id ORDER BY i.start_date"
        db.each(sql) { s in
            let start = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(s, 2))
            let end = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(s, 3))
            let allDay = sqlite3_column_int(s, 4) != 0
            lines += ["BEGIN:VEVENT", "UID:porthop-\(sqlite3_column_int64(s, 0))@backup", "DTSTAMP:\(stamp)",
                      allDay ? "DTSTART;VALUE=DATE:\(day.string(from: start))" : "DTSTART:\(utc.string(from: start))",
                      allDay ? "DTEND;VALUE=DATE:\(day.string(from: max(end, start.addingTimeInterval(86_400))))" : "DTEND:\(utc.string(from: max(end, start)))",
                      "SUMMARY:\(BackupReader.vEsc(SQLiteFile.text(s, 1)))", "CATEGORIES:\(BackupReader.vEsc(SQLiteFile.text(s, 5)))", "END:VEVENT"]
        }
        guard lines.count > 4 else { return nil }
        lines.append("END:VCALENDAR")
        return lines.map(BackupReader.fold).joined(separator: "\r\n") + "\r\n"
    }

    static func vEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Long lines are folded at 75 bytes, as vCard and iCalendar require.
    static func fold(_ line: String) -> String {
        var out = "", width = 0
        for ch in line {
            let n = String(ch).utf8.count
            if width + n > 75 { out += "\r\n "; width = 1 }
            out.append(ch); width += n
        }
        return out
    }

    private func files() -> BackupData {
        var groups: [DataGroup] = []
        var index: [String: Int] = [:]
        manifest.each("SELECT domain, relativePath, fileID FROM Files WHERE flags = 1 ORDER BY domain, relativePath") { s in
            let domain = SQLiteFile.text(s, 0)
            if index[domain] == nil {
                index[domain] = groups.count
                groups.append(DataGroup(id: groups.count, title: BackupReader.friendly(domain), subtitle: domain, columns: ["File", "Folder"]))
            }
            let path = SQLiteFile.text(s, 1) as NSString
            groups[index[domain]!].rows.append([path.lastPathComponent, path.deletingLastPathComponent])
            groups[index[domain]!].fileIDs.append(SQLiteFile.text(s, 2))
        }
        return BackupData(groups: groups)
    }

    static func friendly(_ domain: String) -> String {
        for (prefix, label) in [("AppDomainGroup-", "Shared: "), ("AppDomainPlugin-", "Extension: "), ("AppDomain-", "App: "), ("SysContainerDomain-", "System: "),
                                ("SysSharedContainerDomain-", "System: ")] where domain.hasPrefix(prefix) {
            return label + domain.dropFirst(prefix.count)
        }
        return ["CameraRollDomain": "Camera Roll", "HomeDomain": "Home (Messages, Contacts, Settings)", "MediaDomain": "Media",
                "RootDomain": "System Root", "WirelessDomain": "Mobile Network", "KeychainDomain": "Keychain"][domain] ?? domain
    }

    /// Copies files out of the backup under their real names. Never overwrites. Returns the files written.
    func extract(_ group: DataGroup, rows: [Int], to folder: URL) -> [URL] {
        var written: [URL] = []
        var reserved = Set<String>()
        for r in rows where r < group.fileIDs.count {
            var name = group.rows[r][0].replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            if name.isEmpty || name == "." || name == ".." { name = group.fileIDs[r] }
            var dest = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) || reserved.contains(dest.path) { dest = Exporter.uniqueURL(for: dest, avoiding: reserved) }
            reserved.insert(dest.path)
            if let source = plain(group.fileIDs[r]), (try? FileManager.default.copyItem(at: source, to: dest)) != nil { written.append(dest) }
        }
        return written
    }

    /// A conversation as a web page anyone can open: a folder holding index.html and the attachments that are in the backup.
    /// Returns the page, or nil if nothing could be written. Never overwrites.
    func webPage(_ group: DataGroup, title kindTitle: String, into folder: URL) -> URL? {
        let fm = FileManager.default
        let safe = group.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let preferred = folder.appendingPathComponent("\(safe) (\(kindTitle))")
        let dir = fm.fileExists(atPath: preferred.path) ? Exporter.uniqueURL(for: preferred) : preferred
        let files = dir.appendingPathComponent("attachments", isDirectory: true)
        guard (try? fm.createDirectory(at: files, withIntermediateDirectories: true)) != nil else { return nil }
        func esc(_ t: String) -> String {
            t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\n", with: "<br>")
        }
        var used = Set<String>(), body = ""
        for (r, row) in group.rows.enumerated() {
            let mine = row[1] == "Me"
            var extras = ""
            for ref in group.media[r] ?? [] {
                guard let id = fileID(domain: ref.domain, path: ref.path), let src = plain(id) else { extras += "<div class=\"missing\">Attachment not in this backup: \(esc(ref.name))</div>"; continue }
                var name = ref.name, n = 2
                while used.contains(name.lowercased()) { name = "\((ref.name as NSString).deletingPathExtension) (\(n)).\((ref.name as NSString).pathExtension)"; n += 1 }
                used.insert(name.lowercased())
                guard (try? fm.copyItem(at: src, to: files.appendingPathComponent(name))) != nil else { continue }
                let link = "attachments/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
                switch (name as NSString).pathExtension.lowercased() {
                case "jpg", "jpeg", "png", "gif", "heic", "webp": extras += "<a href=\"\(link)\"><img src=\"\(link)\" alt=\"\(esc(name))\"></a>"
                case "mov", "mp4", "m4v": extras += "<video controls src=\"\(link)\"></video>"
                default: extras += "<a class=\"file\" href=\"\(link)\">\(esc(name))</a>"
                }
            }
            let text = (row[2].hasPrefix("(") && row[2].hasSuffix(")") && !extras.isEmpty) ? "" : esc(row[2])
            body += "<div class=\"msg\(mine ? " me" : "")\"><div class=\"meta\">\(esc(row[1])) · \(esc(row[0]))</div>\(text.isEmpty ? "" : "<div class=\"text\">\(text)</div>")\(extras)</div>\n"
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>\(esc(group.title))</title>
        <style>
        :root { color-scheme: light dark; --me: #0a84ff; --them: #e9e9eb; --themText: #000; }
        @media (prefers-color-scheme: dark) { :root { --them: #2c2c2e; --themText: #fff; } }
        body { font: 15px/1.4 -apple-system, "Segoe UI", Roboto, sans-serif; max-width: 760px; margin: 0 auto; padding: 24px 16px; }
        h1 { font-size: 22px; margin: 0 0 4px; } .sub { opacity: .6; margin-bottom: 20px; }
        .msg { max-width: 75%; margin: 8px 0; } .msg.me { margin-left: auto; text-align: right; }
        .meta { font-size: 12px; opacity: .55; margin: 0 8px 2px; }
        .text { display: inline-block; text-align: left; padding: 8px 12px; border-radius: 18px; background: var(--them); color: var(--themText); white-space: normal; overflow-wrap: anywhere; }
        .me .text { background: var(--me); color: #fff; }
        img, video { display: block; max-width: 320px; max-height: 320px; border-radius: 14px; margin: 4px 0 0 auto; } .msg:not(.me) img, .msg:not(.me) video { margin-left: 0; }
        .file, .missing { display: inline-block; padding: 6px 10px; border-radius: 10px; background: var(--them); color: var(--themText); margin-top: 4px; font-size: 13px; }
        .missing { opacity: .6; }
        </style></head><body>
        <h1>\(esc(group.title))</h1><div class="sub">\(esc(kindTitle)) · \(group.rows.count) messages · saved by PortHop from a device backup</div>
        \(body)</body></html>
        """
        let page = dir.appendingPathComponent("index.html")
        guard (try? html.write(to: page, atomically: true, encoding: .utf8)) != nil else { return nil }
        if (try? fm.contentsOfDirectory(atPath: files.path))?.isEmpty == true { try? fm.removeItem(at: files) }
        return page
    }

    static func csv(_ group: DataGroup) -> String {
        func cell(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return ([group.columns] + group.rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
