import Foundation
import AppKit
import SQLite3
import ImageIO
import AVFoundation

// Copying photos and videos to a folder, safely and resumably.

// MARK: - Export engine

final class ExportJob {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [Process] = []

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock(); cancelled = true; let ps = processes; lock.unlock()
        for p in ps where p.isRunning { p.terminate() }
    }

    func track(_ p: Process) {
        lock.lock(); processes.append(p); let c = cancelled; lock.unlock()
        if c, p.isRunning { p.terminate() }
    }

    func clear() { lock.lock(); processes.removeAll(); lock.unlock() }

    /// Stops the running transfers without cancelling the export (used when the device stops responding).
    func interrupt() {
        lock.lock(); let ps = processes; lock.unlock()
        for p in ps where p.isRunning { p.terminate() }
    }
}

enum Exporter {
    static let manifestName = ".porthop-manifest.json"
    /// What versions before 2.1 called the record and the staging folders; still read, never written.
    static let legacyManifestName = ".iPhoneAlbumExtractor-manifest.json"
    static let legacyStagingPrefix = ".iPhoneAlbumExtractor-staging-"

    /// Swaps each edited item for its rendered edit when that file is on the device; everything else stays the original.
    static func editedVersions(of assets: [PhotoAsset], device: Device, tools: Tools) -> [PhotoAsset] {
        assets.map { a in
            guard a.isEdited else { return a }
            for path in a.renderCandidates {
                if let size = AFC.remoteSize(path, device: device, tools: tools), size > 0 { return a.editedVersion(path: path, size: size) }
            }
            return a
        }
    }

    /// Converts one HEIC photo to a JPEG (quality 0.9) with ImageIO, keeping its metadata, orientation and colour profile.
    static func heicToJPEG(_ source: URL, _ dest: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let out = CGImageDestinationCreateWithURL(dest as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImageFromSource(out, src, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(out) && AFC.fileSize(dest) > 0
    }

    /// The record of what was copied into a folder, shared with the Windows edition: an object keyed by the file's
    /// path on the device. Older Mac copies keyed it by photo ID and older Windows copies wrote a list; both still load.
    static func readManifest(_ url: URL) -> [String: ExportManifestEntry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let entries: [ExportManifestEntry]
        if let dict = try? JSONDecoder().decode([String: ExportManifestEntry].self, from: data) { entries = Array(dict.values) }
        else if let list = try? JSONDecoder().decode([ExportManifestEntry].self, from: data) { entries = list }
        else { return [:] }
        var out: [String: ExportManifestEntry] = [:]
        for e in entries { out[e.sourceRemotePath] = e }
        return out
    }
    static let stagingPrefix = ".porthop-staging-"
    static var stallLimit: TimeInterval = 75

    private struct Pending {
        let asset: PhotoAsset
        let raw: URL
        let final: URL
        let preferredRel: String
        let liveRaw: URL?
        let command: String
    }

    static func run(assets: [PhotoAsset], destination: URL, options: ExportOptions, device: Device, tools: Tools,
                    job: ExportJob, progress: @escaping (ExportProgress) -> Void) -> ExportSummary {
        let assets = options.editedVersions ? editedVersions(of: assets, device: device, tools: tools) : assets
        let fm = FileManager.default
        let started = Date()
        var summary = ExportSummary(destination: destination)
        summary.total = assets.count

        do { try fm.createDirectory(at: destination, withIntermediateDirectories: true) } catch {
            summary.fatalError = "The folder could not be created: \(error.localizedDescription)"
            return summary
        }
        for name in (try? fm.contentsOfDirectory(atPath: destination.path)) ?? [] where name.hasPrefix(stagingPrefix) || name.hasPrefix(legacyStagingPrefix) {
            try? fm.removeItem(at: destination.appendingPathComponent(name))
        }
        let staging = destination.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        do { try fm.createDirectory(at: staging, withIntermediateDirectories: true) } catch {
            summary.fatalError = "This folder is not writable: \(error.localizedDescription)"
            return summary
        }
        defer { try? fm.removeItem(at: staging) }

        let manifestURL = destination.appendingPathComponent(manifestName)
        // A folder filled by an earlier version keeps its record under the old name: read both, write the new one.
        var manifest = Exporter.readManifest(destination.appendingPathComponent(legacyManifestName))
            .merging(Exporter.readManifest(manifestURL)) { _, new in new }
        func saveManifest() {
            if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: manifestURL, options: .atomic) }
        }

        var state = ExportProgress()
        state.total = assets.count
        state.bytesTotal = assets.reduce(0) { $0 + max(0, $1.fileSize) }
        var settledBytes: Int64 = 0
        var transferredBytes: Int64 = 0
        func emit(staged: Int64 = 0, files: Int = 0) {
            var s = state
            s.inFlight = files
            s.bytesDone = settledBytes + staged
            let elapsed = Date().timeIntervalSince(started)
            s.bytesPerSecond = elapsed > 1 ? Double(transferredBytes + staged) / elapsed : 0
            progress(s)
        }
        func fail(_ asset: PhotoAsset, _ reason: String) {
            summary.failures.append(ExportFailure(asset: asset, reason: reason))
            summary.report.append(asset.isCloudOnly
                ? ReportLine(status: .cloud, asset: asset, savedAs: "", note: "Stored only in iCloud. Turn off Optimise Storage on the device to copy it.")
                : ReportLine(status: .failed, asset: asset, savedAs: "", note: reason))
            state.failed += 1
            settledBytes += max(0, asset.fileSize)
        }
        emit()

        var streamCount = 3
        let chunkSize = 60
        var index = 0
        var reserved = Set<String>()

        outer: while index < assets.count {
            if job.isCancelled { break }
            let chunk = assets[index..<min(index + chunkSize, assets.count)]
            index += chunk.count
            var streams = [String](repeating: "", count: streamCount)
            var pending: [Pending] = []

            for asset in chunk {
                var targetDir = destination
                switch options.subfolder {
                case .flat: break
                case .yearMonth: targetDir = destination.appendingPathComponent(asset.yearMonthFolder, isDirectory: true)
                case .iphoneFolder:
                    let sub = asset.directory.split(separator: "/").last.map(String.init) ?? "DCIM"
                    targetDir = destination.appendingPathComponent(sub, isDirectory: true)
                case .custom:
                    let sub = SubfolderMode.folder(options.folderPattern, asset, album: options.albumName, device: options.deviceName)
                    if !sub.isEmpty { targetDir = destination.appendingPathComponent(sub, isDirectory: true) }
                }
                try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

                let chosen = (options.useOriginalNames && !asset.originalFilename.isEmpty) ? asset.originalFilename : asset.filename
                var safeName = URL(fileURLWithPath: chosen).lastPathComponent.replacingOccurrences(of: ":", with: "-")
                if let stem = Pattern.fileStem(options.namePattern, asset, album: options.albumName, device: options.deviceName, original: chosen) {
                    let ext = (safeName as NSString).pathExtension
                    safeName = ext.isEmpty ? stem : stem + "." + ext
                }
                guard !safeName.isEmpty, safeName != ".", safeName != "..", safeName != "/" else {
                    fail(asset, "The filename in the catalog is not usable.")
                    continue
                }
                guard let remoteQuoted = AFC.quote(asset.remotePath) else {
                    fail(asset, "The iPhone path contains characters that cannot be transferred safely.")
                    continue
                }
                let willConvert = options.convertHEIC && asset.isHEIC
                let preferred = targetDir.appendingPathComponent(safeName)
                var final = willConvert ? preferred.deletingPathExtension().appendingPathExtension("jpg") : preferred
                let preferredRel = relativePath(of: final, inside: destination)
                let key = asset.remotePath

                if options.skipExisting {
                    if let prev = manifest[key], prev.preferredPath == preferredRel,
                       prev.sourceRemotePath == asset.remotePath, prev.sourceSize == asset.fileSize {
                        let size = AFC.fileSize(destination.appendingPathComponent(prev.exportedPath))
                        if size > 0, size == prev.exportedSize {
                            summary.report.append(ReportLine(status: .skipped, asset: asset, savedAs: prev.exportedPath, note: ""))
                            state.skipped += 1; summary.skipped += 1
                            settledBytes += max(0, asset.fileSize)
                            continue
                        }
                    }
                    // A same-name file whose byte size equals the iPhone's recorded size is the same file
                    // from an earlier export (including the original app's): adopt it instead of duplicating.
                    if !willConvert, asset.fileSize > 0, !reserved.contains(final.path), AFC.fileSize(final) == asset.fileSize {
                        manifest[key] = ExportManifestEntry(preferredPath: preferredRel, exportedPath: preferredRel,
                                                            sourceRemotePath: asset.remotePath, sourceSize: asset.fileSize,
                                                            exportedSize: asset.fileSize)
                        reserved.insert(final.path)
                        summary.report.append(ReportLine(status: .skipped, asset: asset, savedAs: preferredRel, note: ""))
                        state.skipped += 1; summary.skipped += 1
                        settledBytes += asset.fileSize
                        continue
                    }
                }
                if fm.fileExists(atPath: final.path) || reserved.contains(final.path) {
                    final = uniqueURL(for: final, avoiding: reserved)
                }
                reserved.insert(final.path)

                let ext = asset.fileExtension.isEmpty ? "bin" : asset.fileExtension.lowercased()
                let raw = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                guard let rawQuoted = AFC.quote(raw.path) else {
                    fail(asset, "The destination path contains characters that cannot be used.")
                    continue
                }
                var command = "get \(remoteQuoted) \(rawQuoted)\n"
                var liveRaw: URL? = nil
                if options.includeLiveVideo, asset.isLivePhoto {
                    let lr = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                    if let rq = AFC.quote(asset.livePhotoVideoRemotePath), let lq = AFC.quote(lr.path) {
                        command += "get \(rq) \(lq)\n"
                        liveRaw = lr
                    }
                }
                streams[pending.count % streamCount] += command
                pending.append(Pending(asset: asset, raw: raw, final: final, preferredRel: preferredRel, liveRaw: liveRaw, command: command))
            }

            if pending.isEmpty { emit(); saveManifest(); continue }

            let pollQueue = DispatchQueue(label: "export.poll")
            let timer = DispatchSource.makeTimerSource(queue: pollQueue)
            timer.schedule(deadline: .now() + 0.4, repeating: 0.4)
            var lastStaged: Int64 = -1
            var lastGrowth = Date()
            var stalledNow = false
            timer.setEventHandler {
                let names = (try? fm.contentsOfDirectory(atPath: staging.path)) ?? []
                let staged = names.reduce(Int64(0)) { $0 + AFC.fileSize(staging.appendingPathComponent($1)) }
                // Nothing arriving for a long time means the device stopped answering (often: it locked).
                if staged != lastStaged { lastStaged = staged; lastGrowth = Date() }
                else if Date().timeIntervalSince(lastGrowth) > stallLimit { stalledNow = true; lastGrowth = Date(); job.interrupt() }
                emit(staged: staged, files: max(0, names.count - streamCount))
            }
            timer.resume()
            let active = streams.filter { !$0.isEmpty }
            DispatchQueue.concurrentPerform(iterations: active.count) { i in
                _ = Shell.run(tools.afc, device.baseArgs, stdin: active[i] + "quit\n", onStart: { job.track($0) })
            }
            // Anything a parallel stream missed gets one calm, single-stream retry before it is called a failure.
            let missed = pending.filter { AFC.fileSize($0.raw) <= 0 }
            if !missed.isEmpty, !job.isCancelled, !stalledNow, AFC.isConnected(device, tools: tools) {
                for m in missed { try? fm.removeItem(at: m.raw) }
                _ = Shell.run(tools.afc, device.baseArgs, stdin: missed.map(\.command).joined() + "quit\n", onStart: { job.track($0) })
                let recovered = missed.filter { AFC.fileSize($0.raw) > 0 }.count
                if streamCount > 1, recovered * 2 > missed.count, missed.count > 2 { streamCount = 1 }
            }
            job.clear()
            timer.cancel()
            pollQueue.sync {}

            let cancelledNow = job.isCancelled
            let anyMissing = pending.contains { AFC.fileSize($0.raw) <= 0 }
            pollQueue.sync {}
            let stalled = stalledNow && !cancelledNow
            let disconnected = !cancelledNow && (stalled || (anyMissing && !AFC.isConnected(device, tools: tools)))

            // HEIC → JPEG for the whole batch at once, in-process and on all cores (was one `sips` process per photo).
            var converted: [Int: URL] = [:]
            if options.convertHEIC {
                let jobs = pending.enumerated().filter { $0.element.asset.isHEIC && AFC.fileSize($0.element.raw) > 0 }
                    .map { ($0.offset, $0.element.raw, staging.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")) }
                var ok = [Bool](repeating: false, count: jobs.count)
                ok.withUnsafeMutableBufferPointer { buf in
                    DispatchQueue.concurrentPerform(iterations: jobs.count) { i in buf[i] = Exporter.heicToJPEG(jobs[i].1, jobs[i].2) }
                }
                for (i, j) in jobs.enumerated() where ok[i] { converted[j.0] = j.2 }
            }

            for (n, item) in pending.enumerated() {
                let asset = item.asset
                let received = AFC.fileSize(item.raw)
                let sizeKnown = asset.fileSize > 0
                var problem: String? = nil
                if received <= 0 {
                    problem = "Could not be read from the device. The original may be stored only in iCloud."
                } else if sizeKnown && received != asset.fileSize {
                    if cancelledNow || disconnected {
                        problem = "Transfer was interrupted."
                    } else if let remote = AFC.remoteSize(asset.remotePath, device: device, tools: tools) {
                        if remote != received {
                            problem = "Incomplete transfer (\(Fmt.bytes(received)) of \(Fmt.bytes(remote)))."
                        }
                    } else if !decodes(item.raw, isVideo: asset.isVideo) {
                        problem = "The size differs from the catalog and the file could not be validated."
                    }
                } else if !sizeKnown && (cancelledNow || disconnected) && n == pending.count - 1 {
                    problem = "Transfer was interrupted."
                }

                if let problem {
                    if let c = converted[n] { try? fm.removeItem(at: c) }
                    try? fm.removeItem(at: item.raw)
                    if let lr = item.liveRaw { try? fm.removeItem(at: lr) }
                    if cancelledNow {
                        summary.notAttempted += 1
                        summary.report.append(ReportLine(status: .notCopied, asset: asset, savedAs: "", note: "The copy was stopped first."))
                        continue
                    }
                    fail(asset, stalled ? "The device stopped responding. Unlock it and try again." : (disconnected ? "The device was disconnected." : problem))
                    continue
                }

                var saved = false
                var reason = "The file could not be saved to the folder."
                if options.removeLocation {
                    LocationScrubber.scrub(converted[n] ?? item.raw)
                    if let lr = item.liveRaw { LocationScrubber.scrub(lr) }
                }
                if options.convertHEIC && asset.isHEIC {
                    if let c = converted[n], AFC.fileSize(c) > 0 {
                        do { try fm.moveItem(at: c, to: item.final); saved = true } catch { reason = error.localizedDescription }
                        try? fm.removeItem(at: c)
                    } else {
                        reason = "HEIC to JPEG conversion failed."
                    }
                } else {
                    do { try fm.moveItem(at: item.raw, to: item.final); saved = true } catch { reason = error.localizedDescription }
                }
                try? fm.removeItem(at: item.raw)

                let outSize = saved ? AFC.fileSize(item.final) : 0
                guard saved, outSize > 0 else {
                    if saved { try? fm.removeItem(at: item.final) }
                    if let lr = item.liveRaw { try? fm.removeItem(at: lr) }
                    fail(asset, reason)
                    continue
                }
                var dateAttrs: [FileAttributeKey: Any] = [:]
                if options.setDates, let d = asset.dateCreated { dateAttrs = [.creationDate: d, .modificationDate: d] }
                if !dateAttrs.isEmpty { try? fm.setAttributes(dateAttrs, ofItemAtPath: item.final.path) }

                let key = asset.remotePath
                manifest[key] = ExportManifestEntry(preferredPath: item.preferredRel,
                                                    exportedPath: relativePath(of: item.final, inside: destination),
                                                    sourceRemotePath: asset.remotePath, sourceSize: asset.fileSize, exportedSize: outSize)
                state.copied += 1; summary.copied += 1
                summary.report.append(ReportLine(status: .copied, asset: asset, savedAs: relativePath(of: item.final, inside: destination), note: ""))
                summary.bytesCopied += outSize
                settledBytes += max(0, asset.fileSize)
                transferredBytes += received

                if let lr = item.liveRaw {
                    if AFC.fileSize(lr) > 0 {
                        var liveFinal = item.final.deletingPathExtension().appendingPathExtension("MOV")
                        if fm.fileExists(atPath: liveFinal.path) || reserved.contains(liveFinal.path) {
                            liveFinal = uniqueURL(for: liveFinal, avoiding: reserved)
                        }
                        reserved.insert(liveFinal.path)
                        if (try? fm.moveItem(at: lr, to: liveFinal)) != nil {
                            if !dateAttrs.isEmpty { try? fm.setAttributes(dateAttrs, ofItemAtPath: liveFinal.path) }
                            summary.liveVideos += 1
                        }
                    }
                    try? fm.removeItem(at: lr)
                }
            }

            saveManifest()
            emit()
            if stalled { summary.stalled = true; break outer }
            if disconnected { summary.disconnected = true; break outer }
            if cancelledNow { break outer }
        }

        summary.cancelled = job.isCancelled
        summary.notAttempted = max(0, summary.total - summary.copied - summary.skipped - summary.failures.count)
        summary.elapsed = Date().timeIntervalSince(started)
        if options.saveReport, summary.copied + summary.failures.count + summary.notAttempted > 0 {
            summary.reportURL = writeReport(summary, assets: assets, to: destination, album: options.albumName)
        }
        return summary
    }

    /// "PortHop Reports/2026-11-23 14.05.09 Favourites.csv": a line for every item copied, failed or left out, with
    /// counts at the top. Items already in the folder are counted, not listed, so repeat hops stay small.
    static func writeReport(_ s: ExportSummary, assets: [PhotoAsset], to destination: URL, album: String) -> URL? {
        let folder = destination.appendingPathComponent("PortHop Reports", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let stamp = DateFormatter(); stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func q(_ v: String) -> String { v.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v }
        let seen = Set(s.report.map(\.asset.id))
        let why = s.stalled ? "The device stopped responding." : (s.disconnected ? "The device was disconnected." : "The copy was stopped first.")
        let lines = s.report.filter { $0.status != .skipped }
            + assets.filter { !seen.contains($0.id) }.map { ReportLine(status: .notCopied, asset: $0, savedAs: "", note: why) }
        func count(_ st: ReportLine.Status) -> Int { lines.filter { $0.status == st }.count }
        var csv = "\u{FEFF}PortHop copy report," + q(album.isEmpty ? "Photos" : album) + "," + q(day.string(from: Date())) + "\n"
        csv += "Copied,\(count(.copied))\nAlready in the folder,\(s.skipped)\nFailed,\(count(.failed))\n"
        csv += "Only in iCloud,\(count(.cloud))\nNot copied,\(count(.notCopied))\n\n"
        csv += "Status,Name on device,Saved as,Size (bytes),Date taken,Kind,Note\n"
        for l in lines {
            csv += [l.status.rawValue, l.asset.filename, l.savedAs, String(max(0, l.asset.fileSize)), l.asset.dateCreated.map { day.string(from: $0) } ?? "",
                    l.asset.kindText, l.note].map(q).joined(separator: ",") + "\n"
        }
        let preferred = folder.appendingPathComponent(Pattern.safe("\(stamp.string(from: Date())) \(album.isEmpty ? "Photos" : album)") + ".csv")
        let url = FileManager.default.fileExists(atPath: preferred.path) ? uniqueURL(for: preferred) : preferred
        return (try? csv.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    static func decodes(_ url: URL, isVideo: Bool) -> Bool {
        if isVideo { return AVURLAsset(url: url).isPlayable }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return false }
        return CGImageSourceGetStatus(src) == .statusComplete
    }

    static func uniqueURL(for preferred: URL, avoiding reserved: Set<String> = []) -> URL {
        let dir = preferred.deletingLastPathComponent()
        let base = preferred.deletingPathExtension().lastPathComponent
        let ext = preferred.pathExtension
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) && !reserved.contains(candidate.path) { return candidate }
            i += 1
        }
    }

    static func relativePath(of url: URL, inside root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : url.lastPathComponent
    }
}
