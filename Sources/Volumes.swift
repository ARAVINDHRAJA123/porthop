import Foundation
import AppKit
import SQLite3
import ImageIO
import AVFoundation

// Drives attached to this Mac.

// MARK: - Mac volumes (external drives)

struct VolumeInfo: Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let free: Int64
    let format: String
    let readOnly: Bool
    var isFAT: Bool { let f = format.lowercased(); return f.contains("fat32") || f.contains("ms-dos") }

    static func external() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeIsBrowsableKey,
                                      .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsInternal != true, v.volumeIsBrowsable == true,
                  url.path.hasPrefix("/Volumes/") else { return nil }
            let format = v.volumeLocalizedFormatDescription ?? ""
            let readOnly = v.volumeIsReadOnly ?? false
            // Read-only volumes are hidden (installer disk images), except NTFS drives, which are worth explaining.
            if readOnly && !format.uppercased().contains("NTFS") { return nil }
            return VolumeInfo(url: url, name: v.volumeName ?? url.lastPathComponent, free: Int64(v.volumeAvailableCapacity ?? 0),
                              format: format, readOnly: readOnly)
        }
    }

    /// Free space for a folder that may not exist yet (walks up to the nearest existing parent).
    static func freeSpace(at url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
        guard let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        if let a = v.volumeAvailableCapacityForImportantUsage, a > 0 { return a }
        return v.volumeAvailableCapacity.map(Int64.init)
    }

    static func format(at url: URL) -> String {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]))?.volumeLocalizedFormatDescription ?? ""
    }
}
