#!/usr/bin/env python3
# Builds a small stand-in device backup (not encrypted) in the folder given. Invented data only.
import sys, os, sqlite3, hashlib, plistlib, datetime, gzip
root = sys.argv[1]; os.makedirs(root, exist_ok=True)
files = []
def store(domain, path, build=None, data=None):
    fid = hashlib.sha1((domain + "-" + path).encode()).hexdigest()
    os.makedirs(os.path.join(root, fid[:2]), exist_ok=True)
    p = os.path.join(root, fid[:2], fid)
    if build:
        if os.path.exists(p): os.remove(p)   # rebuilt with more rows (the spyware variant)
        db = sqlite3.connect(p); build(db); db.commit(); db.close()
    else:
        open(p, "wb").write(data)
    files.append((fid, domain, path, 1))
T = 780000000  # seconds since 2001
def sms(db):
    db.executescript("""CREATE TABLE message(ROWID INTEGER PRIMARY KEY, text TEXT, handle_id INT, date INT, is_from_me INT, attributedBody BLOB, cache_has_attachments INT);
    CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT); CREATE TABLE chat(ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT);
    CREATE TABLE chat_message_join(chat_id INT, message_id INT);
    CREATE TABLE attachment(ROWID INTEGER PRIMARY KEY, filename TEXT, mime_type TEXT, transfer_name TEXT);
    CREATE TABLE message_attachment_join(message_id INT, attachment_id INT);""")
    # Message 5 (no text) carries a photo, kept in the backup under MediaDomain.
    db.execute("INSERT INTO attachment VALUES(1,'~/Library/SMS/Attachments/ab/12/GUID-1/IMG_5001.jpeg','image/jpeg','IMG_5001.jpeg')")
    db.execute("INSERT INTO message_attachment_join VALUES(5,1)")
    db.execute("INSERT INTO handle VALUES(1,'+14155550101')"); db.execute("INSERT INTO handle VALUES(2,'sam@example.com')")
    db.execute("INSERT INTO chat VALUES(1,'+14155550101','')"); db.execute("INSERT INTO chat VALUES(2,'chat99','Weekend Trip')")
    long = "Long one " + "x" * 300
    def blob(t):
        b = t.encode(); n = bytes([len(b)]) if len(b) < 128 else (b"\x81" + len(b).to_bytes(2, "little") if len(b) < 65536 else b"\x82" + len(b).to_bytes(4, "little"))
        return b"\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString\x00\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+" + n + b + b"\x86\x84\x02iI"
    rows = [(1, "Hello there", 1, T * 10**9, 0, None, 0, 1), (2, "Hi \"Asha\", how are you?", 0, (T + 60) * 10**9, 1, None, 0, 1),
            (3, None, 1, (T + 120) * 10**9, 0, blob("From the archive"), 0, 1), (4, None, 1, (T + 180) * 10**9, 0, blob(long), 0, 1),
            (5, None, 1, (T + 240) * 10**9, 0, None, 1, 1), (6, "Who is driving?", 2, (T + 9000) * 10**9, 0, None, 0, 2),
            (7, None, 2, (T + 9100) * 10**9, 0, blob("Huge " + "y" * 70000), 0, 2)]
    for r in rows:
        db.execute("INSERT INTO message VALUES(?,?,?,?,?,?,?)", r[:7]); db.execute("INSERT INTO chat_message_join VALUES(?,?)", (r[7], r[0]))
def contacts(db):
    db.executescript("CREATE TABLE ABPerson(ROWID INTEGER PRIMARY KEY, First TEXT, Last TEXT, Organization TEXT); CREATE TABLE ABMultiValue(record_id INT, property INT, value TEXT);")
    db.execute("INSERT INTO ABPerson VALUES(1,'Asha','Rao',NULL)"); db.execute("INSERT INTO ABPerson VALUES(2,NULL,NULL,'City Garage')")
    db.execute("INSERT INTO ABPerson VALUES(3,'Sam','Lee','Acme')")
    db.executemany("INSERT INTO ABMultiValue VALUES(?,?,?)", [(1, 3, "(415) 555-0101"), (1, 4, "asha@example.com"), (2, 3, "+1 415 555 0199"), (3, 4, "Sam@Example.com")])
def pb(field, payload):   # one length-delimited protobuf field
    def varint(n):
        out = b""
        while True:
            b, n = n & 0x7f, n >> 7
            if n: out += bytes([b | 0x80])
            else: return out + bytes([b])
    return varint(field << 3 | 2) + varint(len(payload)) + payload
def note_blob(text):   # how Notes stores a note: gzip(NoteStoreProto{document{version, note{note_text, ...}}})
    note = pb(2, text.encode()) + bytes([0x28, 0x01])
    return gzip.compress(bytes([0x08, 0x00]) + pb(2, bytes([0x10, 0x00]) + pb(3, note)))
def notes(db):
    db.execute("CREATE TABLE ZICCLOUDSYNCINGOBJECT(Z_PK INTEGER PRIMARY KEY, ZTITLE1 TEXT, ZSNIPPET TEXT, ZMODIFICATIONDATE1 REAL, ZMARKEDFORDELETION INT, ZNOTEDATA INT)")
    db.executemany("INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES(?,?,?,?,?,?)", [(1, "Shopping", "Milk, eggs", T, 0, 10), (2, "Deleted note", "gone", T, 1, None), (3, None, None, None, 0, None), (4, "Ideas", "App names", T + 500, 0, 11)])
    db.execute("CREATE TABLE ZICNOTEDATA(Z_PK INTEGER PRIMARY KEY, ZNOTE INT, ZDATA BLOB)")
    # Shopping has its full text; Ideas is locked (its data is encrypted on the device), so only the preview shows.
    db.execute("INSERT INTO ZICNOTEDATA VALUES(10, 1, ?)", (note_blob("Shopping\nMilk, eggs, bread\nAsk about the café ☕"),))
    db.execute("INSERT INTO ZICNOTEDATA VALUES(11, 4, ?)", (os.urandom(64),))
def cal(db):
    db.executescript("CREATE TABLE Calendar(ROWID INTEGER PRIMARY KEY, title TEXT); CREATE TABLE CalendarItem(ROWID INTEGER PRIMARY KEY, summary TEXT, start_date REAL, end_date REAL, all_day INT, calendar_id INT);")
    db.execute("INSERT INTO Calendar VALUES(1,'Home')"); db.execute("INSERT INTO Calendar VALUES(2,'Work')")
    db.executemany("INSERT INTO CalendarItem VALUES(?,?,?,?,?,?)", [(1, "Dentist", T, T + 3600, 0, 1), (2, "Birthday", T + 86400, T + 172800, 1, 1), (3, "Review", T, T + 1800, 0, 2)])
def bookmarks(db):
    db.execute("CREATE TABLE bookmarks(id INTEGER PRIMARY KEY, title TEXT, url TEXT, type INT)")
    db.executemany("INSERT INTO bookmarks VALUES(?,?,?,?)", [(1, "Favourites", None, 1), (2, "Example", "https://example.com", 0)])
def history(db):
    db.executescript("CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT); CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INT, visit_time REAL, title TEXT);")
    db.execute("INSERT INTO history_items VALUES(1,'https://example.org/a')"); db.executemany("INSERT INTO history_visits VALUES(?,?,?,?)", [(1, 1, T, "Page A"), (2, 1, T + 50, "Page A")])
def wa(db):
    db.executescript("CREATE TABLE ZWACHATSESSION(Z_PK INTEGER PRIMARY KEY, ZPARTNERNAME TEXT, ZCONTACTJID TEXT); CREATE TABLE ZWAMESSAGE(Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INT, ZMESSAGEDATE REAL, ZISFROMME INT, ZFROMJID TEXT, ZTEXT TEXT, ZPUSHNAME TEXT, ZMEDIAITEM INT);"
                     "CREATE TABLE ZWAMEDIAITEM(Z_PK INTEGER PRIMARY KEY, ZMEDIALOCALPATH TEXT, ZTITLE TEXT);")
    db.execute("INSERT INTO ZWAMEDIAITEM VALUES(1,'Media/123-456@g.us/1/2/photo1.jpg',NULL)")
    db.executemany("INSERT INTO ZWACHATSESSION VALUES(?,?,?)", [(1, "Asha", "14155550101@s.whatsapp.net"), (2, "Family", "123-456@g.us"), (3, "Empty", "1@s.whatsapp.net")])
    db.executemany("INSERT INTO ZWAMESSAGE VALUES(?,?,?,?,?,?,?,?)", [(1, 1, T, 0, "14155550101@s.whatsapp.net", "Lunch?", None, None), (2, 1, T + 5, 1, None, "Yes", None, None),
                   (3, 2, T + 900, 0, "123-456@g.us", "Dinner at 8", "Uncle Ravi", None), (4, 2, T + 950, 0, "123-456@g.us", None, "Uncle Ravi", 1)])
store("HomeDomain", "Library/SMS/sms.db", sms)
store("HomeDomain", "Library/AddressBook/AddressBook.sqlitedb", contacts)
store("AppDomainGroup-group.com.apple.notes", "NoteStore.sqlite", notes)
store("HomeDomain", "Library/Calendar/Calendar.sqlitedb", cal)
store("HomeDomain", "Library/Safari/Bookmarks.db", bookmarks)
store("AppDomain-com.apple.mobilesafari", "Library/Safari/History.db", history)
if not os.environ.get("NO_WHATSAPP"): store("AppDomainGroup-group.net.whatsapp.WhatsApp.shared", "ChatStorage.sqlite", wa)
store("MediaDomain", "Library/SMS/Attachments/ab/12/GUID-1/IMG_5001.jpeg", data=b"\xff\xd8\xffsms-photo" * 50)
if not os.environ.get("NO_WHATSAPP"): store("AppDomainGroup-group.net.whatsapp.WhatsApp.shared", "Message/Media/123-456@g.us/1/2/photo1.jpg", data=b"\xff\xd8\xffwa-photo" * 50)
store("CameraRollDomain", "Media/DCIM/100APPLE/IMG_0001.JPG", data=b"jpegbytes" * 100)
store("CameraRollDomain", "Media/DCIM/101APPLE/IMG_0050.MOV", data=b"movbytes" * 100)
def memos(db):   # Voice Memos as newer iOS keeps them; the third recording's audio is not in the backup
    db.execute("CREATE TABLE ZCLOUDRECORDING(Z_PK INTEGER PRIMARY KEY, ZENCRYPTEDTITLE TEXT, ZCUSTOMLABEL TEXT, ZDATE REAL, ZDURATION REAL, ZPATH TEXT)")
    db.executemany("INSERT INTO ZCLOUDRECORDING VALUES(?,?,?,?,?,?)", [(1, "Song idea", None, T, 65.4, "20260101 090000-1A2B.m4a"),
                   (2, None, "Lecture: week 3", T + 100, 3600, "20260102 100000-3C4D.m4a"), (3, "Lost one", None, T + 200, 5, "gone.m4a")])
store("AppDomainGroup-group.com.apple.VoiceMemos.shared", "Recordings/CloudRecordings.db", memos)
store("AppDomainGroup-group.com.apple.VoiceMemos.shared", "Recordings/20260101 090000-1A2B.m4a", data=b"m4a-one" * 100)
store("AppDomainGroup-group.com.apple.VoiceMemos.shared", "Recordings/20260102 100000-3C4D.m4a", data=b"m4a-two" * 100)
store("AppDomain-com.example.player", "Documents/movie list.txt", data=b"one\ntwo\n")
SPY = bool(os.environ.get("SPYWARE"))
if SPY:
    # Traces that match Tests/golden/spyware/indicators.stix2 (all invented): what a spyware check must find.
    def spy_history(db):
        history(db)
        db.execute("INSERT INTO history_items VALUES(2,'https://login.bad-spy-domain.test/x')"); db.execute("INSERT INTO history_visits VALUES(3,2,?,'Login')", (T + 70,))
    files[:] = [f for f in files if f[2] != "Library/Safari/History.db"]
    store("AppDomain-com.apple.mobilesafari", "Library/Safari/History.db", spy_history)
    def spy_bookmarks(db):
        bookmarks(db); db.execute("INSERT INTO bookmarks VALUES(3,'Exact','https://exact-url.example/path?id=1',0)")
    files[:] = [f for f in files if f[2] != "Library/Safari/Bookmarks.db"]
    store("HomeDomain", "Library/Safari/Bookmarks.db", spy_bookmarks)
    def spy_sms(db):
        sms(db)
        db.execute("INSERT INTO handle VALUES(3,'sender-bad@example.com')"); db.execute("INSERT INTO chat VALUES(3,'sender-bad@example.com','')")
        db.execute("INSERT INTO message VALUES(8,'check this http://track.evil-sms.example.org/a now',3,?,0,NULL,0)", ((T + 300) * 10**9,))
        db.execute("INSERT INTO chat_message_join VALUES(3,8)")
    files[:] = [f for f in files if f[2] != "Library/SMS/sms.db"]
    store("HomeDomain", "Library/SMS/sms.db", spy_sms)
    def spy_wa(db):
        wa(db); db.execute("INSERT INTO ZWAMESSAGE VALUES(5,1,?,0,'14155550101@s.whatsapp.net','see wa-trap.example.net/z please',NULL,NULL)", (T + 400,))
    files[:] = [f for f in files if f[2] != "ChatStorage.sqlite"]
    store("AppDomainGroup-group.net.whatsapp.WhatsApp.shared", "ChatStorage.sqlite", spy_wa)
    def usage(db):
        db.execute("CREATE TABLE ZPROCESS(Z_PK INTEGER PRIMARY KEY, ZPROCNAME TEXT, ZBUNDLENAME TEXT, ZFIRSTTIMESTAMP REAL, ZTIMESTAMP REAL)")
        db.executemany("INSERT INTO ZPROCESS VALUES(?,?,?,?,?)", [(1, "spyprocessd", None, T, T + 10), (2, "averylongproces", None, T, T + 20),
                       (3, "MobileSafari", "com.apple.mobilesafari", T, T + 30), (4, "averylongothers", None, T, T)])
    store("WirelessDomain", "Library/Databases/DataUsage.sqlite", usage)
    def observations(db):
        db.execute("CREATE TABLE ObservedDomains(domainID INTEGER PRIMARY KEY, registrableDomain TEXT, mostRecentUserInteractionTime REAL)")
        db.executemany("INSERT INTO ObservedDomains VALUES(?,?,?)", [(1, "example.com", 1760000000), (2, "tracker-bad.example", 1760000100)])
    store("AppDomain-com.example.player", "Library/WebKit/WebsiteData/ResourceLoadStatistics/observations.db", observations)
    store("HomeDomain", "Library/Preferences/com.apple.osanalytics.addaily.plist", data=plistlib.dumps({"netUsageBaseline": {"dailyspy": [1, 2], "backboardd": [3, 4]}}))
    store("HomeDomain", "Library/Preferences/com.apple.identityservices.idstatuscache.plist",
          data=plistlib.dumps({"com.apple.madrid": {"mailto:attacker@example.com": {"IDStatus": 1}, "tel:+14155550101": {"IDStatus": 1}}}))
    store("HomeDomain", "Library/Preferences/roleaccountd.plist", data=plistlib.dumps({"a": 1}))
    store("HomeDomain", "Library/Caches/spy-cache/data.bin", data=b"x" * 10)
    store("SysSharedContainerDomain-systemgroup.com.apple.configurationprofiles", "Library/ConfigurationProfiles/profile-abc.stub",
          data=plistlib.dumps({"PayloadUUID": "76DAB334-7E17-475D-A5D6-0794EB5818A5", "PayloadDisplayName": "Totally Normal"}, fmt=plistlib.FMT_BINARY))
m = sqlite3.connect(os.path.join(root, "Manifest.db"))
m.execute("CREATE TABLE Files(fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INT, file BLOB)")
m.executemany("INSERT INTO Files VALUES(?,?,?,?,NULL)", files)
m.execute("INSERT INTO Files VALUES('d1','CameraRollDomain','Media/DCIM',2,NULL)"); m.commit(); m.close()
plistlib.dump({"IsEncrypted": bool(os.environ.get("ENCRYPTED"))}, open(os.path.join(root, "Manifest.plist"), "wb"))
plistlib.dump({"Device Name": "Test iPhone", "Product Version": "27.2", "Last Backup Date": datetime.datetime(2026, 11, 10, 9, 30),
               **({"Installed Applications": ["com.example.player", "com.fake.stalker"]} if SPY else {})}, open(os.path.join(root, "Info.plist"), "wb"))
