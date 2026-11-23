#!/usr/bin/env python3
"""Writes the small files in Tests/golden/location that both editions' "remove location" code is tested on.

Each holds a GPS position (12.3456 N, 65.4321 E) and a place name "PORTHOP-SECRET-PLACE" that must disappear,
plus a camera make "KEEP-..." that must survive. They are not real pictures: only the metadata structure matters.
"""
import json, os, struct

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "golden", "location")

def tiff():
    make = b"KEEP-CAMERA-MAKE\0"
    secret = b"PORTHOP-SECRET-PLACE\0"
    ifd0 = 8
    ifd0_len = 2 + 2 * 12 + 4
    gps = ifd0 + ifd0_len
    gps_len = 2 + 3 * 12 + 4
    data = gps + gps_len
    make_at, lat_at = data, data + len(make)
    secret_at = lat_at + 24
    b = b"MM\x00\x2a" + struct.pack(">I", ifd0)
    b += struct.pack(">H", 2)
    b += struct.pack(">HHII", 0x010F, 2, len(make), make_at)
    b += struct.pack(">HHII", 0x8825, 4, 1, gps)
    b += struct.pack(">I", 0)
    b += struct.pack(">H", 3)
    b += struct.pack(">HHI", 0x0001, 2, 2) + b"N\0\0\0"
    b += struct.pack(">HHII", 0x0002, 5, 3, lat_at)
    b += struct.pack(">HHII", 0x0012, 2, len(secret), secret_at)
    b += struct.pack(">I", 0)
    b += make + struct.pack(">IIIIII", 12, 1, 34, 1, 5678, 100) + secret
    return b

def box(kind, payload):
    return struct.pack(">I", 8 + len(payload)) + kind + payload

def jpeg():
    exif = b"Exif\0\0" + tiff()
    app1 = b"\xff\xe1" + struct.pack(">H", 2 + len(exif)) + exif
    com = b"\xff\xfe" + struct.pack(">H", 2 + 12) + b"KEEP-COMMENT"
    return b"\xff\xd8" + app1 + com + b"\xff\xda\x00\x02" + b"PIXELS" + b"\xff\xd9"

def heic():
    payload = struct.pack(">I", 6) + b"Exif\0\0" + tiff()
    ftyp = box(b"ftyp", b"heic" + struct.pack(">I", 0) + b"mif1heic")
    def meta(offset):
        hdlr = box(b"hdlr", b"\0\0\0\0" + b"\0\0\0\0" + b"pict" + b"\0" * 12 + b"\0")
        infe = box(b"infe", b"\x02\0\0\0" + struct.pack(">HH", 1, 0) + b"Exif" + b"\0")
        iinf = box(b"iinf", b"\0\0\0\0" + struct.pack(">H", 1) + infe)
        iloc = box(b"iloc", b"\x01\0\0\0" + bytes([0x44, 0x00]) + struct.pack(">H", 1)
                   + struct.pack(">HHHH", 1, 0, 0, 1) + struct.pack(">II", offset, len(payload)))
        return box(b"meta", b"\0\0\0\0" + hdlr + iinf + iloc)
    head = ftyp + meta(0)
    offset = len(head) + 8   # the payload starts right after the mdat header
    return ftyp + meta(offset) + box(b"mdat", payload)

def mov():
    xyz = b"+12.3456+065.4321/"
    xyz_atom = box(b"\xa9xyz", struct.pack(">HH", len(xyz), 0x15c7) + xyz)
    udta = box(b"udta", xyz_atom)
    hdlr = box(b"hdlr", b"\0\0\0\0" + b"\0\0\0\0" + b"mdta" + b"\0" * 12 + b"\0")
    k1, k2 = b"com.apple.quicktime.location.ISO6709", b"com.apple.quicktime.make"
    keys = box(b"keys", b"\0\0\0\0" + struct.pack(">I", 2)
               + struct.pack(">I", 8 + len(k1)) + b"mdta" + k1 + struct.pack(">I", 8 + len(k2)) + b"mdta" + k2)
    def item(n, value):
        data = box(b"data", struct.pack(">II", 1, 0) + value)
        return struct.pack(">I", 8 + len(data)) + struct.pack(">I", n) + data
    ilst = box(b"ilst", item(1, b"+12.3456+065.4321+010.000/") + item(2, b"KEEP-PHONE-MAKER"))
    meta = box(b"meta", hdlr + keys + ilst)
    trak = box(b"trak", box(b"tkhd", b"\0" * 12))
    moov = box(b"moov", box(b"mvhd", b"\0" * 8) + trak + udta + meta)
    return box(b"ftyp", b"qt  " + struct.pack(">I", 0) + b"qt  ") + moov + box(b"mdat", b"VIDEO-BYTES")

os.makedirs(HERE, exist_ok=True)
for name, data in [("gps.jpg", jpeg()), ("gps.heic", heic()), ("gps.mov", mov())]:
    with open(os.path.join(HERE, name), "wb") as f:
        f.write(data)
with open(os.path.join(HERE, "expect.json"), "w") as f:
    json.dump([
        {"file": "gps.jpg", "gone": ["PORTHOP-SECRET-PLACE"], "kept": ["KEEP-CAMERA-MAKE", "KEEP-COMMENT", "PIXELS"]},
        {"file": "gps.heic", "gone": ["PORTHOP-SECRET-PLACE"], "kept": ["KEEP-CAMERA-MAKE", "ftypheic"]},
        {"file": "gps.mov", "gone": ["+12.3456", "location.ISO6709", "©xyz"], "kept": ["KEEP-PHONE-MAKER", "VIDEO-BYTES", "com.apple.quicktime.make"]},
    ], f, indent=1)
print("wrote", HERE)
