import Foundation

/// The config document wrapping all flags for one app.
///
/// The CDN serves this document verbatim (ADR 0012) — the SDK parses it
/// rather than assembling it. The PostgREST fallback has no document,
/// only bare rows, so the SDK wraps those into this same shape with a
/// client-side constant `schema_version` (docs/supabase.md). The disk
/// cache stores the same shape either way.
struct ConfigDocument: Codable {
    /// The document version this SDK understands. A document with a
    /// higher version is ignored entirely and the cached last-supported
    /// config is kept (data-model.md).
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    var app: String
    var flags: [JSONValue]

    /// Delivery bookkeeping, present only on documents served by the
    /// CDN; nothing in evaluation reads it. Optional so a document
    /// wrapped from PostgREST rows — or one cached by an older build —
    /// still decodes.
    var revision: Int?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case app
        case flags
        case revision
    }

    /// How fetching a served document turned out. The three cases have
    /// genuinely different consequences, which is why this is not just
    /// an optional.
    enum Fetched {
        /// Usable; replace the cache with it.
        case document(ConfigDocument)
        /// Declares a `schema_version` this build does not understand.
        /// Ignore it *entirely* and keep the cached config — and do not
        /// try another read path either: a newer version can mean the
        /// row shape changed too, so rebuilding a document out of raw
        /// rows would misrepresent what the server meant (data-model.md).
        case unsupported
        /// Missing, unreachable, or unparsable. Nothing was learned, so
        /// the caller is free to try another path.
        case unavailable
    }

    /// Strict decode of a served document. `expecting` guards against
    /// having fetched the wrong object: a document naming a different
    /// product is not this product's config.
    static func decode(_ data: Data, expecting product: String) -> Fetched {
        guard let document = try? JSONDecoder().decode(ConfigDocument.self, from: data) else {
            return .unavailable
        }
        guard document.schemaVersion <= supportedSchemaVersion else { return .unsupported }
        guard document.app == product else { return .unavailable }
        return .document(document)
    }

    /// Flags indexed by key. Entries whose key can't be read are dropped;
    /// lookups then miss and resolve to the compiled-in default, which is
    /// exactly rule 4's behavior for unusable entries.
    func flagsByKey() -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for flag in flags {
            if let key = flag.objectValue?["key"]?.stringValue {
                result[key] = flag
            }
        }
        return result
    }
}
