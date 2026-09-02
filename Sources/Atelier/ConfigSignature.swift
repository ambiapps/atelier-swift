import CryptoKit
import Foundation

/// Verification of the signed config object (ADR 0017).
///
/// `{config_url}/{organization}/{product}.jws` is an ES256 JWS compact
/// token whose payload *is* the config document. Verifying it closes the
/// cheap attack on a public config: a user pointing their own device at
/// a TLS-intercepting proxy and rewriting flag values in flight.
///
/// It closes nothing else, and the rest of the SDK is built on that
/// understanding — a patched binary can still do as it likes, and a
/// device that refuses to fetch keeps whatever it cached. Flags gate
/// product behavior, never authorization.
enum ConfigSignature {

    /// The build's trust anchors, as CryptoKit keys.
    ///
    /// They come from `AtelierConfiguration.signingKeys` — from the
    /// host app's own source — and never from the network. Fetching a
    /// JWKS to decide what to trust would be pointless: an attacker
    /// positioned to rewrite the config through a proxy can rewrite a
    /// JWKS served from the same origin just as easily, and the SDK
    /// would dutifully check an attacker's document against an
    /// attacker's key. The published JWKS is for tooling.
    ///
    /// An entry that will not parse is dropped rather than fatal: one
    /// mistyped constant must not take the usable keys down with it,
    /// and during a rotation the other key is very likely the good one.
    static func anchors(from keys: [AtelierSigningKey]) -> [String: P256.Signing.PublicKey] {
        var result: [String: P256.Signing.PublicKey] = [:]
        for entry in keys {
            // x and y concatenated are exactly CryptoKit's raw
            // representation for P-256.
            guard let x = base64urlDecode(entry.x),
                let y = base64urlDecode(entry.y),
                let key = try? P256.Signing.PublicKey(rawRepresentation: x + y)
            else { continue }
            result[entry.kid] = key
        }
        return result
    }

    /// The whole ADR 0017 accept decision in one place: verify, check
    /// the org/product binding, and refuse a replayed revision.
    ///
    /// Every rejection is `.unavailable` — for a verifying build that
    /// means last-good, never a blocked launch and never a visible
    /// error. `spec/test-vectors.json` → `signature` exercises this
    /// function directly.
    static func verifiedDocument(
        _ token: Data,
        anchors: [String: P256.Signing.PublicKey],
        organization: String,
        product: String,
        cachedRevision: Int?
    ) -> ConfigDocument.Fetched {
        guard
            let payload = verifiedPayload(token, anchors: anchors, organization: organization)
        else { return .unavailable }

        let fetched = ConfigDocument.decode(payload, expecting: product)

        // Replay: the token is authentic, the document is simply old. A
        // signature cannot express freshness, so only the revision
        // catches this — and a signed document carrying no revision at
        // all cannot be placed against the floor, so it is refused too.
        if case .document(let document) = fetched, let floor = cachedRevision {
            guard let revision = document.revision, revision >= floor else {
                return .unavailable
            }
        }
        return fetched
    }

    /// The payload of `token` if it verifies, otherwise nil.
    ///
    /// `organization` is checked against the *protected header*: the
    /// document deliberately does not repeat the org (delivery is scoped
    /// by path), so without this one organization's genuinely-signed
    /// config verifies at another's path. The product is checked
    /// separately, when the payload is decoded.
    static func verifiedPayload(
        _ token: Data,
        anchors: [String: P256.Signing.PublicKey],
        organization: String
    ) -> Data? {
        // No anchors means this build does not verify; callers must not
        // reach here, and returning nil rather than the payload is the
        // safe reading of the mistake if they do.
        guard !anchors.isEmpty else { return nil }

        let parts = token.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let (rawHeader, rawPayload, rawSignature) = (parts[0], parts[1], parts[2])

        guard let headerData = base64urlDecode(rawHeader),
            let header = try? JSONDecoder().decode(Header.self, from: headerData)
        else { return nil }

        // Pin the algorithm rather than dispatching on what the token
        // asks for. This one comparison is the whole defense against
        // `alg: "none"` and against HS256 algorithm-confusion, where a
        // token is MAC'd with the public key everybody has.
        guard header.alg == "ES256" else { return nil }
        guard header.org == organization else { return nil }
        guard let key = anchors[header.kid] else { return nil }

        guard let signatureBytes = base64urlDecode(rawSignature),
            let signature = try? P256.Signing.ECDSASignature(
                rawRepresentation: signatureBytes)
        else { return nil }

        // Signed over the exact ASCII of "<header>.<payload>" as it
        // arrived — never over anything re-serialized, which is why no
        // JSON canonicalization question arises here.
        let signingInput = Data(rawHeader) + Data(".".utf8) + Data(rawPayload)
        guard key.isValidSignature(signature, for: signingInput) else { return nil }

        return base64urlDecode(rawPayload)
    }

    private struct Header: Decodable {
        let alg: String
        let kid: String
        let org: String
    }

    static func base64urlDecode<S: Sequence>(_ input: S) -> Data? where S.Element == UInt8 {
        var s = String(decoding: Array(input), as: UTF8.self)
        s = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - s.count % 4) % 4
        s += String(repeating: "=", count: padding)
        return Data(base64Encoded: s)
    }

    static func base64urlDecode(_ input: String) -> Data? {
        base64urlDecode(Array(input.utf8))
    }
}
