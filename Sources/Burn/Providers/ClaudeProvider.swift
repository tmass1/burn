import Foundation

/// Claude Pro/Max/Team accounts, read from the Keychain items Claude Code maintains — one per `CLAUDE_CONFIG_DIR`.
/// The default profile is `Claude Code-credentials`; other profiles are `Claude Code-credentials-<hash>`.
/// Several items often point at the same account (worktree and desktop sessions), so results are deduped by
/// organization + account before they become cards.
struct ClaudeProvider: Provider {
    let id = ProviderID.claude

    static let servicePrefix = "Claude Code-credentials"
    static let defaultService = "Claude Code-credentials"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = "https://platform.claude.com/v1/oauth/token"
    static let usageURL = "https://api.anthropic.com/api/oauth/usage"
    static let profileURL = "https://api.anthropic.com/api/oauth/profile"

    /// Anthropic's OAuth endpoints treat clients they don't recognise as strangers — the token endpoint answers a
    /// perfectly good refresh with 429 — so Burn identifies itself exactly as the installed CLI does.
    static let userAgent: String = {
        let pkg = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/package.json"
        if let data = FileManager.default.contents(atPath: pkg),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = json["version"] as? String {
            return "claude-cli/\(version) (external, cli)"
        }
        return "claude-cli/2.1.269 (external, cli)"
    }()

    static var headers: [String: String] {
        ["anthropic-beta": "oauth-2025-04-20", "User-Agent": userAgent]
    }

    func fetch() async -> [AccountSnapshot] {
        let allItems = Keychain.items(withServicePrefix: Self.servicePrefix)
        let removed = Preferences.removedKeys()
        let remembered = KnownAccounts.load()
        // A removed account's item is left alone entirely — not even a token refresh on its behalf.
        let items = allItems.filter { item in remembered[item.service].map { !removed.contains($0.id) } ?? true }
        if items.isEmpty, !allItems.isEmpty { return [] }
        guard !items.isEmpty else {
            return [AccountSnapshot(
                id: "claude:none", providerID: .claude, label: "Claude", subtitle: "Not signed in",
                windows: [], fetchedAt: .now,
                problem: AccountProblem(kind: .signedOut, title: "No Claude sign-in found",
                                        hint: "Sign in to Claude Code once and this card fills itself in.",
                                        command: "claude auth login", action: .signIn(.claude(profile: nil))))]
        }

        let results = await withTaskGroup(of: (Keychain.Item, Result<AccountSnapshot, Error>).self) { group in
            for item in items {
                group.addTask {
                    // An item Anthropic refused recently waits its turn; the others poll as usual.
                    if let hold = await RetrySchedule.shared.hold(for: item.service) {
                        return (item, .failure(ProviderError.backingOff(until: hold.until, last: hold.problem)))
                    }
                    let result = await Result { try await Self.fetchOne(item: item) }
                    if case .success = result { await RetrySchedule.shared.succeeded(item.service) }
                    return (item, result)
                }
            }
            var out: [(Keychain.Item, Result<AccountSnapshot, Error>)] = []
            for await r in group { out.append(r) }
            return out
        }

        // One card per account. A duplicate item that fails is dropped when its twin succeeded; an item we have never
        // identified and cannot read is dropped too (a stale worktree profile is not something the user can act on).
        var cards: [String: AccountSnapshot] = [:]
        var order: [String] = []
        let known = KnownAccounts.load()
        for (item, result) in results {
            let suffix = item.service.dropFirst(Self.servicePrefix.count)
            switch result {
            case let .success(snapshot):
                Log.write("claude item \(suffix.isEmpty ? "(default)" : String(suffix)): \(snapshot.identity ?? "?") · \(snapshot.label)")
                KnownAccounts.remember(service: item.service, id: snapshot.id, label: snapshot.label, subtitle: snapshot.subtitle)
                if let existing = cards[snapshot.id], existing.problem == nil { continue }
                if cards[snapshot.id] == nil { order.append(snapshot.id) }
                cards[snapshot.id] = snapshot
            case let .failure(error):
                let remembered = known[item.service]
                let isDefault = item.service == Self.defaultService
                if case ProviderError.notSignedIn = error, remembered == nil, !isDefault {
                    // Connector-only or abandoned worktree profile: nothing to show and nothing the user can do.
                    Log.once("claude-skip:\(item.service)", "claude item \(suffix): no sign-in; ignoring")
                    continue
                }
                if case ProviderError.backingOff = error {} else {
                    Log.write("claude item \(suffix.isEmpty ? "(default)" : String(suffix)): \(error.localizedDescription)")
                }
                guard remembered != nil || isDefault else { continue }
                let id = remembered?.id ?? "claude:service:\(item.service)"
                if cards[id] != nil { continue }
                let problem = Self.problem(for: error, isDefault: isDefault, service: item.service)
                if problem.kind == .throttled, !Self.isBackingOff(error) {
                    let until = await RetrySchedule.shared.failed(item.service, problem: problem)
                    Log.write("claude item \(suffix.isEmpty ? "(default)" : String(suffix)): retrying at \(until.formatted(date: .omitted, time: .shortened))")
                }
                order.append(id)
                cards[id] = AccountSnapshot(
                    id: id, providerID: .claude,
                    label: remembered?.label ?? "Claude",
                    subtitle: remembered?.subtitle ?? (isDefault ? "Default profile" : "Profile"),
                    windows: [], fetchedAt: .now,
                    problem: problem)
            }
        }
        return order.compactMap { cards[$0] }
    }

    private static func isBackingOff(_ error: Error) -> Bool {
        if case ProviderError.backingOff = error { return true }
        return false
    }

    // MARK: - One keychain item

    private static func fetchOne(item: Keychain.Item) async throws -> AccountSnapshot {
        var credentials = try Credentials(service: item.service)
        if credentials.isExpired {
            credentials = try await refresh(credentials, item: item)
        }
        do {
            return try await load(credentials)
        } catch ProviderError.http(401, _) {
            credentials = try await refresh(credentials, item: item)
            return try await load(credentials)
        }
    }

    private static func load(_ credentials: Credentials) async throws -> AccountSnapshot {
        var headers = Self.headers
        headers["Authorization"] = "Bearer \(credentials.accessToken)"
        async let usage: UsageResponse = HTTP.get(usageURL, headers: headers)
        async let profile: ProfileResponse = HTTP.get(profileURL, headers: headers)
        return try await snapshot(usage: usage, profile: profile, credentials: credentials)
    }

    private static func snapshot(usage: UsageResponse, profile: ProfileResponse, credentials: Credentials) -> AccountSnapshot {
        let org = profile.organization
        let isOrg = ["claude_team", "claude_enterprise"].contains(org.organizationType ?? "")
        let label = isOrg ? (org.name ?? "Team") : "Personal"

        var planParts: [String] = []
        if isOrg { planParts.append(org.organizationType == "claude_enterprise" ? "Enterprise" : "Team") }
        if let tier = Self.tierName(org.rateLimitTier ?? credentials.rateLimitTier, subscription: credentials.subscriptionType) {
            planParts.append(tier)
        }

        var windows: [UsageWindow] = []
        if let w = usage.fiveHour, let pct = w.utilization {
            windows.append(UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: pct,
                                       resetsAt: w.resetsAt, windowSeconds: 5 * 3600, detail: nil))
        }
        if let w = usage.sevenDay, let pct = w.utilization {
            windows.append(UsageWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: pct,
                                       resetsAt: w.resetsAt, windowSeconds: 7 * 86400, detail: nil))
        }
        for limit in usage.limits ?? [] where limit.kind == "weekly_scoped" {
            guard let pct = limit.percent else { continue }
            let model = limit.scope?.model?.displayName ?? "Model"
            windows.append(UsageWindow(id: "weekly:\(model)", kind: .model, title: model, usedPercent: pct,
                                       resetsAt: limit.resetsAt, windowSeconds: 7 * 86400, detail: nil))
        }
        if let spend = usage.spend, spend.enabled == true, let limit = spend.limit, limit.amountMinor > 0 {
            let used = spend.used?.amountMinor ?? 0
            let pct = spend.percent ?? (Double(used) / Double(limit.amountMinor) * 100)
            windows.append(UsageWindow(id: "spend", kind: .spend, title: "Extra usage", usedPercent: pct,
                                       resetsAt: nil, windowSeconds: nil,
                                       detail: "\(money(used, limit.exponent)) of \(money(limit.amountMinor, limit.exponent))"))
        }

        return AccountSnapshot(
            id: "claude:\(org.uuid ?? "org"):\(profile.account.uuid ?? "acct")",
            providerID: .claude, label: label,
            subtitle: planParts.joined(separator: " · "),
            identity: profile.account.email,
            windows: windows, fetchedAt: .now, problem: nil)
    }

    private static func tierName(_ tier: String?, subscription: String?) -> String? {
        let t = (tier ?? "").lowercased()
        if t.contains("max_20x") { return "Max 20×" }
        if t.contains("max_5x") { return "Max 5×" }
        if t.contains("max") { return "Max" }
        if t.contains("pro") { return "Pro" }
        switch subscription?.lowercased() {
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return nil
        default: return subscription?.capitalized
        }
    }

    private static func money(_ minor: Int, _ exponent: Int?) -> String {
        let value = Double(minor) / pow(10, Double(exponent ?? 2))
        return value == value.rounded() ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    private static func problem(for error: Error, isDefault: Bool, service: String) -> AccountProblem {
        // Burn can sign the default profile in itself, and any profile it created; other profiles belong to
        // whatever set them up (a worktree, another app) and get the generic hint.
        let target: LoginTarget? = isDefault ? .claude(profile: nil)
            : ClaudeProfiles.profile(forService: service).map { .claude(profile: $0.path) }
        let hint = target == nil ? "Sign in again in the profile this account uses." : "Sign in once and this card fills itself in."
        switch error {
        case ProviderError.notSignedIn:
            return AccountProblem(kind: .signedOut, title: "Not signed in", hint: hint,
                                  command: target?.command, action: target.map { .signIn($0) })
        case ProviderError.http(401, _), ProviderError.http(400, _):
            return AccountProblem(kind: .signedOut, title: "Session expired", hint: hint,
                                  command: target?.command, action: target.map { .signIn($0) })
        case ProviderError.http(429, _):
            return AccountProblem(kind: .throttled, title: "Rate limited", hint: "Anthropic is throttling usage lookups. Backing off.", command: nil)
        case ProviderError.refreshRejected(429, _):
            // The sign-in is fine; Anthropic's token endpoint wouldn't renew it just now.
            return AccountProblem(kind: .throttled, title: "Couldn't renew the sign-in",
                                  hint: "Anthropic's token endpoint answered 429 to the refresh. Burn keeps trying; if it never clears, sign in again.",
                                  command: target?.command, action: target.map { .signIn($0) })
        case ProviderError.refreshRejected:
            return AccountProblem(kind: .signedOut, title: "Session expired", hint: hint,
                                  command: target?.command, action: target.map { .signIn($0) })
        case let ProviderError.backingOff(until, last):
            var waiting = last
            waiting.hint = "\(last.hint) Retrying at \(until.formatted(date: .omitted, time: .shortened))."
            return waiting
        case let ProviderError.http(code, _):
            return AccountProblem(kind: .error, title: "HTTP \(code)", hint: "Anthropic's usage endpoint answered with an error.", command: nil)
        case let ProviderError.decoding(msg):
            return AccountProblem(kind: .error, title: "Unexpected response", hint: msg, command: nil)
        default:
            return AccountProblem(kind: .error, title: "Couldn't reach Anthropic", hint: error.localizedDescription, command: nil)
        }
    }

    // MARK: - Refresh

    /// Same grant Claude Code performs; the new tokens are written back so the CLI and Burn stay in step.
    private static func refresh(_ credentials: Credentials, item: Keychain.Item) async throws -> Credentials {
        struct TokenResponse: Decodable {
            var accessToken: String
            var refreshToken: String?
            var expiresIn: Double?
        }
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": clientID,
            "scope": credentials.scopes.joined(separator: " "),
        ]
        let token: TokenResponse
        do {
            token = try await HTTP.postJSON(tokenURL, body: body, headers: ["User-Agent": userAgent])
        } catch let ProviderError.http(code, body) {
            throw ProviderError.refreshRejected(code, body)
        }
        let suffix = item.service.dropFirst(servicePrefix.count)
        Log.write("claude item \(suffix.isEmpty ? "(default)" : String(suffix)): renewed the sign-in")
        var updated = credentials
        updated.accessToken = token.accessToken
        if let r = token.refreshToken { updated.refreshToken = r }
        updated.expiresAtMS = (Date.now.timeIntervalSince1970 + (token.expiresIn ?? 3600)) * 1000
        try updated.write(service: item.service, account: item.account.isEmpty ? NSUserName() : item.account)
        return updated
    }

    // MARK: - Credential shape (kept as a dictionary so unrelated keys survive a write-back)

    private struct Credentials {
        var raw: [String: Any]
        var accessToken: String
        var refreshToken: String
        var expiresAtMS: Double
        var scopes: [String]
        var subscriptionType: String?
        var rateLimitTier: String?

        init(service: String) throws {
            let text = try Keychain.readString(service: service)
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProviderError.decoding("Keychain item is not a Claude Code credential")
            }
            // The same item also holds MCP connector tokens (`mcpOAuth`); a profile with only those was never signed in.
            guard let oauth = json["claudeAiOauth"] as? [String: Any],
                  let access = oauth["accessToken"] as? String,
                  let refresh = oauth["refreshToken"] as? String else {
                throw ProviderError.notSignedIn("No Claude sign-in in this profile")
            }
            raw = json
            accessToken = access
            refreshToken = refresh
            expiresAtMS = (oauth["expiresAt"] as? Double) ?? 0
            scopes = oauth["scopes"] as? [String] ?? ["user:inference", "user:profile"]
            subscriptionType = oauth["subscriptionType"] as? String
            rateLimitTier = oauth["rateLimitTier"] as? String
        }

        var isExpired: Bool { expiresAtMS / 1000 < Date.now.timeIntervalSince1970 + 60 }

        func write(service: String, account: String) throws {
            var json = raw
            var oauth = json["claudeAiOauth"] as? [String: Any] ?? [:]
            oauth["accessToken"] = accessToken
            oauth["refreshToken"] = refreshToken
            oauth["expiresAt"] = Int(expiresAtMS)
            json["claudeAiOauth"] = oauth
            let data = try JSONSerialization.data(withJSONObject: json)
            try Keychain.write(service: service, account: account, string: String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: - Response shapes (only the fields the cards use)

    private struct UsageResponse: Decodable {
        struct Window: Decodable { var utilization: Double?; var resetsAt: Date? }
        struct Limit: Decodable {
            struct Scope: Decodable { struct Model: Decodable { var displayName: String? }; var model: Model? }
            var kind: String; var percent: Double?; var resetsAt: Date?; var scope: Scope?; var isActive: Bool?
        }
        struct Money: Decodable { var amountMinor: Int; var exponent: Int? }
        struct Spend: Decodable { var used: Money?; var limit: Money?; var percent: Double?; var enabled: Bool? }
        var fiveHour: Window?
        var sevenDay: Window?
        var limits: [Limit]?
        var spend: Spend?
    }

    private struct ProfileResponse: Decodable {
        struct Account: Decodable { var uuid: String?; var email: String?; var displayName: String? }
        struct Organization: Decodable { var uuid: String?; var name: String?; var organizationType: String?; var rateLimitTier: String? }
        var account: Account
        var organization: Organization
    }
}

/// Service name → account identity, so a profile that stops working still shows up with its name and a fix.
enum KnownAccounts {
    struct Entry: Codable { var id: String; var label: String; var subtitle: String }
    private static let key = "knownClaudeAccounts"

    static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return map
    }

    static func remember(service: String, id: String, label: String, subtitle: String) {
        var map = load()
        map[service] = Entry(id: id, label: label, subtitle: subtitle)
        if let data = try? JSONEncoder().encode(map) { UserDefaults.standard.set(data, forKey: key) }
    }
}

extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
