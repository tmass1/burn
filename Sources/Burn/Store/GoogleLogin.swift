import AppKit
import CryptoKit
import Foundation
import Network

/// Google's installed-app OAuth flow, the way Antigravity does it: a loopback listener on a spare port, the browser
/// sent to Google's account chooser, the code exchanged with Antigravity's own client, and the browser forwarded to
/// Google's own "signed in" page. Nothing is written until the tokens are in hand.
@MainActor
final class GoogleLogin {
    nonisolated static let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
    nonisolated static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
    ]
    nonisolated static let successURL = "https://developers.google.com/gemini-code-assist/auth_success_gemini"
    nonisolated static let failureURL = "https://developers.google.com/gemini-code-assist/auth_failure_gemini"

    struct Tokens: Sendable {
        var accessToken: String
        var refreshToken: String
        var idToken: String?
        var expiresAt: Date
        var email: String
    }

    enum Failure: Error, LocalizedError {
        case noClient
        case cancelled
        case denied(String)
        case stateMismatch
        case exchange(String)
        case noEmail

        var errorDescription: String? {
            switch self {
            case .noClient: "Antigravity isn't installed, so there is no Google client to sign in with. Install it from antigravity.google."
            case .cancelled: "Cancelled."
            case let .denied(reason): "Google didn't sign in: \(reason)"
            case .stateMismatch: "The browser came back with a different state than expected."
            case let .exchange(reason): "Google wouldn't exchange the code: \(reason)"
            case .noEmail: "Google didn't say which account signed in."
            }
        }
    }

    private var listener: NWListener?
    private var continuation: CheckedContinuation<(code: String, state: String), Error>?

    /// Runs the whole flow. `onURL` gets the authorize URL as soon as the browser is sent to it.
    func run(loginHint: String?, onURL: @escaping (URL) -> Void) async throws -> Tokens {
        let clients = GeminiProvider.OAuthClient.candidates
        guard let client = clients.first else { throw Failure.noClient }
        let state = Self.random(32)
        let verifier = Self.random(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL

        let port = try await listen()
        let redirect = "http://localhost:\(port)/oauth2callback"
        var components = URLComponents(string: Self.authorizeURL)!
        components.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "select_account consent"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ] + (loginHint.map { [URLQueryItem(name: "login_hint", value: $0)] } ?? [])
        let url = components.url!
        onURL(url)
        NSWorkspace.shared.open(url)

        let callback: (code: String, state: String)
        do {
            callback = try await withCheckedThrowingContinuation { continuation in self.continuation = continuation }
        } catch {
            stop()
            throw error
        }
        stop()
        guard callback.state == state else { throw Failure.stateMismatch }

        struct TokenResponse: Decodable {
            var accessToken: String
            var refreshToken: String?
            var idToken: String?
            var expiresIn: Double?
        }
        // The app carries more than one secret for its client; the code exchange tells us which is right.
        var token: TokenResponse?
        var failure: Error?
        for candidate in clients {
            do {
                token = try await HTTP.postForm(GeminiProvider.tokenURL, form: [
                    "code": callback.code,
                    "client_id": candidate.id,
                    "client_secret": candidate.secret,
                    "redirect_uri": redirect,
                    "grant_type": "authorization_code",
                    "code_verifier": verifier,
                ])
                break
            } catch ProviderError.http(401, let body) where body.contains("invalid_client") {
                failure = ProviderError.http(401, body)
            } catch ProviderError.http(400, let body) where body.contains("invalid_client") {
                failure = ProviderError.http(400, body)
            } catch {
                throw Failure.exchange(error.localizedDescription)
            }
        }
        guard let token else { throw Failure.exchange(failure?.localizedDescription ?? "no client secret was accepted") }
        guard let refresh = token.refreshToken else { throw Failure.exchange("no refresh token came back") }

        struct UserInfo: Decodable { var email: String? }
        let info: UserInfo? = try? await HTTP.get("https://www.googleapis.com/oauth2/v2/userinfo", headers: ["Authorization": "Bearer \(token.accessToken)"])
        guard let email = info?.email ?? token.idToken.flatMap({ JWT.claims($0)?["email"] as? String }) else { throw Failure.noEmail }

        return Tokens(accessToken: token.accessToken, refreshToken: refresh, idToken: token.idToken,
                      expiresAt: .now.addingTimeInterval(token.expiresIn ?? 3600), email: email)
    }

    func cancel() {
        continuation?.resume(throwing: Failure.cancelled)
        continuation = nil
        stop()
    }

    // MARK: - Loopback

    private func listen() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                Task { @MainActor in self?.handle(request: request, on: connection) }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            // The handler fires for every state change; only the first ready/failed may resume.
            let gate = ResumeGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case let .failed(error):
                    if gate.claim() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: .main)
        }
    }

    /// One HTTP request: the redirect from Google. Answer with a hop to Google's own result page, then finish.
    private func handle(request: String, on connection: NWConnection) {
        let line = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let query = URLComponents(string: "http://localhost\(path)")?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        let ok = path.hasPrefix("/oauth2callback") && value("error") == nil && value("code") != nil
        let response = "HTTP/1.1 302 Found\r\nLocation: \(ok ? Self.successURL : Self.failureURL)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

        guard path.hasPrefix("/oauth2callback") else { return }
        if let error = value("error") {
            continuation?.resume(throwing: Failure.denied(value("error_description") ?? error))
        } else if let code = value("code") {
            continuation?.resume(returning: (code, value("state") ?? ""))
        } else {
            continuation?.resume(throwing: Failure.denied("no code in the callback"))
        }
        continuation = nil
    }

    private func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func random(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// A once-only latch for a continuation resumed from a callback that may fire more than once.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
