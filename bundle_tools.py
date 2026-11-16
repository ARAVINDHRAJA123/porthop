#!/usr/bin/env python3
"""Copies the libimobiledevice tools and their libraries into the app so it runs without Homebrew."""
import os, shutil, subprocess, sys

app = sys.argv[1]
src_dirs = ["build", "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
tools = ["idevice_id", "ideviceinfo", "afcclient", "idevicepair", "applist", "idevicebackup2", "idevicediagnostics"]
helpers = os.path.join(app, "Contents/Helpers")
frameworks = os.path.join(app, "Contents/Frameworks")
os.makedirs(helpers, exist_ok=True)
os.makedirs(frameworks, exist_ok=True)

def deps(path):
    out = subprocess.check_output(["otool", "-L", path], text=True).splitlines()[1:]
    return [l.split()[0] for l in out if not l.split()[0].startswith(("/usr/lib", "/System", "@"))]

def run(*a):
    subprocess.check_call(a, stderr=subprocess.DEVNULL)

copied = {}
def add_lib(path):
    real = os.path.realpath(path)
    name = os.path.basename(path)
    if name in copied:
        return
    dest = os.path.join(frameworks, name)
    shutil.copyfile(real, dest)
    os.chmod(dest, 0o755)
    copied[name] = dest
    for d in deps(real):
        if os.path.basename(d) != name:
            add_lib(d)

binaries = []
for t in tools:
    src = next((os.path.join(d, t) for d in src_dirs if os.path.exists(os.path.join(d, t))), None)
    if not src:
        sys.exit(f"missing tool: {t} (brew install libimobiledevice)")
    dest = os.path.join(helpers, t)
    shutil.copyfile(os.path.realpath(src), dest)
    os.chmod(dest, 0o755)
    binaries.append(dest)
    for d in deps(dest):
        add_lib(d)

for path in binaries + list(copied.values()):
    is_lib = path in copied.values()
    if is_lib:
        run("install_name_tool", "-id", "@rpath/" + os.path.basename(path), path)
    for d in deps(path):
        run("install_name_tool", "-change", d, "@executable_path/../Frameworks/" + os.path.basename(d), path)
    run("codesign", "--force", "--sign", "-", path)
# The bundled libraries decide which macOS versions the app can run on; record that honestly.
import re
newest = (13, 0)
for path in copied.values():
    out = subprocess.run(["vtool", "-show-build", path], capture_output=True, text=True).stdout
    m = re.search(r"minos (\d+)\.(\d+)", out)
    if m: newest = max(newest, (int(m.group(1)), int(m.group(2))))
subprocess.call(["plutil", "-replace", "LSMinimumSystemVersion", "-string", "%d.%d" % newest, os.path.join(app, "Contents/Info.plist")])
print("minimum macOS:", "%d.%d" % newest)
print("bundled", len(binaries), "tools and", len(copied), "libraries")
