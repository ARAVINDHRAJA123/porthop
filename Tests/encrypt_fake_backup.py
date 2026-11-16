#!/usr/bin/env python3
# Turns a plain stand-in backup into a password-protected one, laid out the way a real device backup is.
# usage: encrypt_fake_backup.py <plain backup> <new folder> <password>
import sys, os, sqlite3, hashlib, plistlib, subprocess, struct, shutil
src, dst, password = sys.argv[1], sys.argv[2], sys.argv[3].encode()
os.makedirs(dst, exist_ok=True)
def ssl(mode, key, data):
    return subprocess.run(["openssl", "enc", "-" + mode, "-nopad", "-K", key.hex()] + (["-iv", "00" * 16] if "cbc" in mode else []),
                          input=data, capture_output=True, check=True).stdout
def wrap(kek, key):
    n = len(key) // 8; a = b"\xa6" * 8; r = [key[i * 8:(i + 1) * 8] for i in range(n)]
    for j in range(6):
        for i in range(n):
            b = ssl("aes-256-ecb", kek, a + r[i]); t = n * j + i + 1
            a = (int.from_bytes(b[:8], "big") ^ t).to_bytes(8, "big"); r[i] = b[8:]
    return a + b"".join(r)
def cbc(key, data):
    pad = 16 - len(data) % 16
    return ssl("aes-256-cbc", key, data + bytes([pad]) * pad)
def tlv(tag, value): return tag.encode() + struct.pack(">I", len(value)) + value
salt, dpsl, iters = os.urandom(20), os.urandom(20), 1000
passkey = hashlib.pbkdf2_hmac("sha1", hashlib.pbkdf2_hmac("sha256", password, dpsl, iters, 32), salt, iters, 32)
classkeys = {c: os.urandom(32) for c in (1, 2, 3, 4)}
bag = tlv("VERS", struct.pack(">I", 5)) + tlv("TYPE", struct.pack(">I", 1)) + tlv("UUID", os.urandom(16)) + tlv("HMCK", os.urandom(40)) \
    + tlv("WRAP", struct.pack(">I", 0)) + tlv("SALT", salt) + tlv("ITER", struct.pack(">I", iters)) + tlv("DPWT", struct.pack(">I", 1)) \
    + tlv("DPIC", struct.pack(">I", iters)) + tlv("DPSL", dpsl)
for c, k in classkeys.items():
    bag += tlv("UUID", os.urandom(16)) + tlv("CLAS", struct.pack(">I", c)) + tlv("WRAP", struct.pack(">I", 2)) + tlv("KTYP", struct.pack(">I", 0)) + tlv("WPKY", wrap(passkey, k))
old = sqlite3.connect(os.path.join(src, "Manifest.db"))
plain = os.path.join(dst, "Manifest.plain")
new = sqlite3.connect(plain)
new.execute("CREATE TABLE Files(fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INT, file BLOB)")
for fid, domain, path, flags in old.execute("SELECT fileID, domain, relativePath, flags FROM Files"):
    blob = None
    if flags == 1:
        data = open(os.path.join(src, fid[:2], fid), "rb").read()
        fkey = os.urandom(32)
        os.makedirs(os.path.join(dst, fid[:2]), exist_ok=True)
        open(os.path.join(dst, fid[:2], fid), "wb").write(cbc(fkey, data))
        U = plistlib.UID
        blob = plistlib.dumps({"$version": 100000, "$archiver": "NSKeyedArchiver", "$top": {"root": U(1)}, "$objects": [
            "$null", {"$class": U(4), "ProtectionClass": 3, "Size": len(data), "RelativePath": U(2), "EncryptionKey": U(3), "Mode": 33188},
            path, {"$class": U(5), "NS.data": struct.pack("<I", 3) + wrap(classkeys[3], fkey)},
            {"$classname": "MBFile", "$classes": ["MBFile", "NSObject"]}, {"$classname": "NSMutableData", "$classes": ["NSMutableData", "NSData", "NSObject"]}]},
            fmt=plistlib.FMT_BINARY)
    new.execute("INSERT INTO Files VALUES(?,?,?,?,?)", (fid, domain, path, flags, blob))
new.commit(); new.close()
mkey = os.urandom(32)
raw = open(plain, "rb").read(); os.remove(plain)
open(os.path.join(dst, "Manifest.db"), "wb").write(ssl("aes-256-cbc", mkey, raw))
plistlib.dump({"IsEncrypted": True, "BackupKeyBag": bag, "ManifestKey": struct.pack("<I", 4) + wrap(classkeys[4], mkey)}, open(os.path.join(dst, "Manifest.plist"), "wb"))
shutil.copy(os.path.join(src, "Info.plist"), os.path.join(dst, "Info.plist"))
