import Foundation
import os

#if canImport(UIKit) && !os(watchOS)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#elseif canImport(WatchKit)
    import WatchKit
#endif

/// The client. Reads are synchronous and non-blocking against an
/// immutable snapshot; all mutation (context changes, refreshes) funnels
/// through the actor. Initialization loads the disk cache and returns —
/// the first network refresh is fire-and-forget (never block launch).
///
/// Every flag is observable: reads are tracked via the Observation
/// framework where the OS provides it (SwiftUI re-renders on change with
/// no wiring), and `updates` / `observeIsEnabled` expose the same
/// changes as async streams on every supported OS.
public actor AtelierClient {

    // MARK: - Shared state for nonisolated reads

    private struct Snapshot: Sendable, Equatable {
        var flags: [String: JSONValue] = [:]
        var context: [String: JSONValue] = [:]
        var stableID: String = ""
    }

    private final class SharedState: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Snapshot())
        private let subscribers = OSAllocatedUnfairLock(
            initialState: [UUID: AsyncStream<Void>.Continuation]())
        private let onChange: @Sendable () -> Void

        init(onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
        }

        func read() -> Snapshot { lock.withLock { $0 } }

        /// Applies the mutation, then notifies subscribers and the
        /// observation registrar — but only when the snapshot actually
        /// changed, so a refresh that fetched identical config is silent
        /// (indistinguishable from "nothing changed").
        func write(_ transform: @Sendable (inout Snapshot) -> Void) {
            let changed = lock.withLock { snapshot in
                let before = snapshot
                transform(&snapshot)
                return snapshot != before
            }
            guard changed else { return }
            onChange()
            notify()
        }

        func addSubscriber(_ id: UUID, _ continuation: AsyncStream<Void>.Continuation) {
            subscribers.withLock { $0[id] = continuation }
        }
        func removeSubscriber(_ id: UUID) {
            subscribers.withLock { _ = $0.removeValue(forKey: id) }
        }
        private func notify() {
            subscribers.withLock { for continuation in $0.values { continuation.yield() } }
        }
    }

    // MARK: - Stored properties

    private let configuration: AtelierConfiguration
    private let transport: FlagsTransport
    private let cache: DiskCache
    private let shared: SharedState
    private let observation: ObservationSupport
    private let now: @Sendable () -> Date
    private var lastRefresh: Date?
    private var refreshTask: Task<Void, Never>?

    /// Last-known service endpoint (ADR 0008). Seeded from disk at init;
    /// re-resolved from the directory document on every refresh cycle.
    private var endpoint: AtelierEndpoint?

    /// Device registration for the push poke (ADR 0010): pending until
    /// one upload succeeds, retried on each refresh cycle. Best-effort —
    /// a device that never registers just refreshes on the v1 cadence.
    private var pendingRegistration: DeviceRegistration?
    private var uploadedRegistration: DeviceRegistration?

    // MARK: - Init

    public init(configuration: AtelierConfiguration) {
        self.init(
            configuration: configuration,
            transport: URLSessionTransport(),
            cacheOverride: nil,
            now: { Date() },
            defaults: nil)
    }

    /// Test seam: injectable transport, cache location, and clock.
    init(
        configuration: AtelierConfiguration,
        transport: FlagsTransport,
        cacheOverride: DiskCache?,
        now: @escaping @Sendable () -> Date,
        defaults: UserDefaults?
    ) {
        self.configuration = configuration
        self.transport = transport
        self.cache =
            cacheOverride
            ?? DiskCache(
                organization: configuration.organization,
                product: configuration.product,
                appGroupIdentifier: configuration.appGroupIdentifier)
        self.now = now
        let observation = ObservationSupport.make()
        self.observation = observation
        self.shared = SharedState(onChange: observation.invalidate)
        self.endpoint = self.cache.loadEndpoint()

        // Cold boot: synchronously load last-good from disk. Falls back
        // to compiled-in defaults (empty snapshot) on first launch or
        // corrupt/unsupported cache.
        let cached = cache.load()
        let stableID = Self.loadOrMintStableID(
            defaults: defaults ?? Self.defaultsStore(for: configuration))
        shared.write { snapshot in
            snapshot.flags = cached?.flagsByKey() ?? [:]
            snapshot.stableID = stableID
            snapshot.context["stable_id"] = .string(stableID)
        }

        // Background refresh — fire-and-forget, never awaited by init.
        Task { [weak self] in await self?.refresh() }
        Task { [weak self] in await self?.observeForegroundAndPoll() }
    }

    // MARK: - Context

    /// Replaces the evaluation context (call on sign-in/out). Raw email
    /// is hashed here and never stored or sent anywhere.
    public func setContext(_ context: FlagContext) {
        let userId = Self.normalize(context.userId)
        let stableID = userId ?? Self.loadOrMintStableID(
            defaults: Self.defaultsStore(for: configuration))
        var attributes: [String: JSONValue] = [
            "stable_id": .string(stableID),
            "is_anonymous": .bool(userId == nil),
            "platform": .string(context.platform.lowercased()),
            "build": .int(context.build),
            "app_version": .string(context.appVersion),
            "os_version": .string(context.osVersion),
            "locale": .string(context.locale.lowercased()),
        ]
        if let userId {
            attributes["user_id"] = .string(userId)
        }
        if let email = context.email, !email.isEmpty {
            attributes["email_hash"] = .string(Evaluator.emailHash(email))
        }
        let resolved = attributes
        shared.write { snapshot in
            snapshot.context = resolved
            snapshot.stableID = stableID
        }
    }

    // MARK: - Reads (synchronous, non-blocking)

    /// Observable: inside an observation-tracked scope (a SwiftUI `body`,
    /// `withObservationTracking`) this read re-fires when resolved values
    /// change, on OSes with the Observation framework (iOS 17+ etc.).
    public nonisolated func isEnabled(_ key: String, default codeDefault: Bool) -> Bool {
        observation.trackAccess()
        let snapshot = shared.read()
        let isOn = Evaluator.resolve(
            flag: snapshot.flags[key],
            context: snapshot.context,
            stableID: snapshot.stableID,
            codeDefault: codeDefault)
        configuration.onExposure?(key, isOn)
        return isOn
    }

    // MARK: - Observation (react to changes mid-session)

    /// Coarse change signal: emits whenever resolved values may have
    /// changed (config refresh or context change). A refresh that fetched
    /// identical config is silent. For per-flag values use
    /// `observeIsEnabled(_:default:)`.
    public nonisolated var updates: AsyncStream<Void> {
        let id = UUID()
        let state = shared
        return AsyncStream { continuation in
            state.addSubscriber(id, continuation)
            continuation.onTermination = { _ in state.removeSubscriber(id) }
        }
    }

    /// One flag's resolved value as a stream: yields the current value
    /// immediately, then again whenever the resolution changes (refresh
    /// or context change), deduplicated — updates that don't change this
    /// flag's resolved value yield nothing. Fires the exposure hook per
    /// yielded value. Works on every supported OS (no Observation
    /// framework required).
    public nonisolated func observeIsEnabled(
        _ key: String, default codeDefault: Bool
    ) -> AsyncStream<Bool> {
        AsyncStream { continuation in
            // Subscribe before the first read so a refresh landing in
            // between is buffered, not missed (dedupe absorbs overlap).
            let changes = self.updates
            let state = self.shared
            let onExposure = self.configuration.onExposure
            let task = Task {
                var last: Bool?
                func emitIfChanged() {
                    let snapshot = state.read()
                    let isOn = Evaluator.resolve(
                        flag: snapshot.flags[key],
                        context: snapshot.context,
                        stableID: snapshot.stableID,
                        codeDefault: codeDefault)
                    guard isOn != last else { return }
                    last = isOn
                    onExposure?(key, isOn)
                    continuation.yield(isOn)
                }
                emitIfChanged()
                for await _ in changes { emitIfChanged() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Refresh

    /// Background refresh; safe to call often. Calls within the minimum
    /// interval are dropped; a failed or malformed fetch changes nothing
    /// (last-good wins).
    public func refresh() async {
        if let last = lastRefresh,
            now().timeIntervalSince(last) < configuration.minimumRefreshInterval
        {
            return
        }
        lastRefresh = now()
        await performRefresh()
    }

    /// - Parameter revalidating: skip any locally cached HTTP response
    ///   for the config object. Set for a poke-triggered refresh, whose
    ///   entire purpose is freshness — the object is served with a short
    ///   `max-age`, and honoring it there would defeat the poke.
    private func performRefresh(revalidating: Bool = false) async {
        await refreshEndpointFromDirectory()
        // Never resolved (first launch offline): compiled-in defaults
        // keep serving until a later refresh succeeds — never an error.
        guard let endpoint else { return }

        // The CDN object is the normal read (ADR 0012); PostgREST is the
        // fallback for a backend that advertises no `config_url` and for
        // an object that is missing or unusable. `.unsupported` is not a
        // fallback case: a document from the future must be ignored
        // whole, not routed around.
        switch await fetchPublishedConfig(endpoint: endpoint, revalidating: revalidating) {
        case .document(let document):
            apply(document)
        case .unsupported:
            break
        case .unavailable:
            await fetchConfigFromPostgREST(endpoint: endpoint)
        }

        // Piggyback the device registration on the refresh cycle so a
        // token registered before the endpoint resolved still uploads.
        await uploadRegistrationIfPending()
    }

    private func apply(_ document: ConfigDocument) {
        cache.store(document)
        shared.write { snapshot in
            snapshot.flags = document.flagsByKey()
        }
    }

    /// Reads `{config_url}/{organization}/{product}.json` — a static
    /// object on a CDN. No key and no query string: it is public config,
    /// the same bytes the fallback would assemble.
    private func fetchPublishedConfig(
        endpoint: AtelierEndpoint, revalidating: Bool
    ) async -> ConfigDocument.Fetched {
        guard
            let url = endpoint.configObjectURL(
                organization: configuration.organization,
                product: configuration.product)
        else { return .unavailable }

        var request = URLRequest(url: url)
        if revalidating {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else { return .unavailable }
            return ConfigDocument.decode(data, expecting: configuration.product)
        } catch {
            return .unavailable
        }
    }

    /// The pre-ADR-0012 read path, kept as the fallback: bare rows,
    /// wrapped into a document client-side.
    private func fetchConfigFromPostgREST(endpoint: AtelierEndpoint) async {
        var components = URLComponents(
            url: endpoint.baseURL.appendingPathComponent("rest/v1/flags"),
            resolvingAgainstBaseURL: false)!
        // Scope by organization AND product: product slugs are unique
        // per organization, not globally (ADR 0009), so both are required
        // to select the right config.
        components.queryItems = [
            URLQueryItem(name: "org", value: "eq.\(configuration.organization)"),
            URLQueryItem(name: "app", value: "eq.\(configuration.product)"),
            URLQueryItem(
                name: "select", value: "key,enabled,rules,default_rollout_percent"),
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.setValue(endpoint.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return }
            // Strict decode; any error keeps the previous cache.
            let rows = try JSONDecoder().decode([JSONValue].self, from: data)
            apply(
                ConfigDocument(
                    schemaVersion: ConfigDocument.supportedSchemaVersion,
                    app: configuration.product,
                    flags: rows))
        } catch {
            // Fetch/parse failure: keep serving last-good. "Atelier is
            // down" must be indistinguishable from "nothing changed".
        }
    }

    // MARK: - Push poke (ADR 0010)

    private struct DeviceRegistration: Equatable, Sendable {
        var token: String
        var platform: String
        var topic: String
        var environment: String
    }

    /// Registers this device for the opt-in push poke: an admin saving a
    /// flag change can wake the app to refetch immediately instead of at
    /// its next foreground. Call from the app's
    /// `didRegisterForRemoteNotificationsWithDeviceToken` (every launch —
    /// registration is idempotent). Best-effort by design: failure to
    /// register costs latency, never correctness.
    public func registerDeviceToken(
        _ deviceToken: Data, environment: PushEnvironment = .automatic
    ) async {
        let registration = DeviceRegistration(
            token: deviceToken.map { String(format: "%02x", $0) }.joined(),
            platform: Self.currentPlatform,
            topic: Bundle.main.bundleIdentifier ?? "unknown",
            environment: Self.resolve(environment))
        guard registration != uploadedRegistration else { return }
        pendingRegistration = registration
        await uploadRegistrationIfPending()
    }

    /// Call from the app's silent-push handler
    /// (`didReceiveRemoteNotification`). Returns whether the payload was
    /// an Atelier poke; when it is, a refresh has already completed (or
    /// failed harmlessly — last-good keeps serving) by the time this
    /// returns, so the caller can report `.newData` to the system.
    public nonisolated func handlePushNotification(
        _ userInfo: [AnyHashable: Any]
    ) async -> Bool {
        guard userInfo["atelier"] != nil else { return false }
        await pokeRefresh()
        return true
    }

    /// A poke bypasses the refresh debounce *and* the HTTP cache: the
    /// push exists to say something changed right now, so serving a
    /// cached config response would answer the wrong question.
    private func pokeRefresh() async {
        lastRefresh = now()
        await performRefresh(revalidating: true)
    }

    private func uploadRegistrationIfPending() async {
        guard let registration = pendingRegistration,
            registration != uploadedRegistration,
            let endpoint
        else { return }
        // The registry is reachable only through the append-only
        // `register_device` RPC (re-registering an existing token is a
        // no-op server-side); the anon key has no access to the table
        // itself.
        var request = URLRequest(
            url: endpoint.baseURL.appendingPathComponent("rest/v1/rpc/register_device"))
        request.httpMethod = "POST"
        request.setValue(endpoint.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "org": configuration.organization,
            "app": configuration.product,
            "token": registration.token,
            "platform": registration.platform,
            "topic": registration.topic,
            "environment": registration.environment,
        ])
        do {
            let (_, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else { return }
            uploadedRegistration = registration
            pendingRegistration = nil
        } catch {
            // Keep it pending; the next refresh cycle retries.
        }
    }

    private static var currentPlatform: String {
        #if os(iOS)
            return "ios"
        #elseif os(macOS)
            return "macos"
        #elseif os(tvOS)
            return "tvos"
        #elseif os(watchOS)
            return "watchos"
        #elseif os(visionOS)
            return "visionos"
        #else
            return "unknown"
        #endif
    }

    private static func resolve(_ environment: PushEnvironment) -> String {
        switch environment {
        case .production: return "production"
        case .sandbox: return "sandbox"
        case .automatic:
            #if DEBUG
                return "sandbox"
            #else
                return "production"
            #endif
        }
    }

    /// Re-resolves the service endpoint from the directory document.
    /// Piggybacks on the (debounced) refresh cycle, so a moved backend
    /// is picked up within one refresh interval. Any failure — offline,
    /// malformed document, unsupported newer schema — keeps the
    /// last-known endpoint (disk-cached across launches).
    private func refreshEndpointFromDirectory() async {
        let request = URLRequest(url: AtelierDirectory.url)
        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                let resolved = AtelierDirectory.decode(data)
            else { return }
            if resolved != endpoint {
                endpoint = resolved
                cache.storeEndpoint(resolved)
            }
        } catch {
            // Keep the last-known endpoint.
        }
    }

    // MARK: - Foreground refresh + optional poll

    private func observeForegroundAndPoll() async {
        #if canImport(UIKit) && !os(watchOS)
            let notifications = NotificationCenter.default.notifications(
                named: UIApplication.willEnterForegroundNotification)
        #elseif canImport(AppKit)
            let notifications = NotificationCenter.default.notifications(
                named: NSApplication.willBecomeActiveNotification)
        #elseif canImport(WatchKit)
            let notifications = NotificationCenter.default.notifications(
                named: WKApplication.willEnterForegroundNotification)
        #else
            let notifications: [Never] = []
        #endif

        if let interval = configuration.pollWhileForegrounded {
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    await self?.refresh()
                }
            }
            refreshTask = poller
        }

        for await _ in notifications {
            await refresh()
        }
    }

    // MARK: - stable_id persistence

    private static let stableIDKey = "se.ambi.atelier.stable_id"

    private static func defaultsStore(for configuration: AtelierConfiguration) -> UserDefaults {
        if let group = configuration.appGroupIdentifier,
            let defaults = UserDefaults(suiteName: group)
        {
            return defaults
        }
        return .standard
    }

    /// Signed-in uid if available, else a per-install UUID persisted
    /// forever. Normalization: trim + lowercase (data-model.md).
    private static func loadOrMintStableID(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: stableIDKey) {
            return existing
        }
        let minted = UUID().uuidString.lowercased()
        defaults.set(minted, forKey: stableIDKey)
        return minted
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
