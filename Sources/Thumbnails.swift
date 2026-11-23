import Foundation
import AppKit
import SQLite3
import ImageIO
import AVFoundation

// Small previews of photos, fetched in batches over one connection.

// MARK: - Thumbnails

actor Limiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { available = n }
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeLast().resume() }
    }
}

final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    static let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("PortHop-cache", isDirectory: true)

    private let cache = NSCache<NSNumber, NSImage>()
    private let limiter = Limiter(3)
    /// Photo IDs are only unique within one library, so the caches belong to one device at a time.
    private var cacheDevice = ""
    private let deviceLock = NSLock()

    init() { cache.countLimit = 4000 }

    static func purgeDiskCache() {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("iPhoneAlbumExtractor2-cache"))
    }

    func cached(_ id: Int64) -> NSImage? { cache.object(forKey: NSNumber(value: id)) }

    func image(for asset: PhotoAsset, device: Device, tools: Tools) async -> NSImage? {
        deviceLock.withLock { if cacheDevice != device.udid { cacheDevice = device.udid; cache.removeAllObjects() } }
        if let hit = cached(asset.id) { return hit }
        let files = Self.smallFiles(asset, device)
        if AFC.fileSize(files.0) <= 0, AFC.fileSize(files.1) <= 0 {
            // The small JPEGs of everything on screen are fetched together, over one connection per batch.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                enqueue(Want(asset: asset, small: files.0, smaller: files.1, done: { cont.resume() }), device: device, tools: tools)
            }
        }
        if Task.isCancelled { return nil }
        var img: NSImage? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: [files.0, files.1].lazy.filter { AFC.fileSize($0) > 0 }.compactMap { Self.downsample($0, max: 420) }.first)
            }
        }
        if img == nil {   // no pre-made thumbnail: decode the original, a few at a time
            await limiter.acquire()
            if Task.isCancelled { await limiter.release(); return nil }
            img = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: Self.fetchOriginal(asset, device: device, tools: tools)) }
            }
            await limiter.release()
        }
        if let img { cache.setObject(img, forKey: NSNumber(value: asset.id)) }
        return img
    }

    private static var thumbDir: URL {
        let dir = cacheRoot.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    /// Where the two pre-made JPEGs iOS keeps beside the library land; named per device, as photo IDs repeat across devices.
    private static func smallFiles(_ asset: PhotoAsset, _ device: Device) -> (URL, URL) {
        let tag = "\(device.udid.suffix(12))-\(asset.uuid.isEmpty ? String(asset.id) : asset.uuid)"
        return (thumbDir.appendingPathComponent("\(tag)_a.jpg"), thumbDir.appendingPathComponent("\(tag)_b.jpg"))
    }

    private struct Want { let asset: PhotoAsset; let small: URL; let smaller: URL; let done: () -> Void }
    private var waiting: [String: [Want]] = [:]
    private var flushPending = Set<String>()
    private let waitLock = NSLock()
    private let sessions = DispatchSemaphore(value: 2)   // at most two device connections for thumbnails at once
    static let batchSize = 24

    private func enqueue(_ w: Want, device: Device, tools: Tools) {
        let schedule: Bool = waitLock.withLock {
            waiting[device.udid, default: []].append(w)
            return flushPending.insert(device.udid).inserted
        }
        // A short pause lets the rest of the screen's requests join the same batch.
        if schedule { DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.04) { self.flush(device, tools) } }
    }

    private func flush(_ device: Device, _ tools: Tools) {
        let batch: [Want] = waitLock.withLock {
            let all = waiting[device.udid] ?? []
            let take = Array(all.prefix(Self.batchSize))
            waiting[device.udid] = Array(all.dropFirst(take.count))
            if waiting[device.udid]!.isEmpty { flushPending.remove(device.udid) }
            return take
        }
        if waitLock.withLock({ flushPending.contains(device.udid) }) {
            DispatchQueue.global(qos: .userInitiated).async { self.flush(device, tools) }
        }
        guard !batch.isEmpty else { return }
        sessions.wait()
        var cmds = ""
        for w in batch where AFC.fileSize(w.small) <= 0 && AFC.fileSize(w.smaller) <= 0 {
            if let r1 = AFC.quote("PhotoData/Thumbnails/V2/\(w.asset.remotePath)/5005.JPG"), let l1 = AFC.quote(w.small.path) { cmds += "get \(r1) \(l1)\n" }
            if let r2 = AFC.quote("PhotoData/Thumbnails/V2/\(w.asset.remotePath)/5003.JPG"), let l2 = AFC.quote(w.smaller.path) { cmds += "get \(r2) \(l2)\n" }
        }
        if !cmds.isEmpty { _ = Shell.run(tools.afc, device.baseArgs, stdin: cmds + "quit\n", timeout: 60) }
        sessions.signal()
        for w in batch { w.done() }
    }

    private static func fetchOriginal(_ asset: PhotoAsset, device: Device, tools: Tools) -> NSImage? {
        guard !asset.isVideo, asset.fileSize < 60_000_000 else { return nil }
        let tag = "\(device.udid.suffix(12))-\(asset.uuid.isEmpty ? String(asset.id) : asset.uuid)"
        let full = thumbDir.appendingPathComponent("\(tag)_full.\(asset.fileExtension.lowercased())")
        if AFC.fileSize(full) <= 0 { _ = AFC.get(asset.remotePath, to: full, device: device, tools: tools) }
        let img = downsample(full, max: 420)
        try? FileManager.default.removeItem(at: full)
        return img
    }

    static func downsample(_ url: URL, max: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
