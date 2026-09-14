import Foundation

/// GitHub Copilot, through a GitHub sign-in already on this Mac — the Copilot editor config, the GitHub CLI's
/// hosts file, or the CLI's keychain item — and the internal endpoint Copilot's own clients ask for their quota:
/// the monthly premium-request allotment (plus chat and completions where a plan meters them). No token of ours,
/// nothing refreshed, nothing written. Endpoint and headers after openusage (MIT).
struct CopilotProvider: Provider {
    let id = ProviderID.copilot

    static let usageURL = "https://api.github.com/copilot_internal/user"
    static let editorApps = NSString(string: "~/.config/github-copilot/apps.json").expandingTildeInPath
    static let editorHosts = NSString(string: "~/.config/github-copilot/hosts.json").expandingTildeInPath
    static let ghHosts = NSString(string: "~/.config/gh/hosts.yml").expandingTildeInPath
    static let ghKeychainService = "gh:github.com"

    func fetch() async -> [AccountSnapshot] {
        do {
            let auth = try Auth()
            let headers = [
                "Authorization": "token \(auth.token)",
                "Editor-Version": "vscode/1.96.2",
                "Editor-Plugin-Version": "copilot-chat/0.26.7",
                "User-Agent": "GitHubCopilotChat/0.26.7",
                "X-Github-Api-Version": "2025-04-01",
            ]
            let usage: UsageResponse = try await HTTP.get(Self.usageURL, headers: headers)
            let snapshot = try Self.snapshot(usage, auth: auth)
            Log.write("copilot: \(snapshot.identity ?? "?") · \(snapshot.subtitle) · \(snapshot.windows.count) windows")
            return [snapshot]
        } catch {
            Log.write("copilot: \(error.localizedDescription)")
            return [Self.problemCard(error)]
        }
    }

    private static func snapshot(_ usage: UsageResponse, auth: Auth) throws -> AccountSnapshot {
        let reset = usage.quotaResetDate.flatMap(day) ?? usage.limitedUserResetDate.flatMap(day)
        var windows: [UsageWindow] = []
        // Paid plans meter a monthly pool of premium requests; Copilot Free meters chats and completions instead.
        // Whichever buckets carry a real allotment are the pools; anything else on a paid plan is secondary.
        if let premium = usage.quotaSnapshots?.premiumInteractions, let percent = usedPercent(premium) {
            var detail: String?
            if premium.overagePermitted == true, let extra = premium.overageCount, extra > 0 {
                detail = "\(Int(extra)) over the allotment"
            }
            windows.append(UsageWindow(id: "premium", kind: .monthly, title: "Premium", usedPercent: percent,
                                       resetsAt: reset, windowSeconds: 30 * 86400, detail: detail))
        }
        let secondaryKind: UsageWindow.Kind = windows.isEmpty ? .monthly : .model
        for (id, title, bucket) in [("chat", "Chat", usage.quotaSnapshots?.chat), ("completions", "Code", usage.quotaSnapshots?.completions)] {
            guard let bucket, let percent = usedPercent(bucket) else { continue }
            windows.append(UsageWindow(id: id, kind: secondaryKind, title: title, usedPercent: percent,
                                       resetsAt: reset, windowSeconds: 30 * 86400,
                                       detail: bucket.entitlement.map { "\(Int(bucket.remaining ?? 0)) of \(Int($0)) left" }))
        }
        guard !windows.isEmpty else {
            throw ProviderError.decoding(usage.copilotPlan == nil ? "No Copilot on this GitHub account" : "Copilot reported no metered allotment for this plan")
        }
        let plan = planLabel(sku: usage.accessTypeSku, plan: usage.copilotPlan)
        let pool = windows.first?.id == "premium" ? "premium requests" : "monthly chats"
        return AccountSnapshot(
            id: "copilot:\(auth.user ?? "account")", providerID: .copilot,
            label: "Copilot",
            subtitle: plan.isEmpty ? pool.capitalized : "\(plan) · \(pool)",
            identity: auth.user.map { "@\($0)" },
            windows: windows, fetchedAt: .now, problem: nil)
    }

    /// GitHub's SKU is the honest one: `free_limited_copilot` is Copilot Free even when `copilot_plan` says individual.
    private static func planLabel(sku: String?, plan: String?) -> String {
        if sku?.contains("free") == true { return "Free" }
        switch plan?.lowercased() {
        case "individual": return "Pro"
        case "individual_plus", "pro_plus": return "Pro+"
        case let other?: return other.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: return ""
        }
    }

    /// Nil for an unmetered bucket: GitHub's `-1` sentinel, the `unlimited` flag, or no allotment at all.
    private static func usedPercent(_ bucket: UsageResponse.Bucket) -> Double? {
        if bucket.unlimited == true || bucket.entitlement == -1 || bucket.remaining == -1 { return nil }
        if bucket.entitlement == 0 { return nil }
        if let remaining = bucket.percentRemaining { return min(100, max(0, 100 - remaining)) }
        if let entitlement = bucket.entitlement, entitlement > 0, let remaining = bucket.remaining {
            return min(100, max(0, 100 - remaining / entitlement * 100))
        }
        return nil
    }

    /// "2026-10-01" (a day, UTC) or a full timestamp.
    private static func day(_ text: String) -> Date? {
        if let date = ISO8601.parseLenient(text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    private static func problemCard(_ error: Error) -> AccountSnapshot {
        let problem: AccountProblem
        switch error {
        case ProviderError.notSignedIn:
            problem = AccountProblem(kind: .signedOut, title: "No GitHub sign-in found",
                                     hint: "Sign in with the GitHub CLI once; this card takes over.", command: "gh auth login")
        case ProviderError.http(401, _), ProviderError.http(403, _):
            problem = AccountProblem(kind: .signedOut, title: "GitHub sign-in expired",
                                     hint: "Sign in with the GitHub CLI again.", command: "gh auth login")
        case ProviderError.http(404, _):
            problem = AccountProblem(kind: .error, title: "No Copilot on this account", hint: "GitHub has no Copilot plan for this sign-in.", command: nil)
        case ProviderError.http(429, _):
            problem = AccountProblem(kind: .throttled, title: "Rate limited", hint: "GitHub is throttling usage lookups. Backing off.", command: nil)
        case let ProviderError.http(code, _):
            problem = AccountProblem(kind: .error, title: "HTTP \(code)", hint: "GitHub's Copilot endpoint answered with an error.", command: nil)
        case let ProviderError.decoding(msg):
            problem = AccountProblem(kind: .error, title: "Unexpected response", hint: msg, command: nil)
        default:
            problem = AccountProblem(kind: .error, title: "Couldn't reach GitHub", hint: error.localizedDescription, command: nil)
        }
        return AccountSnapshot(id: "copilot:unknown", providerID: .copilot, label: "Copilot", subtitle: "Premium requests",
                               windows: [], fetchedAt: .now, problem: problem)
    }

    // MARK: - A GitHub token, from wherever one already is

    private struct Auth {
        var token: String
        var user: String?

        init() throws {
            let user = Self.ghUser()
            if let token = Self.editorToken() { self.token = token; self.user = user; return }
            if let token = Self.yamlValue(at: CopilotProvider.ghHosts, key: "oauth_token") { self.token = token; self.user = user; return }
            if let token = Self.ghKeychainToken(account: user) { self.token = token; self.user = user; return }
            throw ProviderError.notSignedIn("No GitHub sign-in on this Mac")
        }

        /// `apps.json` (`"github.com:<appId>"` keys) or the older `hosts.json` (`"github.com"`), each value carrying `oauth_token`.
        private static func editorToken() -> String? {
            for path in [CopilotProvider.editorApps, CopilotProvider.editorHosts] {
                guard let data = FileManager.default.contents(atPath: path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                for (host, value) in json where host == "github.com" || host.hasPrefix("github.com:") {
                    if let token = (value as? [String: Any])?["oauth_token"] as? String, !token.isEmpty { return token }
                }
            }
            return nil
        }

        private static func ghUser() -> String? { yamlValue(at: CopilotProvider.ghHosts, key: "user") }

        /// An indented `key: value` inside the `github.com:` block of the GitHub CLI's hosts file.
        private static func yamlValue(at path: String, key: String) -> String? {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            var inHost = false
            for line in text.split(separator: "\n") {
                if !line.hasPrefix(" ") { inHost = line.trimmingCharacters(in: .whitespaces) == "github.com:"; continue }
                guard inHost else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("\(key):") {
                    let value = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { return value }
                }
            }
            return nil
        }

        /// The CLI's keychain item, written by go-keyring: base64 behind a `go-keyring-base64:` prefix.
        private static func ghKeychainToken(account: String?) -> String? {
            let raw = (account.flatMap { try? Keychain.readString(service: CopilotProvider.ghKeychainService, account: $0) })
                ?? (try? Keychain.readString(service: CopilotProvider.ghKeychainService))
            guard let raw else { return nil }
            let prefix = "go-keyring-base64:"
            if raw.hasPrefix(prefix), let data = Data(base64Encoded: String(raw.dropFirst(prefix.count))) {
                let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return token.isEmpty ? nil : token
            }
            return raw.isEmpty ? nil : raw
        }
    }

    // MARK: - Response shape

    private struct UsageResponse: Decodable {
        struct Bucket: Decodable {
            var entitlement: Double?
            var remaining: Double?
            var percentRemaining: Double?
            var unlimited: Bool?
            var overagePermitted: Bool?
            var overageCount: Double?
            var creditsUsed: Double?
        }
        struct Snapshots: Decodable {
            var premiumInteractions: Bucket?
            var chat: Bucket?
            var completions: Bucket?
        }
        var copilotPlan: String?
        var accessTypeSku: String?
        var tokenBasedBilling: Bool?
        var quotaResetDate: String?
        var limitedUserResetDate: String?
        var quotaSnapshots: Snapshots?
        var monthlyQuotas: [String: Double]?
        var limitedUserQuotas: [String: Double]?
    }
}
