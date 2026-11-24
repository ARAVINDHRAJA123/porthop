import Foundation
import SQLite3

/// Checks a phone against published spyware indicators: the STIX2 files that Amnesty International, Citizen Lab and others
/// publish (the format of Amnesty's Mobile Verification Toolkit). An iPhone is checked through its newest backup, an
/// Android phone live over USB. A match is a reason to ask an expert, not proof; no match is not a guarantee.
enum Spyware {
    enum Kind: String, CaseIterable { case domain, url, process, email, fileName, filePath, appID, profile }

    struct Indicator: Hashable {
        let kind: Kind
        let value: String
        let malware: String
        let source: String
    }

    struct Finding: Hashable {
        let area: String
        let found: String
        let indicator: Indicator
        let when: String
    }

    struct Review: Hashable {
        let title: String
        let detail: String
        let apps: [String]
    }

    struct Report {
        var findings: [Finding] = []
        var checked: [String] = []
        var missing: [String] = []
        var review: [Review] = []
        var warnings: [String] = []
        var indicatorCount = 0
        var date = Date()
    }

    /// Indicators by kind, then by lowercased value.
    struct Indicators {
        private(set) var table: [Kind: [String: [Indicator]]] = [:]
        private(set) var count = 0
        var isEmpty: Bool { count == 0 }

        mutating func add(_ i: Indicator) {
            let key = Indicators.normal(i.kind, i.value)
            guard !key.isEmpty else { return }
            if table[i.kind, default: [:]][key]?.contains(where: { $0.malware == i.malware }) == true { return }
            table[i.kind, default: [:]][key, default: []].append(i)
            count += 1
        }

        static func normal(_ kind: Kind, _ value: String) -> String {
            var v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if kind == .domain, v.hasPrefix("www.") { v = String(v.dropFirst(4)) }
            if kind == .filePath, v.count > 1, v.hasSuffix("/") { v = String(v.dropLast()) }
            if kind == .domain { v = v.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            return v
        }

        func lookup(_ kind: Kind, _ value: String) -> [Indicator] { table[kind]?[Indicators.normal(kind, value)] ?? [] }

        /// A host matches an indicator domain when it is that domain or one of its subdomains.
        func domainHits(_ host: String) -> [Indicator] {
            guard let domains = table[.domain] else { return [] }
            var labels = Indicators.normal(.domain, host).split(separator: ".")
            var out: [Indicator] = []
            while labels.count >= 2 {
                if let hit = domains[labels.joined(separator: ".")] { out += hit }
                labels.removeFirst()
            }
            return out
        }

        /// Device usage logs cut process names to 15 or 16 characters, so a cut name matches the longer indicator.
        func processHits(_ name: String) -> [Indicator] {
            let n = Indicators.normal(.process, name)
            guard !n.isEmpty, let all = table[.process] else { return [] }
            if let exact = all[n] { return exact }
            guard n.count == 15 || n.count == 16 else { return [] }
            return all.filter { $0.key.hasPrefix(n) }.flatMap(\.value)
        }

        /// Addresses and web links in a piece of text (a message, say) that point at an indicator domain or link.
        /// One pass over the words, so a very long message takes no longer than its length.
        func textHits(_ text: String) -> [(String, Indicator)] {
            guard !text.isEmpty else { return [] }
            var out: [(String, Indicator)] = []
            if table[.domain] != nil, text.contains(".") {
                for word in text.split(whereSeparator: { $0.isWhitespace || "\"'<>()[]{}|\\^`,;".contains($0) }) where word.contains(".") {
                    let token = word.trimmingCharacters(in: CharacterSet(charactersIn: ".:!?*"))
                    guard let host = Indicators.host(of: token) else { continue }
                    for i in domainHits(host) { out.append((token, i)) }
                }
            }
            if let urls = table[.url], !urls.isEmpty {
                let lower = text.lowercased()
                for (value, list) in urls where lower.contains(value) { for i in list { out.append((value, i)) } }
            }
            return out
        }

        /// The host in "https://user@host.example:8080/path", "host.example/path" or "host.example"; nil when it isn't one.
        static func host(of token: String) -> String? {
            var s = Substring(token.lowercased())
            if let r = s.range(of: "://") { s = s[r.upperBound...] }
            if let end = s.firstIndex(where: { "/?#".contains($0) }) { s = s[..<end] }
            if let at = s.lastIndex(of: "@") { s = s[s.index(after: at)...] }
            if let colon = s.firstIndex(of: ":") { s = s[..<colon] }
            let labels = s.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter),
                  labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else { return nil }
            return String(s)
        }
    }

    // MARK: Reading indicator files

    /// Reads one STIX2 file. Each indicator is credited to the spyware it "indicates" (or the file's only family).
    static func parseSTIX(_ data: Data, source: String) -> [Indicator] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objects = root["objects"] as? [[String: Any]] else { return [] }
        var families: [String: String] = [:], indicates: [String: String] = [:]
        for o in objects {
            if o["type"] as? String == "malware", let id = o["id"] as? String { families[id] = (o["name"] as? String) ?? source }
            if o["type"] as? String == "relationship", o["relationship_type"] as? String == "indicates",
               let from = o["source_ref"] as? String, let to = o["target_ref"] as? String { indicates[from] = to }
        }
        let only = families.count == 1 ? families.values.first : nil
        var out: [Indicator] = []
        for o in objects where o["type"] as? String == "indicator" {
            guard let pattern = o["pattern"] as? String, let (kind, value) = parsePattern(pattern) else { continue }
            let id = o["id"] as? String ?? ""
            let family = indicates[id].flatMap { families[$0] } ?? only ?? source
            out.append(Indicator(kind: kind, value: value, malware: family, source: source))
        }
        return out
    }

    static func parsePattern(_ pattern: String) -> (Kind, String)? {
        let body = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "[] \n"))
        guard let eq = body.firstIndex(of: "=") else { return nil }
        let key = body[..<eq].trimmingCharacters(in: .whitespaces)
        let value = body[body.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        let kinds: [String: Kind] = ["domain-name:value": .domain, "url:value": .url, "process:name": .process, "email-addr:value": .email,
                                     "file:name": .fileName, "file:path": .filePath, "app:id": .appID, "configuration-profile:id": .profile]
        guard let kind = kinds[key], !value.isEmpty else { return nil }
        return (kind, value)
    }

    struct Source: Codable, Hashable {
        var name: String
        var url: String
        var file: String
        var count = 0
        var updated: Date? = nil
    }

    /// The index of public indicator files that the Mobile Verification Toolkit project keeps.
    static let indexURL = URL(string: "https://raw.githubusercontent.com/mvt-project/mvt-indicators/main/indicators.yaml")!

    /// Reads the index (a small YAML list). Only the fields PortHop needs are read: a name and where the file lives.
    static func parseIndex(_ yaml: String) -> [Source] {
        var out: [Source] = []
        var fields: [String: String] = [:]
        func flush() {
            defer { fields = [:] }
            guard let name = fields["name"] else { return }
            var url = fields["download_url"]
            if url == nil, let owner = fields["owner"], let repo = fields["repo"], let path = fields["path"] {
                url = "https://raw.githubusercontent.com/\(owner)/\(repo)/\(fields["branch"] ?? "main")/\(path)"
            }
            guard let url, url.hasPrefix("https://") else { return }
            out.append(Source(name: name, url: url, file: slug(name) + ".stix2"))
        }
        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            // A new entry starts at a top-level "-"; deeper "- " lines are items of a list inside the entry.
            if line.hasPrefix("-"), raw.prefix(while: { $0 == " " }).count <= 2 {
                flush()
                line = line.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            if !value.isEmpty, ["name", "owner", "repo", "branch", "path", "download_url"].contains(key), fields[key] == nil { fields[key] = value }
        }
        flush()
        return out
    }

    static func slug(_ s: String) -> String {
        let kept = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(kept).split(separator: "-").joined(separator: "-")
    }

    static var folder: URL {
        if let d = ProcessInfo.processInfo.environment["PORTHOP_INDICATORS_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/PortHop/Indicators", isDirectory: true)
    }

    static func sources(in folder: URL) -> [Source] {
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("sources.json")) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Source].self, from: d)) ?? []
    }

    static func save(_ list: [Source], in folder: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(list).write(to: folder.appendingPathComponent("sources.json"), options: .atomic)
    }

    static func load(from folder: URL) -> Indicators {
        var set = Indicators()
        for s in sources(in: folder) {
            guard let d = try? Data(contentsOf: folder.appendingPathComponent(s.file)) else { continue }
            for i in parseSTIX(d, source: s.name) { set.add(i) }
        }
        return set
    }

    /// Downloads the current public indicator files. Returns nil when they were saved, or what went wrong.
    static func download(to folder: URL, index: URL = indexURL) async -> String? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func get(_ url: URL) async -> Data? {
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue("PortHop", forHTTPHeaderField: "User-Agent")
            guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return d
        }
        guard let d = await get(index), let text = String(data: d, encoding: .utf8) else {
            return "The list of indicator files could not be downloaded. Check the internet connection and try again."
        }
        let wanted = parseIndex(text)
        guard !wanted.isEmpty else { return "The list of indicator files was empty or in an unexpected format." }
        let fetched: [(Source, Data?)] = await withTaskGroup(of: (Source, Data?).self) { group in
            for s in wanted {
                group.addTask {
                    guard let u = URL(string: s.url) else { return (s, nil) }
                    return (s, await get(u))
                }
            }
            var all: [(Source, Data?)] = []
            for await r in group { all.append(r) }
            return all
        }
        let kept = sources(in: folder).filter { $0.url.hasPrefix("file:") }   // files the user added stay
        var saved: [Source] = []
        for (var s, data) in fetched {
            guard let data else { continue }
            let n = parseSTIX(data, source: s.name).count
            guard n > 0, (try? data.write(to: folder.appendingPathComponent(s.file), options: .atomic)) != nil else { continue }
            s.count = n
            s.updated = Date()
            saved.append(s)
        }
        guard !saved.isEmpty else { return "None of the indicator files could be downloaded. Try again later." }
        save((saved.sorted { $0.name < $1.name }) + kept, in: folder)
        let missed = wanted.count - saved.count
        return missed > 0 ? "\(saved.count) of \(wanted.count) indicator files were downloaded; the others were not available." : nil
    }

    /// Adds an indicator file the user chose (one an investigator sent, say). Returns nil when it was added.
    static func add(file url: URL, to folder: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return "The file could not be read." }
        let name = url.deletingPathExtension().lastPathComponent
        let n = parseSTIX(d, source: name).count
        guard n > 0 else { return "This is not an indicator file PortHop can read (STIX2, as used by the Mobile Verification Toolkit)." }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = "custom-" + slug(name) + ".stix2"
        guard (try? d.write(to: folder.appendingPathComponent(file), options: .atomic)) != nil else { return "The file could not be saved." }
        var list = sources(in: folder).filter { $0.file != file }
        list.append(Source(name: name, url: url.absoluteString, file: file, count: n, updated: Date()))
        save(list, in: folder)
        return nil
    }

    // MARK: Checking an iPhone backup

    static func scan(backup r: BackupReader, with set: Indicators) -> Report {
        var report = Report(indicatorCount: set.count)
        func found(_ area: String, _ value: String, _ hits: [Indicator], _ when: String = "") {
            for i in hits { report.findings.append(Finding(area: area, found: value, indicator: i, when: when)) }
        }
        func area(_ name: String, _ present: Bool) { if present { report.checked.append(name) } else { report.missing.append(name) } }

        var history = false
        for (domain, path) in [("AppDomain-com.apple.mobilesafari", "Library/Safari/History.db"), ("HomeDomain", "Library/Safari/History.db")] {
            guard let db = r.database(domain: domain, path: path) else { continue }
            history = true
            db.each("SELECT i.url, COALESCE(MAX(v.visit_time), 0) FROM history_items i LEFT JOIN history_visits v ON v.history_item = i.id GROUP BY i.id") { s in
                let url = SQLiteFile.text(s, 0)
                for (what, i) in set.textHits(url) { found("Safari history", what, [i], BackupReader.date(sqlite3_column_double(s, 1))) }
            }
        }
        area("Safari history", history)

        var tabs = false
        if let db = r.database(domain: "AppDomain-com.apple.mobilesafari", path: "Library/Safari/SafariTabs.db") {
            tabs = true
            db.each("SELECT url FROM bookmarks WHERE url IS NOT NULL") { s in for (w, i) in set.textHits(SQLiteFile.text(s, 0)) { found("Safari tabs", w, [i]) } }
        }
        for domain in ["AppDomain-com.apple.mobilesafari", "HomeDomain"] {
            guard let db = r.database(domain: domain, path: "Library/Safari/BrowserState.db") else { continue }
            tabs = true
            db.each("SELECT url FROM tabs") { s in for (w, i) in set.textHits(SQLiteFile.text(s, 0)) { found("Safari tabs", w, [i]) } }
        }
        area("Safari tabs", tabs)

        if let db = r.database(domain: "HomeDomain", path: "Library/Safari/Bookmarks.db") {
            area("Safari bookmarks", true)
            db.each("SELECT url FROM bookmarks WHERE url IS NOT NULL") { s in for (w, i) in set.textHits(SQLiteFile.text(s, 0)) { found("Safari bookmarks", w, [i]) } }
        } else { area("Safari bookmarks", false) }

        if let db = r.database(domain: "HomeDomain", path: "Library/SMS/sms.db") {
            area("Messages", true)
            let archive = db.columns("message").contains("attributedBody") ? "m.attributedBody" : "NULL"
            db.each("SELECT m.text, \(archive), m.date, COALESCE(h.id,'') FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id") { s in
                var body = SQLiteFile.text(s, 0)
                if body.isEmpty, let blob = SQLiteFile.data(s, 1) { body = BackupReader.text(fromArchive: blob) ?? "" }
                let when = BackupReader.date(sqlite3_column_double(s, 2))
                for (w, i) in set.textHits(body) { found("Messages", w, [i], when) }
                let sender = SQLiteFile.text(s, 3)
                if sender.contains("@") { found("Messages (sender)", sender, set.lookup(.email, sender), when) }
            }
        } else { area("Messages", false) }

        if let db = r.database(domain: "AppDomainGroup-group.net.whatsapp.WhatsApp.shared", path: "ChatStorage.sqlite") {
            area("WhatsApp", true)
            db.each("SELECT COALESCE(ZTEXT,''), COALESCE(ZMESSAGEDATE,0) FROM ZWAMESSAGE WHERE ZTEXT IS NOT NULL") { s in
                for (w, i) in set.textHits(SQLiteFile.text(s, 0)) { found("WhatsApp", w, [i], BackupReader.date(sqlite3_column_double(s, 1))) }
            }
        } else { area("WhatsApp", false) }

        // Websites that apps' built-in browsers loaded, and the list of every file in the backup.
        var webData: [(String, String)] = [], apps = Set<String>(), profiles: [(String, String)] = []
        r.eachFile { domain, path in
            if path.hasSuffix("ResourceLoadStatistics/observations.db") { webData.append((domain, path)) }
            if domain == "SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles" { profiles.append((domain, path)) }
            for prefix in ["AppDomain-", "AppDomainPlugin-"] where domain.hasPrefix(prefix) { apps.insert(String(domain.dropFirst(prefix.count))) }
            let name = (path as NSString).lastPathComponent
            found("Backup files", "\(domain) › \(path)", set.lookup(.fileName, name))
            if let root = domainRoot(domain) {
                let full = (root + "/" + path).lowercased()
                for (value, list) in set.table[.filePath] ?? [:] where full == value || full.hasPrefix(value + "/") { found("Backup files", root + "/" + path, list) }
            }
        }
        area("Backup files", true)
        for (domain, path) in webData {
            guard let db = r.database(domain: domain, path: path) else { continue }
            db.each("SELECT registrableDomain, COALESCE(mostRecentUserInteractionTime, 0) FROM ObservedDomains") { s in
                let host = SQLiteFile.text(s, 0), t = sqlite3_column_double(s, 1)
                found("Websites apps loaded", host, set.domainHits(host), t > 0 ? BackupReader.date(t - BackupReader.appleEpoch) : "")
            }
        }
        area("Websites apps loaded", !webData.isEmpty)

        if let db = r.database(domain: "WirelessDomain", path: "Library/Databases/DataUsage.sqlite") {
            area("App network use", true)
            db.each("SELECT COALESCE(ZPROCNAME,''), COALESCE(ZBUNDLENAME,''), COALESCE(ZTIMESTAMP, ZFIRSTTIMESTAMP, 0) FROM ZPROCESS") { s in
                let process = SQLiteFile.text(s, 0), bundle = SQLiteFile.text(s, 1), when = BackupReader.date(sqlite3_column_double(s, 2))
                found("App network use", process, set.processHits(process), when)
                if !bundle.isEmpty { found("App network use", bundle, set.lookup(.appID, bundle), when) }
            }
        } else { area("App network use", false) }

        if let d = r.contents(domain: "HomeDomain", path: "Library/Preferences/com.apple.osanalytics.addaily.plist"),
           let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] {
            area("Daily usage statistics", true)
            for name in ((p["netUsageBaseline"] as? [String: Any]) ?? [:]).keys { found("Daily usage statistics", name, set.processHits(name)) }
        } else { area("Daily usage statistics", false) }

        if let d = r.contents(domain: "HomeDomain", path: "Library/Preferences/com.apple.identityservices.idstatuscache.plist"),
           let p = try? PropertyListSerialization.propertyList(from: d, format: nil) {
            area("iMessage and FaceTime lookups", true)
            var handles = Set<String>()
            func walk(_ v: Any) {
                if let dict = v as? [String: Any] {
                    for (k, sub) in dict { if k.lowercased().hasPrefix("mailto:") { handles.insert(String(k.dropFirst(7))) }; walk(sub) }
                } else if let list = v as? [Any] { list.forEach(walk) }
            }
            walk(p)
            for h in handles.sorted() { found("iMessage and FaceTime lookups", h, set.lookup(.email, h)) }
        } else { area("iMessage and FaceTime lookups", false) }

        if let d = try? Data(contentsOf: r.folder.appendingPathComponent("Info.plist")),
           let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] {
            for id in (p["Installed Applications"] as? [String]) ?? [] { apps.insert(id) }
            for id in ((p["Applications"] as? [String: Any]) ?? [:]).keys { apps.insert(id) }
        }
        for id in apps.sorted() { found("Installed apps", id, set.lookup(.appID, id)) }
        area("Installed apps", !apps.isEmpty)

        if !profiles.isEmpty, let ids = set.table[.profile], !ids.isEmpty {
            for (domain, path) in profiles {
                guard let d = r.contents(domain: domain, path: path) else { continue }
                let text = String(decoding: d, as: UTF8.self).lowercased()
                for (value, list) in ids where text.contains(value) { found("Configuration profiles", (path as NSString).lastPathComponent, list) }
            }
        }
        area("Configuration profiles", !profiles.isEmpty)
        report.findings = unique(report.findings)
        return report
    }

    /// Where a backup domain lives on the iPhone, for matching full file paths.
    static func domainRoot(_ domain: String) -> String? {
        let roots = ["HomeDomain": "/private/var/mobile", "MediaDomain": "/private/var/mobile", "CameraRollDomain": "/private/var/mobile",
                     "RootDomain": "/private/var/root", "WirelessDomain": "/private/var/wireless", "SystemPreferencesDomain": "/private/var/preferences",
                     "DatabaseDomain": "/private/var/db", "ManagedPreferencesDomain": "/private/var/Managed Preferences",
                     "KeychainDomain": "/private/var/Keychains", "NetworkDomain": "/private/var/networkd", "ProtectedDomain": "/private/var/protected",
                     "InstallDomain": "/private/var/installd", "MobileDeviceDomain": "/private/var/MobileDevice", "KeyboardDomain": "/private/var/mobile",
                     "TonesDomain": "/private/var/mobile", "HealthDomain": "/private/var/mobile/Library"]
        return roots[domain]
    }

    static func unique(_ list: [Finding]) -> [Finding] {
        var seen = Set<String>()
        return list.filter { seen.insert("\($0.area)|\($0.found.lowercased())|\($0.indicator.value)|\($0.indicator.malware)").inserted }
    }

    // MARK: Checking an Android phone

    static func scan(android device: Device, tools: Tools, with set: Indicators) -> Report {
        var report = Report(indicatorCount: set.count)
        func sh(_ c: String) -> String? { Android.shell(c, device: device, tools: tools, timeout: 60) }
        func packages(_ text: String?) -> [String] {
            (text ?? "").split(whereSeparator: \.isNewline).compactMap { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("package:") ? String(t.dropFirst(8)).components(separatedBy: " ").first : nil
            }
        }
        let installed = packages(sh("pm list packages"))
        if installed.isEmpty { report.missing.append("Installed apps") } else { report.checked.append("Installed apps") }
        for p in installed { for i in set.lookup(.appID, p) { report.findings.append(Finding(area: "Installed apps", found: p, indicator: i, when: "")) } }

        let ps = sh("ps -A -o NAME") ?? sh("ps -A") ?? ""
        var running = Set<String>()
        for line in ps.split(whereSeparator: \.isNewline) {
            guard let name = line.split(separator: " ", omittingEmptySubsequences: true).last.map(String.init), name != "NAME" else { continue }
            running.insert(name)
        }
        if running.isEmpty { report.missing.append("Running programs") } else { report.checked.append("Running programs") }
        for name in running.sorted() {
            let app = name.components(separatedBy: ":").first ?? name
            for i in set.processHits(name) + set.lookup(.appID, app) where !installed.contains(app) || i.kind == .process {
                report.findings.append(Finding(area: "Running programs", found: name, indicator: i, when: "now"))
            }
        }

        let isUserApp = Set(packages(sh("pm list packages -3")))
        func components(_ text: String?) -> [String] {
            let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t != "null" else { return [] }
            return Array(Set(t.split(separator: ":").compactMap { $0.split(separator: "/").first.map(String.init) })).sorted()
        }
        let access = components(sh("settings get secure enabled_accessibility_services"))
        let notifications = components(sh("settings get secure enabled_notification_listeners"))
        let admins: [String] = {
            let text = sh("dumpsys device_policy") ?? ""
            let re = try! NSRegularExpression(pattern: #"ComponentInfo\{([^/}]+)/"#)
            let ns = text as NSString
            return Array(Set(re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })).sorted()
        }()
        let installers = packages(sh("appops query-op REQUEST_INSTALL_PACKAGES allow").map { $0.split(whereSeparator: \.isNewline).map { "package:" + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n") })
        report.checked.append("Apps with special access")
        let groups: [(String, String, [String])] = [
            ("Can read the screen and act for you", "Accessibility access. Stalkerware almost always asks for this.", access),
            ("Can read every notification", "Notification access shows message previews and codes as they arrive.", notifications),
            ("Device administrators", "These apps can lock the phone or stop themselves being removed.", admins),
            ("Can install other apps", "Allowed to install apps from outside the Play Store.", installers.filter { isUserApp.contains($0) }),
        ]
        for (title, detail, apps) in groups where !apps.isEmpty { report.review.append(Review(title: title, detail: detail, apps: apps)) }
        if sh("settings get global package_verifier_enable")?.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
            report.warnings.append("Google Play Protect scanning is turned off. Turn it back on in the Play Store app › Play Protect.")
        }
        report.findings = unique(report.findings)
        return report
    }

    // MARK: Saving the result

    /// The result as a web page (also saved as a PDF), for keeping or sending to someone who can help.
    static func html(_ r: Report, device: String, source: String) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        var b = "<!doctype html><meta charset=utf-8><title>Spyware check — \(esc(device))</title><style>body{font:14px -apple-system,Segoe UI,sans-serif;margin:32px;color:#1d2433}h1{font-size:22px;margin:0 0 4px}table{border-collapse:collapse;width:100%;margin:12px 0}td,th{border-bottom:1px solid #dde;padding:6px 8px;text-align:left;vertical-align:top}th{font-size:12px;color:#667}.bad{color:#b3261e}.ok{color:#1b7a3a}.dim{color:#667}</style>"
        b += "<h1>Spyware check: \(esc(device))</h1><div class=dim>\(esc(df.string(from: r.date))) · \(esc(source)) · \(r.indicatorCount) known indicators</div>"
        if r.findings.isEmpty {
            b += "<h2 class=ok>No known spyware indicators were found</h2><p>This checks only for spyware that has been publicly documented. It is not a guarantee.</p>"
        } else {
            b += "<h2 class=bad>\(r.findings.count) match\(r.findings.count == 1 ? "" : "es") with known spyware indicators</h2>"
            b += "<p>A match can be a false alarm, but take it seriously. Amnesty International's Security Lab (securitylab.amnesty.org) and Access Now's Digital Security Helpline (accessnow.org/help) help people for free.</p>"
            b += "<table><tr><th>Where</th><th>What was found</th><th>Linked to</th><th>When</th></tr>"
            for f in r.findings { b += "<tr><td>\(esc(f.area))</td><td>\(esc(f.found))</td><td>\(esc(f.indicator.malware)) <span class=dim>(\(esc(f.indicator.source)))</span></td><td>\(esc(f.when))</td></tr>" }
            b += "</table>"
        }
        for w in r.warnings { b += "<p class=bad>\(esc(w))</p>" }
        for g in r.review { b += "<h3>\(esc(g.title))</h3><div class=dim>\(esc(g.detail))</div><ul>" + g.apps.map { "<li>\(esc($0))</li>" }.joined() + "</ul>" }
        b += "<p class=dim>Checked: \(esc(r.checked.joined(separator: ", ")))."
        if !r.missing.isEmpty { b += " Not available: \(esc(r.missing.joined(separator: ", ")))." }
        return b + "</p>"
    }
}
