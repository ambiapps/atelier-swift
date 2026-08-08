import Foundation

/// One JSON file per (organization, product) in Application Support —
/// not Caches, which the OS may purge (docs/sdk-swift.md). Writes are
/// atomic (temp file + rename) so a crash mid-write can never corrupt
/// last-good. The resolved service endpoint is persisted alongside the
/// flag documents (one per install, not per product).
struct DiskCache: Sendable {
    let fileURL: URL
    let endpointFileURL: URL

    init(organization: String, product: String, appGroupIdentifier: String?) {
        let base: URL
        if let group = appGroupIdentifier,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group)
        {
            base = container.appendingPathComponent(
                "Library/Application Support", isDirectory: true)
        } else {
            base =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
        }
        let directory = base.appendingPathComponent("Atelier", isDirectory: true)
        self.fileURL =
            directory
            .appendingPathComponent(organization, isDirectory: true)
            .appendingPathComponent("\(product).json")
        self.endpointFileURL = directory.appendingPathComponent("endpoint.json")
    }

    init(fileURL: URL, endpointFileURL: URL? = nil) {
        self.fileURL = fileURL
        self.endpointFileURL =
            endpointFileURL
            ?? fileURL.deletingLastPathComponent().appendingPathComponent("endpoint.json")
    }

    /// Strict decode; any error means "no usable cache" and the caller
    /// falls back to compiled-in defaults. A document with an unsupported
    /// schema_version is unusable by this SDK version.
    func load() -> ConfigDocument? {
        guard let data = try? Data(contentsOf: fileURL),
            let document = try? JSONDecoder().decode(ConfigDocument.self, from: data),
            document.schemaVersion <= ConfigDocument.supportedSchemaVersion
        else { return nil }
        return document
    }

    func store(_ document: ConfigDocument) {
        guard let data = try? JSONEncoder().encode(document) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        // .atomic = write to a temp file, then rename over the old one.
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Last-known service endpoint, so flags keep refreshing across
    /// launches even when the directory document is unreachable.
    func loadEndpoint() -> AtelierEndpoint? {
        guard let data = try? Data(contentsOf: endpointFileURL) else { return nil }
        return AtelierDirectory.decode(data)
    }

    func storeEndpoint(_ endpoint: AtelierEndpoint) {
        guard let data = try? JSONEncoder().encode(endpoint) else { return }
        try? FileManager.default.createDirectory(
            at: endpointFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: endpointFileURL, options: .atomic)
    }
}
