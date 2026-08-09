import Foundation
import XCTest

#if canImport(Observation)
    import Observation
#endif

@testable import Atelier

/// Unit tests per docs/sdk-swift.md: cache behavior, refresh debouncing,
/// context switching, schema_version gating, endpoint discovery
/// (ADR 0008). No network — the transport is stubbed.
final class ClientTests: XCTestCase {

    // MARK: - Helpers

    /// Routes by URL: the directory-document fetch and the flags fetch
    /// are separate legs so tests can fail one independently.
    private final class StubTransport: FlagsTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _directoryResult: Result<Data, Error>
        private var _flagsResult: Result<Data, Error>
        private var _flagsRequests: [URLRequest] = []

        static let directoryJSON = """
            {"schema_version": 1, "base_url": "https://flags.example.test", "api_key": "test-api-key"}
            """

        init(flagsJSON: String, directoryJSON: String = StubTransport.directoryJSON) {
            _flagsResult = .success(Data(flagsJSON.utf8))
            _directoryResult = .success(Data(directoryJSON.utf8))
        }

        init(error: Error) {
            _flagsResult = .failure(error)
            _directoryResult = .failure(error)
        }

        var flagsCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _flagsRequests.count
        }

        var lastFlagsRequest: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return _flagsRequests.last
        }

        func set(flagsJSON: String) {
            lock.lock()
            defer { lock.unlock() }
            _flagsResult = .success(Data(flagsJSON.utf8))
        }

        func set(directoryJSON: String) {
            lock.lock()
            defer { lock.unlock() }
            _directoryResult = .success(Data(directoryJSON.utf8))
        }

        func setDirectory(error: Error) {
            lock.lock()
            defer { lock.unlock() }
            _directoryResult = .failure(error)
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.lock()
            let result: Result<Data, Error>
            if request.url == AtelierDirectory.url {
                result = _directoryResult
            } else {
                _flagsRequests.append(request)
                result = _flagsResult
            }
            lock.unlock()
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (try result.get(), response)
        }
    }

    private struct StubError: Error {}

    private final class ValuesBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Value] = []
        var values: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return _values
        }
        func append(_ value: Value) {
            lock.lock()
            defer { lock.unlock() }
            _values.append(value)
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date(timeIntervalSince1970: 1_000_000)
        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return _now
        }
        func advance(by interval: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            _now = _now.addingTimeInterval(interval)
        }
    }

    private func makeConfiguration() -> AtelierConfiguration {
        AtelierConfiguration(organization: "ambi", product: "ambre")
    }

    private func makeCache() -> DiskCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flags-tests-\(UUID().uuidString)")
        return DiskCache(fileURL: directory.appendingPathComponent("cache.json"))
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "flags-tests-\(UUID().uuidString)")!
    }

    private func makeClient(
        transport: StubTransport,
        cache: DiskCache,
        clock: Clock = Clock(),
        defaults: UserDefaults? = nil
    ) -> AtelierClient {
        AtelierClient(
            configuration: makeConfiguration(),
            transport: transport,
            cacheOverride: cache,
            now: { clock.now },
            defaults: defaults ?? makeDefaults())
    }

    private static let sampleRows = """
        [
          {"key": "on_for_all", "enabled": true,
           "rules": [{"conditions": [], "value": true}]},
          {"key": "paused_flag", "enabled": false,
           "rules": [{"conditions": [], "value": true}]}
        ]
        """

    private func waitUntil(
        _ condition: @escaping () -> Bool, timeout: TimeInterval = 5,
        message: String = "condition not met in time"
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail(message)
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Cold boot / cache

    func testColdBootServesCachedConfigWithoutNetwork() async {
        let cache = makeCache()
        cache.store(
            ConfigDocument(
                schemaVersion: ConfigDocument.supportedSchemaVersion, app: "ambre",
                flags: [
                    .object([
                        "key": .string("cached_flag"), "enabled": .bool(true),
                        "rules": .array([
                            .object(["conditions": .array([]), "value": .bool(true)])
                        ]),
                    ])
                ]))
        // Transport fails: launch must still see last-good immediately.
        let client = makeClient(transport: StubTransport(error: StubError()), cache: cache)
        XCTAssertTrue(client.isEnabled("cached_flag", default: false))
        XCTAssertFalse(client.isEnabled("unknown_flag", default: false))
        XCTAssertTrue(client.isEnabled("unknown_flag", default: true))
    }

    func testCorruptCacheFallsBackToCompiledDefaults() async {
        let cache = makeCache()
        try? FileManager.default.createDirectory(
            at: cache.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("not json {{{".utf8).write(to: cache.fileURL)
        let client = makeClient(transport: StubTransport(error: StubError()), cache: cache)
        XCTAssertTrue(client.isEnabled("anything", default: true))
        XCTAssertFalse(client.isEnabled("anything", default: false))
    }

    func testUnsupportedCacheSchemaVersionIsIgnored() {
        let cache = makeCache()
        cache.store(
            ConfigDocument(
                schemaVersion: ConfigDocument.supportedSchemaVersion + 1, app: "ambre",
                flags: [
                    .object([
                        "key": .string("future_flag"), "enabled": .bool(true),
                        "rules": .array([]),
                    ])
                ]))
        XCTAssertNil(cache.load(), "schema_version above supported must be ignored entirely")
    }

    /// v1 restructured into v2 (ADR 0014), so an older document is not a
    /// subset this build can read — it is a different shape, and reading
    /// it would misrepresent what the server meant.
    func testOlderCacheSchemaVersionIsIgnoredToo() {
        let cache = makeCache()
        cache.store(
            ConfigDocument(
                schemaVersion: 1, app: "ambre",
                flags: [
                    .object([
                        "key": .string("legacy_flag"), "enabled": .bool(true),
                        "rules": .array([]), "default_rollout_percent": .int(100),
                    ])
                ]))
        XCTAssertNil(cache.load(), "a document of another version is ignored entirely")
    }

    func testRefreshReplacesCacheAtomicallyAndUpdatesValues() async {
        let cache = makeCache()
        let transport = StubTransport(flagsJSON: Self.sampleRows)
        let client = makeClient(transport: transport, cache: cache)

        await waitUntil({ client.isEnabled("on_for_all", default: false) })
        XCTAssertTrue(
            client.isEnabled("paused_flag", default: true),
            "a paused flag overrides nobody — the app keeps its own default")
        XCTAssertFalse(
            client.isEnabled("paused_flag", default: false),
            "…whatever that default is")

        // Cache now holds the document; a fresh client cold-boots from it.
        let rebooted = makeClient(transport: StubTransport(error: StubError()), cache: cache)
        XCTAssertTrue(rebooted.isEnabled("on_for_all", default: false))
    }

    func testFailedFetchKeepsLastGood() async {
        let cache = makeCache()
        let transport = StubTransport(flagsJSON: Self.sampleRows)
        let clock = Clock()
        let client = makeClient(transport: transport, cache: cache, clock: clock)
        await waitUntil({ client.isEnabled("on_for_all", default: false) })

        // Next refresh returns garbage: nothing may change.
        transport.set(flagsJSON: "SERVER ERROR PAGE")
        clock.advance(by: 3600)
        await client.refresh()
        XCTAssertTrue(client.isEnabled("on_for_all", default: false))
    }

    // MARK: - Typed values (ADR 0013)

    /// A project's config as the CDN serves it, with typed flags.
    private static let typedRows = """
        [
          {"key": "batch_size", "enabled": true, "value_type": "int",
           "rules": [{"conditions": [], "value": 50}]},
          {"key": "price_factor", "enabled": false, "value_type": "double",
           "rules": [{"conditions": [], "value": 1.5}]},
          {"key": "paywall_copy", "enabled": true, "value_type": "string",
           "rules": [{"conditions": [], "value": "annual_first"}]},
          {"key": "plain", "enabled": true,
           "rules": [{"conditions": [], "value": true}]}
        ]
        """

    private func makeTypedClient() async -> AtelierClient {
        let transport = StubTransport(flagsJSON: Self.typedRows)
        let client = makeClient(transport: transport, cache: makeCache())
        await waitUntil({ client.value("batch_size", default: 0) == 50 })
        return client
    }

    func testTypedReadsServeTheMatchingRulesValue() async {
        let client = await makeTypedClient()
        XCTAssertEqual(client.value("batch_size", default: 7), 50)
        XCTAssertEqual(client.value("paywall_copy", default: "control"), "annual_first")
        // A paused flag overrides nobody: the app's own default stands,
        // whatever the rules say (ADR 0014).
        XCTAssertEqual(client.value("price_factor", default: 0.25), 0.25)
    }

    func testTypedReadOfAnotherTypeFallsBackToTheCompiledDefault() async {
        let client = await makeTypedClient()
        // Reads are exact: no int -> double widening, no coercion.
        XCTAssertEqual(client.value("batch_size", default: 0.5), 0.5)
        XCTAssertEqual(client.value("batch_size", default: "none"), "none")
        XCTAssertEqual(client.value("paywall_copy", default: 7), 7)
    }

    func testUntypedFlagIsABooleanFlag() async {
        let client = await makeTypedClient()
        XCTAssertTrue(client.value("plain", default: false))
        // …and asking it for another type gets the compiled-in default.
        XCTAssertEqual(client.value("plain", default: 7), 7)
    }

    /// `isEnabled` is the bool read, nothing more (ADR 0014): on a flag
    /// of another type it gives the caller's default, like every other
    /// mismatched read.
    func testIsEnabledIsTheBoolRead() async {
        let client = await makeTypedClient()
        XCTAssertTrue(client.isEnabled("plain", default: false))
        XCTAssertTrue(client.isEnabled("batch_size", default: true))
        XCTAssertFalse(client.isEnabled("batch_size", default: false))
    }

    /// The headline of ADR 0014: two users, two rules, two values.
    func testRulesServeDifferentValuesToDifferentUsers() async {
        let rows = """
            [
              {"key": "import_batch_size", "enabled": true, "value_type": "int",
               "rules": [{"conditions": [], "rollout_percent": 10, "value": 100},
                         {"conditions": [], "rollout_percent": 25, "value": 50}]}
            ]
            """
        let transport = StubTransport(flagsJSON: rows)
        let client = makeClient(transport: transport, cache: makeCache())
        // Wait on the fetch, not on a value: the anonymous stable id is a
        // fresh UUID, so which slice it lands in is not ours to predict.
        await waitUntil({ transport.flagsCallCount >= 1 })

        func signIn(as userId: String) async {
            await client.setContext(
                FlagContext(
                    userId: userId, build: 9042, appVersion: "5.2.0", platform: "ios",
                    osVersion: "26.0", locale: "sv-se"))
        }

        // bucket(import_batch_size, user-456) == 1, inside the first gate.
        await signIn(as: "user-456")
        XCTAssertEqual(client.value("import_batch_size", default: 10), 100)

        // bucket(…, user-123) == 15: past the first gate, inside the second.
        await signIn(as: "user-123")
        XCTAssertEqual(client.value("import_batch_size", default: 10), 50)

        // bucket(…, user-a) == 79: no rule claims them, so the app keeps
        // the value its own code compiled in.
        await signIn(as: "user-a")
        XCTAssertEqual(client.value("import_batch_size", default: 10), 10)
    }

    func testMissingTypedFlagUsesTheCompiledDefault() async {
        let client = await makeTypedClient()
        XCTAssertEqual(client.value("never_created", default: 7), 7)
    }

    func testReadsFireTheExposureHookWithTheValueTheAppActsOn() async {
        let exposures = ValuesBox<(String, JSONValue)>()
        var configuration = makeConfiguration()
        configuration.onExposure = { key, value in exposures.append((key, value)) }
        let client = AtelierClient(
            configuration: configuration,
            transport: StubTransport(flagsJSON: Self.typedRows),
            cacheOverride: makeCache(),
            now: { Date() },
            defaults: makeDefaults())
        await waitUntil({ client.value("batch_size", default: 7) == 50 })

        _ = client.value("batch_size", default: 7)
        XCTAssertTrue(exposures.values.contains { $0.0 == "batch_size" && $0.1 == .int(50) })

        // A read nothing overrode still reports: the app acted on a
        // value, and "who fell back?" is what a rollout dashboard asks.
        _ = client.value("never_created", default: 7)
        XCTAssertTrue(
            exposures.values.contains { $0.0 == "never_created" && $0.1 == .int(7) })
    }

    // MARK: - Endpoint discovery (ADR 0008)

    func testFlagsAreFetchedFromDirectoryResolvedEndpoint() async {
        let cache = makeCache()
        let transport = StubTransport(flagsJSON: Self.sampleRows)
        let client = makeClient(transport: transport, cache: cache)

        await waitUntil({ client.isEnabled("on_for_all", default: false) })
        let request = transport.lastFlagsRequest
        XCTAssertEqual(request?.url?.host, "flags.example.test")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "apikey"), "test-api-key")
    }

    func testFlagsRequestIsScopedToOrgAndProduct() async {
        let cache = makeCache()
        let transport = StubTransport(flagsJSON: Self.sampleRows)
        let client = makeClient(transport: transport, cache: cache)

        await waitUntil({ client.isEnabled("on_for_all", default: false) })

        // Product slugs are unique per organization (ADR 0009): the
        // delivery query must carry both. makeConfiguration() is
        // organization "ambi", product "ambre". Assert membership so the
        // check is robust to query-item ordering.
        let items =
            URLComponents(url: transport.lastFlagsRequest!.url!, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "org", value: "eq.ambi")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "app", value: "eq.ambre")))
    }

    func testResolvedEndpointPersistsAcrossLaunches() async {
        let cache = makeCache()
        let first = StubTransport(flagsJSON: Self.sampleRows)
        let client = makeClient(transport: first, cache: cache)
        await waitUntil({ client.isEnabled("on_for_all", default: false) })

        // Next launch: the directory is unreachable, but the disk-cached
        // endpoint keeps flags refreshing.
        let second = StubTransport(flagsJSON: Self.sampleRows)
        second.setDirectory(error: StubError())
        let relaunched = makeClient(transport: second, cache: makeCacheSameEndpoint(as: cache))
        await waitUntil({ second.flagsCallCount >= 1 })
        XCTAssertEqual(second.lastFlagsRequest?.url?.host, "flags.example.test")
        _ = relaunched
    }

    /// A fresh flags cache that shares the endpoint file with `cache`,
    /// mimicking "same install, different product cache state".
    private func makeCacheSameEndpoint(as cache: DiskCache) -> DiskCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flags-tests-\(UUID().uuidString)")
        return DiskCache(
            fileURL: directory.appendingPathComponent("cache.json"),
            endpointFileURL: cache.endpointFileURL)
    }

    func testUnusableDirectoryDocumentMeansNoFlagsFetch() async {
        let cache = makeCache()
        // Newer document schema than this SDK understands, and no cached
        // endpoint: the SDK must not guess — defaults serve.
        let transport = StubTransport(
            flagsJSON: Self.sampleRows,
            directoryJSON: """
                {"schema_version": 2, "base_url": "https://v2.example.test", "api_key": "k"}
                """)
        let client = makeClient(transport: transport, cache: cache)

        // Give the fire-and-forget init refresh a moment to run.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(transport.flagsCallCount, 0)
        XCTAssertFalse(client.isEnabled("on_for_all", default: false))
        XCTAssertTrue(client.isEnabled("on_for_all", default: true))
    }

    func testNewerDirectorySchemaKeepsCachedEndpoint() async {
        let cache = makeCache()
        let first = StubTransport(flagsJSON: Self.sampleRows)
        let bootstrap = makeClient(transport: first, cache: cache)
        await waitUntil({ bootstrap.isEnabled("on_for_all", default: false) })

        // The directory now serves a newer, unsupported document. The
        // cached endpoint must keep serving (fail-safe, ADR 0008).
        let second = StubTransport(
            flagsJSON: Self.sampleRows,
            directoryJSON: """
                {"schema_version": 2, "base_url": "https://v2.example.test", "api_key": "k"}
                """)
        let relaunched = makeClient(transport: second, cache: makeCacheSameEndpoint(as: cache))
        await waitUntil({ second.flagsCallCount >= 1 })
        XCTAssertEqual(second.lastFlagsRequest?.url?.host, "flags.example.test")
        _ = relaunched
    }

    func testDirectoryChangeMovesSubsequentFetches() async {
        let cache = makeCache()
        let transport = StubTransport(flagsJSON: Self.sampleRows)
        let clock = Clock()
        let client = makeClient(transport: transport, cache: cache, clock: clock)
        await waitUntil({ transport.flagsCallCount >= 1 })
        XCTAssertEqual(transport.lastFlagsRequest?.url?.host, "flags.example.test")

        // The backend moves; the next refresh follows the directory.
        transport.set(
            directoryJSON: """
                {"schema_version": 1, "base_url": "https://moved.example.test", "api_key": "k2"}
                """)
        clock.advance(by: 3600)
        await client.refresh()
        await waitUntil({ transport.lastFlagsRequest?.url?.host == "moved.example.test" })
        XCTAssertEqual(transport.lastFlagsRequest?.value(forHTTPHeaderField: "apikey"), "k2")
    }

    // MARK: - Debounce

    func testRefreshIsDebounced() async {
        let cache = makeCache()
        let transport = StubTransport(flagsJSON: Self.sampleRows)
        let clock = Clock()
        let client = makeClient(transport: transport, cache: cache, clock: clock)

        await client.refresh()
        await waitUntil({ transport.flagsCallCount >= 1 })
        let after = transport.flagsCallCount

        await client.refresh()  // within the window: dropped
        XCTAssertEqual(transport.flagsCallCount, after)

        clock.advance(by: 61)
        await client.refresh()
        XCTAssertEqual(transport.flagsCallCount, after + 1)
    }

    // MARK: - Context switching

    func testContextSwitchAnonymousToSignedInChangesResolution() async {
        let rows = """
            [
              {"key": "vip", "enabled": true,
               "rules": [{"conditions": [{"attribute": "user_id", "op": "eq",
                          "value": "user-123"}], "value": true}]}
            ]
            """
        let cache = makeCache()
        let transport = StubTransport(flagsJSON: rows)
        let client = makeClient(transport: transport, cache: cache)
        await client.setContext(
            FlagContext(
                build: 9000, appVersion: "5.2.0", platform: "iOS",
                osVersion: "26.0", locale: "sv-SE"))
        await waitUntil({ transport.flagsCallCount >= 1 })
        // Anonymous: no rule claims them, so the read is whatever the
        // call site compiled in — both ways round (ADR 0014).
        await waitUntil({ client.isEnabled("vip", default: true) })
        XCTAssertFalse(client.isEnabled("vip", default: false))

        // Signing in as the targeted user flips the rule on. Note the SDK
        // normalization: uid is trimmed + lowercased.
        await client.setContext(
            FlagContext(
                userId: " USER-123 ", build: 9000, appVersion: "5.2.0",
                platform: "iOS", osVersion: "26.0", locale: "sv-SE"))
        XCTAssertTrue(client.isEnabled("vip", default: false))
    }

    func testStableIDPersistsAcrossClients() {
        let defaults = makeDefaults()
        let cacheA = makeCache()
        let clientA = makeClient(
            transport: StubTransport(error: StubError()), cache: cacheA, defaults: defaults)
        _ = clientA  // mints and persists the anonymous stable id

        let stored = defaults.string(forKey: "se.ambi.atelier.stable_id")
        XCTAssertNotNil(stored, "anonymous stable_id must be persisted")

        let clientB = makeClient(
            transport: StubTransport(error: StubError()), cache: makeCache(), defaults: defaults)
        _ = clientB
        XCTAssertEqual(
            defaults.string(forKey: "se.ambi.atelier.stable_id"), stored,
            "second client must reuse the same persisted id")
    }

    // MARK: - Updates stream

    func testUpdatesStreamEmitsOnRefresh() async {
        let cache = makeCache()
        let transport = StubTransport(flagsJSON: Self.sampleRows)
        let client = makeClient(transport: transport, cache: cache)

        let received = expectation(description: "update emitted")
        received.assertForOverFulfill = false
        let task = Task {
            for await _ in client.updates {
                received.fulfill()
            }
        }
        await fulfillment(of: [received], timeout: 5)
        task.cancel()
    }

    func testUpdatesStreamSilentWhenRefreshFetchesIdenticalConfig() async {
        let cache = makeCache()
        let transport = StubTransport(flagsJSON: Self.sampleRows)
        let clock = Clock()
        let client = makeClient(transport: transport, cache: cache, clock: clock)
        await waitUntil({ client.isEnabled("on_for_all", default: false) })

        let emissions = ValuesBox<Bool>()
        let updates = client.updates  // subscribes synchronously
        let task = Task { for await _ in updates { emissions.append(true) } }

        // Same document again: must be indistinguishable from "nothing
        // changed" — no emission.
        clock.advance(by: 3600)
        await client.refresh()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(emissions.values.count, 0, "identical config must not emit")

        // An actual change emits.
        transport.set(
            flagsJSON: """
                [
                  {"key": "on_for_all", "enabled": false,
                   "rules": [{"conditions": [], "value": true}]}
                ]
                """)
        clock.advance(by: 3600)
        await client.refresh()
        await waitUntil({ emissions.values.count == 1 })
        task.cancel()
    }

    // MARK: - Per-flag observation streams

    func testObserveIsEnabledYieldsInitialValueThenChanges() async {
        let cache = makeCache()
        let transport = StubTransport(error: StubError())
        let clock = Clock()
        let client = makeClient(transport: transport, cache: cache, clock: clock)

        let values = ValuesBox<Bool>()
        let stream = client.observeIsEnabled("on_for_all", default: false)
        let task = Task { for await value in stream { values.append(value) } }

        // Compiled-in default is delivered immediately, before any fetch.
        await waitUntil({ values.values == [false] })

        transport.set(directoryJSON: StubTransport.directoryJSON)
        transport.set(flagsJSON: Self.sampleRows)
        clock.advance(by: 3600)
        await client.refresh()
        await waitUntil({ values.values == [false, true] })
        task.cancel()
    }

    func testObserveIsEnabledSkipsUnrelatedConfigChanges() async {
        let cache = makeCache()
        let transport = StubTransport(flagsJSON: Self.sampleRows)
        let clock = Clock()
        let client = makeClient(transport: transport, cache: cache, clock: clock)
        await waitUntil({ client.isEnabled("on_for_all", default: false) })

        let values = ValuesBox<Bool>()
        let stream = client.observeIsEnabled("on_for_all", default: false)
        let task = Task { for await value in stream { values.append(value) } }
        await waitUntil({ values.values == [true] })

        // A new unrelated flag appears; the observed flag's resolution is
        // unchanged, so the stream stays quiet (deduplicated).
        transport.set(
            flagsJSON: """
                [
                  {"key": "on_for_all", "enabled": true, "rules": [{"conditions": [], "value": true}]},
                  {"key": "paused_flag", "enabled": false, "rules": [{"conditions": [], "value": true}]},
                  {"key": "unrelated_new_flag", "enabled": true, "rules": [{"conditions": [], "value": true}]}
                ]
                """)
        clock.advance(by: 3600)
        await client.refresh()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(values.values, [true], "unchanged resolution must not re-yield")
        task.cancel()
    }

    func testObserveIsEnabledReactsToContextChange() async {
        let rows = """
            [
              {"key": "vip", "enabled": true,
               "rules": [{"conditions": [{"attribute": "user_id", "op": "eq",
                          "value": "user-123"}], "value": true}]}
            ]
            """
        let cache = makeCache()
        let transport = StubTransport(flagsJSON: rows)
        let client = makeClient(transport: transport, cache: cache)
        await client.setContext(
            FlagContext(
                build: 9000, appVersion: "5.2.0", platform: "iOS",
                osVersion: "26.0", locale: "sv-SE"))
        await waitUntil({ transport.flagsCallCount >= 1 })
        await waitUntil({ !client.isEnabled("vip", default: false) })

        let values = ValuesBox<Bool>()
        let stream = client.observeIsEnabled("vip", default: false)
        let task = Task { for await value in stream { values.append(value) } }
        await waitUntil({ values.values == [false] })

        // Signing in as the targeted user flips the observed value.
        await client.setContext(
            FlagContext(
                userId: "user-123", build: 9000, appVersion: "5.2.0",
                platform: "iOS", osVersion: "26.0", locale: "sv-SE"))
        await waitUntil({ values.values == [false, true] })
        task.cancel()
    }

    // MARK: - Observation framework integration

    func testObservationTrackedReadFiresOnChange() async throws {
        #if canImport(Observation)
            guard #available(iOS 17.0, macOS 14.0, watchOS 10.0, tvOS 17.0, *) else {
                throw XCTSkip("Observation framework unavailable on this OS")
            }
            let cache = makeCache()
            let transport = StubTransport(error: StubError())
            let clock = Clock()
            let client = makeClient(transport: transport, cache: cache, clock: clock)

            let changed = expectation(description: "tracked read invalidated")
            withObservationTracking {
                _ = client.isEnabled("on_for_all", default: false)
            } onChange: {
                changed.fulfill()
            }

            transport.set(directoryJSON: StubTransport.directoryJSON)
            transport.set(flagsJSON: Self.sampleRows)
            clock.advance(by: 3600)
            await client.refresh()
            await fulfillment(of: [changed], timeout: 5)
        #else
            throw XCTSkip("Observation framework unavailable in this SDK")
        #endif
    }
}
