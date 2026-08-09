import Foundation
import XCTest

@testable import Atelier

/// Config delivery (ADR 0012): the CDN object is the normal read, the
/// PostgREST query is the fallback, and the fail-safe ladder underneath
/// both is unchanged. No network — the transport is stubbed.
final class DeliveryTests: XCTestCase {

    // MARK: - Helpers

    /// Routes three legs separately — directory document, CDN config
    /// object, PostgREST rows — so a test can fail exactly one of them
    /// and see which path the client took.
    private final class StubTransport: FlagsTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _objectResult: Result<(Data, Int), Error>
        private var _rowsResult: Result<Data, Error>
        private var _objectRequests: [URLRequest] = []
        private var _rowsRequests: [URLRequest] = []

        static let configURL = "https://cdn.example.test/storage/v1/object/public/config"

        /// The advertised-CDN directory document.
        static let directoryJSON = """
            {"schema_version": 1, "base_url": "https://flags.example.test", \
            "api_key": "test-api-key", "config_url": "\(configURL)"}
            """

        /// A backend that advertises no CDN path (pre-ADR-0012, or one
        /// where delivery is not lit up yet).
        static let directoryWithoutConfigURLJSON = """
            {"schema_version": 1, "base_url": "https://flags.example.test", \
            "api_key": "test-api-key"}
            """

        static let objectJSON = """
            {"schema_version": 1, "app": "ambre", "revision": 7, "flags": [
              {"key": "from_cdn", "enabled": true, "rules": [], "default_rollout_percent": 100}
            ]}
            """

        static let rowsJSON = """
            [{"key": "from_postgrest", "enabled": true, "rules": [], \
            "default_rollout_percent": 100}]
            """

        private var _directoryJSON: String

        init(directoryJSON: String = StubTransport.directoryJSON) {
            _directoryJSON = directoryJSON
            _objectResult = .success((Data(StubTransport.objectJSON.utf8), 200))
            _rowsResult = .success(Data(StubTransport.rowsJSON.utf8))
        }

        var objectRequests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _objectRequests
        }
        var rowsRequestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _rowsRequests.count
        }

        func setObject(json: String, status: Int = 200) {
            lock.lock()
            defer { lock.unlock() }
            _objectResult = .success((Data(json.utf8), status))
        }
        func setObject(status: Int) {
            lock.lock()
            defer { lock.unlock() }
            _objectResult = .success((Data("".utf8), status))
        }
        func setObject(error: Error) {
            lock.lock()
            defer { lock.unlock() }
            _objectResult = .failure(error)
        }
        func setRows(error: Error) {
            lock.lock()
            defer { lock.unlock() }
            _rowsResult = .failure(error)
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.lock()
            let url = request.url!
            let payload: Data
            var status = 200
            if url == AtelierDirectory.url {
                payload = Data(_directoryJSON.utf8)
            } else if url.absoluteString.hasPrefix(StubTransport.configURL) {
                _objectRequests.append(request)
                lock.unlock()
                let (data, code) = try _objectResult.get()
                return (
                    data,
                    HTTPURLResponse(
                        url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
                )
            } else {
                _rowsRequests.append(request)
                lock.unlock()
                let data = try _rowsResult.get()
                return (
                    data,
                    HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            lock.unlock()
            return (
                payload,
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        }
    }

    private struct StubError: Error {}

    private func makeCache() -> DiskCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-tests-\(UUID().uuidString)")
        return DiskCache(fileURL: directory.appendingPathComponent("cache.json"))
    }

    private func makeClient(transport: StubTransport, cache: DiskCache) -> AtelierClient {
        AtelierClient(
            configuration: AtelierConfiguration(organization: "ambi", product: "ambre"),
            transport: transport,
            cacheOverride: cache,
            now: { Date() },
            defaults: UserDefaults(suiteName: "delivery-tests-\(UUID().uuidString)")!)
    }

    // MARK: - The normal path

    func testReadsTheCDNObjectAndNotPostgREST() async {
        let transport = StubTransport()
        let client = makeClient(transport: transport, cache: makeCache())

        await client.refresh()

        XCTAssertTrue(client.isEnabled("from_cdn", default: false))
        XCTAssertEqual(transport.rowsRequestCount, 0, "the fallback must not be used")
        XCTAssertEqual(
            transport.objectRequests.first?.url?.absoluteString,
            "\(StubTransport.configURL)/ambi/ambre.json",
            "the object path is {config_url}/{organization}/{product}.json")
    }

    /// It is a public object: sending the API key would be pointless and
    /// would leak a credential onto a CDN request.
    func testCDNRequestCarriesNoCredentials() async {
        let transport = StubTransport()
        let client = makeClient(transport: transport, cache: makeCache())

        await client.refresh()

        let request = transport.objectRequests.first
        XCTAssertNil(request?.value(forHTTPHeaderField: "apikey"))
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request?.url?.query, "no query string on a static object")
    }

    /// The document is served verbatim; the SDK parses it rather than
    /// assembling one, so the revision it carries survives to the cache.
    func testPublishedDocumentIsStoredAsServed() async {
        let cache = makeCache()
        let client = makeClient(transport: StubTransport(), cache: cache)

        await client.refresh()

        XCTAssertEqual(cache.load()?.revision, 7)
        XCTAssertEqual(cache.load()?.app, "ambre")
    }

    // MARK: - Falling back

    func testFallsBackToPostgRESTWhenNoConfigURLIsAdvertised() async {
        let transport = StubTransport(
            directoryJSON: StubTransport.directoryWithoutConfigURLJSON)
        let client = makeClient(transport: transport, cache: makeCache())

        await client.refresh()

        XCTAssertTrue(client.isEnabled("from_postgrest", default: false))
        XCTAssertEqual(transport.objectRequests.count, 0)
        XCTAssertEqual(transport.rowsRequestCount, 1)
    }

    func testFallsBackWhenTheObjectIsMissing() async {
        let transport = StubTransport()
        transport.setObject(status: 404)
        let client = makeClient(transport: transport, cache: makeCache())

        await client.refresh()

        XCTAssertTrue(
            client.isEnabled("from_postgrest", default: false),
            "a publishing failure costs a round-trip, not a refresh")
        XCTAssertEqual(transport.rowsRequestCount, 1)
    }

    func testFallsBackWhenTheObjectIsUnparsable() async {
        let transport = StubTransport()
        transport.setObject(json: "{ this is not json")
        let client = makeClient(transport: transport, cache: makeCache())

        await client.refresh()

        XCTAssertTrue(client.isEnabled("from_postgrest", default: false))
    }

    func testFallsBackWhenTheObjectIsUnreachable() async {
        let transport = StubTransport()
        transport.setObject(error: StubError())
        let client = makeClient(transport: transport, cache: makeCache())

        await client.refresh()

        XCTAssertTrue(client.isEnabled("from_postgrest", default: false))
    }

    /// Fetching an object that names a different product means we read
    /// the wrong thing — not that this product has no flags.
    func testFallsBackWhenTheObjectNamesAnotherProduct() async {
        let transport = StubTransport()
        transport.setObject(
            json: """
                {"schema_version": 1, "app": "lysten", "flags": [
                  {"key": "wrong_product", "enabled": true, "rules": [], \
                "default_rollout_percent": 100}
                ]}
                """)
        let client = makeClient(transport: transport, cache: makeCache())

        await client.refresh()

        XCTAssertFalse(client.isEnabled("wrong_product", default: false))
        XCTAssertTrue(client.isEnabled("from_postgrest", default: false))
    }

    // MARK: - The one case that must NOT fall back

    /// A document from the future is ignored whole and the cache is kept
    /// (data-model.md). Rebuilding one from raw rows would route around
    /// the very gate that protects shipped builds, so the refresh stops
    /// instead.
    func testNewerSchemaVersionIsIgnoredWithoutFallingBack() async {
        let cache = makeCache()
        cache.store(
            ConfigDocument(
                schemaVersion: 1, app: "ambre",
                flags: [
                    .object([
                        "key": .string("cached_flag"), "enabled": .bool(true),
                        "rules": .array([]), "default_rollout_percent": .int(100),
                    ])
                ]))
        let transport = StubTransport()
        transport.setObject(
            json: """
                {"schema_version": 99, "app": "ambre", "flags": []}
                """)
        let client = makeClient(transport: transport, cache: cache)

        await client.refresh()

        XCTAssertTrue(
            client.isEnabled("cached_flag", default: false),
            "the cached last-supported config keeps serving")
        XCTAssertEqual(
            transport.rowsRequestCount, 0,
            "an unsupported document must not be routed around via PostgREST")
        XCTAssertFalse(client.isEnabled("from_postgrest", default: false))
    }

    // MARK: - Both paths down

    func testLastGoodSurvivesBothPathsFailing() async {
        let cache = makeCache()
        cache.store(
            ConfigDocument(
                schemaVersion: 1, app: "ambre",
                flags: [
                    .object([
                        "key": .string("cached_flag"), "enabled": .bool(true),
                        "rules": .array([]), "default_rollout_percent": .int(100),
                    ])
                ]))
        let transport = StubTransport()
        transport.setObject(error: StubError())
        transport.setRows(error: StubError())
        let client = makeClient(transport: transport, cache: cache)

        await client.refresh()

        XCTAssertTrue(client.isEnabled("cached_flag", default: false))
        XCTAssertEqual(transport.rowsRequestCount, 1, "the fallback was tried before giving up")
    }

    // MARK: - Poke

    /// The object is served with a short max-age; honoring a locally
    /// cached response on the one refresh that exists for freshness
    /// would defeat the poke.
    func testPokeRevalidatesTheObject() async {
        let transport = StubTransport()
        let client = makeClient(transport: transport, cache: makeCache())

        await client.refresh()
        XCTAssertEqual(
            transport.objectRequests.first?.cachePolicy, .useProtocolCachePolicy,
            "an ordinary refresh uses the normal cache policy")

        _ = await client.handlePushNotification(["atelier": ["poke": 1]])

        XCTAssertEqual(transport.objectRequests.count, 2, "a poke bypasses the debounce")
        XCTAssertEqual(
            transport.objectRequests.last?.cachePolicy, .reloadIgnoringLocalCacheData)
    }
}
