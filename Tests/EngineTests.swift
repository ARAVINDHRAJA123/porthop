import Foundation
import ImageIO
import CryptoKit
import AVFoundation
import CoreMedia
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
check("people named in Photos become groups", ExportSummary(destination: URL(fileURLWithPath: "/")), copied: 0, skipped: 0, failed: 0,
      extra: cat.people.map(\.title) == ["Mum", "Ravi Kumar"] && cat.people.map(\.assets.count) == [4, 3] && cat.people[0].id == "person:mum")
let hiddenIDs = Set(hidden.map(\.id))
check("hidden items appear only in Hidden", ExportSummary(destination: URL(fileURLWithPath: "/")), copied: 0, skipped: 0, failed: 0,
      extra: !(cat.smart.dropFirst() + cat.user).contains { $0.id != "smart_trashed" && $0.assets.contains { hiddenIDs.contains($0.id) } })
check("first export", run("out1"), copied: 38, skipped: 0, failed: 1)
check("run again", run("out1"), copied: 0, skipped: 38, failed: 1)
// Edited versions: IMG_0002 comes out as its rendered edit; IMG_0003 (render missing) and the rest stay originals.
do {
    var o = ExportOptions(); o.editedVersions = true
    let flagsOK = hidden.filter(\.isEdited).map(\.filename).sorted() == ["IMG_0002.JPG", "IMG_0003.JPG"]
        && hidden.filter(\.isCloudOnly).map(\.filename) == ["IMG_9000.HEIC"]
    let s = run("edited", o)
    let edited = (try? Data(contentsOf: URL(fileURLWithPath: T + "/edited/IMG_0002.jpg")))?.suffix(6) == Data("EDITED".utf8)
    let original = FileManager.default.fileExists(atPath: T + "/edited/IMG_0003.JPG")
    check("edited versions and iCloud-only flags", s, copied: 38, skipped: 0, failed: 1, extra: flagsOK && edited && original)
}
// File-name pattern, location removal and the copy report.
do {
    var o = ExportOptions(); o.namePattern = "{year}-{month}-{day} {hour}.{minute}.{second}"; o.removeLocation = true; o.albumName = "Hidden"
    let s = run("named", o)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: T + "/named")) ?? []
    let named = files.filter { $0.range(of: #"^\d{4}-\d\d-\d\d \d\d\.\d\d\.\d\d( \(\d+\))?\.(JPG|MOV|HEIC)$"#, options: [.regularExpression, .caseInsensitive]) != nil }
    let reports = (try? FileManager.default.contentsOfDirectory(atPath: T + "/named/PortHop Reports")) ?? []
    let csv = reports.first.flatMap { try? String(contentsOfFile: T + "/named/PortHop Reports/" + $0, encoding: .utf8) } ?? ""
    check("file-name pattern + copy report", s, copied: 38, skipped: 0, failed: 1,
          extra: named.count == 38 && reports.count == 1 && csv.contains("Copied,38") && csv.contains("Only in iCloud,1") && csv.contains("IMG_9000.HEIC") && s.reportURL != nil)
    o.removeLocation = false
    let again = run("named", o)
    let reports2 = (try? FileManager.default.contentsOfDirectory(atPath: T + "/named/PortHop Reports")) ?? []
    check("renamed copies are recognised next time", again, copied: 0, skipped: 38, failed: 1, extra: reports2.count == 2)
}
// Remove location: the shared files in golden/location, and real JPEG, HEIC and MOV files written by Apple's frameworks.
do {
    let golden = FileManager.default.currentDirectoryPath + "/golden/location"
    let work = T + "/location"; try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
    let expect = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: golden + "/expect.json")))) as? [[String: Any]] ?? []
    var problems: [String] = []
    for e in expect {
        let name = e["file"] as! String, url = URL(fileURLWithPath: work + "/" + name)
        try? FileManager.default.removeItem(at: url); try? FileManager.default.copyItem(atPath: golden + "/" + name, toPath: url.path)
        let before = (try? Data(contentsOf: url))?.count ?? 0
        let ok = LocationScrubber.scrub(url)
        let after = (try? Data(contentsOf: url)) ?? Data()
        func has(_ s: String) -> Bool { after.range(of: s.data(using: .isoLatin1)!) != nil }
        let left = (e["gone"] as! [String]).filter(has), lost = (e["kept"] as! [String]).filter { !has($0) }
        if !ok || before != after.count || !left.isEmpty || !lost.isEmpty { problems.append("\(name): scrubbed \(ok), still there \(left), lost \(lost)") }
    }
    // Real files: ImageIO must find no GPS afterwards, and the picture must still decode.
    for (name, type) in [("real.jpg", "public.jpeg"), ("real.heic", "public.heic")] {
        let url = URL(fileURLWithPath: work + "/" + name)
        let ctx = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { problems.append("\(name): not written"); continue }
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 12.3456, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 65.4321, kCGImagePropertyGPSLongitudeRef: "E"]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGPSDictionary: gps] as CFDictionary); CGImageDestinationFinalize(dest)
        let ok = LocationScrubber.scrub(url)
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)
        let props = src.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
        let still = (props?[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude] != nil
        if !ok || still || src.flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) == nil { problems.append("\(name): scrubbed \(ok), GPS still there \(still)") }
    }
    for p in problems { print("  ", p) }
    check("remove location (JPEG, HEIC, MOV; shared and real files)", ExportSummary(destination: URL(fileURLWithPath: "/")), copied: 0, skipped: 0, failed: 0, extra: problems.isEmpty && expect.count == 3)
}
// Custom folder pattern: {year}/{month} {monthName}.
do {
    var o = ExportOptions(); o.subfolder = .custom; o.folderPattern = "{album}/{year}/{month} {monthName}"; o.albumName = "Hidden"
    let s = run("pattern", o)
    let years = (try? FileManager.default.contentsOfDirectory(atPath: T + "/pattern/Hidden")) ?? []
    let months = years.first.flatMap { try? FileManager.default.contentsOfDirectory(atPath: T + "/pattern/Hidden/" + $0) } ?? []
    check("custom folder pattern", s, copied: 38, skipped: 0, failed: 1,
          extra: years.allSatisfy { $0.count == 4 && Int($0) != nil } && months.contains { $0.range(of: #"^\d\d [A-Z][a-z]+$"#, options: .regularExpression) != nil })
}
// HEIC → JPEG in-process: a real HEIC from macOS converts to a JPEG of the same size.
do {
    let heic = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Mac Blue.heic"), jpg = URL(fileURLWithPath: T + "/converted.jpg")
    let ok = FileManager.default.fileExists(atPath: heic.path) ? Exporter.heicToJPEG(heic, jpg) : true
    let size = { (u: URL) -> [Int] in
        guard let s = CGImageSourceCreateWithURL(u as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return [] }
        return [p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0] }
    let same = !FileManager.default.fileExists(atPath: heic.path) || (size(jpg) == size(heic) && !size(jpg).isEmpty)
    check("HEIC converts to JPEG in-process", ExportSummary(destination: URL(fileURLWithPath: "/")), copied: 0, skipped: 0, failed: 0, extra: ok && same)
}
// The Windows edition's older manifest was a list; the Mac must still recognise everything in it.
let mfURL = URL(fileURLWithPath: T + "/out1/.porthop-manifest.json")
if let obj = try? JSONSerialization.jsonObject(with: Data(contentsOf: mfURL)) as? [String: Any],
   let list = try? JSONSerialization.data(withJSONObject: Array(obj.values)) { try? list.write(to: mfURL) }
check("reads a Windows-style manifest", run("out1"), copied: 0, skipped: 38, failed: 1,
      extra: ((try? JSONSerialization.jsonObject(with: Data(contentsOf: mfURL))) as? [String: Any])?.count == 38)
try? FileManager.default.removeItem(atPath: T + "/out1/.porthop-manifest.json")
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
let w1 = Android.wireless(pair: "192.168.1.20:37001", code: "123 456", connect: "192.168.1.20:41235", tools: at)
let w2 = Android.wireless(pair: "192.168.1.20:37001", code: "111111", connect: "192.168.1.20:41235", tools: at)
let w3 = Android.wireless(pair: "", code: "", connect: "192.168.1.20:5555", tools: at)
let w4 = Android.wireless(pair: "", code: "", connect: "not an address; rm -rf", tools: at)
check("android wireless debugging pair and connect", ExportSummary(destination: URL(fileURLWithPath: "/")), copied: 0, skipped: 0, failed: 0,
      extra: w1 == nil && w2?.contains("Pairing didn't work") == true && w3?.contains("didn't answer") == true && w4?.contains("Enter the address") == true)
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
let mediaAlbums = Android.mediaAlbums(ad, tools: at)
check("android albums from MediaStore", blank, copied: 0, skipped: 0, failed: 0,
      extra: mediaAlbums.map(\.path).sorted() == ["/sdcard/DCIM/Camera", "/sdcard/Pictures/It's here"]
        && mediaAlbums.allSatisfy { $0.count == 1 && $0.bytes == AFC.fileSize(local) }
        && Android.parseMediaAlbums("Row: 0 _data=/storage/1234-ABCD/DCIM/x.jpg, _size=5\nRow: 1 _data=/sdcard/Movies/a, b.mp4, _size=9").map(\.name) == ["Movies"])
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
// Chats as web pages: the attached photo is copied next to the page and shown in it.
do {
    let out = URL(fileURLWithPath: T + "/pages")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let p1 = bk.webPage(msg[1], title: "Messages", into: out), p2 = bk.webPage(wa[0], title: "WhatsApp", into: out)
    let h1 = p1.flatMap { try? String(contentsOf: $0) } ?? "", h2 = p2.flatMap { try? String(contentsOf: $0) } ?? ""
    let a1 = p1.map { $0.deletingLastPathComponent().appendingPathComponent("attachments/IMG_5001.jpeg") }
    let a2 = p2.map { $0.deletingLastPathComponent().appendingPathComponent("attachments/photo1.jpg") }
    check("chats saved as web pages with attachments", blank, copied: 0, skipped: 0, failed: 0,
          extra: msg[1].media[4] == [BackupFileRef(domain: "MediaDomain", path: "Library/SMS/Attachments/ab/12/GUID-1/IMG_5001.jpeg")]
            && h1.contains("<img src=\"attachments/IMG_5001.jpeg\"") && h1.contains("Hi &quot;Asha&quot;, how are you?") && a1.map { AFC.fileSize($0) > 0 } == true
            && h2.contains("attachments/photo1.jpg") && a2.map { AFC.fileSize($0) > 0 } == true && p1?.deletingLastPathComponent().lastPathComponent == "Asha Rao (Messages)")
}
let people = tree(.contacts)[0].rows, notes = tree(.notes)[0].rows, cals = tree(.calendar), web = tree(.safari)
check("backup contacts, notes, calendar, safari", blank, copied: 0, skipped: 0, failed: 0,
      extra: people.count == 3 && people.contains(["Asha Rao", "", "(415) 555-0101", "asha@example.com"]) && notes.map { $0[0] } == ["Ideas", "Shopping"]
        && cals.count == 2 && cals.first { $0.title == "Home" }?.rows[0][2] == "All day" && web.map(\.title) == ["Bookmarks", "History"] && web[0].rows.count == 1 && web[1].rows.count == 2)
// Backup extras: full note text, voice memos, photos and videos, contacts as vCard and calendars as .ics.
do {
    let fullNote = notes.first { $0[0] == "Shopping" }?[1] ?? "", locked = notes.first { $0[0] == "Ideas" }?[1] ?? ""
    let memos = tree(.voiceMemos), roll = tree(.photos)
    try? FileManager.default.createDirectory(atPath: T + "/memos", withIntermediateDirectories: true)
    let pulled = memos.first.map { bk.extract($0, rows: Array($0.rows.indices), to: URL(fileURLWithPath: T + "/memos")) } ?? []
    let vcf = bk.vCard() ?? "", ics = bk.iCalendar() ?? ""
    check("backup extras: note text, voice memos, photos, vCard, ics", blank, copied: 0, skipped: 0, failed: 0,
          extra: fullNote == "Shopping\nMilk, eggs, bread\nAsk about the café ☕" && locked == "App names"
            && memos.first?.rows.map { $0[0] } == ["Lecture- week 3.m4a", "Song idea.m4a"] && memos.first?.rows[1][2] == "1:05"
            && pulled.map(\.lastPathComponent).sorted() == ["Lecture- week 3.m4a", "Song idea.m4a"] && AFC.fileSize(pulled[0]) == 700
            && roll.map(\.title) == ["100APPLE", "101APPLE"] && roll[1].rows == [["IMG_0050.MOV", "Video"]]
            && vcf.components(separatedBy: "BEGIN:VCARD").count == 4 && vcf.contains("N:Rao;Asha;;;\r\nFN:Asha Rao\r\nTEL;TYPE=VOICE:(415) 555-0101\r\nEMAIL;TYPE=INTERNET:asha@example.com")
            && vcf.contains("FN:City Garage\r\nORG:City Garage")
            && ics.hasPrefix("BEGIN:VCALENDAR\r\n") && ics.components(separatedBy: "BEGIN:VEVENT").count == 4 && ics.contains("SUMMARY:Birthday")
            && ics.contains("DTSTART;VALUE=DATE:") && ics.hasSuffix("END:VCALENDAR\r\n"))
}
let noCalls = bk.load(.calls)
let fg = tree(.files)
let roll = fg.first { $0.subtitle == "CameraRollDomain" }!
try! FileManager.default.createDirectory(atPath: T + "/bkout", withIntermediateDirectories: true)
let ex1 = bk.extract(roll, rows: [0], to: URL(fileURLWithPath: T + "/bkout")), ex2 = bk.extract(roll, rows: [0], to: URL(fileURLWithPath: T + "/bkout"))
let csv = BackupReader.csv(msg[1])
check("backup files, extract, csv", blank, copied: 0, skipped: 0, failed: 0,
      extra: noCalls.groups.isEmpty && noCalls.note.contains("encrypted") && fg.count == 8 && roll.title == "Camera Roll" && roll.rows.first == ["IMG_0001.JPG", "Media/DCIM/100APPLE"] && roll.rows.count == 2
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
// Earlier versions: before a backup, the previous one is kept as an APFS clone, listed like a backup; the newest 7 stay.
do {
    let root = URL(fileURLWithPath: T + "/snapshots"), udid = "00008110-TESTSNAP"
    let cur = root.appendingPathComponent(udid)
    try? FileManager.default.createDirectory(at: cur, withIntermediateDirectories: true)
    try? Data("db".utf8).write(to: cur.appendingPathComponent("Manifest.db"))
    var made: [URL] = []
    for day in 1...9 {
        let info: [String: Any] = ["Device Name": "Snap Phone", "Last Backup Date": Date(timeIntervalSince1970: 1_780_000_000 + Double(day) * 86_400)]
        try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: cur.appendingPathComponent("Info.plist"))
        if let s = Backup.snapshot(udid: udid, in: root) { made.append(s) }
    }
    let again = Backup.snapshot(udid: udid, in: root)
    let kept = (try? FileManager.default.contentsOfDirectory(atPath: root.path + "/PortHop Snapshots/" + udid)) ?? []
    let listed = Backup.existing(in: root)
    check("earlier versions kept as snapshots", blank, copied: 0, skipped: 0, failed: 0,
          extra: made.count == 9 && again?.path == made.last?.path && kept.count == 7 && listed.count == 8 && listed.first?.isSnapshot == false
            && listed.filter(\.isSnapshot).count == 7 && FileManager.default.fileExists(atPath: (made.last?.path ?? "") + "/Manifest.db")
            && made.last?.lastPathComponent == udid)
}
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
// Shared cases (Tests/golden), also run by the Windows edition's test/golden.js.
do {
    let golden = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/golden")
    let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.locale = Locale(identifier: "en_US_POSIX")
    func json(_ name: String) -> [[String: Any]] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: golden.appendingPathComponent(name)))) as? [[String: Any]] ?? [] }
    var askFails: [String] = []
    let askCases = json("ask.json")
    for c in askCases {
        let ctx = c["context"] as? [String: Any] ?? [:]
        var context = AskContext()
        context.isAndroid = ctx["isAndroid"] as? Bool ?? false
        context.userAlbums = (ctx["userAlbums"] as? [[String: String]] ?? []).map { ($0["id"]!, $0["title"]!) }
        context.people = (ctx["people"] as? [[String: String]] ?? []).map { ($0["id"]!, $0["title"]!) }
        context.albums = context.userAlbums + context.people
        context.destinations = (ctx["destinations"] as? [[String: String]] ?? []).map {
            Destination(id: $0["name"]!, kind: $0["kind"] == "pictures" ? .pictures : ($0["kind"] == "drive" ? .drive : .recent),
                        name: $0["name"]!, detail: "", url: URL(fileURLWithPath: "/tmp/" + $0["name"]!))
        }
        let i = AskParser.parse(c["text"] as! String, context)
        let e = c["expect"] as? [String: Any] ?? [:]
        var got: [String: Any] = [:]
        if let v = i.route { got["route"] = v }
        if let v = i.album { got["album"] = v }
        if let v = i.filter { got["filter"] = String(describing: v) }
        if let r = i.range { got["from"] = day.string(from: r.lowerBound); got["to"] = day.string(from: r.upperBound) }
        if i.minBytes > 0 { got["minBytes"] = Int(i.minBytes) }
        if let d = i.destination { got["dest"] = d.name }
        if NSDictionary(dictionary: got) != NSDictionary(dictionary: e) { askFails.append("\(c["text"]!): got \(got), expected \(e)") }
    }
    for f in askFails { print("  ", f) }
    check("shared Ask cases (\(askCases.count))", blank, copied: 0, skipped: 0, failed: 0, extra: !askCases.isEmpty && askFails.isEmpty)

    var patFails: [String] = []
    let patCases = json("patterns.json")
    for c in patCases {
        let t = (c["time"] as? String ?? "12:00:00").split(separator: ":").compactMap { Double($0) }
        let date = day.date(from: c["date"] as! String)!.addingTimeInterval(t[0] * 3600 + t[1] * 60 + t[2])
        let filename = c["filename"] as? String ?? "IMG_0001.JPG"
        let a = PhotoAsset(id: 1, uuid: "", directory: c["directory"] as! String, filename: filename, originalFilename: "", fileSize: 1, width: 1, height: 1,
                           duration: 0, isHidden: false, isFavorite: false, isTrashed: false, isVideo: c["video"] as? Bool ?? false,
                           isScreenshot: c["screenshot"] as? Bool ?? false, isSelfie: false,
                           isLivePhoto: false, dateCreated: date, dateText: "", searchKey: "")
        let device = c["device"] as? String ?? ""
        if let name = c["name"] as? String {
            let got = Pattern.fileStem(name, a, album: c["album"] as! String, device: device, original: filename)
            let want = c["expectName"] as? String
            if got != want { patFails.append("name \(name): got \(got ?? "nil"), expected \(want ?? "nil")") }
        } else {
            let got = SubfolderMode.folder(c["pattern"] as! String, a, album: c["album"] as! String, device: device)
            if got != c["expect"] as! String { patFails.append("\(c["pattern"]!): got \(got), expected \(c["expect"]!)") }
        }
    }
    for f in patFails { print("  ", f) }
    check("shared folder-pattern cases (\(patCases.count))", blank, copied: 0, skipped: 0, failed: 0, extra: !patCases.isEmpty && patFails.isEmpty)

    let versionCases = json("versions.json")
    let versionFails = versionCases.filter { Updates.isNewer($0["candidate"] as! String, than: $0["current"] as! String) != ($0["newer"] as! Bool) }
    for f in versionFails { print("  ", f) }
    check("shared update-version cases (\(versionCases.count))", blank, copied: 0, skipped: 0, failed: 0, extra: !versionCases.isEmpty && versionFails.isEmpty)
}

// MARK: Phase 7: spyware check, phone screen, music, apps, sending to Android, removing copied items, updates
let g7 = FileManager.default.currentDirectoryPath + "/golden"
func golden(_ path: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: g7 + "/" + path)))) as? [String: Any] ?? [:]
}
func rows(_ v: Any?) -> Set<String> { Set(((v as? [[String]]) ?? []).map { $0.joined(separator: "|") }) }
setenv("FAKE_ANDROID", droid, 1)
setenv("FAKE_ANDROID_LOG", T + "/adb.log", 1)
do {
    let x = golden("spyware/expect.json")
    var set = Spyware.Indicators()
    for i in Spyware.parseSTIX(try! Data(contentsOf: URL(fileURLWithPath: g7 + "/spyware/indicators.stix2")), source: "Test lab") { set.add(i) }
    let index = Spyware.parseIndex(try! String(contentsOfFile: g7 + "/spyware/index.yaml", encoding: .utf8)).map { [$0.name, $0.url] }
    var found = Set<String>(), html = ""
    if case .ready(let r) = BackupReader.open(folder: URL(fileURLWithPath: T + "/spybackup/0000-SPY"), password: nil) {
        let rep = Spyware.scan(backup: r, with: set)
        found = Set(rep.findings.map { "\($0.area)|\($0.found)|\($0.indicator.malware)" })
        html = Spyware.html(rep, device: "Test iPhone", source: "from a backup")
    }
    if found != rows(x["backup"]) { print("  spyware: got", found.sorted(), "missing", rows(x["backup"]).subtracting(found).sorted()) }
    var clean = false
    if case .ready(let r) = BackupReader.open(folder: URL(fileURLWithPath: T + "/backup/0000-TEST"), password: nil) { clean = Spyware.scan(backup: r, with: set).findings.isEmpty }
    let folder = URL(fileURLWithPath: T + "/indicators")
    let added = Spyware.add(file: URL(fileURLWithPath: g7 + "/spyware/indicators.stix2"), to: folder) == nil && Spyware.load(from: folder).count == 17
        && Spyware.add(file: URL(fileURLWithPath: g7 + "/spyware/expect.json"), to: folder) != nil
    check("spyware check of an iPhone backup (shared cases)", blank, copied: 0, skipped: 0, failed: 0,
          extra: set.count == x["indicators"] as? Int && index == x["index"] as? [[String]] && found == rows(x["backup"]) && clean && added
            && html.contains("14 matches") && html.contains("securitylab.amnesty.org"))
    let a = Spyware.scan(android: ad, tools: at, with: set)
    let aFound = Set(a.findings.map { "\($0.area)|\($0.found)|\($0.indicator.malware)" })
    let review = Dictionary(uniqueKeysWithValues: a.review.map { ($0.title, $0.apps) })
    check("spyware check of an Android phone: apps, programs, special access", blank, copied: 0, skipped: 0, failed: 0,
          extra: aFound == rows(x["android"]) && review == x["androidReview"] as? [String: [String]] && a.warnings.count == x["androidWarnings"] as? Int)
}
do {
    let x = golden("screen/expect.json")
    let data = try! Data(contentsOf: URL(fileURLWithPath: g7 + "/screen/stream.h264"))
    let parser = AnnexB()
    var frames: [AnnexB.Frame] = []
    let chunk = x["chunk"] as! Int
    var at0 = 0
    while at0 < data.count { frames += parser.append(data.subdata(in: at0..<min(at0 + chunk, data.count))); at0 += chunk }
    frames += parser.finish()
    let fmt = parser.sps.flatMap { s in parser.pps.flatMap { AnnexB.format(sps: s, pps: $0) } }
    let dims = fmt.map(CMVideoFormatDescriptionGetDimensions)
    let decoded = fmt.map { AnnexB.decodedCount(frames, format: $0) } ?? 0
    let parsed = frames.count == x["frames"] as? Int && frames.filter(\.isKey).count == x["keyFrames"] as? Int && Int(dims?.width ?? 0) == x["width"] as? Int
        && Int(dims?.height ?? 0) == x["height"] as? Int && AnnexB.codec(sps: parser.sps ?? Data()) == x["codec"] as? String && decoded == frames.count
    // Live: the fake phone's stream through the real pipeline, then recorded to a movie as it arrives.
    let screen = AndroidScreen(device: ad, tools: at)
    var size = CGSize.zero
    screen.onSize = { size = $0 }
    screen.start()
    var until = Date().addingTimeInterval(15)
    while size == .zero && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let movie = URL(fileURLWithPath: T + "/screen.mp4")
    let recording = screen.startRecording(to: movie)
    RunLoop.main.run(until: Date().addingTimeInterval(2))
    var saved: URL?, stopped = false
    screen.stopRecording { saved = $0; stopped = true }
    until = Date().addingTimeInterval(15)
    while !stopped && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    screen.stop()
    let tracks = saved.map { AVURLAsset(url: $0).tracks(withMediaType: .video).count } ?? 0
    let shot = AndroidScreen.screenshot(device: ad, tools: at, to: URL(fileURLWithPath: T + "/shot.png"))
    if !parsed || size.width != 320 || !recording || tracks != 1 || !shot { print("  screen", parsed, frames.count, decoded, size, recording, tracks, shot) }
    check("phone screen: stream split, decoded, shown, recorded; screenshot", blank, copied: 0, skipped: 0, failed: 0,
          extra: parsed && size == CGSize(width: 320, height: 640) && recording && tracks == 1 && shot)
}
do {
    let want = (golden("music/expect.json")["songs"] as? [[String: Any]] ?? []).map {
        "\($0["title"]!)|\($0["savedPath"]!)|\(($0["canCopy"] as? Bool) == true)|\($0["size"]!)"
    }
    let (songs, problem) = MusicLibrary.load(device: dev, tools: tools)
    let got = songs.map { "\($0.title)|\($0.savedPath)|\($0.canCopy)|\($0.size)" }
    if got != want { print("  music got", got) }
    let out = URL(fileURLWithPath: T + "/music-out"), job = ExportJob()
    let first = MusicLibrary.copy(songs, to: out, device: dev, tools: tools, job: job) { _, _, _ in }
    let again = MusicLibrary.copy(songs, to: out, device: dev, tools: tools, job: job) { _, _, _ in }
    let sent = MusicLibrary.send(songs.filter { $0.title == "Morning" || $0.title == "Old Phone" }, from: dev, toAndroid: ad, tools: at, job: job) { _, _, _ in }
    check("music: library read, copied by artist and album, sent to Android (shared cases)", blank, copied: 0, skipped: 0, failed: 0,
          extra: problem == nil && got == want && first.copied == 5 && first.failed.count == 2 && again.skipped == 5 && again.copied == 0
            && AFC.fileSize(out.appendingPathComponent("AC-DC/Live- Wire-/2-07 Back in Black.m4a")) == 61000 && sent.copied == 2
            && FileManager.default.fileExists(atPath: droid + "/Music/Asha Band/First Light/02 Morning.mp3")
            && FileManager.default.fileExists(atPath: droid + "/Ringtones/Old Phone.m4r"))
    // A ringtone from any sound file: 3 seconds from a 6-second recording.
    let rate = 22050, count = rate * 6
    var wav = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 2)) }
    wav.append(Data("RIFF".utf8)); u32(UInt32(36 + count * 2)); wav.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
    wav.append(Data("data".utf8)); u32(UInt32(count * 2))
    for i in 0..<count { u16(UInt16(bitPattern: Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 8000))) }
    let src = URL(fileURLWithPath: T + "/tone-src.wav"), tone = URL(fileURLWithPath: T + "/My Tone.m4r")
    try! wav.write(to: src)
    let done = DispatchSemaphore(value: 0)
    var toneProblem: String? = "not run", toneLength = 0.0
    Task.detached { toneProblem = await RingtoneMaker.make(from: src, start: 1, length: 3, to: tone); toneLength = await RingtoneMaker.duration(of: tone); done.signal() }
    done.wait()
    check("ringtone made from a sound file (3 s, .m4r)", blank, copied: 0, skipped: 0, failed: 0, extra: toneProblem == nil && abs(toneLength - 3) < 0.3)
}
do {
    let ios = AppManager.list(device: dev, tools: tools) ?? []
    let ipa = URL(fileURLWithPath: T + "/My App.ipa"), unsigned = URL(fileURLWithPath: T + "/unsigned.ipa"), apk = URL(fileURLWithPath: T + "/app.apk"), old = URL(fileURLWithPath: T + "/old.apk")
    for f in [ipa, unsigned, apk, old] { try? Data("x".utf8).write(to: f) }
    var percents: [Int] = []
    let i1 = AppManager.install(ipa, device: dev, tools: tools) { percents.append($0) }
    let i2 = AppManager.install(unsigned, device: dev, tools: tools) { _ in }
    let u1 = AppManager.uninstall("com.example.player", device: dev, tools: tools), u2 = AppManager.uninstall("com.example.reader", device: dev, tools: tools)
    let droidApps = AppManager.list(device: ad, tools: at) ?? []
    let a1 = AppManager.install(apk, device: ad, tools: at) { _ in }, a2 = AppManager.install(old, device: ad, tools: at) { _ in }
    let a3 = AppManager.install(ipa, device: ad, tools: at) { _ in }
    let a4 = AppManager.uninstall("com.fake.stalker2", device: ad, tools: at), a5 = AppManager.uninstall("com.android.chrome", device: ad, tools: at)
    let w0 = WiFiSync.state(device: dev, tools: tools), w1 = WiFiSync.state(device: dev, tools: tools, set: true), w2 = WiFiSync.state(device: dev, tools: tools)
    let appsOK = ios.map(\.name) == ["Book Reader", "Movie Player", "Tabs & Notes"] && ios.first { $0.id == "com.example.player" }?.bytes == 1_048_576
        && i1 == nil && percents.last == 100 && i2?.contains("not signed for this iPhone") == true && u1 == nil && u2?.contains("cannot be removed") == true
        && droidApps.map(\.id) == ["com.example.app", "com.fake.stalker2"] && droidApps.first?.version == "1.2" && droidApps.first?.bytes == 2020
        && a1 == nil && a2?.contains("newer version") == true && a3?.contains(".apk") == true && a4 == nil && a5?.contains("cannot be removed") == true
    if !appsOK { print("  apps", ios.map(\.name), i1 ?? "-", percents, i2 ?? "-", u1 ?? "-", u2 ?? "-", droidApps, a1 ?? "-", a2 ?? "-", a3 ?? "-", a4 ?? "-", a5 ?? "-") }
    check("apps: list, install and remove on iPhone and Android; Wi-Fi backup setting", blank, copied: 0, skipped: 0, failed: 0,
          extra: appsOK && w0 == false && w1 == true && w2 == true)
}
do {
    func asset(_ id: Int64, _ dir: String, _ name: String, _ size: Int64, live: Bool = false) -> PhotoAsset {
        PhotoAsset(id: id, uuid: "", directory: dir, filename: name, originalFilename: "", fileSize: size, width: 1, height: 1, duration: 0,
                   isHidden: false, isFavorite: false, isTrashed: false, isVideo: false, isScreenshot: false, isSelfie: false,
                   isLivePhoto: live, dateCreated: nil, dateText: "", searchKey: "")
    }
    let a1 = asset(1, "DCIM/100APPLE", "IMG_0001.HEIC", 1000), a2 = asset(2, "DCIM/100APPLE", "IMG_0002.JPG", 500)
    let a3 = asset(3, "DCIM/101APPLE", "IMG_0003.HEIC", 800, live: true), a4 = asset(4, "DCIM/100APPLE", "IMG_0004.JPG", 700)
    let files = [Cleanup.CameraFile(folder: "100APPLE", name: "IMG_0001.JPG", size: 640), Cleanup.CameraFile(folder: "100APPLE", name: "IMG_0002.JPG", size: 500),
                 Cleanup.CameraFile(folder: "101APPLE", name: "IMG_0003.HEIC", size: 800), Cleanup.CameraFile(folder: "101APPLE", name: "IMG_0003.MOV", size: 90),
                 Cleanup.CameraFile(folder: "100APPLE", name: "IMG_0004.JPG", size: 699), Cleanup.CameraFile(folder: "101APPLE", name: "IMG_0002.JPG", size: 500)]
    let pick1 = Cleanup.deletable([a1, a2, a3, a4], files: files, liveVideos: true).map { "\($0.folder)/\($0.name)" }
    let pick2 = Cleanup.deletable([a3], files: files, liveVideos: false).map { "\($0.folder)/\($0.name)" }
    let a5 = asset(5, "DCIM/102APPLE", "IMG_0005.HEIC", 900)
    let pick3 = Cleanup.deletable([a5], files: [Cleanup.CameraFile(folder: "102APPLE", name: "IMG_0005.HEIC", size: 900),
                                                Cleanup.CameraFile(folder: "102APPLE", name: "IMG_0005.JPG", size: 300)], liveVideos: false).map(\.name)
    let dest = URL(fileURLWithPath: T + "/cleanup")
    try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    try? Data(count: 1000).write(to: dest.appendingPathComponent("a1.HEIC")); try? Data(count: 499).write(to: dest.appendingPathComponent("a2.JPG"))
    try? Data(count: 800).write(to: dest.appendingPathComponent("a3.HEIC"))
    var s = ExportSummary(destination: dest)
    s.report = [ReportLine(status: .copied, asset: a1, savedAs: "a1.HEIC", note: ""), ReportLine(status: .copied, asset: a2, savedAs: "a2.JPG", note: ""),
                ReportLine(status: .skipped, asset: a3, savedAs: "a3.HEIC", note: ""), ReportLine(status: .failed, asset: a4, savedAs: "", note: "x")]
    var opts = ExportOptions()
    let c1 = Cleanup.confirmed(s, options: opts).map(\.id)
    opts.includeLiveVideo = true
    let c2 = Cleanup.confirmed(s, options: opts).map(\.id)
    try? FileManager.default.createDirectory(atPath: droid + "/DCIM/Trip/sub", withIntermediateDirectories: true)
    try? Data(count: 300).write(to: URL(fileURLWithPath: droid + "/DCIM/Trip/a.jpg")); try? Data(count: 400).write(to: URL(fileURLWithPath: droid + "/DCIM/Trip/sub/b.jpg"))
    let trip = URL(fileURLWithPath: T + "/trip-copy")
    let pulled = Android.pull("/sdcard/DCIM/Trip", to: trip, device: ad, tools: at)
    try? Data(count: 10).write(to: trip.appendingPathComponent("sub/b.jpg"))   // a bad copy: that photo must stay on the phone
    let sure = Cleanup.androidConfirmed([Cleanup.AndroidPair(remote: "/sdcard/DCIM/Trip", local: trip)], device: ad, tools: at).map(\.path)
    let gone = Android.delete(sure, device: ad, tools: at)
    check("removing copied items: only confirmed copies, matched to the phone's own files", blank, copied: 0, skipped: 0, failed: 0,
          extra: pick1 == ["100APPLE/IMG_0001.JPG", "100APPLE/IMG_0002.JPG", "101APPLE/IMG_0003.HEIC", "101APPLE/IMG_0003.MOV"]
            && pick2 == ["101APPLE/IMG_0003.HEIC"] && pick3 == ["IMG_0005.HEIC"] && c1 == [1] && c2 == [1, 3] && pulled && sure == ["/sdcard/DCIM/Trip/a.jpg"] && gone == sure
            && !FileManager.default.fileExists(atPath: droid + "/DCIM/Trip/a.jpg") && FileManager.default.fileExists(atPath: droid + "/DCIM/Trip/sub/b.jpg"))
}
do {
    let staging = URL(fileURLWithPath: T + "/hop-staging")
    var o = ExportOptions()
    o.convertHEIC = true
    o.saveReport = false
    let few = Array(hidden.filter { $0.filename.hasPrefix("IMG_00") && !$0.isVideo }.prefix(5))
    let r = Exporter.run(assets: few, destination: staging, options: o, device: dev, tools: tools, job: ExportJob()) { _ in }
    let job = ExportJob()
    let s1 = Android.sendFolder(staging, to: "/sdcard/DCIM/PortHop/Hidden", phone: ad, tools: at, job: job) { _, _ in }
    let s2 = Android.sendFolder(staging, to: "/sdcard/DCIM/PortHop/Hidden", phone: ad, tools: at, job: job) { _, _ in }
    let onPhone = ((try? FileManager.default.contentsOfDirectory(atPath: droid + "/DCIM/PortHop/Hidden")) ?? []).filter { !$0.hasPrefix(".") }.count
    let scans = ((try? String(contentsOfFile: T + "/adb.log", encoding: .utf8)) ?? "").components(separatedBy: "scan /sdcard/DCIM/PortHop/Hidden/").count - 1
    if !(r.copied == 5 && s1.sent == 5 && s2.already == 5 && onPhone == 5 && scans == 5) { print("  hop", r.copied, r.failures.map(\.reason), s1, s2, onPhone, scans) }
    check("iPhone to Android: copied off the iPhone, sent to the phone's camera folder, Gallery told", blank, copied: 0, skipped: 0, failed: 0,
          extra: r.copied == 5 && s1.sent == 5 && s1.already == 0 && s2.sent == 0 && s2.already == 5 && onPhone == 5 && scans == 5)
}
do {
    var d = DeviceDetails()
    d.info = [InfoRow(label: "Model", value: "iPhone17,1", symbol: "cpu"), InfoRow(label: "IMEI", value: "35 000000 000000 0", symbol: "simcard")]
    d.batteryHealth = 91
    d.cycleCount = 312
    d.totalDiskBytes = 256_000_000_000
    d.freeDiskBytes = 56_000_000_000
    let page = PhoneReport.html(name: "Asha's iPhone", details: d, isAndroid: false)
    let key = Data(base64Encoded: (try! String(contentsOfFile: g7 + "/update/test-key.pub", encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
    let data = try! Data(contentsOf: URL(fileURLWithPath: g7 + "/update/sample.bin")), sig = try! Data(contentsOf: URL(fileURLWithPath: g7 + "/update/sample.bin.sig"))
    var tampered = data
    tampered[10] ^= 1
    let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    // A release zip holding PortHop.app: accepted only with the right identity and version.
    let app = URL(fileURLWithPath: T + "/upd/PortHop.app")
    try? FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try? FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/PortHop").path)
    (["CFBundleIdentifier": "io.github.aravindhraja123.porthop", "CFBundleShortVersionString": "9.9.9", "CFBundleExecutable": "PortHop",
      "CFBundlePackageType": "APPL"] as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    _ = Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    let zip = URL(fileURLWithPath: T + "/upd/PortHop-9.9.9-mac.zip")
    _ = Shell.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
    let unpacked = Updates.unpack(zip, expecting: "9.9.9", bundleID: "io.github.aravindhraja123.porthop") != nil
    let wrongVersion = Updates.unpack(zip, expecting: "9.9.8", bundleID: "io.github.aravindhraja123.porthop") == nil
    let wrongApp = Updates.unpack(zip, expecting: "9.9.9", bundleID: "com.example.other") == nil
    let release = Updates.Release(version: "9.9.9", url: URL(string: "https://example.org")!, notes: "",
                                  assets: ["PortHop-9.9.9-mac.zip": URL(string: "https://example.org/a.zip")!, "PortHop-9.9.9-mac.zip.sig": URL(string: "https://example.org/a.zip.sig")!])
    check("phone report; signed update downloads (shared case) and unpacking", blank, copied: 0, skipped: 0, failed: 0,
          extra: page.contains("91% of its original capacity") && page.contains("<td>312</td>") && !page.contains("35 000000") && page.contains("Parts and Service History")
            && Updates.verify(data, signature: sig, key: key) && !Updates.verify(tampered, signature: sig, key: key) && !Updates.verify(data, signature: sig, key: otherKey)
            && !Updates.verify(data, signature: Data("junk".utf8), key: key) && unpacked && wrongVersion && wrongApp && Updates.macAssets(release) != nil)
}

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
