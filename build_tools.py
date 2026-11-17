#!/usr/bin/env python3
"""Builds the iPhone tools that PortHop bundles on the Mac, from the official source releases.

Homebrew's copies only run on the macOS version they were built for, so an app that bundles them
cannot be shared with people on older macOS. This script builds the same tools from source for
macOS 13 and later, links each one statically (no libraries to carry around), and records exactly
which source it used so that source can be published next to the app.

Output (reused on later runs unless this script changes):
  build/tools-mac/bin          the programs copied into PortHop.app/Contents/Helpers
  build/tools-mac/licenses     the licence of every package
  build/tools-mac/SOURCES.txt  where each source came from, with its SHA-256

Needs only Xcode's command-line tools (clang, make, perl). The first run takes a few minutes.
"""
import glob, hashlib, os, shutil, subprocess, sys, tarfile, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".tools-cache")
OUT = os.path.join(HERE, "build", "tools-mac")
WORK = os.path.join(OUT, "work")
STAGE = os.path.join(OUT, "stage")
MIN_MACOS = "13.0"
ARCH = "arm64"

# name: (download URL, SHA-256, licence files inside the source)
SOURCES = {
    "openssl": ("https://github.com/openssl/openssl/releases/download/openssl-3.6.5/openssl-3.6.5.tar.gz",
                "a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98", ["LICENSE.txt"]),
    "libplist": ("https://github.com/libimobiledevice/libplist/releases/download/2.7.0/libplist-2.7.0.tar.bz2",
                 "7ac42301e896b1ebe3c654634780c82baa7cb70df8554e683ff89f7c2643eb8b", ["COPYING", "COPYING.LESSER"]),
    "libimobiledevice-glue": ("https://github.com/libimobiledevice/libimobiledevice-glue/releases/download/1.3.2/libimobiledevice-glue-1.3.2.tar.bz2",
                              "6489a3411b874ecd81c87815d863603f518b264a976319725e0ed59935546774", ["COPYING"]),
    "libusbmuxd": ("https://github.com/libimobiledevice/libusbmuxd/releases/download/2.1.1/libusbmuxd-2.1.1.tar.bz2",
                   "5546f1aba1c3d1812c2b47d976312d00547d1044b84b6a461323c621f396efce", ["COPYING"]),
    "libimobiledevice": ("https://github.com/libimobiledevice/libimobiledevice/releases/download/1.4.0/libimobiledevice-1.4.0.tar.bz2",
                         "23cc0077e221c7d991bd0eb02150a0d49199bcca1ddf059edccee9ffd914939d", ["COPYING", "COPYING.LESSER"]),
}
OFFICIAL_TOOLS = ["idevice_id", "ideviceinfo", "idevicepair", "idevicebackup2", "idevicediagnostics", "afcclient"]
HELPERS = {"applist": "applist.c"}  # small programs of PortHop's own, in Helpers/

# The only change made to the official source: afcclient, when it reads commands from another program
# instead of a keyboard, dropped every byte outside plain ASCII, so folder names with accents or
# non-Latin letters (an external drive called "Été", say) were mangled. This keeps those bytes.
AFCCLIENT_PATCH = ("\t\tif (isprint(c)) {", "\t\tif (isprint(c) || c >= 0x80) {")

CONFIG_H = """/* Written by build_tools.py for a macOS build with OpenSSL. */
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
#define HAVE_GETIFADDRS 1
#define HAVE_LOCALTIME_R 1
#define HAVE_STPCPY 1
#define HAVE_STRNDUP 1
#define HAVE_STRCASECMP 1
#define HAVE_STRDUP 1
#define HAVE_STRERROR 1
#define HAVE_DIRENT_D_TYPE 1
#define HAVE_PTHREAD 1
#define HAVE_LIBPTHREAD 1
#define HAVE_DLFCN_H 1
#define HAVE_STDINT_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
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

ARCH_FLAGS = ["-arch", ARCH, f"-mmacosx-version-min={MIN_MACOS}"]
LOG = None


def run(cmd, cwd, env=None):
    LOG.write("\n$ " + " ".join(cmd) + "\n")
    LOG.flush()
    r = subprocess.run(cmd, cwd=cwd, env=env, stdout=LOG, stderr=subprocess.STDOUT)
    if r.returncode != 0:
        LOG.flush()
        tail = open(LOG.name, errors="replace").read()[-3000:]
        sys.exit(f"build step failed in {os.path.basename(cwd)}: {' '.join(cmd[:3])}…\n{tail}")


def fetch(name):
    url, sha, _ = SOURCES[name]
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, url.rsplit("/", 1)[1])
    if not os.path.exists(path):
        print("downloading", os.path.basename(path))
        urllib.request.urlretrieve(url, path + ".part")
        os.rename(path + ".part", path)
    if hashlib.sha256(open(path, "rb").read()).hexdigest() != sha:
        sys.exit(f"{os.path.basename(path)} does not match its expected checksum. Delete it from .tools-cache and try again.")
    return path


def unpack(name):
    path = fetch(name)
    with tarfile.open(path) as t:
        top = t.getnames()[0].split("/")[0]
        t.extractall(WORK, filter="data")
    return os.path.join(WORK, top)


def stamp():
    return hashlib.sha256(open(__file__, "rb").read() + b"".join(open(os.path.join(HERE, "Helpers", h), "rb").read() for h in HELPERS.values())).hexdigest()


def main():
    global LOG
    stamp_file = os.path.join(OUT, ".stamp")
    bins = os.path.join(OUT, "bin")
    wanted = OFFICIAL_TOOLS + list(HELPERS)
    if os.path.exists(stamp_file) and open(stamp_file).read() == stamp() and all(os.path.exists(os.path.join(bins, t)) for t in wanted):
        print("iPhone tools: up to date (build/tools-mac)")
        return
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(WORK)
    LOG = open(os.path.join(OUT, "build.log"), "w")
    print(f"building the iPhone tools for macOS {MIN_MACOS}+ ({ARCH}); the first run takes a few minutes")
    env = dict(os.environ, CC="clang", CXX="clang++", MACOSX_DEPLOYMENT_TARGET=MIN_MACOS,
               CFLAGS=" ".join(ARCH_FLAGS + ["-O2"]), CXXFLAGS=" ".join(ARCH_FLAGS + ["-O2"]), LDFLAGS=" ".join(ARCH_FLAGS),
               PKG_CONFIG_PATH=os.path.join(STAGE, "lib", "pkgconfig"), PKG_CONFIG_LIBDIR=os.path.join(STAGE, "lib", "pkgconfig"))
    jobs = f"-j{os.cpu_count() or 4}"

    print("  OpenSSL")
    src = unpack("openssl")
    run(["perl", "./Configure", f"darwin64-{ARCH}-cc", "no-shared", "no-tests", "no-docs", f"--prefix={STAGE}", "--libdir=lib",
         f"-mmacosx-version-min={MIN_MACOS}"], src, env)
    run(["make", jobs, "build_libs"], src, env)
    run(["make", "install_dev"], src, env)

    for name, extra in [("libplist", ["--without-cython", "--without-tools"]), ("libimobiledevice-glue", []), ("libusbmuxd", [])]:
        print("  " + name)
        src = unpack(name)
        run(["./configure", f"--prefix={STAGE}", "--disable-shared", "--enable-static"] + extra, src, env)
        run(["make", jobs], src, env)
        run(["make", "install"], src, env)

    # libimobiledevice: compiled directly, because its configure script insists on libtatsu, which
    # only a tool PortHop does not use (ideviceimagemounter) needs.
    print("  libimobiledevice")
    src = unpack("libimobiledevice")
    with open(os.path.join(src, "config.h"), "w") as f:
        f.write(CONFIG_H)
    afc = os.path.join(src, "tools", "afcclient.c")
    text = open(afc).read()
    if text.count(AFCCLIENT_PATCH[0]) != 1:
        sys.exit("afcclient.c no longer looks as expected; review AFCCLIENT_PATCH before building")
    open(afc, "w").write(text.replace(*AFCCLIENT_PATCH))
    cc = ["clang"] + ARCH_FLAGS + ["-O2", "-w", "-DHAVE_CONFIG_H", "-I" + src, "-I" + os.path.join(src, "include"), "-I" + os.path.join(STAGE, "include")]
    objs = []
    for c in sorted(glob.glob(os.path.join(src, "src", "*.c")) + glob.glob(os.path.join(src, "common", "*.c"))):
        o = os.path.join(WORK, "limd-" + os.path.basename(c)[:-2] + ".o")
        run(cc + ["-c", c, "-o", o], src)
        objs.append(o)
    lib = os.path.join(STAGE, "lib", "libimobiledevice-1.0.a")
    run(["ar", "rcs", lib] + objs, src)
    link = [lib] + [os.path.join(STAGE, "lib", n) for n in ("libimobiledevice-glue-1.0.a", "libusbmuxd-2.0.a", "libplist-2.0.a", "libssl.a", "libcrypto.a")] \
        + ["-framework", "CoreFoundation", "-framework", "SystemConfiguration", "-framework", "Security", "-Wl,-dead_strip"]
    os.makedirs(bins)
    for tool in OFFICIAL_TOOLS:
        run(cc + [os.path.join(src, "tools", tool + ".c")] + link + ["-o", os.path.join(bins, tool)], src)
    for tool, helper in HELPERS.items():
        run(cc + [os.path.join(HERE, "Helpers", helper)] + link + ["-o", os.path.join(bins, tool)], src)
    for tool in wanted:
        run(["strip", "-x", os.path.join(bins, tool)], src)  # drop debugging symbols; the code is unchanged

    # Licences and a record of the exact sources, to publish alongside the app.
    lines = ["PortHop bundles these open-source programs and libraries, built from the official source releases below",
             f"by build_tools.py for macOS {MIN_MACOS} and later ({ARCH}). The source code is published with every PortHop",
             "release as PortHop-sources.zip: https://github.com/ARAVINDHRAJA123/porthop/releases", ""]
    for name, (url, sha, licences) in SOURCES.items():
        d = os.path.join(OUT, "licenses", name)
        os.makedirs(d, exist_ok=True)
        top = os.path.join(WORK, os.path.basename(url).rsplit(".tar", 1)[0])
        for lic in licences:
            shutil.copy(os.path.join(top, lic), os.path.join(d, lic))
        lines.append(f"{name}: {url}\n  SHA-256 {sha}")
    lines += ["", "Programs: " + ", ".join(OFFICIAL_TOOLS) + " (from libimobiledevice, GPL-2.0-or-later);",
              "  applist (PortHop, MIT). The libraries are LGPL-2.1 (libplist, libimobiledevice-glue, libusbmuxd,",
              "  libimobiledevice) and Apache-2.0 (OpenSSL). Change made to the official source: in afcclient, bytes",
              "  outside ASCII are kept when commands come from another program (see AFCCLIENT_PATCH in build_tools.py)."]
    open(os.path.join(OUT, "SOURCES.txt"), "w").write("\n".join(lines) + "\n")
    shutil.rmtree(WORK)
    open(stamp_file, "w").write(stamp())
    print("iPhone tools: built", len(wanted), "programs into build/tools-mac/bin")


if __name__ == "__main__":
    main()
