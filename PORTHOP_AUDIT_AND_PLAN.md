# PortHop v2.0 — End-to-End Code Audit & Improvement Plan (Handoff for Opus)

**Repository root:** repository root (`.`)  
**Windows edition:** `windows/`  
**Installed macOS app:** `/Applications/PortHop.app`  
**Date:** 2026-11-22

---

## 1. Repository & Architecture Overview

PortHop is a standalone USB photo, video, file, and backup transfer utility for iPhone, iPad, and Android, implemented as two parallel apps in one repository:

### macOS App (Native Swift 5 + AppKit/SwiftUI + C Helpers)
* **Build:** Flat `swiftc -swift-version 5 -O -target arm64-apple-macos13.0 -parse-as-library Sources/*.swift -lsqlite3` via `build.sh` (ad-hoc signed, not notarized, Apple Silicon only).
* **Bundle metadata (`Info.plist`):** `CFBundleIdentifier = io.github.aravindhraja123.porthop`, version `2.0` (build `3`), `LSMinimumSystemVersion = 13.0`.
* **Release size:** `release/PortHop-2.0-mac.zip` = **18.6 MB** (`release/PortHop-2.0-sources.zip` = **121.1 MB** for GPL/LGPL compliance).
* **Source files (`Sources/`, ~335 KB total):**
  * `Engine.swift` (65.8 KB) — Models, `Shell`, `Tools`, `AFC`, `CatalogReader` (`Photos.sqlite`), `Exporter`, `ThumbnailLoader`, `VolumeInfo`, `Backup`.
  * `Screens.swift` (47.7 KB) — Secondary screens and views.
  * `Shores.swift` (40.1 KB) — Main Shores drag-and-drop transfer screen.
  * `Manager.swift` (39.5 KB) — App state coordinator / controller.
  * `BackupReader.swift` (25.3 KB) — Plain & encrypted iOS backup reader (Messages, WhatsApp, Contacts, Notes, Calendar, Safari, Call Log, Backup Files).
  * `FastTable.swift` (23.2 KB) — High-performance table view for large photo libraries.
  * `TopBar.swift` (18.3 KB) — Toolbar & Ask PortHop bar.
  * `DataView.swift` (16.2 KB) — Backup data explorer UI.
  * `BackupView.swift` (15.8 KB) — Backup & Restore UI.
  * `Views.swift` (14.0 KB) — Shared UI components.
  * `Android.swift` (10.8 KB) — ADB device detection, setup (`setUp()`), file browser, pull/push, power.
  * `Home.swift` (9.3 KB) — Home/connection views.
  * `BackupCrypto.swift` (6.5 KB) — PBKDF2 / AES key unwrap / AES-CBC file decryption for encrypted iOS backups.
  * `Timeline.swift` (6.4 KB) — Month-by-month timeline scrubber.
  * `App.swift` (1.6 KB) — App entry point.
* **Custom C Helpers (`Helpers/`):**
  * `afcmini.c` (14.4 KB) — Lightweight `afcclient` replacement (used on Windows; supports `ls`, `info`, `mkdir`, `get`, `put`, interactive stdin batching, `--documents`, and `-n` network lookup).
  * `applist.c` (2.4 KB) — Lists iOS apps with `UIFileSharingEnabled`.
* **Tooling & Tests:** `build_tools.py` (10.7 KB), `make_release.py` (4.8 KB), `Tests/EngineTests.swift` (14.4 KB), `Tests/run_tests.sh`, `Tests/make_fake_phone.sh`, `Tests/make_fake_backup.py`, `Tests/encrypt_fake_backup.py`, `Tests/fake-tools/*`.

### Windows App (Electron 45 + Node `node:sqlite` + Material 3 Expressive UI)
* **Packaging:** `windows/package-win.js` (`@electron/packager`, `win32`/`x64`, `asar: true`) + `windows/fetch-tools.py` (MSYS/libimobiledevice tools into `tools-win/`).
* **Release size:** `release/PortHop-2.0-windows.zip` = **162.5 MB** (~8.7× the Mac build).
* **Core (`windows/core/`):** `backup.js` (24.9 KB), `ios.js` (11.6 KB), `exporter.js` (8.6 KB), `catalog.js` (8.4 KB), `android.js` (5.7 KB), `shell.js` (4.1 KB), `plist.js` (3.2 KB).
* **Main & IPC:** `windows/main.js` (27.8 KB), `windows/preload.js` (1.1 KB).
* **Renderer (`windows/renderer/`):** `app.js` (78.7 KB), `style.css` (33.0 KB), `icons.js` (30.1 KB), `theme.css` (16.9 KB), `index.html` (490 B).
* **Tests (`windows/test/`):** `run.js` (7.8 KB), `backup.js` (5.5 KB).

---

## 2. Verified Code-Level Findings (Bugs, Bottlenecks, Parity Gaps & Security)

The following issues were confirmed directly by reading `Helpers/afcmini.c`, `Sources/BackupCrypto.swift`, `Sources/Android.swift`, `Sources/Engine.swift`, `windows/package.json`, `windows/package-win.js`, `windows/preload.js`, `windows/main.js`, `windows/core/exporter.js`, `windows/core/catalog.js`, and `windows/core/ios.js`.

### A. Concrete Bugs & Reliability Risks

1. **Cross-platform Export Manifest Format Incompatibility (HIGH)**
   * **Mac (`Sources/Engine.swift:542`):** Encodes `.iPhoneAlbumExtractor-manifest.json` as a JSON **object** (`[String: ExportManifestEntry]`) keyed by `asset.uuid` (or `asset.id`).
   * **Windows (`windows/core/exporter.js:31, 132`):** Encodes `.iPhoneAlbumExtractor-manifest.json` as a JSON **array** (`[...manifest.values()]`) keyed in memory by `sourceRemotePath`.
   * **Impact:** Using the same external SSD/folder across both Mac and Windows causes each app to silently fail decoding the other's manifest and overwrite it.
   * **Fix:** Standardize on one versioned schema (e.g., `{ "version": 2, "entries": { ... } }`) and accept both legacy dict and legacy array formats on read.

2. **Encrypted Backup Keybag & Decryption Edge Cases (`Sources/BackupCrypto.swift`) (HIGH)**
   * **Lines 54–62 (`unlock`):** Requires both `DPSL` and `DPIC` (iOS 10.2+ double-PBKDF2); returns `.unreadable` on older backups lacking `DPSL`/`DPIC` instead of falling back to single PBKDF2-SHA1.
   * **Lines 65–69 (`unlock`):** Unwraps *every* class containing `WPKY` using `passKey` without checking the `WRAP` bitmask (`WRAP & 2 != 0` for passcode-wrapped keys). On real iOS keybags that contain hardware-only or differently wrapped classes, this can falsely return `.wrongPassword`.
   * **Lines 77–97 (`decrypt`):**
     * Uses legacy ObjC `output.write(_:)` instead of Swift throwing `try output.write(contentsOf:)`. If the temp volume fills up, ObjC `NSFileHandle.write(_:)` throws an uncatchable `NSException` and crashes the app.
     * Calls `CCCryptorUpdate` in a loop without `CCCryptorFinal`. While safe when `size != nil` and AES-CBC `options = 0`, any file with missing/nil `size` retains raw PKCS7 padding bytes.
   * **Lines 100–112 (`fileRecord`):** Picks the first `Data` of length 44 in `$objects` rather than following the `EncryptionKey` `CFKeyedArchiverUID` pointer from the `MBFile` dictionary.

3. **Partial File Cleanup Missing in `Helpers/afcmini.c` (MEDIUM–HIGH)**
   * **`get_file()` (lines 97–115):** If `afc_file_read` or `fwrite` fails mid-transfer (`rc = 1`), the partially written `local` file is left on disk. Because `get_file()` rejects existing targets (`if (local_exists(local))`), retries against the same path fail unless the caller creates a fresh staging path.
   * **`get_file()`** does not restore `st_mtime` from the device.
   * **`real_main()` stdin loop (lines 221–231):** Emits no deterministic completion sentinel (`OK` / `ERR`) per command, making interactive streaming framing brittle; `split()` caps at `max = 8` tokens.
   * **`cmd_ls()` (line 80):** Uses non-reentrant `localtime(&mt)`.

4. **Thumbnail Cache Collision Across Multiple iOS Devices (`Sources/Engine.swift:752–794`) (MEDIUM)**
   * `ThumbnailLoader` keys both `NSCache<NSNumber, NSImage>` and disk files (`\(asset.id)_a.jpg`) solely by SQLite `Z_PK` (`asset.id`), NOT `(device.udid, asset.uuid)`.
   * Connecting two iPhones or switching devices can serve cached thumbnails from the wrong device for matching `Z_PK` rows.

5. **Windows Exporter `skipExisting: false` Bug & Crash-Loss Risk (`windows/core/exporter.js`) (MEDIUM)**
   * **Line 55:** Checks `manifest.get(item.remote)` and skips existing files *even when `options.skipExisting === false`* (only the fallback filename+size check on line 59 respects `options.skipExisting !== false`).
   * **Line 132:** Writes the manifest only once in `finally` at the end of the entire export (unlike macOS `Engine.swift:724`, which saves after every 60-file chunk). An app crash or power loss mid-transfer loses all manifest progress.

6. **Windows `adb:setup` Missing Signature Verification (`windows/main.js:251–268`) (MEDIUM — Security)**
   * macOS (`Sources/Android.swift:26–30`) downloads `platform-tools-latest-darwin.zip` and strictly verifies Google's Apple code signature (`codesign --verify --strict` + `TeamIdentifier=EQHXZ8M8AV`).
   * Windows (`windows/main.js:251–268`) downloads and extracts `platform-tools-latest-windows.zip` with no Authenticode signature check (`Get-AuthenticodeSignature`) or SHA-256 check.

7. **Swift `DateFormatter` Shared Across Threads (`Sources/Engine.swift:9–18`) (LOW–MEDIUM)**
   * `Fmt.date` and `Fmt.yearMonth` are global `static let DateFormatter` instances accessed from background threads (`CatalogReader.load`, `Exporter.run`). Replace with thread-safe `Date.FormatStyle` or per-call/actor-isolated formatters.

8. **Electron Preload Listener Leak (`windows/preload.js:8`) (LOW)**
   * `on: (name, fn) => { ipcRenderer.on(...) }` provides no unsubscribe function.

---

### B. Performance & Footprint Bottlenecks

1. **Windows Thumbnail IPC is O(N × Albums) per Request (`windows/main.js:274–278`) (HIGH)**
   * `const a = albums().flatMap((x) => x.assets).find((x) => x.id === id);`
   * On a 50,000-photo library across 20 albums, scrolling 100 thumbnails allocates and scans millions of array references on the Electron main process!
   * **Fix:** Maintain a `Map<id, asset>` (`S.byId`) built once when `loadCatalog` completes → `O(1)` lookup.

2. **macOS HEIC → JPEG Conversion Spawns `/usr/bin/sips` Serially per File (`Sources/Engine.swift:680–688`) (HIGH)**
   * Runs `Shell.run("/usr/bin/sips", ...)` synchronously inside the post-batch settlement loop, paying process-spawn overhead for every HEIC image.
   * **Fix:** `ImageIO` is already imported in `Engine.swift`—use in-process `CGImageSource` + `CGImageDestination` (with EXIF/orientation preservation) across a concurrent worker pool for 5–10× faster conversion.

3. **Per-Thumbnail Process Spawn + Lockdown Handshake (`Sources/Engine.swift:778` & `windows/core/ios.js:154`) (HIGH)**
   * Both macOS `ThumbnailLoader.fetch` and Windows `ios.thumbnail` spawn a fresh `afcclient` subprocess (which establishes a new USB/lockdown/AFC session) for *every single thumbnail*.
   * **Fix:** Keep 2–3 persistent interactive `afcclient` stdin/stdout worker processes (or add a lightweight protocol to `afcmini.c`) while browsing a library.

4. **Windows Bundle Size is 162.5 MB (`release/PortHop-2.0-windows.zip`) (MEDIUM–HIGH)**
   * Nearly 9× larger than the 18.6 MB Mac zip due to full Electron 45 + Chromium + all 50+ Chromium locale `.pak` files + `LICENSES.chromium.html` + MSYS DLLs.
   * **Quick wins in `windows/package-win.js`:** Strip unused Chromium locales (keep `en-US.pak` or supported languages) and audit `tools-win/` DLLs for unused transitive libs.
   * **Long-term option:** Evaluate Tauri / WebView2 to drop Windows bundle size from ~162 MB to ~20–30 MB and cut idle RAM dramatically.

5. **Windows Main-Process Synchronous Disk Polling (`windows/core/exporter.js:18, 103`) (MEDIUM)**
   * `dirSize(staging)` calls `fs.readdirSync` + `fs.statSync` synchronously on the main process every 500ms during export. Switch to `fs.promises` or track bytes via progress events from `afcmini.c`.

6. **Windows `drives()` Spawns PowerShell (`windows/main.js:154–166`) (LOW–MEDIUM)**
   * Spawning `powershell.exe -Command Get-CimInstance ...` incurs ~300–800ms startup latency on Windows. Consider a tiny native helper or `wmic`/Win32 API call, or increase cache TTL + event-driven refresh.

---

### C. Cross-Platform Parity & Documentation Drift

* **HEIC conversion & preview missing on Windows:** `windows/core/exporter.js` does not implement `convertHEIC`, and `windows/core/ios.js:158` cannot display HEIC thumbnails when `5005.JPG`/`5003.JPG` are absent.
* **Version mismatch:** `Info.plist` is `2.0` (build `3`), while `windows/package.json` is `"0.1.0"`.
* **Legacy naming artifacts:** `.iPhoneAlbumExtractor-manifest.json`, `.iPhoneAlbumExtractor-staging-`, `iPhoneAlbumExtractor2-cache`, `PhoneAlbumExtractor-` temp dirs, `pae-pack-`, `--pae-ui-test=`, `PAE_*` env vars.
* **README drift:** `README.md` still says Android requires manually installing `adb` into `~/Library/Application Support/iPhoneAlbumExtractor/android/`, even though both macOS (`Android.swift:setUp()`) and Windows (`main.js:adb:setup`) now have built-in one-click Google `platform-tools` downloaders and macOS defaults to `~/Library/Application Support/PortHop/android`.

---

## 3. Prioritized Improvement & Optimization Roadmap

### Pillar 1: High-Impact Power Features
1. **Export Edited Photos & Full Metadata:**
   * Query `ZADJUSTMENTSSTATE` (or `ZHASADJUSTMENTS`) in `Photos.sqlite` and offer an option to export Apple Photos' rendered edits (`PhotoData/Mutations/<dir>/<stem>/Adjustments/FullSizeRender.jpg` or `.mov`) alongside or instead of originals, plus optional `.AAE` sidecars.
   * Add Windows HEIC → JPEG conversion parity (e.g., via Windows Imaging Component / bundled lightweight converter).
2. **Pre-Flight iCloud-Only Detection:**
   * Query `ZCLOUDLOCALSTATE` / `ZVISIBILITYSTATE` in `Photos.sqlite` (with schema guards) to surface a count and filter for iCloud-only assets *before* starting a transfer, plus an exportable CSV/list of skipped cloud-only items.
3. **Custom Folder Templates & Saved Shores Presets:**
   * Expand `SubfolderMode` beyond `flat` / `yearMonth` / `iphoneFolder` to customizable templates (e.g., `YYYY/MM - Month/`, `Album/YYYY-MM/`).
   * Allow saving recurring **Shores** presets (e.g., "2026 Videos → Samsung T7") for one-click incremental syncs.
4. **Content-Verified Deduplication & Resumable Transfers:**
   * Unify the Mac/Windows manifest format (v2 schema), add fast partial-hash verification (head + tail + size) for safer duplicate detection, and persist chunked progress on both platforms.
5. **Wi-Fi Transfer Mode (Opt-In):**
   * `afcmini.c`, `Engine.swift` (`Device.isNetwork`), and `ios.js` already have `-n` (`IDEVICE_LOOKUP_NETWORK`) plumbing—currently disabled in `findDevices()` because Wi-Fi is slower for full library reads. Add an opt-in "Show Wi-Fi devices" toggle (and `adb pair` / wireless debugging support for Android) for convenient incremental syncs.
6. **Rich Backup Reader Exports:**
   * Upgrade `BackupReader` (Swift & JS) from placeholder attachments and note opening lines to full media/attachment extraction in Messages & WhatsApp, full rich-text/protobuf Notes decoding, and clean HTML/PDF conversation exports alongside CSV.
7. **Android Album & MediaStore Parity:**
   * Query Android's `MediaStore` via `adb shell content query --uri content://media/external/images/media` (and video URI) so Android devices gain album grouping, favorites, screenshots, and timeline views instead of folder-only browsing.

### Pillar 2: Graduate Beta Features to Production
1. **Real-Device QA Matrix:** Verify Android mode, Backup & Restore, Backup Reader (plain & encrypted), and the Windows edition on real hardware (iOS 18–27, Android 13–15, Windows 11 with Apple Devices / iTunes drivers).
2. **Guided Driver & Tool Preflight:** On Windows, detect whether Apple Mobile Device Support (`AppleMobileDeviceService` / `usbmuxd`) is installed and running and provide an actionable preflight banner; surface one-click `adb` setup cleanly on both platforms.
3. **SQLite WAL Resilience:** When copying `Photos.sqlite` + `-wal` + `-shm`, handle active-WAL edge cases gracefully (retry or fallback to `immutable=1` URI if read-only open fails).

### Pillar 3: Performance & Footprint Optimization
1. Replace per-file `/usr/bin/sips` with parallel in-process `ImageIO` (`CGImageDestination`) in `Engine.swift`.
2. Replace per-thumbnail `afcclient` spawns with a persistent interactive `afcclient` worker pool, and key caches by `(device.udid, asset.uuid)`.
3. Replace `O(N × albums)` thumbnail lookup in `windows/main.js` with an `O(1)` `Map`.
4. Add `OK`/`ERR` framing, `st_mtime` preservation, and partial-file unlink on failure in `Helpers/afcmini.c`.
5. Prune unused Chromium locales/assets in `windows/package-win.js` (and evaluate Tauri/WebView2 long term).

### Pillar 4: Architecture & Maintainability
1. **Modularize monolithic files:** Split `Engine.swift` (65.8 KB), `Screens.swift` (47.7 KB), `Shores.swift` (40.1 KB), `Manager.swift` (39.5 KB), and `windows/renderer/app.js` (78.7 KB) into focused modules.
2. **Cross-platform Golden Test Suite:** Create shared JSON test fixtures for `Photos.sqlite` schema parsing, Ask PortHop natural-language query parsing, and backup decoding, executed by both `Tests/run_tests.sh` and `windows/test/run.js` to prevent Swift/JS logic drift.
3. **SwiftPM Migration:** Introduce a lightweight `Package.swift` for incremental macOS builds and native `swift test`, keeping `build.sh` for `.app` bundling and signing.

### Pillar 5: Distribution & Polish
1. **Signing & Updates:** Developer ID signing + Apple notarization for macOS, Sparkle auto-updates, and a signed Windows installer (MSIX or Inno Setup) instead of a raw zip.
2. **Optional Universal macOS Binary:** Add `x86_64` + `lipo` in `build.sh` if Intel Mac support is desired.
3. **Cleanup:** Sync `windows/package.json` version to `2.0.0`, update `README.md`, and migrate legacy `iPhoneAlbumExtractor` / `PAE` identifiers cleanly (with backward-compatible read fallbacks).

---

## 4. Suggested Rollout Order

| Phase | Focus | Key Deliverables | Priority |
| :--- | :--- | :--- | :--- |
| **Phase 1: Correctness & Security** | Fix verified bugs & harden beta | Unify Mac/Win manifest schema, fix `BackupCrypto.swift` (`WRAP & 2`, legacy PBKDF2, throwing `write`), fix `afcmini.c` partial-file cleanup, fix Windows `skipExisting: false` & `adb` signature check, fix multi-device thumb cache key, real-device QA | **P0** |
| **Phase 2: Speed & Footprint** | Eliminate bottlenecks | `O(1)` thumb map in `windows/main.js`, in-process `ImageIO` HEIC conversion on Mac, persistent `afcclient` thumbnail workers, prune Windows Electron bundle | **P1** |
| **Phase 3: Power Features** | Differentiating capabilities | Edited-photo export (`ZADJUSTMENTSSTATE`), iCloud-only pre-flight (`ZCLOUDLOCALSTATE`), Windows HEIC conversion, custom folder templates, saved Shores presets, Android `MediaStore` albums | **P1–P2** |
| **Phase 4: Architecture & Ecosystem** | Scale & polish | Split monolithic Swift/JS files, shared Swift/JS golden test suite, Wi-Fi opt-in sync, rich Messages/WhatsApp media export, SwiftPM, notarization + Windows installer | **P2** |

---

## 5. Remaining Files for Opus to Audit End-to-End

The files below were inventoried but not yet read line-by-line; Opus should inspect them first to complete the full audit:
* **macOS Core & Backups:** `Sources/Manager.swift`, `Sources/BackupReader.swift`, `Helpers/applist.c`, `build_tools.py`, `make_release.py`, `Tests/EngineTests.swift`.
* **macOS UI & Ask PortHop:** `Sources/Shores.swift`, `Sources/Screens.swift`, `Sources/FastTable.swift`, `Sources/TopBar.swift`, `Sources/Timeline.swift`, `Sources/DataView.swift`, `Sources/BackupView.swift`, `Sources/Home.swift`, `Sources/Views.swift`.
* **Windows Core & UI:** `windows/core/backup.js`, `windows/core/android.js`, `windows/core/shell.js`, `windows/core/plist.js`, `windows/renderer/app.js`, `windows/fetch-tools.py`, `windows/test/run.js`, `windows/test/backup.js`.

### Build & Test Commands
```bash
# macOS build (and optional install to /Applications)
./build.sh
./build.sh --install

# macOS engine tests (simulated iPhone)
./Tests/run_tests.sh

# Windows tests (runs via Node on macOS)
cd windows && npm test

# Full cross-platform release bundle (Mac + Windows + Sources)
python3 make_release.py
```

---

## 6. Competitive Analysis (November 2026)

PortHop sits where five kinds of tools overlap. Each group has one or two leaders worth beating.

| Group | Leaders | What they do best | Where they fall short |
| :--- | :--- | :--- | :--- |
| **All-in-one iPhone managers** | iMazing 3 (Mac/Win), AnyTrans, Dr.Fone/MobileTrans, Tenorshare, EaseUS MobiMover, Syncios, WinX MediaTrans | iMazing: scheduled Wi-Fi backups with snapshot retention (iMazing Mini), Messages/WhatsApp export to PDF/Excel for legal use, file search across device and backups (3.5), screen recording, spyware analyzer (MVT indicators), Configurator. AnyTrans: phone switcher, iCloud manager, LINE/Viber. WinX: auto-import on connect. | iMazing is subscription-only since June 2025 and its Android support is still "coming". The vendor suites draw constant complaints about billing and cancellation, devices not detected, clutter and upsells, and "backup said complete but wasn't". |
| **Photo transfer** | CopyTrans Photo/Studio (Win), Image Capture (Mac), Windows Photos/Explorer import, Apple Devices (Win), PhotoSync, osxphotos | CopyTrans: albums both ways, HEIC→JPEG, Live Photos. PhotoSync: wireless auto-transfer to computers and NAS. osxphotos: the best folder/file templates, XMP/JSON sidecars, people and album keywords (Mac Photos library only). | Image Capture silently misses iCloud-optimised items and, since macOS 15.4, the locked Hidden album; counts don't match the library. Windows import fails on videos and drops HEIC; Apple Devices can't copy photos off the phone; Phone Link has no iPhone photos. CopyTrans is Windows-only and sold per app. |
| **Android ↔ computer** | OpenMTP, MacDroid, LocalSend, Syncthing, KDE Connect | OpenMTP: free MTP on Mac. MacDroid: Finder mount, Wi-Fi (Pro). LocalSend: one-off wireless sends. Syncthing: continuous sync. | Android File Transfer is abandoned; MTP tools see folders, not albums; two-way copying is a paid tier in MacDroid. None of them also handles iPhones. |
| **Backup readers** | Reincubate iPhone Backup Extractor, iBackup Viewer, imessage-exporter, iLEAPP, MVT | Reincubate: photos, messages, notes, contacts, calendars, voice memos, call history and WhatsApp out of a backup, as PDF/vCard/iCal. imessage-exporter: free HTML export with attachments, encrypted backups. iLEAPP: hundreds of forensic artefacts. | Most are paid or command-line only. None is part of a transfer app, so people juggle three tools. |
| **Device health** | 3uTools, coconutBattery | Battery cycles/health, a parts "verification report". | 3uTools' figures are disputed and it is a jailbreak toolkit; coconutBattery is Mac-only. |

**Where PortHop already leads:** free and open source with no account, subscription, upsell or telemetry; one app for iPhone, iPad and Android on both Mac and Windows; reads the phone's own Photos library, so Hidden, Favourites, Screenshots, Selfies and the person's own albums come across as they are; iCloud-only items are counted before copying (Image Capture silently skips them); edited versions; HEIC→JPEG on both systems; Ask PortHop ("hidden videos from 2024 to T7"), which no competitor has; incremental hops with a manifest shared by both apps; saved hops; folder patterns; a backup reader for plain and encrypted backups with chats as web pages.

**How PortHop one-ups each leader (Phase 6):**

| Area | Best today | PortHop answer |
| :--- | :--- | :--- |
| Automatic copying | WinX auto-import, PhotoSync Autotransfer (paid), iMazing Mini (paid) | Saved hops can run by themselves whenever the phone is plugged in. They copy only what is new and post a notification. |
| Organising | osxphotos templates (Mac library only) | File-name patterns alongside folder patterns, new `{device}`, `{kind}`, `{hour}`, `{minute}`, `{second}`, `{name}` tokens, and **People albums** read from the phone's own face recognition ("photos of Mum from 2024 to T7"). |
| Trust | Nobody: the top complaint is "it said done but files were missing" | A copy report (CSV) saved with every copy: copied, already there, only in iCloud, failed, each with a reason. |
| Privacy | iOS share sheet's location switch | "Remove location from copies": GPS is wiped in place from JPEG, HEIC and MOV/MP4, with no re-encoding and no quality loss. |
| Backups | iMazing Mini (paid) | Automatic backup when plugged in, at most once a day. On the Mac each backup keeps dated snapshots made with APFS clones, so they take almost no extra space. |
| Backup data | Reincubate (paid), iMazing | Full note text (decoded from Notes' compressed format), contacts as vCard, calendars as .ics, voice memos, photos and videos recovered from a backup, every chat as PDF or web page in one go. |
| Android | MacDroid Wi-Fi (paid) | Wireless debugging pairing built in (pair code + connect). |
| Power users | iMazing CLI (business tier), osxphotos | A `porthop` command line on Mac and Windows that uses the same engine. |
| Windows setup | Vendor support scripts | A clear banner when Apple's iPhone driver is missing, with a button to the Microsoft Store page. |

**Deliberately not yet (Phase 7, needs real hardware or new download sources):** a spyware/IOC check (needs indicator downloads), screen mirroring/recording (needs the developer disk image on iOS 17+, scrcpy on Android), iPhone→Android direct hops, music and ringtones (needs the iTunes media database protocol), parts verification (needs Apple server data), installing/removing apps, delete-after-copy (needs the camera protocol so the Photos library stays consistent), Wi-Fi backups, Sparkle delta updates (needs Developer ID signing and a hosted feed).

## 7. Phase 5 & 6 Build List

| # | Item | Mac | Windows |
| :--- | :--- | :--- | :--- |
| 5.1 | Update check against GitHub Releases (instead of Sparkle, which needs Developer ID + a hosted feed) | Done | Done |
| 5.2 | Legacy `iPhoneAlbumExtractor`/`PAE` names → PortHop names, old ones still read | Done | Done |
| 5.3 | Version 2.1.0, README, installer (a universal Intel build is not done: `build_tools.py` builds the bundled tools for arm64 only) | Done | Done |
| 5.4 | Leftovers: preload unsubscribe, async staging size, Photos.sqlite WAL retry, Apple driver banner, DateFormatter (thread-safe since macOS 10.9 — no change needed) | Done | Done |
| 5.5 | Split `Manager.swift` and `Shores.swift` | Done (Manager → 4 files, Shores → 3) | n/a |
| 6.1 | Hops that run when the phone is plugged in + notification | Done | Done |
| 6.2 | File-name patterns and new tokens | Done | Done |
| 6.3 | People albums + Ask PortHop "of <name>" | Done | Done |
| 6.4 | Copy report (CSV) | Done | Done |
| 6.5 | Remove location from copies (JPEG, HEIC, MOV/MP4, lossless) | Done (checked on real Apple-written JPEG, HEIC, MOV) | Done |
| 6.6 | Automatic daily backup; Mac APFS-clone snapshots | Done (auto + APFS snapshots) | Done (auto; no snapshots: NTFS has no clones) |
| 6.7 | Backup data: note text, vCard, .ics, voice memos, photos from backups, PDF and all-chats export | Done | Done (PDF via Electron) |
| 6.8 | Android wireless debugging pairing | Done | Done |
| 6.9 | `porthop` command line | Done (`Contents/Helpers/porthop`) | Done (`porthop.cmd`) |

**Still open after Phase 6:** real-device checks (Android, backups and restore, Windows on a real PC, the Notes and Voice Memos layouts on current iOS), Developer ID signing and notarization, building the Windows installer, an Intel/universal Mac build, and the Phase 7 items above. Not done on purpose: `.AAE` edit sidecars (where iOS puts them varies by version and needs a real device to confirm) and partial-hash duplicate checks (the manifest plus name-and-size matching already prevents false skips; hashing would mean reading every file twice over USB).

## 8. Phase 7 Build List

Each item was first listed as "needs real hardware or new download sources". Each was built without any new download source:
the spyware indicators are fetched by the app only when the user clicks, and the screen, ringtone and update pieces use what
macOS, Windows, Electron and the phones already have.

| # | Item | Mac | Windows |
| :--- | :--- | :--- | :--- |
| 7.1 | Spyware check (STIX2 indicators from the Mobile Verification Toolkit index: Amnesty, Citizen Lab and others; or a file someone sends). iPhone: through the newest backup (Safari history, tabs and bookmarks, Messages and senders, WhatsApp, websites apps loaded, app network use, daily usage statistics, iMessage lookups, installed apps, configuration profiles, every file path). Android: live (installed apps, running programs, apps with accessibility, notification, device-admin or install access, Play Protect off). PDF report. | Done | Done |
| 7.2 | The phone's screen: live view, recording, screenshots | Done: iPhone through the same capture route QuickTime uses (USB, any iOS, nothing installed); Android through adb's H.264 stream, with tap, swipe, Back, Home and Recents | Done for Android (WebCodecs decoding, MP4 recording); an iPhone's screen needs a Mac |
| 7.3 | iPhone → Android direct hops (drop a group on the Android phone: DCIM/PortHop/<group>, Gallery told) | Done | Done |
| 7.4 | Music and ringtones: copy songs and ringtones off the iPhone (Artist/Album), send them to Android, make a ringtone (.m4r, up to 40 s) | Done (AVFoundation) | Done (WebCodecs AAC + PortHop's own .m4r writer) |
| 7.5 | Parts verification → phone report | Report done (battery health and cycles, storage, software). Genuine-part status is shown only on the iPhone itself, so the report says where to look | Same |
| 7.6 | Install and remove apps | Done (iPhone: .ipa signed for that iPhone, through PortHop's helper; Android: .apk) | Done |
| 7.7 | Remove copied items from the phone, only where the copy is confirmed complete, after asking | Done: iPhone through Image Capture's camera route (keeps Photos consistent); Android (only files whose copy matches in size) | Android done; iPhone not offered (Windows has no equivalent of Image Capture's route that could be checked here) |
| 7.8 | Wi-Fi backups: turns on "Show this iPhone when on Wi-Fi", then a daily background backup over Wi-Fi | Done | Done |
| 7.9 | Updates that install themselves, checked against an Ed25519 signature (Sparkle's protection, without Developer ID or a hosted feed). The key: `make_release.py --key-only`; the private half stays in `~/.porthop-release`, the public half is `update-key.pub` | Done (replaces the app, then reopens it) | Done (installer, or the zip version updated in place) |
| 7.10 | Ask PortHop understands "spyware", "mirror", "music", "install"… ; `porthop` gains `check`, `indicators`, `apps` and `music` | Done | Done (Ask) |

Tests: both suites share new cases in `Tests/golden` (spyware: invented indicators against invented traces in a backup and on the
simulated Android phone; screen: a 12-frame H.264 stream; music: the simulated library; update: a signature made with a throwaway
key). The Mac suite also decodes the stream with VideoToolbox, records it to an MP4 and makes a real ringtone.

**Still needs a real device:** all of Phase 7 has only been tried against the simulated phones. In particular: the iPhone screen
(no simulator offers that capture device), removing copied photos from an iPhone, app installs on a real iPhone, the music database
layout on current iOS, Wi-Fi backups, and the Windows update install (it runs only on Windows).

## 9. End-to-End Audit After Phase 7 (November 2026)

**Scope:** both apps end to end: the Mac app (SwiftUI screens, engine, `porthop` command line, the C helpers) and the Windows
app (main process, page, engine, `porthop.cmd`, the same helpers built for Windows), plus the build and release scripts, the
tests and the documentation.

**Method:**
- Re-read all of the Phase 7 code and the riskiest older paths.
- Checked in the code that each finding from section 2 is fixed.
- Ran both test suites and both command lines.
- Took screenshots of every new screen on both apps against the simulated phones.
- Ran targeted checks: device text reaching HTML, the page-to-main-process call list, shell quoting, file names, and update signing.

### Fixed during the audit

| # | Finding | Severity | Where |
| :--- | :--- | :--- | :--- |
| 0 | The Windows package left out `tools-main.js`: the packager's rule for the `tools/` folder also matched files whose names start with "tools", so the packaged app would have failed at launch. The rule now matches whole folder names only. Every `require` and page script is now checked to be in the package, and the packaged code was started under Electron. | Critical | Windows |
| 1 | The spyware check hung on a very long message. Its link-finding pattern backtracked quadratically. It is now a single pass over the words (a 130,000-character message takes about 1 ms). | High | Both |
| 2 | Removing copied items could remove the wrong photo. When the iPhone offered both IMG_0005.HEIC and IMG_0005.JPG, the JPEG was counted as the converted copy of the HEIC. Now a JPEG counts only when the HEIC itself is not offered. A test case was added. | High (data) | Both |
| 3 | A Wi-Fi backup that couldn't finish was retried every 10 minutes, with a passcode prompt on the phone and a notification each time. Each iPhone now waits 6 hours before another try. | Medium | Both |
| 4 | "Install and Restart" could quit in the middle of a copy or backup. It now waits until nothing is running. | Medium | Both |
| 5 | After switching phones, the Apps, Music and Spyware screens could show the previous phone's results. They are now cleared when the phone changes. | Medium | Mac |
| 6 | A failed main-process call left a tool screen waiting forever. The error is now shown. | Medium | Windows |
| 7 | The live Android screen was stretched. Separately, the screen page stopped its own stream through the clean-up order. The picture now keeps the phone's shape, and each stream carries a session ID so a page can only stop its own. | Medium | Windows |
| 8 | Files copied out of a backup could get odd names: `.`, `..`, or Windows device names such as CON and NUL. They now get safe names. | Low | Both |
| 9 | A downloaded update that wasn't PortHop left its unpacked folder in the temporary folder. It is now removed. | Low | Mac |
| 10 | The iPhone screen capture could start before its setup was committed. It now commits first. | Low | Mac |
| 11 | The summary after sending to Android showed the copy-off-the-iPhone counts. It now shows sent, already on the phone, and couldn't send. | Low | Mac |
| 12 | The Back Up button said "Connect an iPhone" when another job was running. It now says what is running. | Low | Windows |
| 13 | Icon-only buttons had no spoken names for VoiceOver and Narrator. They are now labelled. | Low | Both |
| 14 | Polish: "1 investigations"; a Stop button that was always shown; the Android card's text cut off; Screen offered for iPhones on Windows, where it can't work. | Low | Both |
| 15 | `porthop.cmd` lacked `check`, `indicators`, `apps` and `music`, which the README described. They were added and tested. | Low | Windows |
| 16 | Windows was at version 2.1.0 while the Mac was at 2.2. Windows is now 2.2.0. | Low | Windows |

### Checked and sound

- **Section 2 findings:** every fix is present in the code.
  - Shared manifest format.
  - Encrypted backups: older keybags without DPSL, and WRAP checks.
  - `afcmini.c` deletes partial files.
  - Thumbnail cache keyed per device.
  - `skipExisting` respected.
  - Authenticode check of Google's adb.
  - In-process HEIC conversion.
  - O(1) thumbnail lookups.
  - Asynchronous staging size.
- **Never overwrite:** holds in the exporter, the music copy, sending to Android (" (2)" names), and extraction from backups.
- **Destructive actions ask first:**
  - Restore requires typing RESTORE.
  - Removing an app asks first.
  - Removing copied items from an iPhone takes two confirmations.
  - On Android, only files whose copy matches in size are removed.
  - An update moves the old Mac app to the Trash.
- **Device commands:**
  - Android shell commands quote every value.
  - Every other tool runs with an argument list, never through a shell.
  - Taps and swipes are clamped numbers, and key presses come from an allowlist.
- **Windows page:**
  - A content security policy allows only the app's own scripts.
  - Device text is inserted as text, never as HTML.
  - The page can make only allowlisted calls to the main process.
  - Navigation and new windows are blocked.
  - PDF windows run without JavaScript.
  - Only the two help pages can be opened as links.
- **Updates:**
  - The Ed25519 signature is checked before anything is unpacked or run.
  - The Mac also checks the bundle ID, the version and the code signature.
  - The private key is kept outside the repository (file mode 0600, folder mode 0700).
- **Network:** the apps contact GitHub (update check, release download, indicator index) and, only on request, Google (adb). Nothing about the person or the phone is sent.
- **C helpers (`afcmini.c`, `applist.c`):** buffers are bounded, sizes are checked, and plist ownership is correct.
- **Sources:** no personal data, debug output or unfinished markers.

### Still open

- **Real devices:** everything from Phases 5–7 has run only against simulated phones. Most urgent:
  - the iPhone screen;
  - removing photos through Image Capture;
  - app installs;
  - the music database layout on current iOS;
  - Wi-Fi backups;
  - Windows on a real PC, including update installs and the AAC encoder from Media Foundation.
- **Signing and installer:**
  - Developer ID signing and notarization, which needs an Apple Developer account.
  - Windows code signing, so SmartScreen doesn't warn.
  - Building the Inno installer, which has to be done on Windows.
- **Intel Mac build:** the bundled tools are built for Apple Silicon only.
- **`porthop check --password`:** the password appears in the process list. A prompt would be safer.
- **Windows sandbox:** the main window's preload runs without Chromium's sandbox (context isolation is on, Node integration is off). Turning the sandbox on needs a check of the preload's test hook.
- **Windows zip update:** the small script that finishes the update would expand a `%` in the app's folder name (rare).
- **Not offered on Windows:** removing copied items from an iPhone, and earlier-version snapshots (NTFS has no clones).
- **Update-signing key:** back up `~/.porthop-release/update-signing-key.pem`. Without it, no future update can be signed.
