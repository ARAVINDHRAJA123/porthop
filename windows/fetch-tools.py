#!/usr/bin/env python3
"""Builds the Windows iPhone tools this app runs and collects them, with the libraries they load, into ./tools-win.

- libimobiledevice 1.4.0 is compiled here from the official source release (checked against a known SHA-256).
- The libraries it depends on (libplist, libusbmuxd, libimobiledevice-glue, OpenSSL) are the Windows builds
  published by the MSYS2 project, used unmodified.
- Two small helpers from ../Helpers are compiled too: afcclient (file copy) and applist (apps that share a folder).
  The official afcclient is not used on Windows: without readline it reads commands from the console keyboard
  and drops non-English characters, so it cannot be driven by another program.

Nothing built here is run on this machine. Needs Python 3.14+ (for zstd), zig (the cross-compiler) and objdump."""
import glob, hashlib, io, os, re, shutil, subprocess, sys, tarfile, urllib.request
from compression import zstd

REPO = "https://repo.msys2.org/mingw/ucrt64/"
PREFIX = "mingw-w64-ucrt-x86_64-"
WANT = [PREFIX + "libimobiledevice"]
PROGRAMS = ["idevice_id", "ideviceinfo", "idevicepair", "idevicebackup2", "idevicediagnostics", "afcclient", "applist"]
OFFICIAL = ["idevice_id", "ideviceinfo", "idevicepair", "idevicebackup2", "idevicediagnostics"]  # from the official source
HELPERS = {"afcclient": "afcmini.c", "applist": "applist.c"}  # compiled here from ../Helpers
SOURCE_URL = "https://github.com/libimobiledevice/libimobiledevice/releases/download/1.4.0/libimobiledevice-1.4.0.tar.bz2"
SOURCE_SHA256 = "23cc0077e221c7d991bd0eb02150a0d49199bcca1ddf059edccee9ffd914939d"
CONFIG_H = """/* Written by fetch-tools.py for a Windows (mingw, ucrt) build with OpenSSL. */
#define PACKAGE "libimobiledevice"
#define PACKAGE_NAME "libimobiledevice"
#define PACKAGE_VERSION "1.4.0"
#define PACKAGE_STRING "libimobiledevice 1.4.0"
#define PACKAGE_TARNAME "libimobiledevice"
#define PACKAGE_URL "https://libimobiledevice.org"
#define PACKAGE_BUGREPORT "https://github.com/libimobiledevice/libimobiledevice/issues"
#define HAVE_OPENSSL 1
#define HAVE_PLIST_JSON 1
#define HAVE_PLIST_UNIX_DATE 1
#define HAVE_ASPRINTF 1
#define HAVE_VASPRINTF 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRCASECMP 1
#define HAVE_STRDUP 1
#define HAVE_STRERROR 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#ifndef __LITTLE_ENDIAN
#define __LITTLE_ENDIAN 1234
#endif
#ifndef __BIG_ENDIAN
#define __BIG_ENDIAN 4321
#endif
#ifndef __BYTE_ORDER
#define __BYTE_ORDER 1234
#endif
"""
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE, OUT = os.path.join(HERE, ".msys-cache"), os.path.join(HERE, "tools-win")

def fetch(name):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if not os.path.exists(path):
        print("downloading", name)
        urllib.request.urlretrieve(REPO + name, path + ".part")
        os.rename(path + ".part", path)
    return path

def open_zst(path):
    return tarfile.open(fileobj=io.BytesIO(zstd.decompress(open(path, "rb").read())))

packages, provides = {}, {}
with open_zst(fetch("ucrt64.db")) as db:
    for m in db.getmembers():
        if not m.name.endswith("/desc"): continue
        fields, key = {}, None
        for line in db.extractfile(m).read().decode().splitlines():
            if line.startswith("%") and line.endswith("%"): key = line.strip("%"); fields[key] = []
            elif line and key: fields[key].append(line)
        name = fields["NAME"][0]
        packages[name] = fields
        for p in fields.get("PROVIDES", []): provides.setdefault(re.split(r"[<>=]", p)[0], name)

closure, todo = [], list(WANT)
while todo:
    n = re.split(r"[<>=]", todo.pop())[0]
    n = n if n in packages else provides.get(n)
    if not n or n in closure: continue
    closure.append(n)
    todo += packages[n].get("DEPENDS", [])

stage = os.path.join(CACHE, "stage")
shutil.rmtree(stage, ignore_errors=True)
os.makedirs(stage)
versions = {}
for n in closure:
    f = packages[n]
    versions[n] = f["VERSION"][0]
    with open_zst(fetch(f["FILENAME"][0])) as pkg:
        for m in pkg.getmembers():
            base = os.path.basename(m.name)
            if m.isfile() and m.name.startswith("ucrt64/bin/") and base.lower().endswith(".dll") and "imobiledevice-1.0" not in base:
                with open(os.path.join(stage, base), "wb") as out: out.write(pkg.extractfile(m).read())
            elif m.isfile() and (m.name.startswith("ucrt64/include/") or m.name.endswith(".dll.a")) and re.search(r"imobiledevice-glue|plist|usbmuxd|openssl|libssl|libcrypto", m.name):
                dest = os.path.join(stage, "sdk", m.name[len("ucrt64/"):])
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as out: out.write(pkg.extractfile(m).read())
            elif m.isfile() and "/licenses/" in m.name and re.search(r"libimobiledevice|libplist|libusbmuxd|ideviceinstaller|openssl|libtatsu|libzip", m.name):
                d = os.path.join(OUT, "licenses", n.replace(PREFIX, ""))
                os.makedirs(d, exist_ok=True)
                with open(os.path.join(d, base), "wb") as out: out.write(pkg.extractfile(m).read())

def imports(path):
    text = subprocess.run(["objdump", "-p", path], capture_output=True, text=True).stdout
    return re.findall(r"DLL Name: (\S+)", text)

# The official 1.4.0 source, checked before use.
tarball = os.path.join(CACHE, "libimobiledevice-1.4.0.tar.bz2")
if not os.path.exists(tarball):
    print("downloading libimobiledevice 1.4.0 source")
    urllib.request.urlretrieve(SOURCE_URL, tarball)
if hashlib.sha256(open(tarball, "rb").read()).hexdigest() != SOURCE_SHA256:
    sys.exit("The libimobiledevice source download does not match the expected checksum. Stopping.")
src = os.path.join(stage, "src")
with tarfile.open(tarball) as t: t.extractall(stage, filter="data")
os.rename(os.path.join(stage, "libimobiledevice-1.4.0"), src)
with open(os.path.join(src, "config.h"), "w") as f: f.write(CONFIG_H)

sdk = os.path.join(stage, "sdk")
ZIG = ["zig", "cc", "-target", "x86_64-windows-gnu", "-O2", "-w", "-DHAVE_CONFIG_H", "-DLIBIMOBILEDEVICE_STATIC", "-D_WIN32_WINNT=0x0601",
       "-I" + src, "-I" + os.path.join(src, "include"), "-I" + os.path.join(sdk, "include")]
def compile_or_stop(cmd, what):
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=stage)
    if r.returncode != 0: sys.exit("could not build " + what + "\n" + r.stderr[-3000:])

# Every program runs with UTF-8 as its text encoding, so folder names and backup passwords with accents
# or non-Latin letters reach the tools intact (Windows 10 version 1903 and later).
UTF8_MANIFEST = os.path.join(stage, "utf8.manifest")
with open(UTF8_MANIFEST, "w") as f:
    f.write("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>
    </windowsSettings>
  </application>
</assembly>
""")
UTF8_RC = os.path.join(stage, "utf8.rc")
with open(UTF8_RC, "w") as f: f.write('1 24 "utf8.manifest"\n')  # read relative to the stage folder

objs = []
for c in sorted(glob.glob(os.path.join(src, "src", "*.c")) + glob.glob(os.path.join(src, "common", "*.c"))):
    o = os.path.join(stage, "obj-" + os.path.basename(c)[:-2] + ".o")
    compile_or_stop(ZIG + ["-c", c, "-o", o], os.path.basename(c))
    objs.append(o)
lib = os.path.join(stage, "libimobiledevice-static.a")
compile_or_stop(["zig", "ar", "rcs", lib] + objs, "the library archive")
LINK = [lib] + [os.path.join(sdk, "lib", n) for n in ("libimobiledevice-glue-1.0.dll.a", "libusbmuxd-2.0.dll.a", "libplist-2.0.dll.a", "libssl.dll.a", "libcrypto.dll.a")] \
    + ["-lws2_32", "-liphlpapi", "-lole32", "-lshell32", "-lcrypt32", "-ladvapi32", "-luser32"]
for exe in OFFICIAL:
    compile_or_stop(ZIG + [os.path.join(src, "tools", exe + ".c")] + LINK + [UTF8_RC, "-o", os.path.join(stage, exe + ".exe")], exe)
for exe, helper in HELPERS.items():
    compile_or_stop(ZIG + [os.path.join(HERE, "..", "Helpers", helper)] + LINK + [UTF8_RC, "-o", os.path.join(stage, exe + ".exe")], helper)
for name in ("COPYING", "COPYING.LESSER"):
    d = os.path.join(OUT, "licenses", "libimobiledevice")
    os.makedirs(d, exist_ok=True)
    shutil.copy(os.path.join(src, name), os.path.join(d, name))
versions["libimobiledevice (built here from the official 1.4.0 source)"] = "1.4.0"
versions.pop(PREFIX + "libimobiledevice", None)

have = {f.lower(): f for f in os.listdir(stage) if os.path.isfile(os.path.join(stage, f))}
os.makedirs(OUT, exist_ok=True)
need, missing, seen = [p + ".exe" for p in PROGRAMS], set(), set()
while need:
    f = need.pop()
    if f.lower() in seen: continue
    seen.add(f.lower())
    if f.lower() not in have:
        missing.add(f); continue
    shutil.copy(os.path.join(stage, have[f.lower()]), os.path.join(OUT, have[f.lower()]))
    need += imports(os.path.join(stage, have[f.lower()]))

system = {m for m in missing if re.match(r"(api-ms-|kernel32|msvcrt|user32|advapi32|ws2_32|shell32|ole32|crypt32|bcrypt|iphlpapi|setupapi|gdi32|shlwapi|version|winmm|secur32|wldap32|normaliz|userenv|rpcrt4|ntdll|comctl32|oleaut32|psapi|dnsapi|ucrtbase|mswsock|ncrypt|cfgmgr32)", m, re.I)}
with open(os.path.join(OUT, "VERSIONS.txt"), "w") as out:
    out.write("libimobiledevice 1.4.0 was compiled from the official source and is linked into each program.\n")
    out.write("The other libraries are Windows builds from the MSYS2 project (https://www.msys2.org), unmodified.\n")
    out.write("To rebuild everything: python3 fetch-tools.py (see the script for sources and checksums).\n\n")
    for n in sorted(versions): out.write(f"{n} {versions[n]}\n")
# Where every bundled part's source code comes from; published with each release as PortHop-sources.zip.
SHIPPED_MSYS2 = {"libplist": "LGPL-2.1", "libusbmuxd": "LGPL-2.1", "libimobiledevice-glue": "LGPL-2.1", "openssl": "Apache-2.0"}
with open(os.path.join(OUT, "SOURCES.txt"), "w") as out:
    out.write("PortHop for Windows bundles these open-source programs and libraries. Their source code is published with\n"
              "every PortHop release as PortHop-sources.zip: https://github.com/ARAVINDHRAJA123/porthop/releases\n\n")
    out.write("libimobiledevice 1.4.0: idevice_id, ideviceinfo, idevicepair, idevicebackup2 and idevicediagnostics\n"
              "  (programs GPL-2.0-or-later, library LGPL-2.1), compiled by fetch-tools.py, linked into each program.\n"
              f"  source: {SOURCE_URL}\n  SHA-256 {SOURCE_SHA256}\n")
    out.write("afcclient.exe and applist.exe: PortHop's own helpers (MIT), source in Helpers/ of the PortHop repository.\n\n")
    out.write("Windows builds from the MSYS2 project, used unmodified:\n")
    for name, lic in SHIPPED_MSYS2.items():
        ver = versions[PREFIX + name]
        out.write(f"  {name} {ver} ({lic})\n  source: https://repo.msys2.org/mingw/sources/mingw-w64-{name}-{ver}.src.tar.zst\n")
files = sorted(os.listdir(OUT))
print("programs:", [p for p in PROGRAMS if p + ".exe" in files])
print("not found:", [p for p in PROGRAMS if p + ".exe" not in files], "| unexpected missing libraries:", sorted(missing - system))
print(len([f for f in files if f.endswith(".dll")]), "libraries,", sum(os.path.getsize(os.path.join(OUT, f)) for f in files if os.path.isfile(os.path.join(OUT, f))) // 1024, "KB")
print({n.replace(PREFIX, ""): v for n, v in versions.items() if re.search("imobile|plist|usbmux|installer|openssl", n)})
