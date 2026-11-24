import Foundation
import ImageCaptureCore

/// Removing from the phone what has been copied, the way Image Capture does it, so the phone's Photos library stays correct.
/// Only items whose copy is confirmed in the destination folder are ever removed.
enum Cleanup {
    struct CameraFile: Hashable { let folder: String; let name: String; let size: Int64 }

    static func ext(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }

    /// Items safe to remove after a copy: copied (or already there), the copy is in the folder at its full size, and nothing
    /// of the item would be lost (a Live Photo's video and an edited version must have been copied too).
    static func confirmed(_ s: ExportSummary, options: ExportOptions) -> [PhotoAsset] {
        s.report.compactMap { line in
            guard line.status == .copied || line.status == .skipped, !line.savedAs.isEmpty else { return nil }
            let a = line.asset
            if a.isLivePhoto && !options.includeLiveVideo { return nil }
            if a.isEdited && !options.editedVersions { return nil }
            let size = AFC.fileSize(s.destination.appendingPathComponent(line.savedAs))
            let converted = options.convertHEIC && ["heic", "heif"].contains(ext(a.filename))
            guard size > 0, converted || a.fileSize <= 0 || size == a.fileSize else { return nil }
            return a
        }
    }

    /// The iPhone's camera files that belong to confirmed items. The iPhone may offer a HEIC photo as a JPEG
    /// (Settings › Photos › Transfer to Mac or PC: Automatic), so the name without its extension decides, within the same folder.
    static func deletable(_ assets: [PhotoAsset], files: [CameraFile], liveVideos: Bool) -> [CameraFile] {
        func key(_ folder: String, _ name: String) -> String { folder.uppercased() + "/" + (name as NSString).deletingPathExtension.uppercased() }
        var byKey: [String: [CameraFile]] = [:]
        for f in files { byKey[key(f.folder, f.name), default: []].append(f) }
        var out = Set<CameraFile>()
        for a in assets {
            guard let list = byKey[key((a.directory as NSString).lastPathComponent, a.filename)] else { continue }
            let mine = ext(a.filename)
            let offersOriginal = list.contains { ext($0.name) == mine }
            for f in list {
                let theirs = ext(f.name)
                let same = theirs == mine && (f.size <= 0 || a.fileSize <= 0 || f.size == a.fileSize)
                let converted = !offersOriginal && ["heic", "heif"].contains(mine) && ["jpg", "jpeg"].contains(theirs)
                let live = a.isLivePhoto && liveVideos && theirs == "mov" && mine != "mov"
                if same || converted || live { out.insert(f) }
            }
        }
        return out.sorted { ($0.folder, $0.name) < ($1.folder, $1.name) }
    }

    struct AndroidPair: Hashable { let remote: String; let local: URL }

    /// Phone files under copied folders whose copy has the same size: safe to delete.
    static func androidConfirmed(_ pairs: [AndroidPair], device: Device, tools: Tools) -> [AFCFileEntry] {
        var out: [AFCFileEntry] = []
        for p in pairs {
            for e in Android.filesBelow(p.remote, device: device, tools: tools) where e.path.hasPrefix(p.remote + "/") {
                let rel = String(e.path.dropFirst(p.remote.count + 1))
                let local = p.local.appendingPathComponent(rel)
                if e.size > 0, AFC.fileSize(local) == e.size { out.append(e) }
            }
        }
        return out
    }
}

/// Talks to the iPhone as a camera (the system's Image Capture service) to delete photos and videos from it.
final class IPhoneCameraDeleter: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private let udid: String
    private let name: String
    private var choose: (([Cleanup.CameraFile]) -> [Cleanup.CameraFile])?
    private var done: ((Result<(removed: Int, offered: Int), CleanupError>) -> Void)?
    private var timer: Timer?
    private var keepAlive: IPhoneCameraDeleter?

    struct CleanupError: Error { let message: String }

    init(udid: String, name: String) {
        self.udid = udid
        self.name = name
    }

    /// Opens the iPhone's photo list, asks `choose` which files to remove, removes them and reports how many went.
    func run(choose: @escaping ([Cleanup.CameraFile]) -> [Cleanup.CameraFile],
             done: @escaping (Result<(removed: Int, offered: Int), CleanupError>) -> Void) {
        self.choose = choose
        self.done = done
        keepAlive = self
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue) ?? .camera
        browser.start()
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            self?.finish(.failure(CleanupError(message: "The iPhone did not show its photos in time. Unlock it, keep it connected, and try again.")))
        }
    }

    private func finish(_ r: Result<(removed: Int, offered: Int), CleanupError>) {
        timer?.invalidate()
        timer = nil
        guard let done else { return }
        self.done = nil
        camera?.requestCloseSession()
        browser.stop()
        done(r)
        keepAlive = nil
    }

    private func isOurs(_ cam: ICCameraDevice) -> Bool {
        let key = udid.replacingOccurrences(of: "-", with: "").lowercased()
        let serial = (cam.serialNumberString ?? "").replacingOccurrences(of: "-", with: "").lowercased()
        return (!serial.isEmpty && serial == key) || cam.name == name
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, let cam = device as? ICCameraDevice, isOurs(cam) else { return }
        camera = cam
        cam.delegate = self
        cam.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device == camera { finish(.failure(CleanupError(message: "The iPhone was disconnected."))) }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { finish(.failure(CleanupError(message: "The iPhone did not open its photos (\(error.localizedDescription)). Unlock it and tap Trust."))) }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        let files = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        func ref(_ f: ICCameraFile) -> Cleanup.CameraFile { Cleanup.CameraFile(folder: f.parentFolder?.name ?? "", name: f.name ?? "", size: Int64(f.fileSize)) }
        let chosen = Set(choose?(files.map(ref)) ?? [])
        let items: [ICCameraItem] = files.filter { chosen.contains(ref($0)) }
        guard !items.isEmpty else { finish(.success((0, files.count))); return }
        var failed = 0
        _ = device.requestDeleteFiles(items, deleteFailed: { list in failed = list.count }, completion: { _, error in
            DispatchQueue.main.async {
                if let error, failed == 0 { failed = items.count; _ = error }
                self.finish(.success((items.count - failed, files.count)))
            }
        })
    }

    func didRemove(_ device: ICDevice) { finish(.failure(CleanupError(message: "The iPhone was disconnected."))) }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
