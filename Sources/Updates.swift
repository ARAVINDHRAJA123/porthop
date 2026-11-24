import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

/// Looks for a newer PortHop on GitHub Releases and can install it. The request carries nothing about the Mac or the
/// person: it only asks GitHub for the latest release of the public repository. Every download is checked against an
/// Ed25519 signature made with the publisher's private key (the public half is built into the app), the same
/// protection Sparkle uses, so a tampered or corrupted download is never installed.
enum Updates {
    static let repo = "ARAVINDHRAJA123/porthop"
    struct Release: Equatable {
        let version: String
        let url: URL
        let notes: String
        var assets: [String: URL] = [:]
    }
    enum Outcome { case newer(Release), upToDate, noneYet, failed(String) }

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// "v2.1.0-beta" → "2.1.0"
    static func core(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("v") { s.removeFirst() }
        return String(s.split(whereSeparator: { "-+ ".contains($0) }).first ?? "")
    }

    /// True when `candidate` is a later version than `current` ("2.10" > "2.9"; a "-beta" of the same number is not later).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { core(v).split(whereSeparator: { !$0.isNumber }).prefix(3).map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<3 {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func check() async -> Outcome {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PortHop", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return .noneYet }
            guard code == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("GitHub answered with an error (\(code)).")
            }
            let version = core(j["tag_name"] as? String ?? "")
            guard isNewer(version, than: current) else { return .upToDate }
            let url = URL(string: j["html_url"] as? String ?? "") ?? URL(string: "https://github.com/\(repo)/releases")!
            var assets: [String: URL] = [:]
            for a in (j["assets"] as? [[String: Any]]) ?? [] {
                if let n = a["name"] as? String, let u = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) { assets[n] = u }
            }
            return .newer(Release(version: version, url: url, notes: String((j["body"] as? String ?? "").prefix(1500)), assets: assets))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Installing

    /// The publisher's public key (32 bytes, base64), put into Info.plist when the app is built.
    static var publicKey: Data? {
        (Bundle.main.object(forInfoDictionaryKey: "PortHopUpdateKey") as? String).flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// True when `signature` (base64 text, as in the release's .sig file) was made for exactly these bytes with the key's private half.
    static func verify(_ data: Data, signature: Data, key: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              let text = String(data: signature, encoding: .utf8),
              let sig = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// The Mac download in a release and its signature.
    static func macAssets(_ r: Release) -> (zip: URL, sig: URL)? {
        guard let zipName = r.assets.keys.first(where: { $0.lowercased().hasSuffix("-mac.zip") }),
              let zip = r.assets[zipName], let sig = r.assets[zipName + ".sig"] else { return nil }
        return (zip, sig)
    }

    static func canInstall(_ r: Release) -> Bool { publicKey != nil && macAssets(r) != nil }

    /// Unpacks a downloaded, verified zip and checks it holds PortHop at the expected version. Returns the app inside.
    static func unpack(_ zip: URL, expecting version: String, bundleID: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PortHop-update-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], timeout: 300)?.ok == true else { return nil }
        let app = dir.appendingPathComponent("PortHop.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID,
              core(info["CFBundleShortVersionString"] as? String ?? "") == core(version),
              Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 120)?.ok == true else {
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
        return app
    }

    #if canImport(AppKit)
    /// Downloads, verifies and installs the update over this copy of PortHop, then reopens it.
    /// Returns nil when PortHop is about to restart, or what went wrong (nothing has changed then).
    @MainActor
    static func install(_ r: Release, status: @escaping (String) -> Void) async -> String? {
        guard let key = publicKey, let assets = macAssets(r) else { return "This update has to be downloaded from the release page." }
        status("Downloading PortHop \(r.version)…")
        let zipFile = FileManager.default.temporaryDirectory.appendingPathComponent("PortHop-\(r.version)-\(UUID().uuidString).zip")
        guard let got = try? await URLSession.shared.download(from: assets.zip), (got.1 as? HTTPURLResponse)?.statusCode == 200,
              (try? FileManager.default.moveItem(at: got.0, to: zipFile)) != nil,
              let sig = try? await URLSession.shared.data(from: assets.sig), (sig.1 as? HTTPURLResponse)?.statusCode == 200,
              let zipData = try? Data(contentsOf: zipFile, options: .mappedIfSafe) else {
            return "The update could not be downloaded. Check the internet connection and try again."
        }
        defer { try? FileManager.default.removeItem(at: zipFile) }
        let sigData = sig.0
        status("Checking the download…")
        guard verify(zipData, signature: sigData, key: key) else {
            return "The download did not match the publisher's signature, so it was not installed."
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.aravindhraja123.porthop"
        guard let fresh = unpack(zipFile, expecting: r.version, bundleID: bundleID) else { return "The download was not a complete copy of PortHop." }
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            return "PortHop can't replace itself in “\(current.deletingLastPathComponent().lastPathComponent)”. Download the update from the release page instead."
        }
        status("Installing…")
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: current, resultingItemURL: &trashed)
            try FileManager.default.moveItem(at: fresh, to: current)
        } catch {
            if let back = trashed as URL?, !FileManager.default.fileExists(atPath: current.path) { try? FileManager.default.moveItem(at: back, to: current) }
            return "The update could not be installed: \(error.localizedDescription)"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", current.path]
        try? p.run()
        NSApp.terminate(nil)
        return nil
    }
    #endif
}
