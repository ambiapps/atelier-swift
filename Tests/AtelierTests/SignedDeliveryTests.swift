import CryptoKit
import Foundation
import XCTest

@testable import Atelier

/// Signed config delivery (ADR 0017). What matters here is not that a
/// good signature is accepted — the conformance vectors cover the
/// algorithm — but that the *client* reads the signed object, refuses
/// everything it should, and refuses it by falling back to last-good
/// rather than by failing loudly or by quietly taking an unsigned path.
final class SignedDeliveryTests: XCTestCase {

    // MARK: - Helpers

    /// Routes four legs separately — directory, signed object, plain
    /// object, PostgREST rows — so a test can see exactly which one the
    /// client reached for.
    private final class StubTransport: FlagsTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _signed: Result<(Data, Int), Error>
        private var _plain: Result<(Data, Int), Error>
        private var _signedCount = 0
        private var _plainCount = 0
        private var _rowsCount = 0

        static let configURL = "https://cdn.example.test/storage/v1/object/public/config"
        static let directoryJSON = """
            {"schema_version": 1, "base_url": "https://flags.example.test", \
            "api_key": "test-api-key", "config_url": "\(configURL)"}
            """
        static let plainJSON = """
            {"schema_version": 2, "app": "ambre", "revision": 7, "flags": [
              {"key": "from_plain", "enabled": true, "rules": [{"conditions": [], "value": true}]}
            ]}
            """
        static let rowsJSON = """
            [{"key": "from_postgrest", "enabled": true, \
            "rules": [{"conditions": [], "value": true}]}]
            """

        init(signed: Data) {
            _signed = .success((signed, 200))
            _plain = .success((Data(StubTransport.plainJSON.utf8), 200))
        }

        var signedCount: Int { lock.withLock { _signedCount } }
        var plainCount: Int { lock.withLock { _plainCount } }
        var rowsCount: Int { lock.withLock { _rowsCount } }

        func setSigned(_ data: Data, status: Int = 200) {
            lock.withLock { _signed = .success((data, status)) }
        }
        func setSigned(status: Int) {
            lock.withLock { _signed = .success((Data(), status)) }
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url!
            func response(_ code: Int) -> URLResponse {
                HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            }
            if url == AtelierDirectory.url {
                return (Data(StubTransport.directoryJSON.utf8), response(200))
            }
            if url.absoluteString.hasSuffix(".jws") {
                let result = lock.withLock { () -> Result<(Data, Int), Error> in
                    _signedCount += 1
                    return _signed
                }
                let (data, code) = try result.get()
                return (data, response(code))
            }
            if url.absoluteString.hasPrefix(StubTransport.configURL) {
                let result = lock.withLock { () -> Result<(Data, Int), Error> in
                    _plainCount += 1
                    return _plain
                }
                let (data, code) = try result.get()
                return (data, response(code))
            }
            lock.withLock { _rowsCount += 1 }
            return (Data(StubTransport.rowsJSON.utf8), response(200))
        }
    }

    private static let signingKey = P256.Signing.PrivateKey()

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A JWS compact token over `payload`, exactly as the publisher
    /// renders it.
    private static func sign(
        payload: String, kid: String = "test-key", org: String = "ambi",
        key: P256.Signing.PrivateKey = SignedDeliveryTests.signingKey
    ) -> Data {
        let header = #"{"alg":"ES256","kid":"\#(kid)","org":"\#(org)"}"#
        let input = "\(base64url(Data(header.utf8))).\(base64url(Data(payload.utf8)))"
        let signature = try! key.signature(for: Data(input.utf8))
        return Data("\(input).\(base64url(signature.rawRepresentation))".utf8)
    }

    private static func document(revision: Int, flagKey: String = "from_signed") -> String {
        """
        {"schema_version": 2, "app": "ambre", "revision": \(revision), "flags": [
          {"key": "\(flagKey)", "enabled": true, "rules": [{"conditions": [], "value": true}]}
        ]}
        """
    }

    /// The test key in the form a host app supplies it: the JWK halves
    /// published in the project's JWKS.
    private static var publishedKey: AtelierSigningKey {
        let raw = signingKey.publicKey.rawRepresentation
        return AtelierSigningKey(
            kid: "test-key",
            x: base64url(raw.prefix(32)),
            y: base64url(raw.suffix(32)))
    }

    private var anchors: [AtelierSigningKey] { [Self.publishedKey] }

    /// Last-good already on disk, as after any previous successful
    /// refresh.
    private func seededCache(revision: Int, flagKey: String = "from_signed") -> DiskCache {
        let cache = makeCache()
        cache.store(
            ConfigDocument(
                schemaVersion: ConfigDocument.supportedSchemaVersion,
                app: "ambre",
                flags: [
                    .object([
                        "key": .string(flagKey), "enabled": .bool(true),
                        "rules": .array([
                            .object(["conditions": .array([]), "value": .bool(true)])
                        ]),
                    ])
                ],
                revision: revision))
        return cache
    }

    private func makeCache() -> DiskCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-tests-\(UUID().uuidString)")
        return DiskCache(fileURL: directory.appendingPathComponent("cache.json"))
    }

    private func makeClient(
        transport: StubTransport, cache: DiskCache, anchors: [AtelierSigningKey]
    ) -> AtelierClient {
        AtelierClient(
            configuration: AtelierConfiguration(
                organization: "ambi", product: "ambre", signingKeys: anchors),
            transport: transport,
            cacheOverride: cache,
            now: { Date() },
            defaults: UserDefaults(suiteName: "signed-tests-\(UUID().uuidString)")!)
    }

    // MARK: - The normal path

    func testVerifyingBuildReadsTheSignedObject() async {
        let transport = StubTransport(signed: Self.sign(payload: Self.document(revision: 7)))
        let client = makeClient(transport: transport, cache: makeCache(), anchors: anchors)

        await client.refresh()

        XCTAssertTrue(client.isEnabled("from_signed", default: false))
        XCTAssertEqual(transport.signedCount, 1)
        XCTAssertEqual(transport.plainCount, 0, "the unsigned object must not be read")
        XCTAssertEqual(transport.rowsCount, 0)
    }

    func testBuildWithoutAnchorsReadsThePlainObject() async {
        let transport = StubTransport(signed: Self.sign(payload: Self.document(revision: 7)))
        let client = makeClient(transport: transport, cache: makeCache(), anchors: [])

        await client.refresh()

        XCTAssertTrue(client.isEnabled("from_plain", default: false))
        XCTAssertEqual(transport.signedCount, 0, "a build with no keys must not read .jws")
    }

    // MARK: - Refusals

    /// The attack this whole ADR is about: a proxy rewriting values in
    /// flight. The signature no longer covers the bytes, so the document
    /// is refused and the app keeps what it had.
    func testTamperedPayloadIsRefusedAndLastGoodKept() async {
        // A genuine token, with the payload swapped underneath its
        // signature — literally what a proxy rewriting values produces.
        let token = String(decoding: Self.sign(payload: Self.document(revision: 8)), as: UTF8.self)
        let parts = token.split(separator: ".")
        let forged = Self.document(revision: 8, flagKey: "attacker_added")
        let transport = StubTransport(
            signed: Data("\(parts[0]).\(Self.base64url(Data(forged.utf8))).\(parts[2])".utf8))

        let client = makeClient(
            transport: transport, cache: seededCache(revision: 7), anchors: anchors)
        await client.refresh()

        XCTAssertFalse(client.isEnabled("attacker_added", default: false))
        XCTAssertTrue(client.isEnabled("from_signed", default: false), "last-good is kept")
    }

    /// Signed by a key we do not trust — the shape of an attacker who
    /// generated their own keypair and rewrote the JWKS too.
    func testDocumentSignedByAnotherKeyIsRefused() async {
        let other = P256.Signing.PrivateKey()
        let transport = StubTransport(
            signed: Self.sign(payload: Self.document(revision: 7), key: other))
        let client = makeClient(transport: transport, cache: makeCache(), anchors: anchors)

        await client.refresh()

        XCTAssertFalse(client.isEnabled("from_signed", default: false))
    }

    /// A genuinely-signed *older* document. The signature is perfect;
    /// only the revision floor catches it.
    func testReplayedOlderRevisionIsRefused() async {
        let transport = StubTransport(
            signed: Self.sign(payload: Self.document(revision: 4, flagKey: "rolled_back")))
        let client = makeClient(
            transport: transport, cache: seededCache(revision: 9), anchors: anchors)

        await client.refresh()

        XCTAssertFalse(client.isEnabled("rolled_back", default: false))
        XCTAssertTrue(client.isEnabled("from_signed", default: false), "last-good is kept")
    }

    /// The load-bearing one. If a verifying build fell back to PostgREST
    /// then breaking a single fetch would re-open exactly the hole the
    /// signature closes — the fallback carries no signature at all.
    func testVerifyingBuildNeverFallsBackToPostgREST() async {
        let transport = StubTransport(signed: Data())
        transport.setSigned(status: 404)
        let client = makeClient(transport: transport, cache: makeCache(), anchors: anchors)

        await client.refresh()

        XCTAssertEqual(transport.rowsCount, 0, "there is no unsigned rung under a signed read")
        XCTAssertEqual(transport.plainCount, 0)
        XCTAssertFalse(client.isEnabled("from_postgrest", default: false))
    }
}
