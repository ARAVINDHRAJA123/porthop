#!/usr/bin/env python3
"""Builds everything for a public release into release/:

  PortHop-<version>-mac.zip       the Mac app (Apple Silicon, macOS 13 and later)
  PortHop-<version>-windows.zip   the Windows app (64-bit Windows 10 and 11)
  PortHop-<version>-setup.exe     the Windows installer, when windows/installer/Output/PortHop-Setup.exe was built (on Windows)
  PortHop-<version>-sources.zip   PortHop's own code plus the exact source of every bundled tool and library
  *.sig                           an Ed25519 signature of each app download, which the apps check before installing an update

Upload everything to the same GitHub release. The GPL and LGPL licences of the bundled tools require their
source to be offered from the same place as the apps; the sources zip is that offer.
Run it from a clean commit (it refuses otherwise, so the published source matches the published apps).

The update-signing key: the private half is kept in ~/.porthop-release (never in the repository; back it up, because
updates can't be signed without it), the public half is update-key.pub, which build.sh and package-win.js put into the
apps. `python3 make_release.py --key-only` creates the key (once) and does nothing else.
"""
import os, re, shutil, subprocess, sys, tempfile, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "release")
KEY_DIR = os.path.expanduser("~/.porthop-release")
KEY = os.path.join(KEY_DIR, "update-signing-key.pem")
PUB = os.path.join(HERE, "update-key.pub")


def node(script, *args):
    return subprocess.run(["node", "-e", script, *args], capture_output=True, text=True, check=True).stdout


def ensure_key():
    """Creates the update-signing key if there is none, and keeps update-key.pub matching it. True when update-key.pub changed."""
    if not os.path.exists(KEY):
        os.makedirs(KEY_DIR, mode=0o700, exist_ok=True)
        node("const c=require('crypto'),fs=require('fs');const k=c.generateKeyPairSync('ed25519');"
             "fs.writeFileSync(process.argv[1],k.privateKey.export({format:'pem',type:'pkcs8'}),{mode:0o600})", KEY)
        print(f"Created the update-signing key: {KEY}\nBack it up somewhere safe. Without it, updates can't be signed and the apps won't install them.")
    pub = node("const c=require('crypto'),fs=require('fs');process.stdout.write(c.createPublicKey(fs.readFileSync(process.argv[1]))"
               ".export({format:'der',type:'spki'}).subarray(12).toString('base64'))", KEY).strip()
    if os.path.exists(PUB) and open(PUB).read().strip() == pub:
        return False
    open(PUB, "w").write(pub + "\n")
    return True


def sign(path):
    """Writes path.sig: the file's Ed25519 signature (base64), checked by the apps before they install an update."""
    sig = node("const c=require('crypto'),fs=require('fs');process.stdout.write(c.sign(null,fs.readFileSync(process.argv[2]),"
               "c.createPrivateKey(fs.readFileSync(process.argv[1]))).toString('base64'))", KEY, path).strip()
    open(path + ".sig", "w").write(sig + "\n")


def sh(*cmd, cwd=HERE):
    subprocess.run(cmd, cwd=cwd, check=True)


def main():
    changed = ensure_key()
    if "--key-only" in sys.argv:
        print("update-key.pub is " + ("new: commit it, then build the apps." if changed else "up to date."))
        return
    if changed and "--allow-dirty" not in sys.argv:
        sys.exit("update-key.pub was written. Commit it, then run make_release.py again.")
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
    setup = os.path.join(win, "installer", "Output", "PortHop-Setup.exe")
    if os.path.exists(setup):
        shutil.copy(setup, os.path.join(OUT, f"{name}-setup.exe"))
    else:
        print("  (no installer: build windows/installer/PortHop.iss on Windows first to include one)")

    print("== Signatures")
    for f in sorted(os.listdir(OUT)):
        if re.search(r"-(mac\.zip|windows\.zip|setup\.exe)$", f):
            sign(os.path.join(OUT, f))

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
    print("Upload all of them, the .sig files included, to the same GitHub release.")


if __name__ == "__main__":
    main()
