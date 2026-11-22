import Foundation

/// Android phones and tablets over USB, through Google's adb. The phone must have USB debugging switched on.
enum Android {
    /// adb is Google's program and may not be redistributed, so it is downloaded from Google on request
    /// and kept outside the app. The second folder is where earlier versions of the app kept it.
    static let supportDir = NSHomeDirectory() + "/Library/Application Support/PortHop/android"
    static let toolsDirs = [supportDir + "/platform-tools",
                            NSHomeDirectory() + "/Library/Application Support/iPhoneAlbumExtractor/android/platform-tools"]

    /// Downloads Google's platform-tools and checks adb is signed by Google. Returns nil on success, otherwise a reason.
    static func setUp() async -> String? {
        let url = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!
        let fm = FileManager.default
        do {
            let (file, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "Google's server answered with an error. Try again later." }
            try fm.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
            let zip = URL(fileURLWithPath: supportDir).appendingPathComponent("platform-tools.zip")
            try? fm.removeItem(at: zip)
            try fm.moveItem(at: file, to: zip)
            defer { try? fm.removeItem(at: zip) }
            try? fm.removeItem(atPath: supportDir + "/platform-tools")
            guard Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, supportDir], timeout: 180)?.ok == true else {
                return "The download finished but could not be unpacked."
            }
            let adb = supportDir + "/platform-tools/adb"
            let check = Shell.run("/usr/bin/codesign", ["--verify", "--strict", "-dv", "--verbose=2", adb], timeout: 30)
            guard check?.ok == true, check?.output.contains("TeamIdentifier=EQHXZ8M8AV") == true else {
                try? fm.removeItem(atPath: supportDir + "/platform-tools")
                return "The download could not be confirmed as Google's own, so it was removed. Try again later."
            }
            return nil
        } catch {
            return "The download did not finish (\(error.localizedDescription)). Check the internet connection and try again."
        }
    }
    static let storageRoot = "/sdcard"

    static func args(_ device: Device) -> [String] { ["-s", device.udid] }

    /// Quotes one argument for the phone's shell.
    static func sh(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func findDevices(_ tools: Tools) -> [Device] {
        guard let adb = tools.adb, let r = Shell.run(adb, ["devices"], timeout: 12), r.ok else { return [] }
        var out: [Device] = []
        for line in r.output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard parts.count == 2, ["device", "unauthorized"].contains(parts[1]) else { continue }
            out.append(Device(udid: parts[0], isNetwork: parts[0].contains(":"), isAndroid: true, unauthorized: parts[1] == "unauthorized"))
        }
        return out
    }

    static func shell(_ command: String, device: Device, tools: Tools, timeout: TimeInterval = 20) -> String? {
        guard let adb = tools.adb, let r = Shell.run(adb, args(device) + ["shell", command], timeout: timeout), r.ok else { return nil }
        return r.output.replacingOccurrences(of: "\r\n", with: "\n")
    }

    static func name(of device: Device, tools: Tools) -> String {
        let n = shell("getprop ro.product.model", device: device, tools: tools, timeout: 8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? "Android \(device.udid.suffix(4))" : n
    }

    static func details(_ device: Device, tools: Tools) -> (name: String, details: DeviceDetails)? {
        guard let raw = shell("getprop", device: device, tools: tools) else { return nil }
        var p: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            // [ro.product.model]: [Pixel 8]
            let parts = line.components(separatedBy: "]: [")
            guard parts.count == 2, parts[0].hasPrefix("["), parts[1].hasSuffix("]") else { continue }
            p[String(parts[0].dropFirst())] = String(parts[1].dropLast())
        }
        guard let model = p["ro.product.model"], !model.isEmpty else { return nil }
        let maker = (p["ro.product.manufacturer"] ?? "").capitalized
        var d = DeviceDetails()
        d.modelName = model.lowercased().hasPrefix(maker.lowercased()) || maker.isEmpty ? model : "\(maker) \(model)"
        d.productType = p["ro.product.device"] ?? "—"
        d.iosVersion = p["ro.build.version.release"] ?? "—"
        d.buildVersion = p["ro.build.id"] ?? "—"
        d.serialNumber = p["ro.serialno"] ?? device.udid

        if let df = shell("df -k \(storageRoot)/", device: device, tools: tools), let last = df.split(separator: "\n").last {
            // Filesystem 1K-blocks Used Available Use% Mounted on
            let f = last.split(separator: " ", omittingEmptySubsequences: true)
            if f.count >= 4, let total = Int64(f[1]), let free = Int64(f[3]) {
                d.totalDiskBytes = total * 1024
                d.freeDiskBytes = free * 1024
            }
        }
        if let bat = shell("dumpsys battery", device: device, tools: tools) {
            func value(_ key: String) -> String? {
                for line in bat.split(separator: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(key + ":") { return String(t.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
                }
                return nil
            }
            if let level = Int(value("level") ?? ""), let scale = Int(value("scale") ?? "100"), scale > 0 { d.batteryPercent = level * 100 / scale }
            // 2 = charging, 5 = full
            if let status = Int(value("status") ?? "") { d.isCharging = status == 2 || status == 5 }
            if let cycles = Int(value("Charging cycle count") ?? value("cycle count") ?? ""), cycles > 0 { d.cycleCount = cycles }
        }
        func row(_ label: String, _ key: String, _ symbol: String) {
            if let v = p[key], !v.isEmpty { d.info.append(InfoRow(label: label, value: v, symbol: symbol)) }
        }
        d.info.append(InfoRow(label: "Model", value: d.modelName, symbol: "cpu"))
        row("Device code name", "ro.product.device", "tag")
        d.info.append(InfoRow(label: "Serial number", value: d.serialNumber, symbol: "barcode"))
        d.info.append(InfoRow(label: "Software", value: "Android \(d.iosVersion) (\(d.buildVersion))", symbol: "gearshape"))
        row("Security patch", "ro.build.version.security_patch", "lock.shield")
        row("Processor", "ro.product.cpu.abi", "memorychip")
        row("Chipset", "ro.soc.model", "cpu")
        row("Modem firmware", "gsm.version.baseband", "antenna.radiowaves.left.and.right")
        row("Carrier", "gsm.sim.operator.alpha", "simcard")
        row("Time zone", "persist.sys.timezone", "clock")
        return (model, d)
    }

    /// A folder of photos or videos as Android's media index (MediaStore) sees it: Camera, Screenshots, WhatsApp Images…
    struct MediaAlbum: Equatable { let name: String; let path: String; let count: Int; let bytes: Int64 }

    /// Every folder holding photos or videos, from MediaStore, biggest first. Empty if the index can't be read.
    static func mediaAlbums(_ device: Device, tools: Tools) -> [MediaAlbum] {
        guard let out = shell("content query --uri content://media/external/file --projection _data:_size --where 'media_type=1 OR media_type=3'",
                              device: device, tools: tools, timeout: 60) else { return [] }
        return parseMediaAlbums(out)
    }

    static func parseMediaAlbums(_ out: String) -> [MediaAlbum] {
        var byDir: [String: (Int, Int64)] = [:]
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("Row:") {
            guard let d = line.range(of: "_data=") else { continue }
            let rest = line[d.upperBound...]
            let sizeRange = rest.range(of: ", _size=")
            var path = String(sizeRange.map { rest[..<$0.lowerBound] } ?? rest)
            let size = sizeRange.flatMap { Int64(rest[$0.upperBound...].prefix { $0.isNumber }) } ?? 0
            for prefix in ["/storage/emulated/0", "/sdcard"] where path.hasPrefix(prefix + "/") { path = storageRoot + path.dropFirst(prefix.count) }
            guard path.hasPrefix(storageRoot + "/") else { continue }   // SD cards and other volumes: not browsable here
            let dir = (path as NSString).deletingLastPathComponent
            let cur = byDir[dir] ?? (0, 0)
            byDir[dir] = (cur.0 + 1, cur.1 + size)
        }
        return byDir.map { MediaAlbum(name: ($0.key as NSString).lastPathComponent, path: $0.key, count: $0.value.0, bytes: $0.value.1) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    static func list(_ dir: String, device: Device, tools: Tools) -> [AFCFileEntry] {
        // The trailing slash makes ls follow /sdcard, which is a link on most phones.
        guard let out = shell("ls -la \(sh(dir.hasSuffix("/") ? dir : dir + "/"))", device: device, tools: tools, timeout: 60) else { return [] }
        var entries: [AFCFileEntry] = []
        for raw in out.split(separator: "\n") {
            // drwxrwx--x 3 root sdcard_rw 4096 2026-11-10 18:34 Camera
            let parts = raw.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 8, let kind = parts[0].first, "d-l".contains(kind), parts[0].count >= 10 else { continue }
            var name = parts[7]
            if kind == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            if name.isEmpty || name == "." || name == ".." { continue }
            entries.append(AFCFileEntry(name: name, path: dir == "/" ? "/\(name)" : "\(dir)/\(name)", isDirectory: kind != "-",
                                        size: Int64(parts[4]) ?? 0, modifiedDate: "\(parts[5]) \(parts[6])"))
        }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return entries
    }

    /// Phone → Mac. Folders are copied whole. `local` must not exist yet.
    static func pull(_ remote: String, to local: URL, device: Device, tools: Tools, onStart: ((Process) -> Void)? = nil) -> Bool {
        guard let adb = tools.adb, !FileManager.default.fileExists(atPath: local.path) else { return false }
        let r = Shell.run(adb, args(device) + ["pull", "-a", remote, local.path], onStart: onStart)
        return r?.ok == true && FileManager.default.fileExists(atPath: local.path)
    }

    /// Mac → phone. Never overwrites: an existing name gets " (2)" etc.
    static func push(_ local: URL, intoDir dir: String, existing: inout Set<String>, device: Device, tools: Tools,
                     onStart: ((Process) -> Void)? = nil) -> Bool {
        guard let adb = tools.adb, FileManager.default.fileExists(atPath: local.path) else { return false }
        var name = local.lastPathComponent
        if existing.contains(name) {
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            var i = 2
            repeat { name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"; i += 1 } while existing.contains(name)
        }
        let r = Shell.run(adb, args(device) + ["push", local.path, "\(dir)/\(name)"], onStart: onStart)
        let ok = r?.ok == true
        if ok { existing.insert(name) }
        return ok
    }

    static func mkdir(_ path: String, device: Device, tools: Tools) -> Bool {
        shell("mkdir \(sh(path)) && echo made", device: device, tools: tools)?.contains("made") == true
    }

    static func power(_ action: String, device: Device, tools: Tools) -> Bool {
        guard let adb = tools.adb else { return false }
        if action == "restart" { return Shell.run(adb, args(device) + ["reboot"], timeout: 20)?.ok == true }
        if action == "sleep" { return shell("input keyevent 223", device: device, tools: tools) != nil }
        return false
    }
}
