#!/bin/bash
# Engine tests against a simulated iPhone. No real device is touched.
set -euo pipefail
cd "$(dirname "$0")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
./make_fake_phone.sh "$T/phone" >/dev/null
SPYWARE=1 ./make_fake_backup.py "$T/spybackup/0000-SPY"
./make_fake_backup.py "$T/backup/0000-TEST"; ENCRYPTED=1 ./make_fake_backup.py "$T/backup/0000-LOCKED"; ./encrypt_fake_backup.py "$T/backup/0000-TEST" "$T/backup/0000-SECURE" "correct horse"
cp EngineTests.swift "$T/main.swift"
swiftc -swift-version 5 -O ../Sources/Models.swift ../Sources/Device.swift ../Sources/Catalog.swift ../Sources/Exporter.swift ../Sources/Thumbnails.swift ../Sources/Volumes.swift ../Sources/Backup.swift ../Sources/Ask.swift ../Sources/Android.swift ../Sources/LocationScrubber.swift ../Sources/Updates.swift ../Sources/BackupReader.swift ../Sources/BackupCrypto.swift ../Sources/Spyware.swift ../Sources/ScreenStream.swift ../Sources/Music.swift ../Sources/Apps.swift ../Sources/Cleanup.swift "$T/main.swift" -lsqlite3 -o "$T/enginetest" 2>&1 | grep error || true
FAKE_PHONE="$T/phone" "$T/enginetest" "$T" "$PWD/fake-tools"
# The porthop command line, against the same simulated iPhone.
swiftc -swift-version 5 -O ../Sources/Models.swift ../Sources/Device.swift ../Sources/Catalog.swift ../Sources/Exporter.swift ../Sources/Backup.swift ../Sources/Android.swift ../Sources/LocationScrubber.swift ../Sources/Spyware.swift ../Sources/BackupReader.swift ../Sources/BackupCrypto.swift ../Sources/Apps.swift ../Sources/Music.swift ../CLI/main.swift -lsqlite3 -o "$T/porthop" 2>&1 | grep error || true
export FAKE_PHONE="$T/phone" PORTHOP_TOOLS_DIR="$PWD/fake-tools"
cli_fail=0
has() { case "$1" in *"$2"*) ;; *) echo "  porthop: missing $2"; cli_fail=1 ;; esac; }
has "$("$T/porthop" devices --json)" '"kind" : "ios"'
has "$("$T/porthop" groups)" $'smart_hidden\tHidden\t39 items'
has "$("$T/porthop" groups --json)" '"id" : "person:mum"'
set +e
first="$("$T/porthop" copy Hidden "$T/cli-out" --pattern "{year}/{month}" --names "{year}-{month}-{day} {hour}.{minute}.{second}" 2>/dev/null)"; code1=$?
again="$("$T/porthop" copy smart_hidden "$T/cli-out" --pattern "{year}/{month}" --names "{year}-{month}-{day} {hour}.{minute}.{second}" --json 2>/dev/null)"
"$T/porthop" copy "No Such Album" "$T/cli-out" >/dev/null 2>&1; code3=$?
set -e
has "$first" "Copied 38, already there 0, couldn't copy 1"; has "$again" '"skipped" : 38'
[ $code1 -eq 1 ] && [ $code3 -eq 2 ] || { echo "  porthop: exit codes $code1 $code3"; cli_fail=1; }
export PORTHOP_INDICATORS_DIR="$T/indicators-cli"
has "$("$T/porthop" indicators golden/spyware/indicators.stix2)" "17 indicators from 1 source"
set +e
spy="$("$T/porthop" check "$T/spybackup/0000-SPY" --json)"; code4=$?
"$T/porthop" check "$T/backup/0000-TEST" >/dev/null; code5=$?
music="$("$T/porthop" music "$T/cli-music" --json 2>/dev/null)"; code6=$?
set -e
has "$spy" '"spyware" : "StalkTest"'; has "$music" '"copied" : 5'; has "$("$T/porthop" apps)" $'com.example.notes	Tabs & Notes'
[ $code4 -eq 1 ] && [ $code5 -eq 0 ] && [ $code6 -eq 0 ] || { echo "  porthop: check/music exit codes $code4 $code5 $code6"; cli_fail=1; }
[ "$(find "$T/cli-out" -type f \( -name '*.JPG' -o -name '*.MOV' \) | wc -l | tr -d ' ')" = "38" ] || { echo "  porthop: wrong file count"; cli_fail=1; }
if [ $cli_fail = 0 ]; then echo "PASS porthop command line"; else echo "FAIL porthop command line"; exit 1; fi
