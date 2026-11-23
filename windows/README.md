# PortHop for Windows

Copies photos, videos and files between an iPhone, iPad or Android device and a Windows PC over USB. It is the Windows edition of the Mac app in this repository and does the same things.

It follows Material 3 Expressive: colours generated from PortHop's blue with Google's Material colour library (`tools/make-theme.mjs` writes `renderer/theme.css`), expressive shapes that morph on hover and press, a wavy progress bar, spring-based motion, the Roboto Flex font (SIL Open Font Licence, `renderer/fonts/OFL.txt`) and Google's Material Symbols icons (Apache 2.0, `renderer/icons-LICENSE.txt`; `tools/fetch-icons.mjs` writes `renderer/icons.js` from Google's repository at a fixed commit).

STATUS: built and tested on a Mac against simulated devices. It has NOT yet been run on a real Windows PC. Treat the first run as a test.

## Before the first run (Windows 10 or 11, 64-bit)

1. For iPhone or iPad: install **Apple Devices** from the Microsoft Store (or iTunes). It provides the driver Windows needs to talk to an iPhone. Without it the phone never appears.
2. Unzip the whole **PortHop** folder somewhere, for example your Desktop. Do not run it from inside the zip.
3. Open **PortHop.exe**. Windows may show "Windows protected your PC" because the app is not signed: choose More info, then Run anyway.
4. Plug in the device, unlock it, and tap **Trust** (iPhone) or **Allow** (Android).

For Android: on the phone turn on USB debugging (Settings > About phone > tap Build number seven times, then Settings > Developer options > USB debugging). In the app click **Set Up Android Support** once; it downloads Google's connection tool (adb) from Google, because Google does not allow that tool to be shipped inside other apps.

## What it does

The main screen, Shores, shows your phone's photo groups on the left and places to copy them on the right (Pictures, each drive, folders used before). Drag a group across, or click a place and pick a group. Click a group to filter it, pick months on its timeline and copy just some items. Type a request into Ask PortHop at the top (Ctrl+K), such as "hidden videos from 2024 to my D drive".


- iPhone and iPad: every album including Hidden, and People named in the Photos app; sort by size, name, date and more, filters and search, export all or selected items to a folder or an external drive. Exporting again into the same folder skips what is already there. Nothing is ever overwritten and nothing on the device is changed.
- Copy options: edited versions, HEIC to JPEG (with Microsoft's free HEIF Image Extensions), folder and file-name patterns, remove location from the copies (no re-encoding), and a copy report (CSV) of what was and wasn't copied.
- Saved hops, which can run by themselves whenever that phone is plugged in and post a Windows notification when done.
- If Apple's iPhone driver isn't running, the start screen says so and opens the Apple Devices page in the Microsoft Store.
- Send files into apps that share a folder (video players, readers), make folders, copy their files back.
- Backups: a standard full device backup into a folder or drive of your choice, and Restore to put one back onto a device (asks for a typed confirmation first; not yet verified on a real device).
- Backups can run by themselves once a day when the phone is plugged in.
- From your backup: Messages, WhatsApp, Contacts, Notes (full text), Calendar, Call Log, Safari, Photos & Videos, Voice Memos, and every file in the backup. Works with password-protected backups; the password is never saved. Each list saves as a spreadsheet (CSV) file; contacts also as vCard, calendars as .ics, chats as web pages or PDF.
- Device overview: battery, charge cycles, health, storage, identifiers, Restart and Sleep.
- Android: browse shared storage, photo albums from the phone's media index, copy both ways, device overview, and Wi-Fi with Wireless debugging (Android 11 and later).
- Command line: `porthop.cmd devices | groups | copy <group> <folder> | backup <folder>`, the same engine for scripts (`porthop.cmd help`).
- Update check: ⋯ ▸ Check for updates (also weekly by itself unless turned off).

## Not included

WhatsApp transfer between phones, photo thumbnails grid.

## Known unknowns on Windows

- The iPhone tools are libimobiledevice 1.4.0 (the same version as the Mac app), compiled from the official source on a Mac. They have not yet been run on Windows.
- The file-copy helper (`afcclient.exe`) and the app-list helper (`applist.exe`) were written for this app, because the official file-copy tool cannot be driven by another program on Windows. They have not been run on Windows or against a real device.

## Building it yourself (on a Mac)

```
npm install
python3 fetch-tools.py      # compiles libimobiledevice 1.4.0 and the two helpers for Windows (needs zig)
npm test                    # engine tests against simulated devices
npm run package             # writes dist/PortHop-Windows.zip
node --import ./tools/js-extension-hook.mjs tools/make-theme.mjs   # only after changing the theme colours or shapes
node tools/fetch-icons.mjs  # only after changing which icons the app uses
```

Bundled third-party tools and their licences are listed in `resources/tools/VERSIONS.txt` and `resources/tools/licenses`.
