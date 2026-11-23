import Foundation
import SwiftUI

// Ask PortHop: turns a typed request ("hidden videos from 2025 over 1 MB to T7") into where to go and what to filter.
// It only needs the small AskContext below, so the engine tests can run it without the app's interface.

/// A place copies can go: the Pictures folder, an external drive, or a folder used before.
struct Destination: Identifiable, Equatable {
    enum Kind { case pictures, drive, recent }
    let id: String
    let kind: Kind
    let name: String
    let detail: String
    let url: URL
    var free: Int64? = nil
    var readOnly = false
    var isFAT = false
    var symbol: String {
        switch kind {
        case .pictures: return "photo.on.rectangle.angled"
        case .drive: return "externaldrive.fill"
        case .recent: return "folder.fill"
        }
    }
}

/// What the parser needs to know about the connected device and the places copies can go.
struct AskContext {
    var isAndroid = false
    /// Every group on the device (smart groups and the person's own albums), for naming the result.
    var albums: [(id: String, title: String)] = []
    /// The person's own albums, matched by name in the request.
    var userAlbums: [(id: String, title: String)] = []
    /// People named in Photos ("photos of Mum"), matched as whole words.
    var people: [(id: String, title: String)] = []
    var destinations: [Destination] = []
}

struct AskIntent {
    var route: String?
    var album: String?
    var filter: MediaFilter?
    var range: ClosedRange<Date>?
    var minBytes: Int64 = 0
    var destination: Destination?
    var parts: [String] = []
    var isEmpty: Bool { route == nil && album == nil && filter == nil && range == nil && minBytes == 0 && destination == nil }
}

enum AskParser {
    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    static func parse(_ raw: String, _ c: AskContext) -> AskIntent {
        var i = AskIntent()
        let text = " " + raw.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }

        // Where it should go: "to T7", "into pictures".
        var body = text
        if let r = text.range(of: " (to|into|onto) ", options: [.regularExpression, .backwards]) {
            let target = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
            let options = c.destinations
            let hit = options.first { $0.name.lowercased() == target }
                ?? options.first { !target.isEmpty && ($0.name.lowercased().contains(target) || target.contains($0.name.lowercased())) }
                ?? (["mac", "this mac", "my mac", "pictures", "computer"].contains(target) ? options.first { $0.kind == .pictures } : nil)
            if let hit, !hit.readOnly {
                i.destination = hit
                body = String(text[..<r.lowerBound]) + " "
            }
        }
        func says(_ words: String...) -> Bool { words.contains { body.contains($0) } }

        // Things that are places in the app rather than photos.
        let routes: [(String, [String])] = [
            ("bk:whatsapp", ["whatsapp"]), ("bk:messages", ["message", "imessage", " sms", "texts"]), ("bk:contacts", ["contact"]),
            ("bk:notes", [" note"]), ("bk:calendar", ["calendar", "event"]), ("bk:calls", ["call log", "calls", "call history"]),
            ("bk:safari", ["safari", "bookmark", "browsing"]), ("bk:voiceMemos", ["voice memo", "recording"]), ("nav_backup", ["back up", "backup", "restore"]),
            ("nav_device", ["battery", "health", "storage", "serial", "imei", "details"]), ("nav_files", ["files", "apps", "documents"])]

        // Which group of photos.
        let albumWords: [(String, [String])] = [
            ("smart_hidden", ["hidden"]), ("smart_screenshots", ["screenshot"]), ("smart_favorites", ["favorite", "favourite"]),
            ("smart_selfies", ["selfie"]), ("smart_live", ["live photo"]), ("smart_trashed", ["deleted", "trash"]),
            ("smart_all", ["everything", "all photos", "library", "all my"])]
        // A person comes first ("favourite videos of Mum"); smart words then narrow it down where they can.
        if !c.isAndroid, let p = c.people.first(where: { $0.title.count >= 2 && mentions(body, $0.title.lowercased()) }) {
            i.album = p.id
            if says("favorite", "favourite") { i.filter = .favorites }
            else if says("screenshot") { i.filter = .screenshots }
            else if says("live photo") { i.filter = .live }
        }
        if !c.isAndroid && i.album == nil {
            for (id, words) in albumWords where words.contains(where: { body.contains($0) }) { i.album = id; break }
            if i.album == nil, let a = c.userAlbums.first(where: { $0.title.count >= 3 && body.contains($0.title.lowercased()) }) { i.album = a.id }
        }
        if says("video", "movie", "clip") { if i.album == nil { i.album = "smart_videos" } else { i.filter = .videos } }
        if says("photo", "picture", "pic ") && !says("live photo") && i.album != nil { i.filter = i.filter ?? .photos }
        if says("heic") { i.filter = .heic }

        // When: "2024", "march 2025", "2023 to 2024", "last year", "this month".
        let cal = Calendar.current
        let now = Date()
        func year(_ y: Int) -> ClosedRange<Date>? {
            guard let s = cal.date(from: DateComponents(year: y, month: 1, day: 1)), let e = cal.date(from: DateComponents(year: y + 1, month: 1, day: 1)) else { return nil }
            return s...e.addingTimeInterval(-1)
        }
        func month(_ y: Int, _ mo: Int) -> ClosedRange<Date>? {
            guard let s = cal.date(from: DateComponents(year: y, month: mo, day: 1)), let e = cal.date(byAdding: .month, value: 1, to: s) else { return nil }
            return s...e.addingTimeInterval(-1)
        }
        let years = matches(#"\b(19|20)\d{2}\b"#, in: body).compactMap(Int.init)
        let thisYear = cal.component(.year, from: now)
        if let mi = months.firstIndex(where: { body.contains(" " + $0) || body.contains(" " + $0.prefix(3) + " ") }) {
            var y = years.first ?? thisYear
            if years.isEmpty, mi + 1 > cal.component(.month, from: now) { y -= 1 }
            i.range = month(y, mi + 1)
        } else if years.count >= 2, let a = year(min(years[0], years[1])), let b = year(max(years[0], years[1])) {
            i.range = a.lowerBound...b.upperBound
        } else if let y = years.first {
            i.range = year(y)
        } else if says("last year") {
            i.range = year(thisYear - 1)
        } else if says("this year") {
            i.range = year(thisYear)
        } else if says("last month"), let d = cal.date(byAdding: .month, value: -1, to: now) {
            i.range = month(cal.component(.year, from: d), cal.component(.month, from: d))
        } else if says("this month") {
            i.range = month(thisYear, cal.component(.month, from: now))
        }

        // How big: "over 100 MB", "bigger than 1 GB".
        if let s = firstGroups(#"(?:over|above|bigger than|larger than|more than|at least|>)\s*(\d+(?:\.\d+)?)\s*(kb|mb|gb)"#, in: body),
           let n = Double(s[0]) {
            let unit: Double = s[1] == "gb" ? 1_000_000_000 : (s[1] == "mb" ? 1_000_000 : 1_000)
            i.minBytes = Int64(n * unit)
        }

        let photoRequest = i.album != nil || i.filter != nil || i.range != nil || i.minBytes > 0
        if !photoRequest, let r = routes.first(where: { $0.1.contains(where: { body.contains($0) }) }) {
            if r.0.hasPrefix("bk:") || r.0 == "nav_backup" { if !c.isAndroid { i.route = r.0 } } else { i.route = r.0 }
        }
        if photoRequest && i.album == nil && !c.isAndroid { i.album = "smart_all" }

        // What was understood, in plain words.
        if let r = i.route { i.parts.append(routeName(r, c)) }
        if let a = i.album { i.parts.append(c.albums.first { $0.id == a }?.title ?? "Library") }
        if let f = i.filter { i.parts.append(f.rawValue) }
        if let r = i.range { i.parts.append(rangeText(r)) }
        if i.minBytes > 0 { i.parts.append("over \(Fmt.bytes(i.minBytes))") }
        if let d = i.destination { i.parts.append("to \(d.name)") }
        return i
    }

    static func rangeText(_ r: ClosedRange<Date>) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        let a = f.string(from: r.lowerBound), b = f.string(from: r.upperBound)
        return a == b ? a : "\(a) – \(b)"
    }

    private static func routeName(_ r: String, _ c: AskContext) -> String {
        switch r {
        case "nav_backup": return "Backups"
        case "nav_device": return "Device details"
        case "nav_files": return c.isAndroid ? "Phone Storage" : "Media Files"
        default: return BackupKind(rawValue: String(r.dropFirst(3)))?.title ?? r
        }
    }

    /// The name as a whole word: "mum" is in "photos of mum" but not in "mumbai".
    private static func mentions(_ body: String, _ name: String) -> Bool {
        body.range(of: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])", options: .regularExpression) != nil
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    private static func firstGroups(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }

}
