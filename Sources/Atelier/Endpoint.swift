import Foundation

/// Where flag config is served from. Never part of the public API:
/// integrating apps identify themselves with organization/product and
/// the SDK locates the service itself, so the backend can move without
/// an app update and apps carry no backend details (ADR 0008).
struct AtelierEndpoint: Codable, Equatable, Sendable {
    /// The endpoint-document version this SDK understands. A newer
    /// document is unusable and ignored entirely — the last-known
    /// endpoint keeps serving (same fail-safe posture as the config
    /// document).
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    var baseURL: URL
    var apiKey: String

    /// Where rendered config objects are served from (ADR 0012):
    /// `{configURL}/{organization}/{product}.json` is a static object on
    /// a CDN, and reading it is the normal path.
    ///
    /// Optional because the field is additive — a directory document
    /// without it (an older backend, or one where CDN delivery is not
    /// lit up yet) is not an error. It means "no CDN path advertised",
    /// and the PostgREST read serves instead.
    var configURL: URL?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case baseURL = "base_url"
        case apiKey = "api_key"
        case configURL = "config_url"
    }

    /// The object holding one product's config, or nil when the backend
    /// advertises no CDN path.
    func configObjectURL(organization: String, product: String) -> URL? {
        configURL?
            .appendingPathComponent(organization, isDirectory: true)
            .appendingPathComponent("\(product).json")
    }
}

enum AtelierDirectory {
    /// The one address compiled into the SDK: a tiny JSON document on
    /// Atelier's own origin, published by the web deploy workflow,
    /// naming the current config backend.
    static let url = URL(string: "https://atelier.ambi.se/api/v1/endpoint.json")!

    /// Strict decode; any error (or an unsupported newer version) means
    /// "no usable document" and the caller keeps its last-known endpoint.
    static func decode(_ data: Data) -> AtelierEndpoint? {
        guard let endpoint = try? JSONDecoder().decode(AtelierEndpoint.self, from: data),
            endpoint.schemaVersion <= AtelierEndpoint.supportedSchemaVersion
        else { return nil }
        return endpoint
    }
}
