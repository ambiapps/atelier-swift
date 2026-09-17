import Foundation

public struct AtelierConfiguration: Sendable {
    /// Organization identifier, as defined in Atelier. Scopes `product`:
    /// product identifiers are unique within an organization, not
    /// globally (ADR 0008).
    public var organization: String

    /// Product identifier, as defined in Atelier (the project slug in
    /// the admin UI). Together with `organization` this is the complete
    /// identity an integrating app provides — the SDK locates the
    /// Atelier service on its own (ADR 0008).
    public var product: String

    /// Optional foreground poll interval. `nil` means refresh only on
    /// init/foreground/explicit `refresh()`.
    public var pollWhileForegrounded: Duration?

    /// App-group identifier. When set, the disk cache and the persisted
    /// anonymous stable id live in the group container so extensions can
    /// read the same cache (extensions never fetch).
    public var appGroupIdentifier: String?

    /// Exposure hook: called when a flag is read, with the value the app
    /// is about to act on — a rule's value, or the compiled-in default
    /// when no rule overrode this user (ADR 0014). Host apps log these to
    /// their own analytics; the SDK has no analytics dependency.
    public var onExposure: (@Sendable (_ key: String, _ value: JSONValue) -> Void)?

    /// Called after every config download with how long the network
    /// request took — for the host's own analytics, like `onExposure`.
    public var onConfigDownload: (@Sendable (_ download: ConfigDownload) -> Void)?

    /// Minimum interval between network refreshes; `refresh()` calls
    /// inside the window are dropped (docs/sdk-swift.md).
    public var minimumRefreshInterval: TimeInterval

    /// Public keys this build accepts config signatures from (ADR
    /// 0017) — each the base64url string shown in Project settings.
    ///
    /// A P-256 public key is a single value, so this is a single
    /// string: the JWK's `x` and `y` concatenated, which is what the
    /// admin UI hands you ready to paste.
    ///
    /// **Empty — the default — means this build does not verify** and
    /// reads the unsigned config exactly as before signing existed.
    /// That is what makes verification adoptable: ship the key first,
    /// turn on signing second.
    ///
    /// Pass more than one across a rotation. Every key here is tried,
    /// so shipping the new key alongside the old one *before* Atelier
    /// signs with it is what keeps rotation from stranding installs
    /// that have not updated — they would otherwise reject every
    /// document and sit on last-good until they do.
    public var signingKeys: [String]

    /// How old the disk cache may be and still be served at cold boot.
    /// `nil` — the default — means last-good is served however old it
    /// is, which is the SDK's standing guarantee.
    ///
    /// Set it and a cache older than this is ignored at init: reads
    /// resolve to the compiled-in defaults until a refresh succeeds.
    /// That trades "last-good wins" for "never act on a config nobody
    /// has confirmed recently" — right for an app that runs experiments
    /// and would rather be in control than in a stale arm, wrong for a
    /// kill switch that must survive a week offline. The age is measured
    /// once, at init; a config loaded then keeps serving for the life of
    /// the process.
    public var maximumCacheAge: TimeInterval?

    public init(
        organization: String,
        product: String,
        pollWhileForegrounded: Duration? = nil,
        appGroupIdentifier: String? = nil,
        onExposure: (@Sendable (_ key: String, _ value: JSONValue) -> Void)? = nil,
        minimumRefreshInterval: TimeInterval = 60,
        signingKeys: [String] = [],
        maximumCacheAge: TimeInterval? = nil,
        onConfigDownload: (@Sendable (_ download: ConfigDownload) -> Void)? = nil
    ) {
        self.organization = organization
        self.product = product
        self.pollWhileForegrounded = pollWhileForegrounded
        self.appGroupIdentifier = appGroupIdentifier
        self.onExposure = onExposure
        self.minimumRefreshInterval = minimumRefreshInterval
        self.signingKeys = signingKeys
        self.maximumCacheAge = maximumCacheAge
        self.onConfigDownload = onConfigDownload
    }
}

/// One config download, as timed by the SDK: the network request for
/// the config object alone — not service discovery, decoding or
/// signature verification.
public struct ConfigDownload: Sendable {
    public let duration: Duration
    /// HTTP status, or `nil` when the request failed before a response
    /// (offline, timeout, TLS).
    public let statusCode: Int?
    public let bytes: Int
    /// The first download of the process — the one a cold start waits
    /// on in `waitForLaunchRefresh`.
    public let isLaunch: Bool

    public var succeeded: Bool { statusCode.map { (200..<300).contains($0) } ?? false }
}

/// Which APNs environment the current build's device tokens belong to
/// (ADR 0010). `.automatic` assumes debug builds run against the APNs
/// sandbox and release builds (TestFlight, App Store) against
/// production; pass an explicit value if your build setup differs.
public enum PushEnvironment: Sendable {
    case automatic
    case production
    case sandbox
}

public struct FlagContext: Sendable {
    /// Account uid when signed in; nil when anonymous. Determines
    /// `stable_id` (falls back to a persisted per-install UUID).
    public var userId: String?
    /// Raw email of the signed-in user. The SDK hashes it immediately;
    /// the raw address never leaves the device.
    public var email: String?
    public var build: Int
    public var appVersion: String
    public var platform: String
    public var osVersion: String
    public var locale: String

    public init(
        userId: String? = nil,
        email: String? = nil,
        build: Int,
        appVersion: String,
        platform: String,
        osVersion: String,
        locale: String
    ) {
        self.userId = userId
        self.email = email
        self.build = build
        self.appVersion = appVersion
        self.platform = platform
        self.osVersion = osVersion
        self.locale = locale
    }
}
