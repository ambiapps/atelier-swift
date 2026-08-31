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

    /// Public keys this build accepts config signatures from (ADR
    /// 0017). Each project has its own signing key; copy `x`, `y` and
    /// `kid` out of the JWKS Atelier publishes for your project.
    ///
    /// **Empty — the default — means this build does not verify** and
    /// reads the unsigned config exactly as before signing existed.
    /// That is what makes verification adoptable: ship the key first,
    /// turn on signing second.
    ///
    /// Pass more than one across a rotation. A build trusts every key
    /// here, so shipping the new key alongside the old one *before*
    /// Atelier starts signing with it is what keeps rotation from
    /// stranding installs that have not updated — they would otherwise
    /// reject every document and sit on last-good until they do.
    public var signingKeys: [AtelierSigningKey]

    public init(
        organization: String,
        product: String,
        pollWhileForegrounded: Duration? = nil,
        appGroupIdentifier: String? = nil,
        onExposure: (@Sendable (_ key: String, _ value: JSONValue) -> Void)? = nil,
        minimumRefreshInterval: TimeInterval = 60,
        signingKeys: [AtelierSigningKey] = []
    ) {
        self.organization = organization
        self.product = product
        self.pollWhileForegrounded = pollWhileForegrounded
        self.appGroupIdentifier = appGroupIdentifier
        self.onExposure = onExposure
        self.minimumRefreshInterval = minimumRefreshInterval
        self.signingKeys = signingKeys
    }
}

/// One public key a build will accept signed config from, in the form
/// the published JWKS gives it (ADR 0017).
///
/// Keys are per project: a leaked private half costs that one project
/// its signature, not every tenant's. The public half is not secret —
/// it is served on the CDN — so it belongs in your source next to your
/// organization and product identifiers.
public struct AtelierSigningKey: Sendable, Equatable {
    /// Key id, matched against the `kid` in the signed document's
    /// header so a rotation can be in flight without ambiguity.
    public let kid: String
    /// The JWK's `x` and `y`, base64url, exactly as published.
    public let x: String
    public let y: String

    public init(kid: String, x: String, y: String) {
        self.kid = kid
        self.x = x
        self.y = y
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
