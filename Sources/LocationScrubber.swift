import Foundation

/// Removes where a photo or video was taken, in place: the GPS block of a photo's EXIF data (JPEG, HEIC/HEIF,
/// DNG/TIFF) and the location entries of a video's QuickTime metadata (MOV/MP4). Nothing is re-encoded and the file
/// keeps its exact size; the picture, the sound and every other detail stay as they were.
/// The Windows edition has the same logic in core/location.js; both are checked against Tests/golden/location.
enum LocationScrubber {
    /// True when location data was found and removed.
    @discardableResult
    static func scrub(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forUpdating: url) else { return false }
        defer { try? h.close() }
        let f = File(h)
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return jpeg(f)
        case "heic", "heif", "hif", "avif": return heif(f)
        case "dng", "tif", "tiff": return tiffFile(f)
        case "mov", "mp4", "m4v", "3gp": return quickTime(f)
        default: return false
        }
    }

    struct File {
        let h: FileHandle
        let size: UInt64
        init(_ h: FileHandle) { self.h = h; size = (try? h.seekToEnd()) ?? 0 }
        func read(_ offset: UInt64, _ count: Int) -> Data? {
            guard count > 0, offset + UInt64(count) <= size else { return nil }
            do { try h.seek(toOffset: offset); return try h.read(upToCount: count).map { Data($0) } } catch { return nil }
        }
        func write(_ offset: UInt64, _ data: Data) -> Bool {
            do { try h.seek(toOffset: offset); try h.write(contentsOf: data); return true } catch { return false }
        }
    }

    // MARK: EXIF (TIFF structure)

    /// Empties the GPS directory of a TIFF/EXIF block: every GPS value is overwritten with zeros and the directory
    /// is left with no entries. Offsets inside the block count from its first byte.
    static func wipeGPS(_ t: inout Data) -> Bool {
        guard t.count >= 8 else { return false }
        let little: Bool
        if t[0] == 0x49, t[1] == 0x49 { little = true } else if t[0] == 0x4D, t[1] == 0x4D { little = false } else { return false }
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= t.count else { return nil }
            let a = Int(t[o]), b = Int(t[o + 1])
            return little ? a | b << 8 : a << 8 | b
        }
        func u32(_ o: Int) -> Int? {
            guard let a = u16(o), let b = u16(o + 2) else { return nil }
            return little ? a | b << 16 : a << 16 | b
        }
        func zero(_ o: Int, _ len: Int) {
            guard o >= 0, len > 0, o + len <= t.count else { return }
            t.replaceSubrange(o..<(o + len), with: Data(count: len))
        }
        guard u16(2) == 42, let ifd0 = u32(4), let n0 = u16(ifd0), n0 < 1000 else { return false }
        var gps: Int?
        for i in 0..<n0 where u16(ifd0 + 2 + 12 * i) == 0x8825 { gps = u32(ifd0 + 2 + 12 * i + 8) }
        guard let g = gps, let n = u16(g), n > 0, n < 1000, g + 2 + 12 * n <= t.count else { return false }
        let typeSize = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8]
        for i in 0..<n {
            let e = g + 2 + 12 * i
            guard let type = u16(e + 2), let count = u32(e + 4) else { continue }
            let len = (type < typeSize.count ? typeSize[type] : 1) * count
            if len > 4, let off = u32(e + 8) { zero(off, len) }
        }
        zero(g, 2 + 12 * n)
        return true
    }

    private static func tiffFile(_ f: File) -> Bool {
        let n = Int(min(f.size, 4_000_000))
        guard var t = f.read(0, n), wipeGPS(&t) else { return false }
        return f.write(0, t)
    }

    // MARK: JPEG

    private static func jpeg(_ f: File) -> Bool {
        guard let soi = f.read(0, 2), soi == Data([0xFF, 0xD8]) else { return false }
        var o: UInt64 = 2
        var changed = false
        while o + 4 <= f.size {
            guard let m = f.read(o, 4), m[0] == 0xFF else { break }
            let marker = m[1]
            if marker == 0xFF { o += 1; continue }                                   // fill byte
            if marker == 0x01 || (0xD0...0xD8).contains(marker) { o += 2; continue }  // markers without a length
            if marker == 0xDA || marker == 0xD9 { break }                             // image data from here on
            let len = UInt64(m[2]) << 8 | UInt64(m[3])
            guard len >= 2 else { break }
            if marker == 0xE1, len > 8, let seg = f.read(o + 4, Int(len) - 2), seg.starts(with: Data("Exif\0\0".utf8)) {
                var t = Data(seg[6...])
                if wipeGPS(&t), f.write(o + 4 + 6, t) { changed = true }
            }
            o += 2 + len
        }
        return changed
    }

    // MARK: HEIF (ISO base media boxes)

    static func be32(_ d: Data, _ o: Int) -> Int {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3])
    }
    static func be(_ d: Data, _ o: Int, _ n: Int) -> Int {
        guard n > 0, o >= 0, o + n <= d.count else { return 0 }
        return (0..<n).reduce(0) { $0 << 8 | Int(d[o + $1]) }
    }
    static func fourCC(_ d: Data, _ o: Int) -> String {
        guard o >= 0, o + 4 <= d.count else { return "" }
        return String(bytes: d[o..<(o + 4)], encoding: .isoLatin1) ?? ""
    }

    /// A box at `o` in the file: its size, type and header length.
    private static func box(_ f: File, _ o: UInt64) -> (size: UInt64, type: String, header: UInt64)? {
        guard let h = f.read(o, 8) else { return nil }
        var size = UInt64(be32(h, 0))
        var header: UInt64 = 8
        if size == 1 {
            guard let l = f.read(o + 8, 8) else { return nil }
            size = UInt64(be(l, 0, 8)); header = 16
        } else if size == 0 { size = f.size - o }
        guard size >= header, o + size <= f.size else { return nil }
        return (size, fourCC(h, 4), header)
    }

    /// The boxes directly inside `d[start..<end]`.
    static func children(_ d: Data, _ start: Int, _ end: Int) -> [(offset: Int, size: Int, type: String, header: Int)] {
        var out: [(Int, Int, String, Int)] = []
        var o = start
        while o + 8 <= end {
            var size = be32(d, o), header = 8
            if size == 1 { guard o + 16 <= end else { break }; size = be(d, o + 8, 8); header = 16 }
            else if size == 0 { size = end - o }
            guard size >= header, o + size <= end else { break }
            out.append((o, size, fourCC(d, o + 4), header))
            o += size
        }
        return out
    }

    private static func heif(_ f: File) -> Bool {
        var o: UInt64 = 0
        while o + 8 <= f.size, let b = box(f, o) {
            if b.type == "meta" {
                guard b.size <= 16_000_000, let meta = f.read(o, Int(b.size)) else { return false }
                return heifExif(f, meta, metaStart: o, header: Int(b.header))
            }
            o += b.size
        }
        return false
    }

    /// Finds the 'Exif' item through iinf (its ID) and iloc (where its bytes are), then wipes its GPS block.
    private static func heifExif(_ f: File, _ meta: Data, metaStart: UInt64, header: Int) -> Bool {
        let kids = children(meta, header + 4, meta.count)   // 'meta' is a full box: 4 bytes of version and flags first
        var exifIDs = Set<Int>()
        if let iinf = kids.first(where: { $0.type == "iinf" }) {
            let p = iinf.offset + iinf.header
            let version = be(meta, p, 1)
            let first = p + 4 + (version == 0 ? 2 : 4)
            for e in children(meta, first, iinf.offset + iinf.size) where e.type == "infe" {
                let q = e.offset + e.header
                let v = be(meta, q, 1)
                guard v >= 2 else { continue }
                let idLen = v == 2 ? 2 : 4
                if fourCC(meta, q + 4 + idLen + 2) == "Exif" { exifIDs.insert(be(meta, q + 4, idLen)) }
            }
        }
        guard !exifIDs.isEmpty, let iloc = kids.first(where: { $0.type == "iloc" }) else { return false }
        let idat = kids.first(where: { $0.type == "idat" }).map { Int(metaStart) + $0.offset + $0.header }
        var p = iloc.offset + iloc.header
        let version = be(meta, p, 1); p += 4
        let offsetSize = be(meta, p, 1) >> 4, lengthSize = be(meta, p, 1) & 15
        let baseSize = be(meta, p + 1, 1) >> 4, indexSize = version >= 1 ? be(meta, p + 1, 1) & 15 : 0
        p += 2
        let count: Int
        if version < 2 { count = be(meta, p, 2); p += 2 } else { count = be(meta, p, 4); p += 4 }
        var changed = false
        for _ in 0..<count {
            guard p < meta.count else { break }
            let id: Int
            if version < 2 { id = be(meta, p, 2); p += 2 } else { id = be(meta, p, 4); p += 4 }
            var method = 0
            if version >= 1 { method = be(meta, p, 2) & 15; p += 2 }
            p += 2                                                  // data_reference_index
            let base = be(meta, p, baseSize); p += baseSize
            let extents = be(meta, p, 2); p += 2
            var firstOffset = 0, firstLength = 0
            for x in 0..<extents {
                p += indexSize
                let off = be(meta, p, offsetSize); p += offsetSize
                let len = be(meta, p, lengthSize); p += lengthSize
                if x == 0 { firstOffset = off; firstLength = len }
            }
            guard exifIDs.contains(id), firstLength > 8 else { continue }
            let start: Int
            if method == 0 { start = base + firstOffset } else if method == 1, let idat { start = idat + base + firstOffset } else { continue }
            guard let payload = f.read(UInt64(start), min(firstLength, 4_000_000)) else { continue }
            // The payload starts with how far in the TIFF header is; look a little further for writers that differ.
            var tiffAt = 4 + be32(payload, 0)
            if !isTIFF(payload, tiffAt), let found = (0..<min(64, payload.count - 4)).first(where: { isTIFF(payload, $0) }) { tiffAt = found }
            guard isTIFF(payload, tiffAt) else { continue }
            var t = Data(payload[tiffAt...])
            if wipeGPS(&t), f.write(UInt64(start + tiffAt), t) { changed = true }
        }
        return changed
    }

    private static func isTIFF(_ d: Data, _ o: Int) -> Bool {
        guard o >= 0, o + 4 <= d.count else { return false }
        return (d[o] == 0x49 && d[o + 1] == 0x49 && d[o + 2] == 0x2A && d[o + 3] == 0)
            || (d[o] == 0x4D && d[o + 1] == 0x4D && d[o + 2] == 0 && d[o + 3] == 0x2A)
    }

    // MARK: QuickTime / MP4

    private static func quickTime(_ f: File) -> Bool {
        var o: UInt64 = 0
        var changed = false
        while o + 8 <= f.size, let b = box(f, o) {
            if b.type == "moov", b.size <= 256_000_000, var moov = f.read(o, Int(b.size)) {
                if patchAtoms(&moov, Int(b.header), moov.count), f.write(o, moov) { changed = true }
            }
            o += b.size
        }
        return changed
    }

    /// Location atoms (©xyz, loci) become 'free' space with their contents zeroed; metadata keys about location
    /// are renamed and their values zeroed. Everything keeps its size and place.
    static func patchAtoms(_ d: inout Data, _ start: Int, _ end: Int) -> Bool {
        var changed = false
        let kids = children(d, start, end)
        var locationKeys = Set<Int>()
        for k in kids where k.type == "keys" { locationKeys.formUnion(renameLocationKeys(&d, k.offset + k.header, k.offset + k.size)) }
        for k in kids {
            switch k.type {
            case "\u{A9}xyz", "loci":
                d.replaceSubrange((k.offset + 4)..<(k.offset + 8), with: Data("free".utf8))
                d.replaceSubrange((k.offset + k.header)..<(k.offset + k.size), with: Data(count: k.size - k.header))
                changed = true
            case "ilst" where !locationKeys.isEmpty:
                for item in children(d, k.offset + k.header, k.offset + k.size) where locationKeys.contains(be32(d, item.offset + 4)) {
                    for v in children(d, item.offset + item.header, item.offset + item.size) where v.type == "data" && v.size > v.header + 8 {
                        let from = v.offset + v.header + 8   // after the value's type and locale
                        d.replaceSubrange(from..<(v.offset + v.size), with: Data(count: v.offset + v.size - from))
                        changed = true
                    }
                }
            case "moov", "trak", "mdia", "minf", "udta", "edts", "dinf":
                if patchAtoms(&d, k.offset + k.header, k.offset + k.size) { changed = true }
            case "meta":
                // QuickTime's 'meta' holds atoms directly; the ISO form starts with 4 bytes of version and flags.
                let inner = k.offset + k.header
                let iso = !plausibleAtom(d, inner, k.offset + k.size)
                if patchAtoms(&d, inner + (iso ? 4 : 0), k.offset + k.size) { changed = true }
            default: break
            }
        }
        return changed || !locationKeys.isEmpty
    }

    private static func plausibleAtom(_ d: Data, _ o: Int, _ end: Int) -> Bool {
        let size = be32(d, o)
        guard size >= 8, o + size <= end else { return false }
        return d[(o + 4)..<(o + 8)].allSatisfy { ($0 >= 0x20 && $0 <= 0x7E) || $0 == 0xA9 }
    }

    /// In a 'keys' atom, renames every key mentioning location (same length, so nothing moves) and returns their
    /// 1-based numbers, which is how 'ilst' refers to them.
    private static func renameLocationKeys(_ d: inout Data, _ start: Int, _ end: Int) -> Set<Int> {
        var found = Set<Int>()
        let count = be32(d, start + 4)
        var o = start + 8
        for i in 1...max(1, count) {
            guard count > 0, o + 8 <= end else { break }
            let size = be32(d, o)
            guard size >= 8, o + size <= end else { break }
            if let r = d[(o + 8)..<(o + size)].range(of: Data("location".utf8)) {
                d.replaceSubrange(r, with: Data("redacted".utf8))
                found.insert(i)
            }
            o += size
        }
        return found
    }
}
