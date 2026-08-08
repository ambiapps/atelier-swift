import Foundation

/// Fetch abstraction so tests never touch the network
/// (docs/sdk-swift.md testing requirements).
public protocol FlagsTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionTransport: FlagsTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}
