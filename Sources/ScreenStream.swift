import Foundation
import AVFoundation
import CoreMediaIO
import VideoToolbox
import CoreImage
import AppKit

/// Splits an H.264 byte stream (Annex B: NAL units after 00 00 01 start codes) into whole frames. This is what
/// `adb exec-out screenrecord --output-format=h264 -` sends: parameter sets, then one or more slices per frame.
final class AnnexB {
    struct Frame { let nals: [Data]; let isKey: Bool }
    private var buffer = Data()
    private var pending: [Data] = []
    private var pendingHasSlice = false
    private(set) var sps: Data?
    private(set) var pps: Data?

    /// Feeds bytes as they arrive; returns the frames now complete. A frame is known complete when the next one starts.
    func append(_ bytes: Data) -> [Frame] {
        buffer.append(bytes)
        var out: [Frame] = []
        let starts = AnnexB.startCodes(buffer)
        guard starts.count >= 2 else { return out }
        for k in 0..<(starts.count - 1) {
            out += take(AnnexB.trim(buffer.subdata(in: starts[k].payload..<starts[k + 1].at)))
        }
        buffer = buffer.subdata(in: starts[starts.count - 1].at..<buffer.count)
        return out
    }

    /// The last frame, once the stream has ended.
    func finish() -> [Frame] {
        var out: [Frame] = []
        if let s = AnnexB.startCodes(buffer).first { out += take(AnnexB.trim(buffer.subdata(in: s.payload..<buffer.count))) }
        buffer.removeAll()
        if pendingHasSlice { out.append(frame()) }
        pending.removeAll()
        pendingHasSlice = false
        return out
    }

    private func frame() -> Frame {
        let f = Frame(nals: pending, isKey: pending.contains { ($0.first ?? 0) & 0x1F == 5 })
        pending.removeAll()
        pendingHasSlice = false
        return f
    }

    private func take(_ nal: Data) -> [Frame] {
        guard let head = nal.first else { return [] }
        var out: [Frame] = []
        switch head & 0x1F {
        case 9:                                   // access unit delimiter: always a new frame
            if pendingHasSlice { out.append(frame()) }
            return out
        case 6, 7, 8:                             // SEI and parameter sets come before the slices of their frame
            if pendingHasSlice { out.append(frame()) }
            if head & 0x1F == 7 { sps = nal } else if head & 0x1F == 8 { pps = nal }
            pending.append(nal)
        case 1, 5:                                // a slice; the first slice of a frame starts at macroblock 0
            let firstOfFrame = nal.count > 1 && nal[nal.startIndex + 1] & 0x80 != 0
            if firstOfFrame && pendingHasSlice { out.append(frame()) }
            pending.append(nal)
            pendingHasSlice = true
        default:
            pending.append(nal)
        }
        return out
    }

    struct Start { let at: Int; let payload: Int }

    static func startCodes(_ d: Data) -> [Start] {
        var out: [Start] = []
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 2 < b.count {
                if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                    out.append(Start(at: (i > 0 && b[i - 1] == 0) ? i - 1 : i, payload: i + 3))
                    i += 3
                } else { i += 1 }
            }
        }
        return out
    }

    static func trim(_ nal: Data) -> Data {
        var end = nal.count
        while end > 0, nal[nal.startIndex + end - 1] == 0 { end -= 1 }
        return nal.prefix(end)
    }

    /// The codec name a decoder is configured with, from the sequence parameter set: "avc1.PPCCLL".
    static func codec(sps: Data) -> String {
        guard sps.count >= 4 else { return "avc1.42E01E" }
        let b = [UInt8](sps.prefix(4))
        return String(format: "avc1.%02X%02X%02X", b[1], b[2], b[3])
    }

    static func format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var fmt: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                          parameterSetPointers: ptrs, parameterSetSizes: [sps.count, pps.count],
                                                                          nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        return status == noErr ? fmt : nil
    }

    /// One frame as a sample buffer that a display layer, decoder or movie writer accepts (length-prefixed NAL units).
    static func sample(_ frame: Frame, format: CMVideoFormatDescription, at time: CMTime) -> CMSampleBuffer? {
        var avcc = Data()
        for n in frame.nals where ![7, 8, 9].contains((n.first ?? 0) & 0x1F) {
            var len = UInt32(n.count).bigEndian
            avcc.append(Data(bytes: &len, count: 4))
            avcc.append(n)
        }
        guard !avcc.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied: OSStatus = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(frame.isKey ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// Decodes frames and counts the pictures that came out (used by the tests to prove a stream really plays).
    static func decodedCount(_ frames: [Frame], format: CMVideoFormatDescription) -> Int {
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil,
                                           outputCallback: nil, decompressionSessionOut: &session) == noErr, let session else { return 0 }
        defer { VTDecompressionSessionInvalidate(session) }
        var count = 0
        for (i, f) in frames.enumerated() {
            guard let s = sample(f, format: format, at: CMTime(value: CMTimeValue(i), timescale: 30)) else { continue }
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: s, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, image != nil { count += 1 }
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return count
    }
}

/// An Android phone's screen, live: adb streams H.264 from the phone's own encoder and the Mac shows it as it arrives.
/// Taps and swipes on the picture are sent back to the phone. Nothing is installed on the phone.
final class AndroidScreen {
    let layer = AVSampleBufferDisplayLayer()
    var onSize: ((CGSize) -> Void)?
    var onEnded: ((String) -> Void)?
    private(set) var size = CGSize.zero
    private let queue = DispatchQueue(label: "porthop.android-screen")
    private var process: Process?
    private var stopped = true
    private var parser = AnnexB()
    private var format: CMVideoFormatDescription?
    private var formatKey = Data()
    private var framesThisRun = 0
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var writerStarted = false
    private var limitSize: String?
    private let device: Device
    private let tools: Tools

    init(device: Device, tools: Tools) {
        self.device = device
        self.tools = tools
        layer.videoGravity = .resizeAspect
    }

    func start() {
        queue.async { self.stopped = false; self.launch() }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.process?.terminate()
            self.process = nil
        }
        stopRecording { _ in }
    }

    private func launch() {
        guard !stopped, let adb = tools.adb else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = Android.args(device) + ["exec-out", "screenrecord", "--output-format=h264", "--bit-rate", "8000000"]
            + (limitSize.map { ["--size", $0] } ?? []) + ["-"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        parser = AnnexB()
        framesThisRun = 0
        let started = Date()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard let self else { return }
            if d.isEmpty { h.readabilityHandler = nil; return }
            self.queue.async { self.feed(self.parser.append(d)) }
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 0.2) {
                self.feed(self.parser.finish())
                guard !self.stopped else { return }
                if self.framesThisRun == 0 {
                    // Some phones refuse to encode at full resolution: try once more at a smaller size.
                    if self.limitSize == nil, Date().timeIntervalSince(started) < 8, let smaller = self.smallerSize() {
                        self.limitSize = smaller
                        self.launch()
                    } else {
                        self.stopped = true
                        DispatchQueue.main.async { self.onEnded?("The phone did not send its screen. Unlock it and try again; Android 10 or later is needed.") }
                    }
                } else {
                    self.launch()   // screenrecord stops by itself after three minutes; carry on seamlessly
                }
            }
        }
        do { try p.run(); process = p } catch {
            stopped = true
            DispatchQueue.main.async { self.onEnded?("adb could not be started.") }
        }
    }

    private func smallerSize() -> String? {
        guard let text = Android.shell("wm size", device: device, tools: tools),
              let m = text.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) else { return "720x1280" }
        let parts = text[m].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return "720x1280" }
        let scale = min(1, 1280 / max(parts[0], parts[1]))
        func even(_ v: Double) -> Int { Int(v * scale) / 2 * 2 }
        return "\(even(parts[0]))x\(even(parts[1]))"
    }

    private func feed(_ frames: [AnnexB.Frame]) {
        for f in frames {
            if f.isKey, let sps = parser.sps, let pps = parser.pps, sps + pps != formatKey, let fmt = AnnexB.format(sps: sps, pps: pps) {
                formatKey = sps + pps
                format = fmt
                let dims = CMVideoFormatDescriptionGetDimensions(fmt)
                let newSize = CGSize(width: Int(dims.width), height: Int(dims.height))
                if writer != nil && newSize != size { stopRecording { _ in } }   // a movie keeps one picture size
                size = newSize
                DispatchQueue.main.async { self.onSize?(newSize) }
            }
            guard let format else { continue }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            guard let sample = AnnexB.sample(f, format: format, at: now) else { continue }
            framesThisRun += 1
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
            record(sample, isKey: f.isKey, at: now)
        }
    }

    // MARK: Recording: the frames are written as they arrive, without re-encoding.

    func startRecording(to url: URL) -> Bool {
        var ok = false
        queue.sync {
            guard let format, writer == nil, let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            guard w.canAdd(input) else { return }
            w.add(input)
            guard w.startWriting() else { return }
            writer = w
            writerInput = input
            writerStarted = false
            ok = true
            process?.terminate()   // the stream restarts at once with a whole picture, so the movie starts without a wait
        }
        return ok
    }

    private func record(_ sample: CMSampleBuffer, isKey: Bool, at time: CMTime) {
        guard let writer, let input = writerInput else { return }
        if !writerStarted {
            guard isKey else { return }   // a movie has to start with a whole picture
            writer.startSession(atSourceTime: time)
            writerStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sample) }
    }

    func stopRecording(_ done: @escaping (URL?) -> Void) {
        queue.async {
            guard let writer = self.writer, let input = self.writerInput else { DispatchQueue.main.async { done(nil) }; return }
            self.writer = nil
            self.writerInput = nil
            guard self.writerStarted else { writer.cancelWriting(); DispatchQueue.main.async { done(nil) }; return }
            input.markAsFinished()
            writer.finishWriting { DispatchQueue.main.async { done(writer.status == .completed ? writer.outputURL : nil) } }
        }
    }

    // MARK: Screenshots and control

    /// Saves a full-resolution screenshot straight from the phone.
    static func screenshot(device: Device, tools: Tools, to url: URL) -> Bool {
        guard let adb = tools.adb, FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: url.path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = Android.args(device) + ["exec-out", "screencap", "-p"]
        p.standardOutput = handle
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        try? handle.close()
        guard p.terminationStatus == 0, let head = try? Data(contentsOf: url).prefix(8), head.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    /// The phone's real screen size in pixels, for turning a click on the picture into a tap on the phone.
    static func screenSize(device: Device, tools: Tools) -> CGSize? {
        guard let text = Android.shell("wm size", device: device, tools: tools) else { return nil }
        let line = text.split(separator: "\n").last { $0.contains("Override") } ?? text.split(separator: "\n").first { $0.contains("Physical") }
        guard let line, let m = line.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) else { return nil }
        let parts = line[m].split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }

    /// x and y are fractions of the picture (0…1); the picture may be landscape while the size is given portrait.
    static func tap(_ x: Double, _ y: Double, picture: CGSize, device: Device, tools: Tools) {
        let p = point(x, y, picture: picture, device: device, tools: tools)
        _ = Android.shell("input tap \(p.0) \(p.1)", device: device, tools: tools)
    }

    static func swipe(from a: (Double, Double), to b: (Double, Double), picture: CGSize, device: Device, tools: Tools) {
        let p = point(a.0, a.1, picture: picture, device: device, tools: tools), q = point(b.0, b.1, picture: picture, device: device, tools: tools)
        _ = Android.shell("input swipe \(p.0) \(p.1) \(q.0) \(q.1) 250", device: device, tools: tools)
    }

    /// Back, Home and Recents, as Android key codes.
    static func key(_ code: Int, device: Device, tools: Tools) {
        _ = Android.shell("input keyevent \(code)", device: device, tools: tools)
    }

    private static var sizes: [String: CGSize] = [:]
    private static func point(_ x: Double, _ y: Double, picture: CGSize, device: Device, tools: Tools) -> (Int, Int) {
        var real = sizes[device.udid] ?? screenSize(device: device, tools: tools) ?? picture
        sizes[device.udid] = real
        if (picture.width > picture.height) != (real.width > real.height) { real = CGSize(width: real.height, height: real.width) }
        return (Int((min(max(x, 0), 1) * real.width).rounded()), Int((min(max(y, 0), 1) * real.height).rounded()))
    }
}

/// An iPhone's screen, live, the way QuickTime Player shows it: macOS offers a connected iPhone as a capture device once
/// screen-capture devices are allowed. Works over USB with any iOS version and needs nothing installed on the iPhone.
final class IPhoneScreen: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    private(set) lazy var preview = AVCaptureVideoPreviewLayer(session: session)
    private let frames = AVCaptureVideoDataOutput()
    private let movie = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "porthop.iphone-screen")
    private var last: CVPixelBuffer?
    private var recordingDone: ((URL?) -> Void)?

    static func allowScreenCaptureDevices() {
        var prop = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    /// The capture device for this iPhone: macOS names it by the iPhone's identifier (with or without dashes) and its name.
    static func find(udid: String, name: String) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.external] } else { types = [.externalUnknown] }
        let all = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .muxed, position: .unspecified).devices
        let key = udid.replacingOccurrences(of: "-", with: "").lowercased()
        return all.first { $0.uniqueID.replacingOccurrences(of: "-", with: "").lowercased() == key }
            ?? all.first { $0.localizedName == name }
            ?? (all.count == 1 ? all.first : nil)
    }

    func start(_ device: AVCaptureDevice) -> Bool {
        session.beginConfiguration()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        frames.setSampleBufferDelegate(self, queue: queue)
        frames.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(frames) { session.addOutput(frames) }
        if session.canAddOutput(movie) { session.addOutput(movie) }
        session.commitConfiguration()
        preview.videoGravity = .resizeAspect
        queue.async { self.session.startRunning() }
        return true
    }

    func stop() {
        if movie.isRecording { movie.stopRecording() }
        queue.async { self.session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        last = CMSampleBufferGetImageBuffer(sampleBuffer)
    }

    var size: CGSize {
        var frame: CVPixelBuffer?
        queue.sync { frame = last }
        guard let frame else { return .zero }
        return CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
    }

    func screenshot(to url: URL) -> Bool {
        var frame: CVPixelBuffer?
        queue.sync { frame = last }
        guard let frame else { return false }
        let image = CIImage(cvPixelBuffer: frame)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              (try? CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: space)) != nil else { return false }
        return true
    }

    var isRecording: Bool { movie.isRecording }

    func startRecording(to url: URL) -> Bool {
        guard !movie.isRecording, session.outputs.contains(movie) else { return false }
        movie.startRecording(to: url, recordingDelegate: self)
        return true
    }

    func stopRecording(_ done: @escaping (URL?) -> Void) {
        guard movie.isRecording else { done(nil); return }
        recordingDone = done
        movie.stopRecording()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        let ok = FileManager.default.fileExists(atPath: url.path)
        DispatchQueue.main.async { self.recordingDone?(ok ? url : nil); self.recordingDone = nil }
    }
}
