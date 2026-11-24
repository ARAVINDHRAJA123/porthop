import SwiftUI
import AppKit

// The file browser: an app's shared files or Android storage, and copying both ways.

extension DeviceManager {
    // MARK: File browser

    func openBrowser(app: String?) {
        guard let device, let tools else { return }
        afcApp = app
        afcRoot = device.isAndroid ? Android.storageRoot : "/"
        afcPath = afcRoot
        afcEntries = []
        afcGeneration += 1
        afcSelection.removeAll()
        afcMessage = ""
        afcLoading = true
        browseToken += 1
        let token = browseToken
        Task.detached {
            var root = device.isAndroid ? Android.storageRoot : "/"
            var entries = DeviceManager.listDir(root, app: app, device: device, tools: tools)
            // An app's shared area is a "Documents" folder inside its container; start there.
            if app != nil, entries.contains(where: { $0.isDirectory && $0.name == "Documents" }) {
                root = "/Documents"
                entries = AFC.list(root, app: app, device: device, tools: tools)
            }
            let finalRoot = root, finalEntries = entries
            await MainActor.run {
                guard token == self.browseToken else { return }
                self.afcRoot = finalRoot
                self.afcPath = finalRoot
                self.afcEntries = finalEntries
                self.afcGeneration += 1
                self.afcLoading = false
                self.runPendingUploads()
            }
        }
    }

    func browse(_ path: String, keepMessage: Bool = false) {
        guard let device, let tools else { return }
        afcLoading = true
        browseToken += 1
        let token = browseToken
        let app = afcApp
        Task.detached {
            let entries = DeviceManager.listDir(path, app: app, device: device, tools: tools)
            await MainActor.run {
                guard token == self.browseToken else { return }
                self.afcPath = path
                self.afcEntries = entries
                self.afcGeneration += 1
                self.afcSelection.removeAll()
                self.afcLoading = false
                if !keepMessage { self.afcMessage = "" }
                self.runPendingUploads()
            }
        }
    }

    var canBrowseUp: Bool { afcPath != afcRoot && afcPath != "/" }

    func browseUp() {
        guard canBrowseUp else { return }
        let parent = (afcPath as NSString).deletingLastPathComponent
        browse(parent.isEmpty ? "/" : parent)
    }

    func stopTransfer() { transferJob?.cancel() }

    /// Device → Mac for the selected files and folders.
    func downloadAFCSelection(to folder: URL) {
        download(afcEntries.filter { afcSelection.contains($0.path) }, app: afcApp, to: folder)
    }

    /// Device → Mac for files and folders, never overwriting. Used by the file browser and by Android folder hops.
    func download(_ chosen: [AFCFileEntry], app: String?, to folder: URL) {
        guard let device, let tools, !chosen.isEmpty, !afcBusy else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let job = ExportJob()
        transferJob = job
        afcBusy = true
        afcMessageIsError = false
        afcMessage = "Copying \(chosen.count) item\(chosen.count == 1 ? "" : "s") to your Mac…"
        androidCopied = []
        Task.detached {
            var saved: [URL] = []
            var pairs: [Cleanup.AndroidPair] = []
            var reserved = Set<String>()
            for (i, entry) in chosen.enumerated() {
                if job.isCancelled { break }
                await MainActor.run { self.afcMessage = "Copying \(i + 1) of \(chosen.count) to your Mac: \(entry.name)" }
                let remote = entry.path.hasPrefix("/") ? String(entry.path.dropFirst()) : entry.path
                var dest = folder.appendingPathComponent(entry.name)
                if FileManager.default.fileExists(atPath: dest.path) || reserved.contains(dest.path) {
                    dest = Exporter.uniqueURL(for: dest, avoiding: reserved)
                }
                reserved.insert(dest.path)
                if device.isAndroid {
                    _ = Android.pull(entry.path, to: dest, device: device, tools: tools, onStart: { job.track($0) })
                } else {
                    let args = device.baseArgs + AFC.container(app) + ["--", "get"] + (entry.isDirectory ? ["-r"] : []) + [remote, dest.path]
                    _ = Shell.run(tools.afc, args, onStart: { job.track($0) })
                }
                job.clear()
                let ok = FileManager.default.fileExists(atPath: dest.path) && (entry.isDirectory || entry.size <= 0 || AFC.fileSize(dest) == entry.size)
                if ok && !job.isCancelled {
                    saved.append(dest)
                    if device.isAndroid && entry.isDirectory { pairs.append(Cleanup.AndroidPair(remote: entry.path, local: dest)) }
                } else if !entry.isDirectory { try? FileManager.default.removeItem(at: dest) }
            }
            let done = saved, copiedFolders = pairs
            let cancelled = job.isCancelled
            await MainActor.run {
                self.afcBusy = false
                self.transferJob = nil
                self.androidCopied = copiedFolders
                let missed = chosen.count - done.count
                self.afcMessageIsError = missed > 0 && !cancelled
                self.afcMessage = cancelled ? "Stopped. \(done.count) of \(chosen.count) copied."
                    : (missed == 0 ? "Copied \(done.count) item\(done.count == 1 ? "" : "s") to “\(folder.lastPathComponent)”."
                                   : "Copied \(done.count) of \(chosen.count). \(missed) could not be copied.")
                if !done.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(done) }
            }
        }
    }

    /// Mac → device: adds files or folders to the folder being shown (apps' shared folders only).
    func upload(_ urls: [URL]) {
        guard let device, let tools, canAddFiles, !urls.isEmpty, !afcBusy else { return }
        let app = afcApp
        let dir = afcPath
        let names = Set(afcEntries.map(\.name))
        let job = ExportJob()
        transferJob = job
        afcBusy = true
        afcMessageIsError = false
        let android = device.isAndroid
        let target = android ? "“\((afcPath as NSString).lastPathComponent)”" : (currentApp?.name ?? "the app")
        let kind = deviceKind
        afcMessage = "Adding \(urls.count) item\(urls.count == 1 ? "" : "s") to \(target)…"
        Task.detached {
            var existing = names
            var added = 0
            for (i, url) in urls.enumerated() {
                if job.isCancelled { break }
                await MainActor.run { self.afcMessage = "Adding \(i + 1) of \(urls.count) to \(target): \(url.lastPathComponent)" }
                let ok = android ? Android.push(url, intoDir: dir, existing: &existing, device: device, tools: tools, onStart: { job.track($0) })
                                 : AFC.put(url, intoDir: dir, existing: &existing, app: app, device: device, tools: tools, onStart: { job.track($0) })
                if ok { added += 1 }
                job.clear()
            }
            let after = DeviceManager.listDir(dir, app: app, device: device, tools: tools)
            let total = added
            let cancelled = job.isCancelled
            await MainActor.run {
                self.afcBusy = false
                self.transferJob = nil
                if self.afcApp == app, self.afcPath == dir {
                    self.afcEntries = after
                    self.afcGeneration += 1
                }
                let missed = urls.count - total
                self.afcMessageIsError = missed > 0 && !cancelled
                self.afcMessage = cancelled ? "Stopped. \(total) of \(urls.count) added."
                    : (missed == 0 ? "Added \(total) item\(total == 1 ? "" : "s") to \(target)." + (android ? "" : " Open the app on the \(kind) to see \(total == 1 ? "it" : "them").")
                                   : "Added \(total) of \(urls.count). \(missed) could not be added.")
                if missed == 0 && !cancelled { NSSound(named: "Glass")?.play() }
            }
        }
    }

    func newFolder(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard let device, let tools, canAddFiles, !clean.isEmpty, !afcBusy else { return }
        let app = afcApp
        let path = afcPath == "/" ? "/\(clean)" : "\(afcPath)/\(clean)"
        let dir = afcPath
        afcLoading = true
        Task.detached {
            let ok = device.isAndroid ? Android.mkdir(path, device: device, tools: tools) : AFC.mkdir(path, app: app, device: device, tools: tools)
            await MainActor.run {
                self.afcMessageIsError = !ok
                self.afcMessage = ok ? "Created “\(clean)”." : "The folder could not be created."
                self.browse(dir, keepMessage: true)
            }
        }
    }
}
