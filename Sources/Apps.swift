import Foundation

/// An app the user installed on the phone.
struct InstalledApp: Identifiable, Hashable {
    let id: String          // bundle ID on iPhone, package name on Android
    let name: String
    let version: String
    let bytes: Int64
}

/// Lists, installs and removes the user's apps. iPhone: through PortHop's helper (installation service), only apps signed for
/// that iPhone install (your own builds, ad-hoc and company apps; App Store apps cannot be). Android: through adb.
enum AppManager {
    static func list(device: Device, tools: Tools) -> [InstalledApp]? {
        if device.isAndroid {
            guard let packages = Android.shell("pm list packages -3", device: device, tools: tools, timeout: 60) else { return nil }
            let versions = Android.shell("dumpsys package packages", device: device, tools: tools, timeout: 90) ?? ""
            let sizes = Android.shell("dumpsys diskstats", device: device, tools: tools, timeout: 60) ?? ""
            return parseAndroid(packages: packages, versions: versions, diskstats: sizes)
        }
        guard let helper = tools.applist, let r = Shell.run(helper, [device.udid] + (device.isNetwork ? ["-n"] : []) + ["--all"], timeout: 60), r.ok else { return nil }
        return parseIOS(r.output)
    }

    static func parseIOS(_ text: String) -> [InstalledApp] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> InstalledApp? in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, !f[0].isEmpty, !f[0].hasPrefix("ERROR") else { return nil }
            return InstalledApp(id: f[0], name: f[1], version: f.count > 2 ? f[2] : "", bytes: f.count > 3 ? Int64(f[3]) ?? 0 : 0)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Android lists only package names; versions come from the package manager's report and sizes from the storage report.
    static func parseAndroid(packages: String, versions: String, diskstats: String) -> [InstalledApp] {
        let ids = packages.split(whereSeparator: \.isNewline).compactMap { l -> String? in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("package:") ? String(t.dropFirst(8)).components(separatedBy: " ").first : nil
        }
        var version: [String: String] = [:], current: String?
        for line in versions.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Package ["), let close = t.firstIndex(of: "]") { current = String(t[t.index(t.startIndex, offsetBy: 9)..<close]) }
            else if t.hasPrefix("versionName="), let c = current, version[c] == nil { version[c] = String(t.dropFirst(12)) }
        }
        func array(_ key: String) -> [String] {
            guard let line = diskstats.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(key + ": [") }),
                  let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]") else { return [] }
            return line[line.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
        }
        let names = array("Package Names"), app = array("App Sizes"), data = array("App Data Sizes")
        var size: [String: Int64] = [:]
        for (i, n) in names.enumerated() { size[n] = (i < app.count ? Int64(app[i]) ?? 0 : 0) + (i < data.count ? Int64(data[i]) ?? 0 : 0) }
        return ids.map { InstalledApp(id: $0, name: $0, version: version[$0] ?? "", bytes: size[$0] ?? 0) }
            .sorted { $0.id < $1.id }
    }

    /// Installs an .ipa (iPhone) or .apk (Android). Returns nil when it worked, or a plain-language reason.
    static func install(_ file: URL, device: Device, tools: Tools, progress: @escaping (Int) -> Void) -> String? {
        let ext = file.pathExtension.lowercased()
        if device.isAndroid {
            guard ext == "apk" else { return "Android apps install from an .apk file. Split bundles (.apks, .xapk) are not supported." }
            guard let adb = tools.adb, let r = Shell.run(adb, Android.args(device) + ["install", "-r", file.path], timeout: 600) else { return "adb could not be started." }
            return r.output.contains("Success") ? nil : explain(r.output)
        }
        guard ext == "ipa" else { return "iPhone apps install from an .ipa file." }
        guard let helper = tools.applist else { return "The app helper is missing from PortHop. Download PortHop again." }
        var all = ""
        let status = Shell.stream(helper, [device.udid] + (device.isNetwork ? ["-n"] : []) + ["--install", file.path]) { chunk in
            all += chunk
            for line in chunk.split(whereSeparator: \.isNewline) where line.hasPrefix("PROGRESS ") {
                if let n = Int(line.dropFirst(9)) { progress(n) }
            }
        }
        return status == 0 && all.contains("OK") ? nil : explain(all)
    }

    static func uninstall(_ id: String, device: Device, tools: Tools) -> String? {
        if device.isAndroid {
            guard let adb = tools.adb, let r = Shell.run(adb, Android.args(device) + ["uninstall", id], timeout: 120) else { return "adb could not be started." }
            return r.output.contains("Success") ? nil : explain(r.output)
        }
        guard let helper = tools.applist, let r = Shell.run(helper, [device.udid] + (device.isNetwork ? ["-n"] : []) + ["--uninstall", id], timeout: 300) else {
            return "The app helper is missing from PortHop. Download PortHop again."
        }
        return r.ok && r.output.contains("OK") ? nil : explain(r.output)
    }

    /// Turns the installers' error names into something a person can act on.
    static func explain(_ raw: String) -> String {
        let known: [(String, String)] = [
            ("ApplicationVerificationFailed", "This app is not signed for this iPhone. Only apps signed for it (your own builds, ad-hoc or company apps) can be installed; App Store apps cannot."),
            ("MismatchedApplicationIdentifierEntitlement", "A different version of this app, from another developer, is already installed. Remove it first."),
            ("DeviceOSVersionTooLow", "This app needs a newer iOS version than the iPhone has."),
            ("IncorrectArchitecture", "This app was not built for this iPhone."),
            ("PackageInspectionFailed", "This is not a valid .ipa file."),
            ("PackageExtractionFailed", "This is not a valid .ipa file."),
            ("UninstallProhibited", "This app cannot be removed (it may be managed by an organisation)."),
            ("INSTALL_FAILED_VERSION_DOWNGRADE", "A newer version of this app is already installed."),
            ("INSTALL_FAILED_UPDATE_INCOMPATIBLE", "The installed copy was signed by someone else. Remove it first, then install."),
            ("INSTALL_FAILED_INSUFFICIENT_STORAGE", "The phone is out of space."),
            ("INSTALL_FAILED_USER_RESTRICTED", "The phone blocked the install. Allow \u{201C}Install via USB\u{201D} in Developer options, or tap Allow on the phone."),
            ("INSTALL_FAILED_OLDER_SDK", "This app needs a newer Android version."),
            ("INSTALL_FAILED_NO_MATCHING_ABIS", "This app was not built for this phone's processor."),
            ("INSTALL_PARSE_FAILED", "This is not a valid .apk file."),
            ("DELETE_FAILED_INTERNAL_ERROR", "This app cannot be removed (it may be part of the system)."),
            ("DELETE_FAILED_DEVICE_POLICY_MANAGER", "This app is a device administrator. Turn that off in the phone's Settings first."),
            ("device not found", "The phone is not connected."),
        ]
        for (code, text) in known where raw.contains(code) { return text }
        let line = raw.split(whereSeparator: \.isNewline).last { $0.contains("ERROR") || $0.contains("Failure") }.map(String.init) ?? raw
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The phone did not accept the request." : trimmed.replacingOccurrences(of: "ERROR: ", with: "")
    }
}

/// "Show this iPhone when on Wi-Fi": the iPhone setting that lets backups run over Wi-Fi (Finder calls it the same).
enum WiFiSync {
    /// Reads the setting, or sets it first when `set` is given. nil when the iPhone could not be asked.
    static func state(device: Device, tools: Tools, set: Bool? = nil) -> Bool? {
        guard !device.isAndroid, let helper = tools.applist else { return nil }
        let args = [device.udid] + (device.isNetwork ? ["-n"] : []) + ["--wifi"] + (set.map { [$0 ? "on" : "off"] } ?? [])
        guard let r = Shell.run(helper, args, timeout: 20), r.ok else { return nil }
        let t = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "on" ? true : (t == "off" ? false : nil)
    }
}

/// A one-page report about the phone (for selling it, or for a repair shop): model, storage, software, battery health.
enum PhoneReport {
    static func html(name: String, details d: DeviceDetails, isAndroid: Bool) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short
        let skip: Set<String> = ["Phone number", "IMEI", "Wi-Fi address", "Bluetooth address", "Identifier (UDID)", "Time zone"]
        var rows: [(String, String)] = d.info.filter { !skip.contains($0.label) }.map { ($0.label, $0.value) }
        if d.totalDiskBytes > 0 {
            let used = d.totalDiskBytes - d.freeDiskBytes
            rows.append(("Storage", "\(ByteCountFormatter.string(fromByteCount: d.totalDiskBytes, countStyle: .file)) (\(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) used)"))
        }
        if let h = d.batteryHealth { rows.append(("Battery health", "\(h)% of its original capacity")) }
        if let c = d.cycleCount { rows.append(("Battery charge cycles", "\(c)")) }
        if let p = d.batteryPercent { rows.append(("Charge now", "\(p)%")) }
        var b = "<!doctype html><meta charset=utf-8><title>\(esc(name)) report</title><style>body{font:14px -apple-system,Segoe UI,sans-serif;margin:36px;color:#1d2433}h1{font-size:24px;margin:0}table{border-collapse:collapse;width:100%;margin:18px 0}td{border-bottom:1px solid #dde;padding:7px 8px}td:first-child{color:#667;width:38%}.dim{color:#667;font-size:12.5px}</style>"
        b += "<h1>\(esc(name))</h1><div class=dim>Phone report made by PortHop on \(esc(df.string(from: Date()))), read from the phone over USB.</div><table>"
        for (k, v) in rows { b += "<tr><td>\(esc(k))</td><td>\(esc(v))</td></tr>" }
        b += "</table>"
        b += isAndroid
            ? "<p class=dim>Battery health is what the phone reports about itself. Android does not report whether parts were replaced.</p>"
            : "<p class=dim>Battery health is read from the battery's own report (design capacity against today's full charge). Whether parts are genuine Apple parts is shown only on the iPhone itself, in Settings › General › About › Parts and Service History; Apple does not make it readable over USB.</p>"
        return b
    }
}
