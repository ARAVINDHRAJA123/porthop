import Foundation

/// Android phones and tablets over USB, through Google's adb. The phone must have USB debugging switched on.
enum Android {
    /// adb is Google's program and may not be redistributed, so it lives outside the app bundle.
    static let toolsDir = NSHomeDirectory() + "/Library/Application Support/iPhoneAlbumExtractor/android/platform-tools"
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
