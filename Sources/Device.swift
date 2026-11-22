import Foundation
import AppKit
import SQLite3
import ImageIO
import AVFoundation

// Running the bundled device tools, and talking to an iPhone or iPad over AFC.

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

/// Test-only switches (environment variables used by the UI checks) work only in builds compiled with `-D UITEST`.
let uiTestBuild: Bool = {
    #if UITEST
    return true
    #else
    return false
    #endif
}()

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
                    NSHomeDirectory() + "/.local/bin"] + Android.toolsDirs
        if uiTestBuild, let override = ProcessInfo.processInfo.environment["IPHONE_TOOLS_DIR"], !override.isEmpty {
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
        // USB by default: reading a whole library over Wi-Fi crawls. Wi-Fi phones are added only when the user opts in.
        if UserDefaults.standard.bool(forKey: "includeWiFi") {
            for u in all("-n") where seen.insert(u).inserted { out.append(Device(udid: u, isNetwork: true)) }
        }
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
