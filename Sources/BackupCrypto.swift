import Foundation
import CommonCrypto

/// Opens password-protected device backups. The password is only used in memory to derive keys.
enum BackupCrypto {
    static func pbkdf2(_ password: Data, salt: Data, rounds: Int, sha1: Bool) -> Data? {
        var out = Data(count: 32)
        let status = out.withUnsafeMutableBytes { o in
            password.withUnsafeBytes { p in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.bindMemory(to: Int8.self).baseAddress, password.count,
                                         s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(sha1 ? kCCPRFHmacAlgSHA1 : kCCPRFHmacAlgSHA256), UInt32(rounds),
                                         o.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        return status == kCCSuccess ? out : nil
    }

    /// Standard AES key unwrap. Returns nil when the wrapping key is wrong.
    static func unwrap(_ wrapped: Data, with key: Data) -> Data? {
        var length = CCSymmetricUnwrappedSize(CCWrappingAlgorithm(kCCWRAPAES), wrapped.count)
        guard length > 0 else { return nil }
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { o in
            wrapped.withUnsafeBytes { w in
                key.withUnsafeBytes { k in
                    CCSymmetricKeyUnwrap(CCWrappingAlgorithm(kCCWRAPAES), CCrfc3394_iv, CCrfc3394_ivLen,
                                         k.bindMemory(to: UInt8.self).baseAddress, key.count,
                                         w.bindMemory(to: UInt8.self).baseAddress, wrapped.count,
                                         o.bindMemory(to: UInt8.self).baseAddress, &length)
                }
            }
        }
        return status == kCCSuccess ? out.prefix(length) : nil
    }

    static func uint(_ d: Data) -> Int { d.reduce(0) { $0 << 8 | Int($1) } }
    static func classID(_ d: Data) -> UInt32 { d.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) } }

    enum Unlock { case keys([UInt32: Data]), wrongPassword, unreadable }

    /// Derives the backup's class keys from its key bag and the password.
    static func unlock(keyBag: Data, password: String) -> Unlock {
        var header: [String: Data] = [:]
        var classes: [[String: Data]] = []
        var current: [String: Data]?
        var i = keyBag.startIndex
        while i + 8 <= keyBag.endIndex {
            let tag = String(decoding: keyBag[i..<i + 4], as: UTF8.self)
            let n = uint(keyBag[i + 4..<i + 8])
            guard i + 8 + n <= keyBag.endIndex else { break }
            let value = Data(keyBag[i + 8..<i + 8 + n])
            i += 8 + n
            if tag == "UUID" && header["UUID"] == nil { header[tag] = value }
            else if tag == "WRAP" && header["WRAP"] == nil && current == nil { header[tag] = value }
            else if tag == "UUID" { if let c = current { classes.append(c) }; current = [tag: value] }
            else if current != nil && ["CLAS", "WRAP", "WPKY", "KTYP", "PBKY"].contains(tag) { current?[tag] = value }
            else { header[tag] = value }
        }
        if let c = current { classes.append(c) }
        guard let salt = header["SALT"], let iter = header["ITER"] else { return .unreadable }
        // iOS 10.2 and later add a first SHA-256 round (DPSL/DPIC); older backups use the SHA-1 round alone.
        var secret = Data(password.utf8)
        if let dpsl = header["DPSL"], let dpic = header["DPIC"] {
            guard let first = pbkdf2(secret, salt: dpsl, rounds: uint(dpic), sha1: false) else { return .unreadable }
            secret = first
        }
        guard let passKey = pbkdf2(secret, salt: salt, rounds: uint(iter), sha1: true) else { return .unreadable }
        var keys: [UInt32: Data] = [:]
        var wrappedCount = 0
        for c in classes {
            guard let clas = c["CLAS"], let wpky = c["WPKY"] else { continue }
            // Only keys wrapped with the password (WRAP bit 2) can be opened here; device-only ones are left alone.
            if let wrap = c["WRAP"], uint(wrap) & 2 == 0 { continue }
            wrappedCount += 1
            guard let key = unwrap(wpky, with: passKey) else { return .wrongPassword }
            keys[UInt32(uint(clas))] = key
        }
        return wrappedCount == 0 ? .unreadable : .keys(keys)
    }

    /// Decrypts one stored file (AES-CBC, empty starting block) and trims it to its real length.
    static func decrypt(_ source: URL, to dest: URL, key: Data, size: Int?) -> Bool {
        guard let input = try? FileHandle(forReadingFrom: source), FileManager.default.createFile(atPath: dest.path, contents: nil),
              let output = try? FileHandle(forUpdating: dest) else { return false }
        defer { try? input.close(); try? output.close() }
        var cryptor: CCCryptorRef?
        let made = key.withUnsafeBytes { k in
            CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0, k.baseAddress, key.count, nil, &cryptor)
        }
        guard made == kCCSuccess, let cryptor else { return false }
        defer { CCCryptorRelease(cryptor) }
        var buffer = Data(count: (1 << 20) + kCCBlockSizeAES128)
        while true {
            let chunk = input.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            var moved = 0
            let cap = buffer.count
            let status = buffer.withUnsafeMutableBytes { o in
                chunk.withUnsafeBytes { c in CCCryptorUpdate(cryptor, c.baseAddress, chunk.count, o.baseAddress, cap, &moved) }
            }
            guard status == kCCSuccess else { return false }
            // The throwing write: a full disk becomes a failed file, not a crash.
            do { try output.write(contentsOf: buffer.prefix(moved)) } catch { return false }
        }
        guard let end = try? output.offset() else { return false }
        if let size, size >= 0, UInt64(size) <= end {
            do { try output.truncate(atOffset: UInt64(size)) } catch { return false }
        } else if size == nil, end >= 16 {
            // No recorded size: remove the block padding (PKCS#7) from the end instead.
            do {
                try output.seek(toOffset: end - 1)
                let pad = UInt64((try output.read(upToCount: 1))?.first ?? 0)
                if pad >= 1, pad <= 16 { try output.truncate(atOffset: end - pad) }
            } catch { return false }
        }
        return true
    }

    /// The index inside an NSKeyedArchiver UID (CFKeyedArchiverUID has no public accessor; its description is "{value = N}").
    static func uidIndex(_ o: Any) -> Int? {
        let text = String(describing: o)
        guard text.contains("CFKeyedArchiverUID"), let r = text.range(of: #"value = (\d+)"#, options: .regularExpression) else { return nil }
        return Int(text[r].dropFirst("value = ".count))
    }

    /// Reads the protection class, real size and wrapped key out of one file's record in the backup's index.
    static func fileRecord(_ blob: Data) -> (clas: UInt32, size: Int?, wrappedKey: Data)? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: blob, format: nil)) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        var size: Int?, clas: UInt32?, key: Data?
        func data(_ o: Any) -> Data? { (o as? Data) ?? ((o as? [String: Any])?["NS.data"] as? Data) }
        for o in objects {
            guard let d = o as? [String: Any], let c = d["ProtectionClass"] as? Int else { continue }
            clas = UInt32(c); size = d["Size"] as? Int
            // Follow the file's own EncryptionKey reference (an archiver UID pointing into $objects).
            if let ref = d["EncryptionKey"], let idx = uidIndex(ref), objects.indices.contains(idx), let k = data(objects[idx]) { key = k }
        }
        if key == nil {   // fallback for unusual archives: the one 44-byte key blob
            for o in objects { if let k = data(o), k.count == 44 { key = k; break } }
        }
        guard let key else { return nil }
        return (clas ?? classID(key), size, key.dropFirst(4))
    }
}
