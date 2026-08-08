import Foundation

/// The config document wrapping all flags for one (app, environment).
/// PostgREST delivers bare rows; the SDK wraps them into this shape with
/// a client-side constant `schema_version` (docs/supabase.md). The same
/// shape is what the disk cache stores.
struct ConfigDocument: Codable {
    /// The document version this SDK understands. A document with a
    /// higher version is ignored entirely and the cached last-supported
    /// config is kept (data-model.md).
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    var app: String
    var flags: [JSONValue]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case app
        case flags
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
