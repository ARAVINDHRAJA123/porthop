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
        guard let salt = header["SALT"], let iter = header["ITER"], let dpsl = header["DPSL"], let dpic = header["DPIC"],
              let first = pbkdf2(Data(password.utf8), salt: dpsl, rounds: uint(dpic), sha1: false),
              let passKey = pbkdf2(first, salt: salt, rounds: uint(iter), sha1: true) else { return .unreadable }
        var keys: [UInt32: Data] = [:]
        var wrappedCount = 0
        for c in classes {
            guard let clas = c["CLAS"], let wpky = c["WPKY"] else { continue }
            wrappedCount += 1
            guard let key = unwrap(wpky, with: passKey) else { return .wrongPassword }
            keys[UInt32(uint(clas))] = key
        }
        return wrappedCount == 0 ? .unreadable : .keys(keys)
    }

    /// Decrypts one stored file (AES-CBC, empty starting block) and trims it to its real length.
    static func decrypt(_ source: URL, to dest: URL, key: Data, size: Int?) -> Bool {
        guard let input = try? FileHandle(forReadingFrom: source), FileManager.default.createFile(atPath: dest.path, contents: nil),
              let output = try? FileHandle(forWritingTo: dest) else { return false }
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
            output.write(buffer.prefix(moved))
        }
        if let size, size >= 0, UInt64(size) <= output.offsetInFile { output.truncateFile(atOffset: UInt64(size)) }
        return true
    }

    /// Reads the protection class, real size and wrapped key out of one file's record in the backup's index.
    static func fileRecord(_ blob: Data) -> (clas: UInt32, size: Int?, wrappedKey: Data)? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: blob, format: nil)) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        var size: Int?, clas: UInt32?, key: Data?
        for o in objects {
            if let d = o as? [String: Any] {
                if let c = d["ProtectionClass"] as? Int { clas = UInt32(c); size = d["Size"] as? Int }
                if let data = d["NS.data"] as? Data, data.count == 44 { key = data }
            } else if let data = o as? Data, data.count == 44 { key = data }
        }
        guard let key else { return nil }
        return (clas ?? classID(key), size, key.dropFirst(4))
    }
}
