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
