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

    /// Minimum interval between network refreshes; `refresh()` calls
    /// inside the window are dropped (docs/sdk-swift.md).
    public var minimumRefreshInterval: TimeInterval

    public init(
        organization: String,
        product: String,
        pollWhileForegrounded: Duration? = nil,
        appGroupIdentifier: String? = nil,
        onExposure: (@Sendable (_ key: String, _ value: JSONValue) -> Void)? = nil,
        minimumRefreshInterval: TimeInterval = 60
    ) {
        self.organization = organization
        self.product = product
        self.pollWhileForegrounded = pollWhileForegrounded
        self.appGroupIdentifier = appGroupIdentifier
        self.onExposure = onExposure
        self.minimumRefreshInterval = minimumRefreshInterval
    }
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
