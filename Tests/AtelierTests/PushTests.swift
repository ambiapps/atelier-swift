import Foundation
import XCTest

@testable import Atelier

/// Push-poke support (ADR 0010): device-token registration is uploaded
/// (and retried) in the background, and an incoming poke forces a
/// refresh straight past the debounce. No network — stubbed transport.
final class PushTests: XCTestCase {

    /// Routes the three legs separately: directory document, flag
    /// fetches, and device-token registrations.
    private final class StubTransport: FlagsTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var _flagsRequests: [URLRequest] = []
        private var _registrationRequests: [URLRequest] = []
        private var _registrationFails = false

        var flagsCallCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _flagsRequests.count
        }
        var registrationRequests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _registrationRequests
        }
        func setRegistrationFails(_ fails: Bool) {
            lock.lock()
            defer { lock.unlock() }
            _registrationFails = fails
        }

        struct StubError: Error {}

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            lock.lock()
            defer { lock.unlock() }
            let ok = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if request.url == AtelierDirectory.url {
                let directory = """
                    {"schema_version": 1, "base_url": "https://flags.example.test", \
                    "api_key": "test-api-key"}
                    """
                return (Data(directory.utf8), ok)
            }
            if request.url!.path.hasSuffix("/rest/v1/rpc/register_device") {
                _registrationRequests.append(request)
                if _registrationFails { throw StubError() }
                return (Data(), ok)
            }
            _flagsRequests.append(request)
            return (Data("[]".utf8), ok)
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

    private func makeClient(transport: StubTransport, clock: Clock = Clock()) -> AtelierClient {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flags-push-tests-\(UUID().uuidString)")
        return AtelierClient(
            configuration: AtelierConfiguration(organization: "ambi", product: "ambre"),
            transport: transport,
            cacheOverride: DiskCache(fileURL: directory.appendingPathComponent("cache.json")),
            now: { clock.now },
            defaults: UserDefaults(suiteName: "flags-push-tests-\(UUID().uuidString)")!)
    }

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

    // MARK: - Registration upload

    func testRegisterDeviceTokenUploadsRegistration() async throws {
        let transport = StubTransport()
        let client = makeClient(transport: transport)
        await client.registerDeviceToken(
            Data([0xAB, 0xCD, 0x01]), environment: .sandbox)
        await waitUntil { transport.registrationRequests.count == 1 }

        let request = try XCTUnwrap(transport.registrationRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.path, "/rest/v1/rpc/register_device",
            "registration goes through the append-only RPC, never the table")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "test-api-key")

        let row = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
                as? [String: String])
        XCTAssertEqual(row["org"], "ambi")
        XCTAssertEqual(row["app"], "ambre")
        XCTAssertEqual(row["token"], "abcd01", "token is lowercase hex")
        XCTAssertEqual(row["environment"], "sandbox")
        XCTAssertEqual(row["topic"], Bundle.main.bundleIdentifier ?? "unknown")
        XCTAssertFalse(try XCTUnwrap(row["platform"]).isEmpty)
    }

    func testSameTokenIsNotReuploaded() async {
        let transport = StubTransport()
        let client = makeClient(transport: transport)
        await client.registerDeviceToken(Data([0x01]), environment: .production)
        await waitUntil { transport.registrationRequests.count == 1 }
        await client.registerDeviceToken(Data([0x01]), environment: .production)
        // Deliberately no wait: a second upload would be asynchronous
        // noise; the immediate count is the contract (actor-serialized).
        XCTAssertEqual(transport.registrationRequests.count, 1)
    }

    func testFailedRegistrationRetriesOnNextRefresh() async {
        let transport = StubTransport()
        transport.setRegistrationFails(true)
        let clock = Clock()
        let client = makeClient(transport: transport, clock: clock)
        await client.registerDeviceToken(Data([0x02]), environment: .production)
        await waitUntil { transport.registrationRequests.count == 1 }

        transport.setRegistrationFails(false)
        clock.advance(by: 61)
        await client.refresh()
        await waitUntil(
            { transport.registrationRequests.count == 2 },
            message: "pending registration must ride the next refresh cycle")
    }

    // MARK: - Poke handling

    func testPokeForcesRefreshPastDebounce() async {
        let transport = StubTransport()
        let client = makeClient(transport: transport)
        await waitUntil { transport.flagsCallCount == 1 }  // init refresh

        // Inside the debounce window an ordinary refresh is dropped…
        await client.refresh()
        XCTAssertEqual(transport.flagsCallCount, 1)

        // …but a poke means "something changed right now".
        let handled = await client.handlePushNotification(["atelier": ["poke": 1]])
        XCTAssertTrue(handled)
        XCTAssertEqual(transport.flagsCallCount, 2)
    }

    func testForeignPushPayloadIsIgnored() async {
        let transport = StubTransport()
        let client = makeClient(transport: transport)
        await waitUntil { transport.flagsCallCount == 1 }

        let handled = await client.handlePushNotification(["aps": ["alert": "hi"]])
        XCTAssertFalse(handled)
        XCTAssertEqual(transport.flagsCallCount, 1)
    }
}
