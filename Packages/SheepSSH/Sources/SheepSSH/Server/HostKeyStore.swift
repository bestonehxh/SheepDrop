// Host keys for the server role: load or generate an Ed25519 key (stored in
// the OpenSSH private-key container, unencrypted) and an RSA key (generated
// with Security.framework, stored as PKCS#1 PEM — the formats ssh-keygen and
// libssh both read and write). Generation replaces what libssh's
// ssh_pki_generate did for SheepDrop's server before it dropped libssh.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum HostKeyStoreError: Error, Sendable {
    case generationFailed(String)
    case storageFailed(String)
}

public enum HostKeyStore {
    /// Loads the key in `path` (any format PEMPrivateKey reads), or returns
    /// nil when the file is missing or empty.
    public static func load(path: String) -> SSHPrivateKey? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
              size > 0,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        if OpenSSHPrivateKeyFile.isOpenSSHFormat(text) {
            if let file = try? OpenSSHPrivateKeyFile(text: text), !file.isEncrypted {
                return (try? file.decrypt(passphrase: [])) ?? nil
            }
            return nil
        }
        return try? PEMPrivateKey.load(text, passphrase: nil)
    }

    /// Loads or generates an Ed25519 host key and writes it back as an
    /// OpenSSH-format file.
    public static func ensureEd25519(path: String) throws -> SSHPrivateKey {
        if let key = load(path: path) { restrict(path); return key }
        try? FileManager.default.removeItem(atPath: path)
        let signing = Curve25519.Signing.PrivateKey()
        let seed = Array(signing.rawRepresentation)
        let key = SSHPrivateKey(kind: .ed25519(seed: seed), comment: "SheepDrop host key")
        try writeOpenSSHContainer(key: key, path: path)
        return key
    }

    /// Loads or generates a 2048-bit RSA host key, stored as PKCS#1 PEM.
    public static func ensureRSA(path: String) throws -> SSHPrivateKey {
        // restrict(): installs before 2026-10-02 wrote this file 0644.
        if let key = load(path: path) { restrict(path); return key }
        try? FileManager.default.removeItem(atPath: path)
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        guard let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil) else {
            throw HostKeyStoreError.generationFailed("SecKeyCreateRandomKey failed")
        }
        var error: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            throw HostKeyStoreError.generationFailed("RSA export failed: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        let key = try rsaPrivateKey(fromPKCS1: Array(der))
        try writePEM(der: Array(der), path: path)
        return key
    }

    // MARK: - OpenSSH container writer (ed25519)

    private static func writeOpenSSHContainer(key: SSHPrivateKey, path: String) throws {
        guard case .ed25519(let seed) = key.kind else {
            throw HostKeyStoreError.storageFailed("only ed25519 keys go in the OpenSSH container")
        }
        // Public blob: string "ssh-ed25519" + string public (the seed's
        // public half, 32 bytes, computed from the seed).
        // Derive the public half THROUGH the private key — Signing.PublicKey
        // (rawRepresentation:) would happily treat the seed AS the public key.
        let publicRaw = (try? Curve25519.Signing.PrivateKey(rawRepresentation: seed))
            .map { Array($0.publicKey.rawRepresentation) } ?? []
        guard publicRaw.count == 32 else {
            throw HostKeyStoreError.storageFailed("cannot derive the ed25519 public key")
        }
        var pubBlob = SSHWriter()
        pubBlob.writeString("ssh-ed25519")
        pubBlob.writeString(publicRaw)

        // Private section: checkints, key type, public, private (seed ‖ public).
        var rng = SystemRandomNumberGenerator()
        let check = UInt32.random(in: 0...UInt32.max, using: &rng)
        var section = SSHWriter()
        section.writeUInt32(check)
        section.writeUInt32(check)
        section.writeString("ssh-ed25519")
        section.writeString(publicRaw)
        section.writeString(seed + publicRaw)
        section.writeString("SheepDrop host key")
        // OpenSSH pads the private section to the cipher's block size (8 for
        // "none") with the sequence 1, 2, 3, … .
        var pad: UInt8 = 1
        while section.bytes.count % 8 != 0 {
            section.writeByte(pad)
            pad &+= 1
        }

        var body = SSHWriter()
        body.writeBytes(OpenSSHPrivateKeyFile.magic)
        body.writeString("none")       // cipher
        body.writeString("none")       // kdf
        body.writeString([])           // kdf options
        body.writeUInt32(1)            // one key
        body.writeString(pubBlob.bytes)
        body.writeString(section.bytes)

        let text = OpenSSHPrivateKeyFile.armorBegin + "\n"
            + Data(body.bytes).base64EncodedString().chunks(ofCount: 64).joined(separator: "\n")
            + "\n" + OpenSSHPrivateKeyFile.armorEnd + "\n"
        try writePrivate(text, path: path)
    }

    /// Private keys are created 0600 from the first byte — writing then
    /// chmod-ing left a world-readable window (and the RSA path never chmod-ed
    /// at all: its key sat at 0644, audit 2026-10-02).
    private static func writePrivate(_ text: String, path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        guard FileManager.default.createFile(atPath: path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw HostKeyStoreError.generationFailed("cannot write \(path)")
        }
        restrict(path)
    }

    private static func restrict(_ path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    // MARK: - PKCS#1 PEM writer + DER reader (RSA)

    private static func writePEM(der: [UInt8], path: String) throws {
        let base64 = Data(der).base64EncodedString().chunks(ofCount: 64).joined(separator: "\n")
        let text = "-----BEGIN RSA PRIVATE KEY-----\n" + base64 + "\n-----END RSA PRIVATE KEY-----\n"
        try writePrivate(text, path: path)
    }

    /// Minimal DER parse of a PKCS#1 RSAPrivateKey:
    /// SEQUENCE { INTEGER version, n, e, d, p, q, dp, dq, qinv }.
    private static func rsaPrivateKey(fromPKCS1 der: [UInt8]) throws -> SSHPrivateKey {
        var reader = HostKeyDERReader(der)
        guard reader.readTag() == 0x30,                       // SEQUENCE
              let content = reader.readLengthPrefixed() else {
            throw HostKeyStoreError.generationFailed("malformed PKCS#1 DER")
        }
        var r = HostKeyDERReader(content)
        guard r.readTag() == 0x02, r.readLengthPrefixed() != nil else {   // version
            throw HostKeyStoreError.generationFailed("malformed PKCS#1 DER")
        }
        func integer() throws -> BigUInt {
            guard r.readTag() == 0x02, let bytes = r.readLengthPrefixed() else {
                throw HostKeyStoreError.generationFailed("malformed PKCS#1 DER")
            }
            var trimmed = bytes
            while trimmed.count > 1, trimmed[0] == 0 { trimmed.removeFirst() }  // leading 0x00
            return BigUInt(bigEndian: trimmed)
        }
        let n = try integer()
        let e = try integer()
        let d = try integer()
        let p = try integer()
        let q = try integer()
        _ = try integer()       // dp
        _ = try integer()       // dq
        let qinv = try integer()
        return SSHPrivateKey(kind: .rsa(modulus: n, publicExponent: e, privateExponent: d,
                                        iqmp: qinv, p: p, q: q), comment: "SheepDrop host key")
    }
}

/// The smallest DER reader that walks PKCS#1: tag + length prefixes.
struct HostKeyDERReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func readTag() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// Returns the bytes after a DER length prefix (short or long form).
    mutating func readLengthPrefixed() -> [UInt8]? {
        guard offset < bytes.count else { return nil }
        let first = bytes[offset]
        offset += 1
        let length: Int
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, offset + count <= bytes.count else { return nil }
            length = bytes[offset..<(offset + count)].reduce(0) { $0 << 8 | Int($1) }
            offset += count
        }
        guard length >= 0, offset + length <= bytes.count else { return nil }
        let out = Array(bytes[offset..<(offset + length)])
        offset += length
        return out
    }
}

private extension String {
    func chunks(ofCount count: Int) -> [String] {
        stride(from: 0, to: self.count, by: count).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: Swift.min(count, self.count - offset))
            return String(self[start..<end])
        }
    }
}
