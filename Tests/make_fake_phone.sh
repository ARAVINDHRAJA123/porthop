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
# People named in Photos (newer iOS column names): Mum twice (one record not merged yet), Ravi by full name only,
# someone never named, and a face of Mum in a hidden photo, which stays out of her group.
c.executescript("""
CREATE TABLE ZPERSON(Z_PK INTEGER PRIMARY KEY, ZDISPLAYNAME TEXT, ZFULLNAME TEXT);
CREATE TABLE ZDETECTEDFACE(Z_PK INTEGER PRIMARY KEY, ZASSETFORFACE INT, ZPERSONFORFACE INT);
INSERT INTO ZPERSON VALUES(1,'Mum',NULL),(2,'','Ravi Kumar'),(3,NULL,NULL),(4,'mum','');
""")
for i,(asset,person) in enumerate([(37,1),(38,1),(40,1),(40,4),(44,4),(10,1),(39,2),(41,2),(45,2),(38,3),(46,3)]):
    c.execute("INSERT INTO ZDETECTEDFACE VALUES(?,?,?)",(i+1,asset,person))
db.commit()
# The music library: three songs synced from a computer, an Apple Music download (protected), a song only in the cloud,
# a ringtone the library knows and one it does not (named by the ringtone list), as the iPhone keeps them.
mu=f"{root}/iTunes_Control"; os.makedirs(mu+"/Music/F00"); os.makedirs(mu+"/Music/F01"); os.makedirs(mu+"/iTunes"); os.makedirs(mu+"/Ringtones")
for name,size in [("F00/AAAA.mp3",40000),("F00/BBBB.m4a",52000),("F01/CCCC.m4a",61000),("F01/DDDD.m4p",70000)]: open(f"{mu}/Music/{name}","wb").write(os.urandom(size))
open(mu+"/Ringtones/TONE1.m4r","wb").write(os.urandom(9000)); open(mu+"/Ringtones/TONE2.m4r","wb").write(os.urandom(8000))
import plistlib; plistlib.dump({"Ringtones": {"TONE2.m4r": {"Name": "Old Phone", "Total Time": 12000}}}, open(mu+"/iTunes/Ringtones.plist","wb"))
m=sqlite3.connect(mu+"/iTunes/MediaLibrary.sqlitedb")
m.executescript("""
CREATE TABLE item(item_pid INTEGER PRIMARY KEY, media_type INT, item_artist_pid INT, album_pid INT, album_artist_pid INT, base_location_id INT, disc_number INT, track_number INT);
CREATE TABLE item_extra(item_pid INTEGER PRIMARY KEY, title TEXT, total_time_ms INT, year INT, location TEXT, file_size INT);
CREATE TABLE item_artist(item_artist_pid INTEGER PRIMARY KEY, item_artist TEXT);
CREATE TABLE album(album_pid INTEGER PRIMARY KEY, album TEXT, album_artist_pid INT);
CREATE TABLE album_artist(album_artist_pid INTEGER PRIMARY KEY, album_artist TEXT);
CREATE TABLE base_location(base_location_id INTEGER PRIMARY KEY, path TEXT);
INSERT INTO base_location VALUES(1,'iTunes_Control/Music/F00'),(2,'iTunes_Control/Music/F01'),(3,'iTunes_Control/Ringtones');
INSERT INTO item_artist VALUES(1,'Asha Band'),(2,'Ravi'),(3,'AC/DC');
INSERT INTO album_artist VALUES(1,'Asha Band'),(3,'AC/DC');
INSERT INTO album VALUES(1,'First Light',1),(2,'Live: Wire?',3);
INSERT INTO item VALUES(11,8,1,1,1,1,1,2),(12,8,2,1,1,1,1,1),(13,8,3,2,3,2,2,7),(14,8,1,1,1,2,1,3),(15,8,2,1,1,0,1,4),(16,16384,2,0,0,3,0,0);
INSERT INTO item_extra VALUES(11,'Morning',201000,2024,'AAAA.mp3',40000),(12,'Ravi''s Song',180500,2024,'BBBB.m4a',52000),
 (13,'Back in Black',255000,1980,'CCCC.m4a',61000),(14,'Streamed',199000,2025,'DDDD.m4p',70000),(15,'Cloud Only',150000,2025,NULL,0),
 (16,'Chime',9000,0,'TONE1.m4r',9000);
""")
m.commit()
PY
