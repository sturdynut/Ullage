import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(CryptoKit)
import CryptoKit

/// Web Push: RFC 8291 for the payload, RFC 8292 for the identity.
///
/// Written against CryptoKit rather than a dependency, and therefore macOS
/// only — hence the `canImport` wall. Core still builds on Linux; a Linux box
/// serves the gauge and cannot push, which is the right trade for a machine
/// with no menu bar either.
///
/// The payload is encrypted to the device's own key, so the push service (for
/// an iPhone, Apple's) relays ciphertext it cannot read. That is the reason
/// this is a defensible thing to send a project name through.
public enum WebPush {

    public enum Failure: Error, CustomStringConvertible {
        case badKey(String)
        case badEndpoint(String)

        public var description: String {
            switch self {
            case let .badKey(detail): return "bad key: \(detail)"
            case let .badEndpoint(detail): return "bad endpoint: \(detail)"
            }
        }
    }

    /// One keypair per database, generated on first use. Rotating it
    /// invalidates every subscription, so nothing rotates it automatically.
    public static func generateKeyPair(now: Date = Date()) -> VAPIDKeyPair {
        let key = P256.Signing.PrivateKey()
        return VAPIDKeyPair(
            privateKey: Base64URL.encode(key.rawRepresentation),
            publicKey: Base64URL.encode(key.publicKey.x963Representation),
            createdAt: Timestamps.string(from: now)
        )
    }

    // MARK: - RFC 8291 payload encryption

    /// `salt` and `ephemeral` are injectable only so a test can pin them
    /// against a known-good implementation; nothing else should pass them.
    static func encrypt(
        payload: Data,
        p256dh: Data,
        auth: Data,
        salt: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
        ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()
    ) throws -> Data {
        guard let userAgentKey = try? P256.KeyAgreement.PublicKey(x963Representation: p256dh) else {
            throw Failure.badKey("p256dh is not an uncompressed P-256 point")
        }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: userAgentKey)
        let serverPublic = ephemeral.publicKey.x963Representation

        // The "WebPush: info" context binds the derived key to *both* public
        // keys, which is what stops a relayed ciphertext being replayed at a
        // different subscriber.
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0x00)
        keyInfo.append(p256dh)
        keyInfo.append(serverPublic)

        // `CryptoKit.` throughout: UllageCore ships its own SHA256 for file
        // hashing, and an unqualified SHA256 here resolves to that one.
        let ikm = shared.hkdfDerivedSymmetricKey(
            using: CryptoKit.SHA256.self, salt: auth, sharedInfo: keyInfo, outputByteCount: 32
        )

        var contentInfo = Data("Content-Encoding: aes128gcm".utf8); contentInfo.append(0x00)
        var nonceInfo = Data("Content-Encoding: nonce".utf8); nonceInfo.append(0x00)
        let contentKey = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: contentInfo, outputByteCount: 16
        )
        let nonceBytes = HKDF<CryptoKit.SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt, info: nonceInfo, outputByteCount: 12
        ).withUnsafeBytes { Data($0) }

        // One record, so the delimiter is 0x02 rather than 0x01. Getting this
        // byte wrong produces a notification that arrives and silently fails to
        // decrypt on the phone, which is a miserable thing to debug.
        var plaintext = payload
        plaintext.append(0x02)
        let sealed = try AES.GCM.seal(
            plaintext, using: contentKey, nonce: try AES.GCM.Nonce(data: nonceBytes)
        )

        var body = salt
        body.append(contentsOf: withUnsafeBytes(of: UInt32(4096).bigEndian) { Data($0) })
        body.append(UInt8(serverPublic.count))
        body.append(serverPublic)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)
        return body
    }

    // MARK: - RFC 8292 identity

    /// `vapid t=<jwt>, k=<public key>`. The audience is the *origin* of the push
    /// service, never the full endpoint: a JWT scoped to the path is rejected.
    static func authorization(
        endpoint: URL,
        key: VAPIDKeyPair,
        subject: String,
        now: Date = Date(),
        lifetime: TimeInterval = 12 * 3600
    ) throws -> String {
        guard let scheme = endpoint.scheme, let host = endpoint.host else {
            throw Failure.badEndpoint(endpoint.absoluteString)
        }
        var audience = scheme + "://" + host
        if let port = endpoint.port, !(port == 443 && scheme == "https"), !(port == 80 && scheme == "http") {
            audience += ":\(port)"
        }
        guard let secret = Base64URL.decode(key.privateKey),
              let signing = try? P256.Signing.PrivateKey(rawRepresentation: secret) else {
            throw Failure.badKey("stored VAPID private key is not a P-256 scalar")
        }

        // Written by hand rather than through JSONEncoder: a JWT is signed over
        // exact bytes, so the serialisation has to be deterministic.
        let header = #"{"typ":"JWT","alg":"ES256"}"#
        let expiry = Int(now.addingTimeInterval(lifetime).timeIntervalSince1970)
        let claims = #"{"aud":"\#(audience)","exp":\#(expiry),"sub":"\#(subject)"}"#
        let signingInput = Base64URL.encode(Data(header.utf8)) + "." + Base64URL.encode(Data(claims.utf8))
        let signature = try signing.signature(for: Data(signingInput.utf8))
        // ES256 wants the raw r||s pair, not the DER encoding CryptoKit also offers.
        let token = signingInput + "." + Base64URL.encode(signature.rawRepresentation)
        return "vapid t=\(token), k=\(key.publicKey)"
    }

    // MARK: - The request

    public static func request(
        subscription: PushSubscription,
        payload: Data,
        key: VAPIDKeyPair,
        subject: String,
        ttl: Int = 86_400,
        now: Date = Date()
    ) throws -> URLRequest {
        guard let url = URL(string: subscription.endpoint) else {
            throw Failure.badEndpoint(subscription.endpoint)
        }
        guard let p256dh = Base64URL.decode(subscription.p256dh),
              let auth = Base64URL.decode(subscription.auth) else {
            throw Failure.badKey("subscription keys are not base64url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encrypt(payload: payload, p256dh: p256dh, auth: auth)
        request.setValue(try authorization(endpoint: url, key: key, subject: subject, now: now), forHTTPHeaderField: "Authorization")
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(ttl), forHTTPHeaderField: "TTL")
        request.setValue("normal", forHTTPHeaderField: "Urgency")
        return request
    }
}
#endif
