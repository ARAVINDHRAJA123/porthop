import Foundation

/// Looks for a newer PortHop on GitHub Releases. The request carries nothing about the Mac or the person:
/// it only asks GitHub for the latest release of the public repository. (Sparkle would need Developer ID
/// signing and a hosted update feed; this needs neither.)
enum Updates {
    static let repo = "ARAVINDHRAJA123/porthop"
    struct Release: Equatable { let version: String; let url: URL; let notes: String }
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
            return .newer(Release(version: version, url: url, notes: String((j["body"] as? String ?? "").prefix(1500))))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
