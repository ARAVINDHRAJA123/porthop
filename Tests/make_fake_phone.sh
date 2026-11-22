#!/bin/bash
# Creates a simulated iPhone (sample images + a Photos.sqlite) in the folder given as $1.
set -euo pipefail
P="$1"; rm -rf "$P"; mkdir -p "$P/DCIM/100APPLE" "$P/DCIM/101APPLE" "$P/PhotoData"
cat > "$P/gen.swift" <<'SW'
import AppKit
let root = CommandLine.arguments[1]
for i in 1...48 {
    let w = i % 3 == 0 ? 900 : 1200, h = i % 3 == 0 ? 1200 : 900
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let hue = CGFloat(i) / 48
    NSGradient(colors: [NSColor(hue: hue, saturation: 0.6, brightness: 0.95, alpha: 1), NSColor(hue: fmod(hue + 0.15, 1), saturation: 0.8, brightness: 0.55, alpha: 1)])!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: CGFloat(i * 37 % 360))
    NSColor.white.withAlphaComponent(0.25).setFill()
    NSBezierPath(ovalIn: NSRect(x: CGFloat(i * 53 % 700), y: CGFloat(i * 91 % 500), width: 380, height: 380)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let dir = i <= 30 ? "100APPLE" : "101APPLE"
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: URL(fileURLWithPath: "\(root)/DCIM/\(dir)/IMG_\(String(format: "%04d", i)).JPG"))
}
SW
swift "$P/gen.swift" "$P"; rm "$P/gen.swift"
mkdir -p "$P/Apps/com.example.player/Documents/Trips" "$P/Apps/com.example.reader/Documents"; echo hello > "$P/Apps/com.example.player/Documents/notes.txt"
python3 - "$P" <<'PY'
import sqlite3, os, sys
root=sys.argv[1]
db=sqlite3.connect(root+"/PhotoData/Photos.sqlite"); c=db.cursor()
c.executescript("""
CREATE TABLE ZASSET(Z_PK INTEGER PRIMARY KEY, ZUUID TEXT, ZDIRECTORY TEXT, ZFILENAME TEXT, ZHIDDEN INT, ZFAVORITE INT, ZTRASHEDSTATE INT, ZKIND INT, ZKINDSUBTYPE INT, ZDATECREATED REAL, ZWIDTH INT, ZHEIGHT INT, ZDURATION REAL, ZISDETECTEDSCREENSHOT INT, ZCAMERACAPTUREDEVICE INT);
CREATE TABLE ZADDITIONALASSETATTRIBUTES(Z_PK INTEGER PRIMARY KEY, ZASSET INT, ZORIGINALFILENAME TEXT, ZORIGINALFILESIZE INT);
CREATE TABLE ZGENERICALBUM(Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT, ZTRASHEDSTATE INT);
CREATE TABLE Z_30ASSETS(Z_30ALBUMS INT, Z_3ASSETS INT);
INSERT INTO ZGENERICALBUM VALUES(1,'Goa Trip',0),(2,'Family',0);
""")
pk=0
for d in ("100APPLE","101APPLE"):
    for fn in sorted(os.listdir(f"{root}/DCIM/{d}")):
        pk+=1; size=os.path.getsize(f"{root}/DCIM/{d}/{fn}")
        if pk==5: size+=17          # stale catalog size, file is fine
        live = 2 if pk%7==0 else 0
        w,h=(900,1200) if pk%3==0 else (1200,900)
        c.execute("INSERT INTO ZASSET VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",(pk,f"UUID-{pk:04d}",f"DCIM/{d}",fn,1 if pk<=36 else 0,1 if pk%5==0 else 0,0,0,live,780000000-pk*86400*3.3,w,h,0,1 if pk%11==0 else 0,1 if pk%9==0 else 0))
        c.execute("INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES(?,?,?,?)",(pk,pk,f"Original {pk}.jpg",size))
        if live: open(f"{root}/DCIM/{d}/{fn[:-4]}.MOV","wb").write(os.urandom(50000))
        if pk%4==0: c.execute("INSERT INTO Z_30ASSETS VALUES(1,?)",(pk,))
        if pk%6==0: c.execute("INSERT INTO Z_30ASSETS VALUES(2,?)",(pk,))
c.execute("INSERT INTO ZASSET VALUES(100,'UUID-0100','DCIM/100APPLE','IMG_9000.HEIC',1,0,0,0,0,779000000,4032,3024,0,0,0)")  # iCloud-only: no file
c.execute("INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES(100,100,'IMG_9000.HEIC',2400000)")
open(f"{root}/DCIM/100APPLE/IMG_9001.MOV","wb").write(os.urandom(3_000_000))
c.execute("INSERT INTO ZASSET VALUES(101,'UUID-0101','DCIM/100APPLE','IMG_9001.MOV',1,0,0,1,0,778000000,1920,1080,42.5,0,0)")
c.execute("INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES(101,101,'IMG_9001.MOV',3000000)")
src=f"{root}/DCIM/100APPLE/IMG_0001.JPG"; open(f"{root}/DCIM/100APPLE/we\"ird name.JPG","wb").write(open(src,"rb").read())
c.execute("INSERT INTO ZASSET VALUES(102,'UUID-0102','DCIM/100APPLE','we\"ird name.JPG',1,0,0,0,0,777000000,1200,900,0,0,0)")
c.execute("INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES(102,102,'we\"ird name.JPG',?)",(os.path.getsize(src),))
# Photos edits and iCloud: IMG_0002 was edited (its render is on the device), IMG_0003 was edited but its render
# is missing (the original is used), IMG_9000 is in iCloud only, IMG_0001 is in iCloud and also on the device.
for col in ("ZHASADJUSTMENTS INT", "ZCLOUDASSETGUID TEXT", "ZCLOUDLOCALSTATE INT"): c.execute("ALTER TABLE ZASSET ADD COLUMN "+col)
c.execute("UPDATE ZASSET SET ZHASADJUSTMENTS=1 WHERE ZFILENAME IN ('IMG_0002.JPG','IMG_0003.JPG')")
c.execute("UPDATE ZASSET SET ZCLOUDASSETGUID='G100', ZCLOUDLOCALSTATE=0 WHERE Z_PK=100")
c.execute("UPDATE ZASSET SET ZCLOUDASSETGUID='G1', ZCLOUDLOCALSTATE=1 WHERE ZFILENAME='IMG_0001.JPG'")
adj=f"{root}/PhotoData/Mutations/DCIM/100APPLE/IMG_0002/Adjustments"; os.makedirs(adj)
open(adj+"/FullSizeRender.jpg","wb").write(open(f"{root}/DCIM/100APPLE/IMG_0001.JPG","rb").read()+b"EDITED")
db.commit()
PY
