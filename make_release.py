#!/usr/bin/env python3
"""Builds everything for a public release into release/:

  PortHop-<version>-mac.zip       the Mac app (Apple Silicon, macOS 13 and later)
  PortHop-<version>-windows.zip   the Windows app (64-bit Windows 10 and 11)
  PortHop-<version>-sources.zip   PortHop's own code plus the exact source of every bundled tool and library

Upload all three to the same GitHub release. The GPL and LGPL licences of the bundled tools require their
source to be offered from the same place as the apps; the sources zip is that offer.
Run it from a clean commit (it refuses otherwise, so the published source matches the published apps).
"""
import os, re, shutil, subprocess, sys, tempfile, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "release")


def sh(*cmd, cwd=HERE):
    subprocess.run(cmd, cwd=cwd, check=True)


def main():
    if subprocess.run(["git", "status", "--porcelain"], cwd=HERE, capture_output=True, text=True).stdout.strip() and "--allow-dirty" not in sys.argv:
        sys.exit("There are uncommitted changes. Commit them first, so the published source matches the apps (or pass --allow-dirty for a trial run).")
    version = subprocess.run(["plutil", "-extract", "CFBundleShortVersionString", "raw", "Info.plist"], cwd=HERE, capture_output=True, text=True).stdout.strip()
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    name = f"PortHop-{version}"

    print("== Mac app")
    sh("./build.sh")
    sh("ditto", "-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", "PortHop.app", os.path.join(OUT, f"{name}-mac.zip"))

    print("== Windows app")
    win = os.path.join(HERE, "windows")
    if not os.path.exists(os.path.join(win, "tools-win", "SOURCES.txt")):
        sh("python3", "fetch-tools.py", cwd=win)
    sh("node", "package-win.js", cwd=win)
    shutil.copy(os.path.join(win, "dist", "PortHop-Windows.zip"), os.path.join(OUT, f"{name}-windows.zip"))

    print("== Sources")
    with tempfile.TemporaryDirectory() as tmp:
        root = os.path.join(tmp, f"{name}-sources")
        os.makedirs(os.path.join(root, "porthop"))
        archive = subprocess.run(["git", "archive", "--format=tar", "HEAD"], cwd=HERE, capture_output=True, check=True).stdout
        subprocess.run(["tar", "-x", "-C", os.path.join(root, "porthop")], input=archive, check=True)
        sys.path.insert(0, HERE)
        import build_tools
        mac = os.path.join(root, "mac-tools")
        os.makedirs(mac)
        for pkg in build_tools.SOURCES:
            shutil.copy(build_tools.fetch(pkg), mac)
        shutil.copy(os.path.join(HERE, "build", "tools-mac", "SOURCES.txt"), mac)
        winsrc = os.path.join(root, "windows-tools")
        os.makedirs(winsrc)
        listing = open(os.path.join(win, "tools-win", "SOURCES.txt")).read()
        shutil.copy(os.path.join(win, "tools-win", "SOURCES.txt"), winsrc)
        for url in re.findall(r"source: (\S+)", listing):
            dest = os.path.join(winsrc, url.rsplit("/", 1)[1])
            cached = os.path.join(HERE, ".tools-cache", os.path.basename(dest))
            if os.path.exists(cached):
                shutil.copy(cached, dest)
            else:
                print("  downloading", os.path.basename(dest))
                urllib.request.urlretrieve(url, dest)
        electron = subprocess.run(["node", "-p", "require('./node_modules/electron/package.json').version"], cwd=win, capture_output=True, text=True).stdout.strip()
        open(os.path.join(root, "README.txt"), "w").write(f"""Source code for {name}

porthop/        PortHop itself (MIT licence): the Mac app, the Windows app, their helpers and build scripts.
mac-tools/      The exact source releases the Mac app's bundled tools were built from (see SOURCES.txt there;
                build_tools.py in porthop/ rebuilds them, including the one documented change to afcclient).
windows-tools/  The libimobiledevice source the Windows tools were built from, and the MSYS2 source packages
                of the Windows libraries bundled unmodified (see SOURCES.txt there; porthop/windows/fetch-tools.py
                rebuilds them).

The Windows app runs on Electron {electron} (MIT), which includes Chromium and FFmpeg (LGPL-2.1). Their source:
https://github.com/electron/electron/tree/v{electron} and https://chromium.googlesource.com/chromium/third_party/ffmpeg
""")
        sh("ditto", "-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", root, os.path.join(OUT, f"{name}-sources.zip"))

    print("\nRelease files in release/:")
    for f in sorted(os.listdir(OUT)):
        print(f"  {f}  {os.path.getsize(os.path.join(OUT, f)) // 1_000_000} MB")
    print("Upload all three to the same GitHub release.")


if __name__ == "__main__":
    main()
