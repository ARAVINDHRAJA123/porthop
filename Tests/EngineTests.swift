import Foundation
import ImageIO
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

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
