import Foundation

/// The Grok account, through the same credential the Grok CLI keeps in `~/.grok/auth.json` and the billing endpoint
/// the CLI itself calls. Grok access tokens live six hours, so unlike Codex this provider refreshes on its own
/// (standard OIDC refresh grant against auth.x.ai) and writes the rotated tokens back for the CLI.
struct GrokProvider: Provider {
    let id = ProviderID.grok

    static let billingURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    static let settingsURL = "https://cli-chat-proxy.grok.com/v1/settings"
    static let tokenURL = "https://auth.x.ai/oauth2/token"
    static let weeklyPeriod = "USAGE_PERIOD_TYPE_WEEKLY"

    static var authFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
    }

    func fetch() async -> [AccountSnapshot] {
        do {
            var auth = try Auth(file: Self.authFile)
            if auth.isExpired { auth = try await Self.refresh(auth) }
            do {
                return [try await Self.load(auth)]
            } catch ProviderError.http(401, _) {
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
            "X-XAI-Token-Auth": "xai-grok-cli",
            "User-Agent": "grok-cli",
        ]
        async let billing: BillingResponse = HTTP.get(billingURL, headers: headers)
        // Plan name is decoration; a failure there must not hide the numbers.
        let settings: SettingsResponse? = try? await HTTP.get(settingsURL, headers: headers)
        return snapshot(try await billing, settings: settings, auth: auth)
    }

    private static func snapshot(_ billing: BillingResponse, settings: SettingsResponse?, auth: Auth) -> AccountSnapshot {
        let config = billing.config
        var windows: [UsageWindow] = []
        let period = config?.currentPeriod
        let isWeekly = period?.type == weeklyPeriod
        let seconds = period.flatMap { p -> Int? in
            guard let s = p.start, let e = p.end else { return nil }
            return Int(e.timeIntervalSince(s))
        }
        windows.append(UsageWindow(id: "pool", kind: .weekly, title: isWeekly ? "Weekly" : "Period",
                                   usedPercent: min(100, max(0, config?.creditUsagePercent ?? 0)),
                                   resetsAt: period?.end, windowSeconds: seconds ?? (isWeekly ? 7 * 86400 : nil), detail: nil))
        if let cap = config?.onDemandCap?.val, cap > 0 {
            windows.append(UsageWindow(id: "payg", kind: .spend, title: "Pay as you go", usedPercent: 0, resetsAt: nil,
                                       windowSeconds: nil, detail: String(format: "cap $%.0f", cap)))
        }
        let plan = settings?.subscriptionTierDisplay?.trimmingCharacters(in: .whitespaces) ?? ""
        return AccountSnapshot(
            id: "grok:\(auth.userID ?? auth.email ?? "account")", providerID: .grok,
            label: "Grok",
            subtitle: plan.isEmpty ? "Weekly pool" : "\(plan) · weekly pool",
            identity: auth.email,
            windows: windows, fetchedAt: .now, problem: nil)
    }

    private static func problemCard(_ error: Error) -> AccountSnapshot {
        let problem: AccountProblem
        switch error {
        case ProviderError.notSignedIn, ProviderError.http(400, _), ProviderError.http(401, _), ProviderError.http(403, _):
            problem = AccountProblem(kind: .signedOut, title: "Grok session expired",
                                     hint: "Sign in once and this card takes over.",
                                     command: "grok login", action: .signIn(.grok))
        case ProviderError.http(429, _):
            problem = AccountProblem(kind: .throttled, title: "Rate limited", hint: "xAI is throttling usage lookups. Backing off.", command: nil)
        case let ProviderError.http(code, _):
            problem = AccountProblem(kind: .error, title: "HTTP \(code)", hint: "Grok's billing endpoint answered with an error.", command: nil)
        case let ProviderError.decoding(msg):
            problem = AccountProblem(kind: .error, title: "Unexpected response", hint: msg, command: nil)
        default:
            problem = AccountProblem(kind: .error, title: "Couldn't reach xAI", hint: error.localizedDescription, command: nil)
        }
        return AccountSnapshot(id: "grok:unknown", providerID: .grok, label: "Grok", subtitle: "Weekly pool",
                               windows: [], fetchedAt: .now, problem: problem)
    }

    // MARK: - Refresh

    private static func refresh(_ auth: Auth) async throws -> Auth {
        struct TokenResponse: Decodable {
            var accessToken: String
            var refreshToken: String?
            var idToken: String?
            var expiresIn: Double?
        }
        let token: TokenResponse
        do {
            token = try await HTTP.postForm(tokenURL, form: [
                "grant_type": "refresh_token",
                "refresh_token": auth.refreshToken,
                "client_id": auth.clientID,
            ])
        } catch ProviderError.http(400, _) {
            throw ProviderError.notSignedIn("Grok refresh token is no longer valid")
        }
        var updated = auth
        updated.accessToken = token.accessToken
        if let r = token.refreshToken { updated.refreshToken = r }
        updated.idToken = token.idToken ?? auth.idToken
        updated.expiresAt = Date.now.addingTimeInterval(token.expiresIn ?? 6 * 3600)
        try updated.write(to: authFile)
        return updated
    }

    // MARK: - auth.json (a dictionary keyed "<issuer>::<client_id>", kept whole for the write-back)

    private struct Auth {
        var raw: [String: Any]
        var entryKey: String
        var accessToken: String
        var refreshToken: String
        var idToken: String?
        var expiresAt: Date
        var clientID: String
        var email: String?
        var userID: String?

        init(file: URL) throws {
            guard let data = FileManager.default.contents(atPath: file.path) else {
                throw ProviderError.notSignedIn("No Grok auth file at \(file.path)")
            }
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let entries = json.compactMap { k, v in (v as? [String: Any]).map { (key: k, entry: $0) } }
                .sorted { $0.key < $1.key }
            guard let first = entries.first,
                  let access = first.entry["key"] as? String,
                  let refresh = first.entry["refresh_token"] as? String else {
                throw ProviderError.notSignedIn("Grok auth file has no OAuth entry")
            }
            let (key, entry) = first
            raw = json
            entryKey = key
            accessToken = access
            refreshToken = refresh
            idToken = entry["id_token"] as? String
            clientID = (entry["oidc_client_id"] as? String) ?? key.components(separatedBy: "::").last ?? ""
            email = entry["email"] as? String
            userID = entry["user_id"] as? String
            let claimExp = (JWT.claims(access)?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let fileExp = (entry["expires_at"] as? String).flatMap(ISO8601.parseLenient)
            expiresAt = claimExp ?? fileExp ?? .distantPast
        }

        var isExpired: Bool { expiresAt.timeIntervalSinceNow < 5 * 60 }

        func write(to file: URL) throws {
            var json = raw
            var entry = json[entryKey] as? [String: Any] ?? [:]
            entry["key"] = accessToken
            entry["refresh_token"] = refreshToken
            if let idToken { entry["id_token"] = idToken }
            entry["expires_at"] = ISO8601.string(expiresAt)
            entry["create_time"] = ISO8601.string(.now)
            json[entryKey] = entry
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
        }
    }

    // MARK: - Response shapes

    private struct BillingResponse: Decodable {
        struct Period: Decodable { var type: String?; var start: Date?; var end: Date? }
        struct Cap: Decodable { var val: Double? }
        struct Config: Decodable { var creditUsagePercent: Double?; var currentPeriod: Period?; var onDemandCap: Cap? }
        var config: Config?
    }

    private struct SettingsResponse: Decodable {
        var subscriptionTierDisplay: String?
    }
}
