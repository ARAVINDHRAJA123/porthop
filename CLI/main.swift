import Foundation

// porthop: PortHop's engine from Terminal, for scripts and power users. The same rules as the app: nothing on the
// device is changed, nothing in the destination is overwritten, and running a copy again copies only what is new.

// It lives in PortHop.app/Contents/Helpers (a name that can't clash with the app's own "PortHop" on a case-insensitive disk).
let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: CommandLine.arguments[0])
let appInfo = (try? Data(contentsOf: exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")))
    .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
let version = appInfo?["CFBundleShortVersionString"] as? String ?? "2.2"
var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool { if let i = args.firstIndex(of: name) { args.remove(at: i); return true }; return false }
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func fail(_ s: String, _ code: Int32 = 2) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(code) }
func emit(_ value: Any) {
    if let d = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: d, as: UTF8.self)) }
}

let usage = """
porthop \(version): copy photos and videos off an iPhone or iPad, from Terminal.

  porthop devices                    the connected devices
  porthop groups                     the photo groups on the device: Library, Hidden, Favorites, albums, people…
  porthop copy <group> <folder>      copy a group (its id or name); running it again copies only what is new
      --pattern "{year}/{month}"     folders inside <folder>
      --names "{year}-{month}-{day} {hour}.{minute}.{second}"   rename the copies
      --heic-to-jpeg  --edited  --live  --original-names  --no-location  --no-report  --no-dates
  porthop backup <folder> [--keep-versions]   a full backup in the same format as Finder's
  porthop music <folder>             copy the iPhone's songs and ringtones (Artist/Album/01 Title)
  porthop apps                       the apps installed on the iPhone, iPad or Android phone
  porthop indicators [file.stix2]    download the public spyware indicators (or add a file someone sent you)
  porthop check <backup folder>      check an iPhone backup for known spyware (exit code 1 when something matches)
  porthop check                      check a connected Android phone for known spyware and stalkerware
      --password <password>          for an encrypted backup

  Pattern tokens: \(Pattern.tokens)
  Options: --device <id> picks a device when several are connected; --json prints machine-readable results.
"""

let json = flag("--json"), wantedDevice = option("--device")
guard let command = args.first, !["-h", "--help", "help"].contains(command) else { print(usage); exit(0) }
if command == "version" || command == "--version" { print("porthop \(version)"); exit(0) }
args.removeFirst()

// The device tools sit next to this program inside PortHop.app, also when it is started through a link.
var helperDirs: [String] = []
if let env = ProcessInfo.processInfo.environment["PORTHOP_TOOLS_DIR"], !env.isEmpty { helperDirs.append(env) }
helperDirs.append(exe.deletingLastPathComponent().path)
guard let tools = Tools.locate(extraDirs: helperDirs) else { fail("The device tools were not found. Run porthop from inside PortHop.app (Contents/MacOS).") }

func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

/// Prints a spyware check and exits: 0 when nothing matched, 1 when something did.
func report(_ r: Spyware.Report) -> Never {
    if json {
        emit(["matches": r.findings.map { ["area": $0.area, "found": $0.found, "spyware": $0.indicator.malware, "source": $0.indicator.source, "when": $0.when] },
              "checked": r.checked, "notAvailable": r.missing, "indicators": r.indicatorCount, "warnings": r.warnings,
              "review": r.review.map { ["title": $0.title, "apps": $0.apps] as [String: Any] }])
    } else {
        print(r.findings.isEmpty ? "No known spyware found (checked against \(r.indicatorCount) indicators)." : "\(r.findings.count) match(es) with known spyware:")
        for f in r.findings { print("  \(f.area): \(f.found)  [\(f.indicator.malware), \(f.indicator.source)]\(f.when.isEmpty ? "" : "  " + f.when)") }
        for w in r.warnings { print("Warning: \(w)") }
        for g in r.review { print("\(g.title): \(g.apps.joined(separator: ", "))") }
        if !r.findings.isEmpty { print("A match can be a false alarm, but get expert help: securitylab.amnesty.org, accessnow.org/help") }
    }
    exit(r.findings.isEmpty ? 0 : 1)
}

func indicators() -> Spyware.Indicators {
    let set = Spyware.load(from: Spyware.folder)
    if set.isEmpty { fail("No spyware indicators yet. Run: porthop indicators", 3) }
    return set
}

if command == "indicators" {
    if let file = args.first {
        let problem = Spyware.add(file: URL(fileURLWithPath: expand(file)), to: Spyware.folder)
        if let problem { fail(problem, 2) }
    } else {
        let done = DispatchSemaphore(value: 0)
        var problem: String?
        Task.detached { problem = await Spyware.download(to: Spyware.folder); done.signal() }
        done.wait()
        if let problem, Spyware.load(from: Spyware.folder).isEmpty { fail(problem, 1) }
        if let problem { FileHandle.standardError.write(Data((problem + "\n").utf8)) }
    }
    let n = Spyware.load(from: Spyware.folder).count, sources = Spyware.sources(in: Spyware.folder).count
    if json { emit(["indicators": n, "sources": sources]) } else { print("\(n) indicators from \(sources) source\(sources == 1 ? "" : "s").") }
    exit(0)
}
let password = option("--password")
if command == "check", let path = args.first {
    let set = indicators()
    switch BackupReader.open(folder: URL(fileURLWithPath: expand(path)), password: password) {
    case .ready(let r): report(Spyware.scan(backup: r, with: set))
    case .needsPassword: fail("This backup is encrypted: add --password <its password>.")
    case .wrongPassword: fail("That password didn't open the backup.")
    case .unreadable: fail("That folder isn't a readable backup (it should hold Manifest.db).", 3)
    }
}

let found = AFC.findDevices(tools) + Android.findDevices(tools)
if command == "devices" {
    let list: [[String: Any]] = found.map { d in
        let name = d.isAndroid ? Android.details(d, tools: tools)?.name : AFC.details(d, tools: tools)?.name
        return ["id": d.udid, "kind": d.isAndroid ? "android" : "ios", "name": name ?? (d.unauthorized ? "(not allowed yet)" : "(locked)"), "wifi": d.isNetwork]
    }
    if json { emit(list) } else if list.isEmpty { print("No device. Plug one in, unlock it and tap Trust (or Allow on Android).") }
    else { for d in list { print("\(d["kind"]!)\t\(d["name"]!)\t\(d["id"]!)") } }
    exit(0)
}

let androidToo = ["apps", "check"].contains(command)
guard let device = (wantedDevice.map { id in found.first { $0.udid == id } } ?? found.first(where: { !$0.isAndroid }) ?? (androidToo ? found.first : nil)) else {
    fail(wantedDevice != nil ? "No connected device has the id \(wantedDevice!)." : "No iPhone or iPad. Plug it in, unlock it and tap Trust.", 3)
}
guard !device.isAndroid || androidToo else { fail("Android phones are copied from the app for now; the command line copies from iPhones and iPads.") }

func catalog() -> Catalog {
    let fm = FileManager.default
    let temp = fm.temporaryDirectory.appendingPathComponent("PortHop-cli-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temp) }
    var cmds = ""
    for f in ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"] {
        if let l = AFC.quote(temp.appendingPathComponent(f).path) { cmds += "get \"PhotoData/\(f)\" \(l)\n" }
    }
    _ = Shell.run(tools.afc, device.baseArgs, stdin: cmds + "quit\n", timeout: 600)
    let db = temp.appendingPathComponent("Photos.sqlite")
    guard AFC.fileSize(db) > 0 else { fail("The photo library could not be read. Unlock the device and tap Trust.", 3) }
    var result = CatalogReader.load(path: db.path)
    if case .failure = result {
        for f in ["Photos.sqlite-wal", "Photos.sqlite-shm"] { try? fm.removeItem(at: temp.appendingPathComponent(f)) }
        result = CatalogReader.load(path: db.path)
    }
    guard case .success(let cat) = result else { fail("This version of iOS stores its photo library in a way PortHop can't read yet.", 3) }
    return cat
}

switch command {
case "groups":
    let cat = catalog()
    let groups = cat.smart.filter { !$0.assets.isEmpty || $0.id == "smart_hidden" } + cat.user + cat.people
    if json { emit(groups.map { ["id": $0.id, "title": $0.title, "count": $0.assets.count, "bytes": $0.totalBytes] as [String: Any] }) }
    else { for g in groups { print("\(g.id)\t\(g.title)\t\(g.assets.count) items\t\(Fmt.bytes(g.totalBytes))") } }

case "copy":
    guard args.count >= 2 else { fail("Usage: porthop copy <group> <folder>   (see porthop help)") }
    var o = ExportOptions()
    if let p = option("--pattern") { o.subfolder = .custom; o.folderPattern = p }
    if let n = option("--names") { o.namePattern = n }
    o.convertHEIC = flag("--heic-to-jpeg"); o.editedVersions = flag("--edited"); o.includeLiveVideo = flag("--live")
    o.useOriginalNames = flag("--original-names"); o.removeLocation = flag("--no-location")
    o.saveReport = !flag("--no-report"); o.setDates = !flag("--no-dates")
    let want = args[0], folder = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
    let cat = catalog()
    let all = cat.smart + cat.user + cat.people
    guard let group = all.first(where: { $0.id == want }) ?? all.first(where: { $0.title.lowercased() == want.lowercased() }) else {
        fail("No group called “\(want)”. See the list with: porthop groups")
    }
    o.albumName = group.title
    o.deviceName = AFC.details(device, tools: tools)?.name ?? "iPhone"
    let job = ExportJob()
    signal(SIGINT, SIG_IGN)
    let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    stop.setEventHandler { FileHandle.standardError.write(Data("\nStopping…\n".utf8)); job.cancel() }
    stop.resume()
    var last = Date.distantPast
    let s = Exporter.run(assets: group.assets, destination: folder, options: o, device: device, tools: tools, job: job) { p in
        guard !json, Date().timeIntervalSince(last) > 0.5 || p.processed == p.total else { return }
        last = Date()
        let speed = p.bytesPerSecond > 0 ? " · \(Fmt.bytes(Int64(p.bytesPerSecond)))/s" : ""
        FileHandle.standardError.write(Data("\r\(p.processed)/\(p.total) · \(Fmt.bytes(p.bytesDone)) of \(Fmt.bytes(p.bytesTotal))\(speed)   ".utf8))
    }
    if !json { FileHandle.standardError.write(Data("\n".utf8)) }
    if json {
        emit(["copied": s.copied, "skipped": s.skipped, "failed": s.failures.map { ["file": $0.asset.filename, "reason": $0.reason] }, "notCopied": s.notAttempted,
              "bytes": s.bytesCopied, "report": (s.reportURL?.path as Any?) ?? NSNull(), "stopped": s.cancelled || s.disconnected || s.stalled, "error": (s.fatalError as Any?) ?? NSNull()])
    } else {
        if let e = s.fatalError { fail(e, 1) }
        print("Copied \(s.copied), already there \(s.skipped), couldn't copy \(s.failures.count)\(s.notAttempted > 0 ? ", not copied \(s.notAttempted)" : "") · \(Fmt.bytes(s.bytesCopied))")
        for f in s.failures.prefix(10) { print("  \(f.asset.filename): \(f.reason)") }
        if s.failures.count > 10 { print("  …and \(s.failures.count - 10) more") }
        if let r = s.reportURL { print("Report: \(r.path)") }
    }
    exit(s.isClean ? 0 : 1)

case "backup":
    guard let path = args.first else { fail("Usage: porthop backup <folder> [--keep-versions]") }
    let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    if flag("--keep-versions") { Backup.snapshot(udid: device.udid, in: folder) }
    FileHandle.standardError.write(Data("Backing up… enter the passcode on the device if it asks.\n".utf8))
    let problem = Backup.run(device: device, tools: tools, folder: folder, job: ExportJob()) { percent, phase in
        if let percent, !json { FileHandle.standardError.write(Data("\r\(phase) \(Int(percent * 100))%   ".utf8)) }
    }
    if json { emit(["ok": problem == nil, "error": (problem as Any?) ?? NSNull()]) } else { print(problem.map { "\n" + $0 } ?? "\nBackup complete.") }
    exit(problem == nil ? 0 : 1)

case "check":
    guard device.isAndroid else { fail("Give the backup folder to check: porthop check <backup folder>. Make one with: porthop backup <folder>") }
    report(Spyware.scan(android: device, tools: tools, with: indicators()))

case "apps":
    guard let list = AppManager.list(device: device, tools: tools) else { fail("The app list could not be read. Unlock the device.", 3) }
    if json { emit(list.map { ["id": $0.id, "name": $0.name, "version": $0.version, "bytes": $0.bytes] as [String: Any] }) }
    else { for a in list { print("\(a.id)\t\(a.name)\t\(a.version)") } }

case "music":
    guard let path = args.first else { fail("Usage: porthop music <folder>") }
    let (songs, problem) = MusicLibrary.load(device: device, tools: tools)
    if let problem { fail(problem, 3) }
    let o = MusicLibrary.copy(songs, to: URL(fileURLWithPath: expand(path)), device: device, tools: tools, job: ExportJob()) { n, total, title in
        if !json { FileHandle.standardError.write(Data("\r\(n + 1)/\(total) \(title)                    ".utf8)) }
    }
    let locked = songs.filter { !$0.canCopy }.count
    if json { emit(["copied": o.copied, "skipped": o.skipped, "failed": o.failed.count - locked, "notCopyable": locked]) }
    else { print("\nCopied \(o.copied), already there \(o.skipped)" + (locked > 0 ? ", \(locked) not copyable (Apple Music or only in the cloud)" : "") + (o.failed.count > locked ? ", \(o.failed.count - locked) failed." : ".")) }
    exit(o.failed.count > locked ? 1 : 0)

default:
    fail("Unknown command “\(command)”.\n\n" + usage)
}
