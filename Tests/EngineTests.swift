import Foundation
// Runs the export engine against the simulated iPhone and checks the counts.
let T = CommandLine.arguments[1], bin = CommandLine.arguments[2]
let tools = Tools(ideviceId: bin + "/idevice_id", ideviceInfo: bin + "/ideviceinfo", afc: bin + "/afcclient", applist: bin + "/applist")
let dev = AFC.findDevice(tools)!
guard case .success(let cat) = CatalogReader.load(path: T + "/phone/PhotoData/Photos.sqlite") else { fatalError("catalog") }
let hidden = cat.smart[0].assets
var failures = 0
func check(_ name: String, _ s: ExportSummary, copied: Int, skipped: Int, failed: Int, extra: Bool = true) {
    let ok = s.copied == copied && s.skipped == skipped && s.failures.count == failed && extra
    if !ok { failures += 1 }
    print(ok ? "PASS" : "FAIL", name, "copied", s.copied, "skipped", s.skipped, "failed", s.failures.count, "live", s.liveVideos, "notStarted", s.notAttempted)
}
func run(_ dest: String, _ o: ExportOptions = ExportOptions(), job: ExportJob = ExportJob()) -> ExportSummary {
    Exporter.run(assets: hidden, destination: URL(fileURLWithPath: T + "/" + dest), options: o, device: dev, tools: tools, job: job) { _ in }
}
check("catalog", ExportSummary(destination: URL(fileURLWithPath: "/")), copied: 0, skipped: 0, failed: 0, extra: hidden.count == 39 && cat.user.count == 2)
let hiddenIDs = Set(hidden.map(\.id))
check("hidden items appear only in Hidden", ExportSummary(destination: URL(fileURLWithPath: "/")), copied: 0, skipped: 0, failed: 0,
      extra: !(cat.smart.dropFirst() + cat.user).contains { $0.id != "smart_trashed" && $0.assets.contains { hiddenIDs.contains($0.id) } })
check("first export", run("out1"), copied: 38, skipped: 0, failed: 1)
check("run again", run("out1"), copied: 0, skipped: 38, failed: 1)
try? FileManager.default.removeItem(atPath: T + "/out1/.iPhoneAlbumExtractor-manifest.json")
check("adopt earlier export", run("out1"), copied: 1, skipped: 37, failed: 1)
var o = ExportOptions(); o.includeLiveVideo = true; o.subfolder = .yearMonth; o.useOriginalNames = true
let live = run("out2", o)
check("live photos + by month", live, copied: 38, skipped: 0, failed: 1, extra: live.liveVideos == 5)
setenv("FAKE_DELAY", "0.05", 1)
let job = ExportJob()
DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { job.cancel() }
let c = run("out3", job: job)
check("cancel", c, copied: c.copied, skipped: 0, failed: 0, extra: c.cancelled && c.copied < 38 && c.notAttempted > 0)
setenv("FAKE_DELAY", "0", 1)
let r = run("out3")
check("resume after cancel", r, copied: 38 - c.copied, skipped: c.copied, failed: 1)
FileManager.default.createFile(atPath: T + "/phone/.unplugged", contents: nil)
let u = run("out4")
check("unplugged", u, copied: u.copied, skipped: 0, failed: u.failures.count, extra: u.disconnected)
try? FileManager.default.removeItem(atPath: T + "/phone/.unplugged")
let stray = ["out1", "out2", "out3", "out4"].flatMap { (try? FileManager.default.contentsOfDirectory(atPath: T + "/" + $0)) ?? [] }.filter { $0.contains("staging") }
check("no leftover staging", ExportSummary(destination: URL(fileURLWithPath: "/")), copied: 0, skipped: 0, failed: 0, extra: stray.isEmpty)
let listing = AFC.list("/DCIM/100APPLE", device: dev, tools: tools)
check("file listing", ExportSummary(destination: URL(fileURLWithPath: "/")), copied: 0, skipped: 0, failed: 0,
      extra: listing.contains { $0.name == "we\"ird name.JPG" && $0.size > 0 } && AFC.list("/DCIM", device: dev, tools: tools).map(\.name) == ["100APPLE", "101APPLE"])
check("remote size", ExportSummary(destination: URL(fileURLWithPath: "/")), copied: 0, skipped: 0, failed: 0,
      extra: (AFC.remoteSize("DCIM/100APPLE/IMG_9001.MOV", device: dev, tools: tools) ?? 0) == 3_000_000)
let blank = ExportSummary(destination: URL(fileURLWithPath: "/"))
let app = "com.example.player"
check("app list", blank, copied: 0, skipped: 0, failed: 0, extra: AFC.apps(dev, tools: tools).map(\.name) == ["Book Reader", "Movie Player"])
var names = Set(AFC.list("/Documents", app: app, device: dev, tools: tools).map(\.name))
let local = URL(fileURLWithPath: T + "/phone/DCIM/100APPLE/IMG_0001.JPG")
let put1 = AFC.put(local, intoDir: "/Documents", existing: &names, app: app, device: dev, tools: tools)
let put2 = AFC.put(local, intoDir: "/Documents", existing: &names, app: app, device: dev, tools: tools)
let made = AFC.mkdir("/Documents/New Stuff", app: app, device: dev, tools: tools)
let putDir = AFC.put(URL(fileURLWithPath: T + "/phone/DCIM/101APPLE"), intoDir: "/Documents/New Stuff", existing: &names, app: app, device: dev, tools: tools)
let after = AFC.list("/Documents", app: app, device: dev, tools: tools)
check("send to app (no overwrite)", blank, copied: 0, skipped: 0, failed: 0,
      extra: put1 && put2 && made && putDir && after.contains { $0.name == "IMG_0001.JPG" && $0.size == AFC.fileSize(local) }
        && after.contains { $0.name == "IMG_0001 (2).JPG" } && AFC.list("/Documents/New Stuff/101APPLE", app: app, device: dev, tools: tools).count == 20)
Exporter.stallLimit = 1.5
setenv("FAKE_DELAY", "30", 1)
let st = run("out5")
setenv("FAKE_DELAY", "0", 1)
check("stalled device is abandoned, not waited on", st, copied: 0, skipped: 0, failed: st.failures.count, extra: st.stalled && st.elapsed < 12)
// Android through the stand-in adb.
let droid = T + "/android"
for d in ["DCIM/Camera", "Download", "Pictures/It's here"] { try! FileManager.default.createDirectory(atPath: droid + "/" + d, withIntermediateDirectories: true) }
try! FileManager.default.copyItem(atPath: local.path, toPath: droid + "/DCIM/Camera/PXL 0001.jpg")
try! FileManager.default.copyItem(atPath: local.path, toPath: droid + "/Pictures/It's here/a.jpg")
var at = tools; at.adb = bin + "/adb"
let noDroid = Android.findDevices(at).isEmpty
setenv("FAKE_ANDROID", droid, 1)
setenv("FAKE_ANDROID_LOCKED", "1", 1)
let lockedDroid = Android.findDevices(at).first?.unauthorized == true
unsetenv("FAKE_ANDROID_LOCKED")
let ad = Android.findDevices(at).first!
let info = Android.details(ad, tools: at)
check("android device details", blank, copied: 0, skipped: 0, failed: 0,
      extra: noDroid && lockedDroid && ad.isAndroid && info?.name == "Pixel 8" && info?.details.modelName == "Google Pixel 8" && info?.details.iosVersion == "16"
        && info?.details.batteryPercent == 76 && info?.details.isCharging == true && info?.details.cycleCount == 212
        && info?.details.totalDiskBytes == 119771136 * 1024 && info?.details.freeDiskBytes == 59771136 * 1024)
let top = Android.list("/sdcard", device: ad, tools: at)
let cam = Android.list("/sdcard/DCIM/Camera", device: ad, tools: at)
let quoted = Android.list("/sdcard/Pictures/It's here", device: ad, tools: at)
check("android listing", blank, copied: 0, skipped: 0, failed: 0,
      extra: top.map(\.name) == ["DCIM", "Download", "Pictures"] && top.allSatisfy(\.isDirectory) && quoted.count == 1
        && cam.count == 1 && cam[0].name == "PXL 0001.jpg" && cam[0].size == AFC.fileSize(local) && cam[0].path == "/sdcard/DCIM/Camera/PXL 0001.jpg")
let pulled = URL(fileURLWithPath: T + "/pulled.jpg"), pulledDir = URL(fileURLWithPath: T + "/pulledDCIM")
let p1 = Android.pull(cam[0].path, to: pulled, device: ad, tools: at)
let p2 = Android.pull(cam[0].path, to: pulled, device: ad, tools: at)
let p3 = Android.pull("/sdcard/DCIM", to: pulledDir, device: ad, tools: at)
var dnames = Set(Android.list("/sdcard/Download", device: ad, tools: at).map(\.name))
let s1 = Android.push(local, intoDir: "/sdcard/Download", existing: &dnames, device: ad, tools: at)
let s2 = Android.push(local, intoDir: "/sdcard/Download", existing: &dnames, device: ad, tools: at)
let mk1 = Android.mkdir("/sdcard/Download/New Stuff", device: ad, tools: at)
let mk2 = Android.mkdir("/sdcard/Download/New Stuff", device: ad, tools: at)
let dl = Android.list("/sdcard/Download", device: ad, tools: at).map(\.name)
check("android copy both ways (no overwrite)", blank, copied: 0, skipped: 0, failed: 0,
      extra: p1 && !p2 && p3 && AFC.fileSize(pulled) == AFC.fileSize(local) && AFC.fileSize(pulledDir.appendingPathComponent("Camera/PXL 0001.jpg")) == AFC.fileSize(local)
        && s1 && s2 && mk1 && !mk2 && dl.first == "New Stuff" && Set(dl) == ["New Stuff", "IMG_0001.JPG", "IMG_0001 (2).JPG"])
if !(p1 && !p2 && p3 && s1 && s2 && mk1 && !mk2) { print("  detail", p1, p2, p3, s1, s2, mk1, mk2, dl) }
// Reading data out of a stand-in backup.
let bk = BackupReader(folder: URL(fileURLWithPath: T + "/backup/0000-TEST"))!
func tree(_ k: BackupKind) -> [DataGroup] { bk.load(k).groups }
let msg = tree(.messages)
check("backup messages", blank, copied: 0, skipped: 0, failed: 0,
      extra: msg.count == 2 && msg[0].title == "Weekend Trip" && msg[0].rows[0][1] == "Sam Lee" && msg[0].rows.count == 2 && msg[0].rows[1][2].count == 70005 && msg[1].title == "Asha Rao" && msg[1].rows.count == 5
        && msg[1].rows[0][1] == "Asha Rao" && msg[1].rows[1][1] == "Me" && msg[1].rows[2][2] == "From the archive" && msg[1].rows[3][2].count == 309
        && msg[1].rows[4][2] == "(attachment)" && msg[1].rows[0][0].hasPrefix("2025-"))
let wa = tree(.whatsapp)
check("backup whatsapp", blank, copied: 0, skipped: 0, failed: 0,
      extra: wa.count == 2 && wa[0].title == "Family" && wa[0].rows[0][1] == "Uncle Ravi" && wa[0].rows[1][2].hasPrefix("(photo") && wa[1].rows[1] .dropFirst() == ["Me", "Yes"])
let people = tree(.contacts)[0].rows, notes = tree(.notes)[0].rows, cals = tree(.calendar), web = tree(.safari)
check("backup contacts, notes, calendar, safari", blank, copied: 0, skipped: 0, failed: 0,
      extra: people.count == 3 && people.contains(["Asha Rao", "", "(415) 555-0101", "asha@example.com"]) && notes.map { $0[0] } == ["Ideas", "Shopping"]
        && cals.count == 2 && cals.first { $0.title == "Home" }?.rows[0][2] == "All day" && web.map(\.title) == ["Bookmarks", "History"] && web[0].rows.count == 1 && web[1].rows.count == 2)
let noCalls = bk.load(.calls)
let fg = tree(.files)
let roll = fg.first { $0.subtitle == "CameraRollDomain" }!
try! FileManager.default.createDirectory(atPath: T + "/bkout", withIntermediateDirectories: true)
let ex1 = bk.extract(roll, rows: [0], to: URL(fileURLWithPath: T + "/bkout")), ex2 = bk.extract(roll, rows: [0], to: URL(fileURLWithPath: T + "/bkout"))
let csv = BackupReader.csv(msg[1])
check("backup files, extract, csv", blank, copied: 0, skipped: 0, failed: 0,
      extra: noCalls.groups.isEmpty && noCalls.note.contains("encrypted") && fg.count == 6 && roll.title == "Camera Roll" && roll.rows == [["IMG_0001.JPG", "Media/DCIM/100APPLE"]]
        && ex1.first?.lastPathComponent == "IMG_0001.JPG" && ex2.count == 1 && ex2[0] != ex1[0] && AFC.fileSize(ex1[0]) == 900
        && csv.hasPrefix("\"Date\",\"From\",\"Message\"\r\n") && csv.contains("\"Hi \"\"Asha\"\", how are you?\"")
        && BackupReader(folder: URL(fileURLWithPath: T + "/backup/0000-LOCKED")) == nil && Backup.existing(in: URL(fileURLWithPath: T + "/backup")).count == 3)
// A password-protected backup.
let secure = URL(fileURLWithPath: T + "/backup/0000-SECURE")
func state(_ o: BackupReader.Opened) -> String {
    switch o { case .ready: return "ready"; case .needsPassword: return "needs"; case .wrongPassword: return "wrong"; case .unreadable: return "unreadable" }
}
let sealed = (try? Data(contentsOf: secure.appendingPathComponent("Manifest.db")))?.prefix(15) != Data("SQLite format 3".utf8)
var sbk: BackupReader?
if case .ready(let r) = BackupReader.open(folder: secure, password: "correct horse") { sbk = r }
let smsg = sbk?.load(.messages).groups ?? []
let sroll = sbk?.load(.files).groups.first { $0.subtitle == "CameraRollDomain" }
try! FileManager.default.createDirectory(atPath: T + "/bkout2", withIntermediateDirectories: true)
let sex = sroll.map { sbk!.extract($0, rows: [0], to: URL(fileURLWithPath: T + "/bkout2")) } ?? []
check("encrypted backup opens only with its password", blank, copied: 0, skipped: 0, failed: 0,
      extra: sealed && state(BackupReader.open(folder: secure, password: nil)) == "needs" && state(BackupReader.open(folder: secure, password: "wrong one")) == "wrong"
        && state(BackupReader.open(folder: URL(fileURLWithPath: T + "/backup/0000-TEST"), password: nil)) == "ready" && sbk != nil
        && smsg.count == 2 && smsg[1].rows.count == 5 && smsg[1].rows[2][2] == "From the archive" && smsg[1].rows[0][1] == "Asha Rao"
        && sex.count == 1 && (try? Data(contentsOf: sex[0])) == Data(String(repeating: "jpegbytes", count: 100).utf8))
// Restore, against the stand-in tool (nothing real is restored).
let entries = Backup.existing(in: URL(fileURLWithPath: T + "/backup"))
let plainEntry = entries.first { $0.path.lastPathComponent == "0000-TEST" }!, secureEntry = entries.first { $0.path.lastPathComponent == "0000-SECURE" }!
var rt = tools; rt.backup = bin + "/idevicebackup2"
var pcts: [Double] = []
let r1 = Backup.restore(plainEntry, to: dev, tools: rt, password: nil, job: ExportJob()) { p, _ in if let p { pcts.append(p) } }
let asked1 = (try? String(contentsOfFile: T + "/backup/restore-request.txt")) ?? ""
let r2 = Backup.restore(secureEntry, to: dev, tools: rt, password: nil, job: ExportJob()) { _, _ in }
let r3 = Backup.restore(secureEntry, to: dev, tools: rt, password: "correct horse", job: ExportJob()) { _, _ in }
let asked3 = (try? String(contentsOfFile: T + "/backup/restore-request.txt")) ?? ""
setenv("FAKE_FINDMY", "1", 1)
let r4 = Backup.restore(plainEntry, to: dev, tools: rt, password: nil, job: ExportJob()) { _, _ in }
unsetenv("FAKE_FINDMY")
setenv("FAKE_REFUSED", "1", 1)
let r5 = Backup.restore(plainEntry, to: dev, tools: rt, password: nil, job: ExportJob()) { _, _ in }
unsetenv("FAKE_REFUSED")
check("restore asks the tool correctly and explains failures", blank, copied: 0, skipped: 0, failed: 0,
      extra: r1 == nil && pcts.last == 1 && asked1.contains("--source 0000-TEST restore --system --settings --reboot") && asked1.contains("password=none")
        && !asked1.contains("--remove") && r2?.contains("password") == true && r3 == nil && asked3.contains("--source 0000-SECURE") && asked3.contains("password=correct horse")
        && !asked3.components(separatedBy: " | ")[0].contains("correct horse") && r4?.contains("Find My") == true && r5?.contains("ErrorCode 211") == true && r5?.contains("Find My") == true)
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
