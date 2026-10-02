// Server-role key exchange methods — the mirror of the client KexMethods in
// Transport/KeyExchange.swift: the client's KEXDH_INIT arrives, the server
// computes the shared secret and answers KEXDH_REPLY with its host key and a
// SIGNATURE over H (the client verifies it; the server never verifies).
//
//   H = HASH(V_C ‖ V_S ‖ I_C ‖ I_S ‖ K_S ‖ e ‖ f ‖ K)
//
// Same exchange-hash layout as the client side, with e (client) before
// f (server). SheepDrop's addition for its built-in SFTP/SCP server.
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

enum ServerKexStep {
    case done(outcome: KexOutcome, reply: [UInt8])
}

protocol ServerKexMethod: AnyObject {
    /// Handles the client's KEXDH_INIT and produces the KEXDH_REPLY.
    func handle(_ payload: [UInt8]) throws(KexError) -> ServerKexStep
}

enum ServerKexFactory {
    /// `hostKeyBlob` is the public key blob K_S the REPLY carries and the
    /// exchange hash mixes in.
    static func make(_ algorithm: KexAlgorithm, prefix: ExchangeHashPrefix,
                     hostKeyBlob: [UInt8], signer: SSHSigner,
                     signatureAlgorithm: String) throws -> ServerKexMethod {
        switch algorithm {
        case .curve25519, .curve25519LibSSH:
            return ServerCurve25519Kex(prefix: prefix, hostKeyBlob: hostKeyBlob, signer: signer,
                                       signatureAlgorithm: signatureAlgorithm)
        case .ecdhP256:
            return ServerECDHKex<P256.KeyAgreement.PrivateKey>(prefix: prefix, hostKeyBlob: hostKeyBlob, signer: signer,
                                                               signatureAlgorithm: signatureAlgorithm, hash: .sha256)
        case .ecdhP384:
            return ServerECDHKex<P384.KeyAgreement.PrivateKey>(prefix: prefix, hostKeyBlob: hostKeyBlob, signer: signer,
                                                               signatureAlgorithm: signatureAlgorithm, hash: .sha384)
        case .ecdhP521:
            return ServerECDHKex<P521.KeyAgreement.PrivateKey>(prefix: prefix, hostKeyBlob: hostKeyBlob, signer: signer,
                                                               signatureAlgorithm: signatureAlgorithm, hash: .sha512)
        case .dhGroup1:
            return ServerFixedGroupDH(prefix: prefix, hostKeyBlob: hostKeyBlob, signer: signer,
                                      signatureAlgorithm: signatureAlgorithm,
                                      group: .group1, hash: .sha1, exponentBits: 2048)
        case .dhGroup14SHA1:
            return ServerFixedGroupDH(prefix: prefix, hostKeyBlob: hostKeyBlob, signer: signer,
                                      signatureAlgorithm: signatureAlgorithm,
                                      group: .group14, hash: .sha1, exponentBits: 2048)
        case .dhGroup14SHA256:
            return ServerFixedGroupDH(prefix: prefix, hostKeyBlob: hostKeyBlob, signer: signer,
                                      signatureAlgorithm: signatureAlgorithm,
                                      group: .group14, hash: .sha256, exponentBits: 2048)
        case .dhGroup16:
            return ServerFixedGroupDH(prefix: prefix, hostKeyBlob: hostKeyBlob, signer: signer,
                                      signatureAlgorithm: signatureAlgorithm,
                                      group: .group16, hash: .sha512, exponentBits: 3072)
        case .dhGroup18:
            return ServerFixedGroupDH(prefix: prefix, hostKeyBlob: hostKeyBlob, signer: signer,
                                      signatureAlgorithm: signatureAlgorithm,
                                      group: .group18, hash: .sha512, exponentBits: 3072)
        case .dhGexSHA1, .dhGexSHA256, .mlkem768x25519:
            // Group exchange needs a moduli file the server would have to
            // ship; the post-quantum hybrid needs a client that offers it.
            // Neither is offered by SheepDrop's server (see its KEXINIT).
            throw KexError.groupRejected("algorithm not offered by the server")
        }
    }
}

/// string  signature-blob = string algorithm-name, string signature
private func signatureBlob(algorithm: String, raw: [UInt8]) -> [UInt8] {
    var w = SSHWriter()
    w.writeString(algorithm)
    w.writeString(raw)
    return w.bytes
}

private func buildReply(hostKeyBlob: [UInt8], exchangeHash: [UInt8], signer: SSHSigner,
                        signatureAlgorithm: String,
                        value: (inout SSHWriter) -> Void) throws(KexError) -> [UInt8] {
    // signer.sign returns the COMPLETE SSH signature string (algorithm name
    // prefixed) — exactly what KEXDH_REPLY's signature field carries.
    let blob: [UInt8]
    do {
        blob = try signer.sign(exchangeHash, algorithm: signatureAlgorithm)
    } catch {
        throw KexError.malformed("host key signing failed: \(error)")
    }
    var w = SSHWriter(capacity: 512)
    w.writeByte(SSHMessage.kexDHReply)
    w.writeString(hostKeyBlob)
    value(&w)
    w.writeString(blob)
    return w.bytes
}

// MARK: - X25519 (RFC 8731)

final class ServerCurve25519Kex: ServerKexMethod {
    let prefix: ExchangeHashPrefix
    let hostKeyBlob: [UInt8]
    let signer: SSHSigner
    let signatureAlgorithm: String
    let privateKey = Curve25519.KeyAgreement.PrivateKey()

    init(prefix: ExchangeHashPrefix, hostKeyBlob: [UInt8], signer: SSHSigner, signatureAlgorithm: String) {
        self.prefix = prefix
        self.hostKeyBlob = hostKeyBlob
        self.signer = signer
        self.signatureAlgorithm = signatureAlgorithm
    }

    func handle(_ payload: [UInt8]) throws(KexError) -> ServerKexStep {
        var r = SSHReader(payload)
        do {
            guard try r.readByte() == SSHMessage.kexDHInit else { throw KexError.unexpectedMessage(payload.first ?? 0) }
            let e = try r.readString()
            guard e.count == 32,
                  let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: e),
                  let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else {
                throw KexError.invalidPeerPublicValue
            }
            let secret = shared.withUnsafeBytes { Array($0) }
            guard !isAllZero(secret) else { throw KexError.invalidPeerPublicValue }
            let f = Array(privateKey.publicKey.rawRepresentation)
            var k = SSHWriter()
            k.writeMPInt(unsigned: secret)
            var h = SSHWriter(capacity: 1024)
            prefix.write(into: &h)
            h.writeString(hostKeyBlob)
            h.writeString(e)
            h.writeString(f)
            h.writeBytes(k.bytes)
            let hash = SSHHash.sha256.hash(h.bytes)
            if ProcessInfo.processInfo.environment["SD_KEX_DEBUG"] != nil {
                let hex = hash.map { String(format: "%02x", $0) }.joined()
                let note = "SERVER H: \(hex) prefix=\(prefix.clientVersion) e=\(e.count) f=\(f.count)\n"
                FileHandle.standardError.write(Data(note.utf8))
            }
            let reply = try buildReply(hostKeyBlob: hostKeyBlob, exchangeHash: hash, signer: signer,
                                       signatureAlgorithm: signatureAlgorithm) { $0.writeString(f) }
            return .done(outcome: KexOutcome(encodedSecret: k.bytes, exchangeHash: hash,
                                             hostKeyBlob: hostKeyBlob, signatureBlob: []),
                         reply: reply)
        } catch let error as KexError {
            throw error
        } catch {
            throw .malformed("truncated key exchange init")
        }
    }
}

// MARK: - ECDH over NIST curves (RFC 5656)

final class ServerECDHKex<Key: NISTKeyAgreementKey>: ServerKexMethod {
    let prefix: ExchangeHashPrefix
    let hostKeyBlob: [UInt8]
    let signer: SSHSigner
    let signatureAlgorithm: String
    let hash: SSHHash
    let privateKey = Key.generate()

    init(prefix: ExchangeHashPrefix, hostKeyBlob: [UInt8], signer: SSHSigner,
         signatureAlgorithm: String, hash: SSHHash) {
        self.prefix = prefix
        self.hostKeyBlob = hostKeyBlob
        self.signer = signer
        self.signatureAlgorithm = signatureAlgorithm
        self.hash = hash
    }

    func handle(_ payload: [UInt8]) throws(KexError) -> ServerKexStep {
        var r = SSHReader(payload)
        do {
            guard try r.readByte() == SSHMessage.kexDHInit else { throw KexError.unexpectedMessage(payload.first ?? 0) }
            let e = try r.readString()
            // CryptoKit refuses points that are not on the curve.
            guard let secret = privateKey.sharedX(withX963: e) else { throw KexError.invalidPeerPublicValue }
            let f = privateKey.x963PublicKey
            var k = SSHWriter()
            k.writeMPInt(unsigned: secret)
            var h = SSHWriter(capacity: 1024)
            prefix.write(into: &h)
            h.writeString(hostKeyBlob)
            h.writeString(e)
            h.writeString(f)
            h.writeBytes(k.bytes)
            let exchangeHash = hash.hash(h.bytes)
            let reply = try buildReply(hostKeyBlob: hostKeyBlob, exchangeHash: exchangeHash, signer: signer,
                                       signatureAlgorithm: signatureAlgorithm) { $0.writeString(f) }
            return .done(outcome: KexOutcome(encodedSecret: k.bytes, exchangeHash: exchangeHash,
                                             hostKeyBlob: hostKeyBlob, signatureBlob: []),
                         reply: reply)
        } catch let error as KexError {
            throw error
        } catch {
            throw .malformed("truncated key exchange init")
        }
    }
}

// MARK: - Finite-field DH, fixed groups (RFC 4253 §8, RFC 8268)

final class ServerFixedGroupDH: ServerKexMethod {
    let prefix: ExchangeHashPrefix
    let hostKeyBlob: [UInt8]
    let signer: SSHSigner
    let signatureAlgorithm: String
    let group: DHGroup
    let hash: SSHHash
    let exponentBits: Int
    let y: BigUInt

    init(prefix: ExchangeHashPrefix, hostKeyBlob: [UInt8], signer: SSHSigner,
         signatureAlgorithm: String, group: DHGroup, hash: SSHHash, exponentBits: Int) {
        self.prefix = prefix
        self.hostKeyBlob = hostKeyBlob
        self.signer = signer
        self.signatureAlgorithm = signatureAlgorithm
        self.group = group
        self.hash = hash
        self.exponentBits = min(exponentBits, group.bits - 1)
        self.y = randomExponent(bits: self.exponentBits)
    }

    func handle(_ payload: [UInt8]) throws(KexError) -> ServerKexStep {
        var r = SSHReader(payload)
        do {
            guard try r.readByte() == SSHMessage.kexDHInit else { throw KexError.unexpectedMessage(payload.first ?? 0) }
            let e = BigUInt(bigEndian: try r.readMPIntBytes())
            // sharedSecret enforces 1 < e < p−1 for the client's value, the
            // same check the client applies to our f.
            guard let secret = group.sharedSecret(peerPublic: e, privateExponent: y, exponentBits: exponentBits) else {
                throw KexError.invalidPeerPublicValue
            }
            let f = group.publicValue(privateExponent: y, exponentBits: exponentBits)
            var k = SSHWriter()
            k.writeMPInt(secret)
            var h = SSHWriter(capacity: 2048)
            prefix.write(into: &h)
            h.writeString(hostKeyBlob)
            h.writeMPInt(e)
            h.writeMPInt(f)
            h.writeBytes(k.bytes)
            let exchangeHash = hash.hash(h.bytes)
            let reply = try buildReply(hostKeyBlob: hostKeyBlob, exchangeHash: exchangeHash, signer: signer,
                                       signatureAlgorithm: signatureAlgorithm) { $0.writeMPInt(f) }
            return .done(outcome: KexOutcome(encodedSecret: k.bytes, exchangeHash: exchangeHash,
                                             hostKeyBlob: hostKeyBlob, signatureBlob: []),
                         reply: reply)
        } catch let error as KexError {
            throw error
        } catch {
            throw .malformed("truncated key exchange init")
        }
    }
}

private func isAllZero(_ bytes: [UInt8]) -> Bool {
    bytes.allSatisfy { $0 == 0 }
}
