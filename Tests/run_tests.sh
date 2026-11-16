#!/bin/bash
# Engine tests against a simulated iPhone. No real device is touched.
set -euo pipefail
cd "$(dirname "$0")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
./make_fake_phone.sh "$T/phone" >/dev/null
./make_fake_backup.py "$T/backup/0000-TEST"; ENCRYPTED=1 ./make_fake_backup.py "$T/backup/0000-LOCKED"; ./encrypt_fake_backup.py "$T/backup/0000-TEST" "$T/backup/0000-SECURE" "correct horse"
cp EngineTests.swift "$T/main.swift"
swiftc -swift-version 5 -O ../Sources/Engine.swift ../Sources/Android.swift ../Sources/BackupReader.swift ../Sources/BackupCrypto.swift "$T/main.swift" -lsqlite3 -o "$T/enginetest" 2>&1 | grep error || true
FAKE_PHONE="$T/phone" "$T/enginetest" "$T" "$PWD/fake-tools"
