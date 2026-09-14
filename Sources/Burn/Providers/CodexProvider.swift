import Foundation

/// The ChatGPT account, seen through Codex: `~/.codex/auth.json` holds the ChatGPT OAuth token, and the Codex usage
/// endpoint reports the 5-hour and weekly windows for that plan. ChatGPT's chat-side message caps are not exposed
/// anywhere readable, so this card is explicitly the Codex quota.
///
/// Codex rotates the token whenever it runs, but on a Mac where Codex lives inside the ChatGPT app that can be days
/// apart, so this provider refreshes ahead of expiry the way the CLI does (`codex-rs/login`: a JSON refresh grant
/// against auth.openai.com with the client that issued the token) and writes the new tokens back for it.
struct CodexProvider: Provider {
    let id = ProviderID.codex

    static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    static let tokenURL = "https://auth.openai.com/oauth/token"
    /// The Codex CLI's OAuth client; the token's own `client_id` claim is preferred when present.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    static var authFile: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("auth.json")
    }

    func fetch() async -> [AccountSnapshot] {
        do {
            var auth = try Auth(file: Self.authFile)
            if auth.isExpiring { auth = try await Self.refresh(auth) }
            do {
                return [try await Self.load(auth)]
            } catch ProviderError.http(401, _), ProviderError.http(403, _) {
                auth = try await Self.refresh(auth)
                return [try await Self.load(auth)]
            }
        } catch {
            return [Self.problemCard(error)]
        }
    }

    private static func load(_ auth: Auth) async throws -> AccountSnapshot {
        let headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "ChatGPT-Account-Id": auth.accountID,
            "User-Agent": "codex_cli_rs",
        ]
        let usage: UsageResponse = try await HTTP.get(usageURL, headers: headers)
        return snapshot(usage, auth: auth)
    }

    // MARK: - Refresh

    private static func refresh(_ auth: Auth) async throws -> Auth {
        struct TokenResponse: Decodable {
            var idToken: String?
            var accessToken: String?
            var refreshToken: String?
        }
        let token: TokenResponse
        do {
            token = try await HTTP.postJSON(tokenURL, body: [
                "client_id": auth.clientID,
                "grant_type": "refresh_token",
                "refresh_token": auth.refreshToken,
            ])
        } catch ProviderError.http(400, _), ProviderError.http(401, _) {
            // invalid_grant, or an expired / reused / revoked refresh token: the sign-in is gone.
            throw ProviderError.notSignedIn("The ChatGPT sign-in can't be renewed any more")
        }
        var updated = auth
        if let access = token.accessToken { updated.accessToken = access }
        if let refreshToken = token.refreshToken { updated.refreshToken = refreshToken }
        if let idToken = token.idToken { updated.idToken = idToken }
        updated.expiresAt = (JWT.claims(updated.accessToken)?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .now.addingTimeInterval(3600)
        try updated.write(to: authFile)
        Log.write("codex: token refreshed, expires \(updated.expiresAt.formatted(.iso8601))")
        return updated
    }

    private static func snapshot(_ usage: UsageResponse, auth: Auth) -> AccountSnapshot {
        var windows: [UsageWindow] = []
        if let w = usage.rateLimit?.primaryWindow {
            var detail: String?
            if let credits = usage.rateLimitResetCredits?.availableCount, credits > 0 {
                detail = credits == 1 ? "1 reset credit" : "\(credits) reset credits"
            }
            windows.append(window(w, id: "session", kind: .session, title: "Session", detail: detail))
        }
        if let w = usage.rateLimit?.secondaryWindow {
            windows.append(window(w, id: "weekly", kind: .weekly, title: "Weekly", detail: nil))
        }
        for extra in usage.additionalRateLimits ?? [] {
            guard let w = extra.rateLimit?.primaryWindow else { continue }
            let name = extra.normalModelSlug ?? extra.limitName ?? "Model"
            windows.append(window(w, id: "extra:\(name)", kind: .model, title: name, detail: nil))
        }
        if let credits = usage.credits, credits.hasCredits == true, let balance = credits.balance, let value = Double(balance) {
            windows.append(UsageWindow(id: "credits", kind: .spend, title: "Credits", usedPercent: 0, resetsAt: nil,
                                       windowSeconds: nil, detail: String(format: "$%.2f left", value)))
        }

        let plan = (usage.planType ?? auth.planType ?? "").capitalized
        return AccountSnapshot(
            id: "codex:\(auth.accountID)", providerID: .codex,
            label: "ChatGPT",
            subtitle: plan.isEmpty ? "Codex quota" : "\(plan) · Codex quota",
            identity: usage.email,
            windows: windows, fetchedAt: .now, problem: nil)
    }

    private static func window(_ w: UsageResponse.Window, id: String, kind: UsageWindow.Kind, title: String, detail: String?) -> UsageWindow {
        UsageWindow(id: id, kind: kind, title: title,
                    usedPercent: w.usedPercent ?? 0,
                    resetsAt: w.resetAt.map { Date(timeIntervalSince1970: $0) },
                    windowSeconds: w.limitWindowSeconds, detail: detail)
    }

    /// The ChatGPT desktop app bundles Codex and keeps `auth.json` fresh; where it is installed, it is the fix.
    static let chatGPTApp: (bundleID: String, name: String)? = {
        FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app") ? ("com.openai.chat", "ChatGPT") : nil
    }()

    private static func problemCard(_ error: Error) -> AccountSnapshot {
        let problem: AccountProblem
        let open = chatGPTApp.map { AccountProblem.Action.openApp(bundleID: $0.bundleID, name: $0.name) }
        switch error {
        case let ProviderError.notSignedIn(message):
            let expired = message.contains("renewed")
            problem = AccountProblem(kind: .signedOut, title: expired ? "Session expired" : "Codex isn't signed in",
                                     hint: open == nil ? "Sign in with your ChatGPT account once." : "Sign in to Codex in the ChatGPT app once.",
                                     command: open == nil ? "codex login" : nil, action: open)
        case ProviderError.http(401, _), ProviderError.http(403, _):
            problem = AccountProblem(kind: .signedOut, title: "Session expired",
                                     hint: open == nil ? "Sign in to Codex again." : "Sign in to Codex again in the ChatGPT app.",
                                     command: open == nil ? "codex login" : nil, action: open)
        case ProviderError.http(429, _):
            problem = AccountProblem(kind: .throttled, title: "Rate limited", hint: "OpenAI is throttling usage lookups. Backing off.", command: nil)
        case let ProviderError.http(code, _):
            problem = AccountProblem(kind: .error, title: "HTTP \(code)", hint: "The Codex usage endpoint answered with an error.", command: nil)
        case let ProviderError.decoding(msg):
            problem = AccountProblem(kind: .error, title: "Unexpected response", hint: msg, command: nil)
        default:
            problem = AccountProblem(kind: .error, title: "Couldn't reach OpenAI", hint: error.localizedDescription, command: nil)
        }
        return AccountSnapshot(id: "codex:unknown", providerID: .codex, label: "ChatGPT", subtitle: "Codex quota",
                               windows: [], fetchedAt: .now, problem: problem)
    }

    // MARK: - auth.json (kept whole for the write-back)

    private struct Auth {
        var raw: [String: Any]
        var accessToken: String
        var refreshToken: String
        var idToken: String?
        var expiresAt: Date
        var clientID: String
        var accountID: String
        var planType: String?

        init(file: URL) throws {
            guard let data = FileManager.default.contents(atPath: file.path) else {
                throw ProviderError.notSignedIn("No Codex auth file at \(file.path)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = json["tokens"] as? [String: Any],
                  let access = tokens["access_token"] as? String else {
                throw ProviderError.notSignedIn("Codex is signed in with an API key, not a ChatGPT account")
            }
            raw = json
            accessToken = access
            refreshToken = tokens["refresh_token"] as? String ?? ""
            idToken = tokens["id_token"] as? String
            let claims = JWT.claims(access)
            let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
            accountID = (tokens["account_id"] as? String) ?? (auth?["chatgpt_account_id"] as? String) ?? ""
            planType = auth?["chatgpt_plan_type"] as? String
            clientID = claims?["client_id"] as? String ?? CodexProvider.clientID
            expiresAt = (claims?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantFuture
        }

        /// Ten minutes of margin, so a poll never races the expiry; no refresh token means nothing to renew with.
        /// `BURN_FORCE_RENEW=1` in the environment renews regardless — for exercising the path on demand.
        var isExpiring: Bool {
            guard !refreshToken.isEmpty else { return false }
            if ProcessInfo.processInfo.environment["BURN_FORCE_RENEW"] == "1" { return true }
            return expiresAt.timeIntervalSinceNow < 10 * 60
        }

        func write(to file: URL) throws {
            var json = raw
            var tokens = json["tokens"] as? [String: Any] ?? [:]
            tokens["access_token"] = accessToken
            tokens["refresh_token"] = refreshToken
            if let idToken { tokens["id_token"] = idToken }
            json["tokens"] = tokens
            json["last_refresh"] = ISO8601.string(.now)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
        }
    }

    // MARK: - Response shape

    private struct UsageResponse: Decodable {
        struct Window: Decodable { var usedPercent: Double?; var limitWindowSeconds: Int?; var resetAfterSeconds: Double?; var resetAt: Double? }
        struct RateLimit: Decodable { var primaryWindow: Window?; var secondaryWindow: Window? }
        struct Additional: Decodable { var limitName: String?; var rateLimit: RateLimit?; var normalModelSlug: String? }
        struct Credits: Decodable { var hasCredits: Bool?; var unlimited: Bool?; var balance: String? }
        struct ResetCredits: Decodable { var availableCount: Int? }
        var email: String?
        var planType: String?
        var rateLimit: RateLimit?
        var additionalRateLimits: [Additional]?
        var credits: Credits?
        var rateLimitResetCredits: ResetCredits?
    }
}

enum JWT {
    /// Payload of a JWS compact token, undecoded and unverified — enough to read plan and expiry claims locally.
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
