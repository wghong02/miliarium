import Foundation
import OSLog
import FirebaseAuth

/// An error returned by the backend API, carrying the server's `code` and a
/// user-facing `message` (surfaced directly by the existing UI error paths).
struct BackendError: LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }

    /// Decodes the `{ error: { code, message } }` envelope from a failed
    /// response, falling back to a generic message.
    static func from(data: Data, status: Int) -> BackendError {
        struct Envelope: Decodable {
            struct Inner: Decodable { let code: String; let message: String }
            let error: Inner
        }
        if let env = try? JSONDecoder().decode(Envelope.self, from: data),
           !env.error.message.isEmpty {
            return BackendError(code: env.error.code, message: env.error.message)
        }
        return BackendError(
            code: "http-\(status)",
            message: "Request failed (\(status)). Please try again."
        )
    }
}

/// Thin HTTPS client for the Miliarium backend API. Attaches the signed-in
/// user's Firebase ID token as a Bearer credential, sends/receives JSON, and
/// maps non-2xx responses to `BackendError`.
actor BackendClient {
    static let shared = BackendClient()

    private let session: URLSession = .shared

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Performs a request and returns the raw response body. `@discardableResult`
    /// so callers that don't need the body can ignore it.
    @discardableResult
    func request(
        _ method: String,
        _ path: String,
        body: (any Encodable)? = nil
    ) async throws -> Data {
        guard let user = Auth.auth().currentUser else {
            throw BackendError(code: "unauthenticated", message: "You must be signed in.")
        }
        let token = try await user.getIDToken()

        guard let url = URL(string: BackendConfig.baseURL.absoluteString + path) else {
            throw BackendError(code: "bad-url", message: "Invalid request path.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try Self.encoder.encode(AnyEncodable(body))
        }

        AppLogger.backend.debug("\(method) \(path)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.dataWithRetry(session: session, request: req)
        } catch let urlError as URLError {
            throw BackendError(code: "network", message: Self.friendlyNetworkMessage(urlError))
        } catch {
            throw BackendError(code: "network", message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BackendError(code: "network", message: "No response from the server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let apiError = BackendError.from(data: data, status: http.statusCode)
            AppLogger.backend.error("\(method) \(path) failed status=\(http.statusCode) code=\(apiError.code)")
            throw apiError
        }
        return data
    }

    /// One safe retry when there's no connection at all — the request never
    /// reached the server, so retrying can't double-apply a mutation.
    private static func dataWithRetry(
        session: URLSession,
        request: URLRequest
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            try? await Task.sleep(for: .seconds(1))
            return try await session.data(for: request)
        }
    }

    private static func friendlyNetworkMessage(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
            return "You appear to be offline. Check your connection and try again."
        case .timedOut:
            return "The request timed out. Check your connection and try again."
        default:
            return error.localizedDescription
        }
    }

    /// Performs a request and decodes the JSON response into `Response`.
    func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        body: (any Encodable)? = nil
    ) async throws -> Response {
        let data = try await request(method, path, body: body)
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            AppLogger.backend.error("decode failed for \(method) \(path): \(error)")
            throw BackendError(code: "decode-error", message: "Unexpected response from the server.")
        }
    }
}

/// Type-erasing wrapper so a heterogeneous `any Encodable` body can be encoded.
private struct AnyEncodable: Encodable {
    private let encodeTo: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) { encodeTo = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeTo(encoder) }
}
