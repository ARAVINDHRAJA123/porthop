# iPhone Album Extractor 2

A native macOS app (Apple Silicon) that copies photos and videos from an iPhone or iPad to a Mac folder or an external drive over USB. Standalone: the device tools it needs are bundled inside the app.

## Use it

1. Open **iPhone Album Extractor 2.app**.
2. Plug in the iPhone or iPad, unlock it, tap **Trust** if asked. It appears by itself. With two devices plugged in, switch between them from the device card.
3. Pick **Hidden** (or any album), sort or filter, then **Export All…** or select items and **Export Selected…**.
4. Choose a folder or an external drive, then **Copy**. The summary shows what was copied, what was already there and anything that couldn't be copied.

Exporting again into the same folder is safe: files with the same name and exact size are recognised and skipped, and nothing is ever overwritten.

## External drives

Any drive the Mac can write to works (APFS, Mac OS Extended, exFAT, FAT32): pen drives, SSDs, hard disks. They show up as one-click destinations. FAT32 cannot hold files over 4 GB; the app warns before copying. NTFS drives are read-only on macOS and are shown as such.

## Home and device details

The app opens on a task screen (copy photos, get the Hidden album, send files, back up, check the device). **Overview** shows battery health and charge cycles, storage, device identifiers with Copy All, and Restart and Sleep actions. Screen transitions can be turned off under View ▸ Animated Screen Transitions.

Hidden items appear only in **Hidden**, never in Screenshots, Favorites or other albums, matching the Photos app.

## Sending files to the device

The sidebar lists apps that share a folder (for example video players and document readers). Open one to drag files in from Finder, create folders, or copy its files back to the Mac. Existing files are never overwritten. Photos cannot be added to the Photos library this way; iOS does not allow it over this connection.

## Android (beta)

With an Android phone or tablet plugged in, the app shows its shared storage (Camera, Pictures, Download, Movies and the rest): copy files and folders to the Mac, drag files in from Finder, make folders. Nothing is overwritten in either direction. Overview shows battery, storage and device details, with Restart and Sleep.

Two things are needed:

- On the phone: turn on **USB debugging** (Settings ▸ About phone ▸ tap Build number seven times, then Settings ▸ Developer options ▸ USB debugging) and tap **Allow** when the Mac is first connected.
- On the Mac: Google's `adb`. Its licence does not allow it to be shipped inside another app, so it is not bundled. Install it with `brew install android-platform-tools`, or unzip Google's platform-tools into `~/Library/Application Support/iPhoneAlbumExtractor/android/`.

Tested against a simulated phone only; not yet verified on a real Android device. There is no album view for Android yet, only folders.

## Backups (beta)

**Backups** makes a standard full device backup (the format Finder uses) into a folder or external drive of your choice; later runs only copy changes. **Restore…** on a backup puts it back onto the connected device, replacing its settings and app data; it needs Find My turned off and asks for a typed confirmation first. Neither backup nor restore has been verified on a real device yet.

## Reading a backup (beta)

**From your backup** in the sidebar reads the newest backup in the backup folder without changing it: Messages and WhatsApp conversations, Contacts, Notes (title and opening lines), Calendar, Safari bookmarks and history, and every file in the backup (Backup Files), which can be copied out under its real name. Each list can be searched and saved as a spreadsheet (CSV) file.

Password-protected (encrypted) backups are supported: the app asks for the backup password, uses it in memory only and never saves it. Decrypted working copies go to a temporary folder that is removed when the app quits. Apple only puts the call log in encrypted backups, so Call Log is empty for plain ones. Photos and attachments inside conversations are shown as a placeholder. Tested against a simulated backup with invented data only; not yet verified on a real one.

## What it does not do (yet)

- It copies each photo's **original file**. Edits made in the Photos app are not applied.
- Live Photos export as the still image unless **Include Live Photo videos** is on.
- Originals stored only in iCloud are reported as not copied.
- Wi-Fi setup is not implemented.

## Windows edition

`windows/` holds a Windows edition with the same features (an Electron app, so it can be built and tested from a Mac). See `windows/README.md`. It has been tested against simulated devices only, not yet on a real Windows PC.

## iOS compatibility

The app reads the device's internal `PhotoData/Photos.sqlite`, which Apple does not document and can change in any release. The tables and columns are checked before use: optional ones degrade with a visible warning, and a missing required one stops with a clear message instead of wrong results. Verified on iOS 27.2 (iPhone 15 Pro Max).

## Build and test

- `./build.sh` builds and ad-hoc signs the app, bundling `libimobiledevice` from Homebrew (`brew install libimobiledevice` is needed on the build machine only).
- `Tests/run_tests.sh` runs the export engine against a simulated iPhone; no real device is touched.

Apple Silicon. The bundled device tools come from Homebrew and set the minimum macOS version (currently macOS 27.2; `build.sh` records it in the app). Not notarized: on another Mac, right-click → Open the first time.

Bundled third-party tools are listed in `Licenses/`.
