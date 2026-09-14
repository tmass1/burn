import Foundation

/// Gemini, the way Google now meters it for individuals: through Antigravity. Google retired the Gemini CLI's free
/// tier ("UNSUPPORTED_CLIENT — migrate to Antigravity"), so this provider speaks to Code Assist as Antigravity does —
/// the app's own OAuth client, read from its installed binary, and `retrieveUserQuotaSummary` for the pools: Gemini
/// 5-hour and weekly, plus the pools for the other models Antigravity offers. Accounts come from a Google sign-in run
/// by Burn (`GeminiAccounts`), or from the Antigravity app's own keychain token when it is signed in. Tokens are
/// refreshed with the same client; Antigravity's keychain item is never written.
struct GeminiProvider: Provider {
    let id = ProviderID.gemini

    static let endpoints = ["https://daily-cloudcode-pa.googleapis.com/v1internal", "https://cloudcode-pa.googleapis.com/v1internal"]
    static let tokenURL = "https://oauth2.googleapis.com/token"
    static let appPath = "/Applications/Antigravity.app"

    /// Antigravity's Google OAuth client, read from the installed app (`Contents/Resources/bin/language_server`).
    /// An installed-app client's secret ships in every copy of the app; Google does not treat it as confidential.
    /// The binary carries two clients and their secrets; the sign-in client is the `1071006060591` one (the one the
    /// app and openusage use), and the secret that goes with it is whichever Google accepts — callers try each.
    struct OAuthClient: Sendable {
        var id: String
        var secret: String

        static let candidates: [OAuthClient] = {
            let binary = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Resources/bin/language_server")
            guard let data = FileManager.default.contents(atPath: binary.path) else { return [] }
            let text = String(decoding: data, as: UTF8.self)
            let ids = text.matches(of: /[0-9]{10,}-[a-z0-9]{20,}\.apps\.googleusercontent\.com/).map { String(text[$0.range]) }
            let secrets = text.matches(of: /GOCSPX-[A-Za-z0-9_-]{28}/).map { String(text[$0.range]) }
            guard let id = ids.first(where: { $0.hasPrefix("1071006060591-") }) ?? ids.first, !secrets.isEmpty else { return [] }
            return Array(Set(secrets)).sorted { (secrets.firstIndex(of: $0) ?? 0) < (secrets.firstIndex(of: $1) ?? 0) }.map { OAuthClient(id: id, secret: $0) }
        }()

        static var installed: OAuthClient? { candidates.first }
        static var appInstalled: Bool { FileManager.default.fileExists(atPath: appPath) }
    }

    /// One credential: a Google account Burn signed in, or the Antigravity app's own.
    struct Source: Sendable {
        var email: String?
        var file: URL?          // Burn's file, when it is ours
        var auth: Auth
        var owned: Bool { file != nil }
        var accountID: String { "gemini:\(email ?? "antigravity")" }
    }

    private let renewed = RenewedTokens()

    func fetch() async -> [AccountSnapshot] {
        let removed = Preferences.removedKeys()
        var cards: [AccountSnapshot] = []
        var seen: Set<String> = []
        for source in Self.sources() where !removed.contains(source.accountID) {
            let snapshot = await fetchOne(source)
            guard seen.insert(snapshot.id).inserted else { continue }
            cards.append(snapshot)
        }
        return cards
    }

    static func sources() -> [Source] {
        var out: [Source] = []
        if let app = Auth.fromAntigravityKeychain() {
            out.append(Source(email: app.email, file: nil, auth: app))
        }
        for account in GeminiAccounts.all() {
            if let auth = try? Auth(file: account.file) {
                out.append(Source(email: account.email, file: account.file, auth: auth))
            } else {
                // A file we can't read — most likely one from before Antigravity's client was the one to use.
                out.append(Source(email: account.email, file: account.file, auth: Auth.unusable))
            }
        }
        return out
    }

    private func fetchOne(_ source: Source) async -> AccountSnapshot {
        do {
            var auth = source.auth
            guard auth.isUsable, auth.client == "antigravity" else { throw GeminiError.signInAgain }
            if let cached = await renewed.token(for: auth.refreshToken) { auth.accessToken = cached.token; auth.expiresAt = cached.expiresAt }
            if auth.isExpired { auth = try await renew(auth, writeTo: source.file) }
            do {
                return try await Self.load(auth, source: source)
            } catch ProviderError.http(401, _), ProviderError.http(403, _) {
                auth = try await renew(auth, writeTo: source.file)
                return try await Self.load(auth, source: source)
            }
        } catch {
            Log.write("gemini \(source.email ?? "antigravity"): \(error.localizedDescription)")
            return Self.problemCard(error, source: source)
        }
    }

    // MARK: - Code Assist, as Antigravity asks it

    private static func load(_ auth: Auth, source: Source) async throws -> AccountSnapshot {
        let summary: SummaryResponse = try await cloudCode("retrieveUserQuotaSummary", token: auth.accessToken, userAgent: "antigravity", body: [:])
        // Plan name is decoration; a failure there must not hide the numbers.
        let tier: LoadResponse? = try? await cloudCode("loadCodeAssist", token: auth.accessToken, userAgent: "agy", body: [:])
        let buckets = (summary.response?.groups ?? summary.groups ?? []).flatMap { $0.buckets ?? [] }
        guard !buckets.isEmpty else {
            Log.write("gemini quota summary had no buckets: \(summary.rawDescription)")
            throw ProviderError.decoding("Antigravity reported no quota for this account")
        }
        var windows: [UsageWindow] = []
        var seen: Set<String> = []
        for bucket in buckets {
            guard let bucketID = bucket.bucketId, seen.insert(bucketID).inserted, let fraction = bucket.remainingFraction else { continue }
            let used = min(100, max(0, (1 - fraction) * 100))
            switch bucketID {
            case "gemini-5h":
                windows.append(UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: used, resetsAt: bucket.resetTime, windowSeconds: 5 * 3600, detail: nil))
            case "gemini-weekly":
                windows.append(UsageWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: used, resetsAt: bucket.resetTime, windowSeconds: 7 * 86400, detail: nil))
            case "3p-5h":
                windows.append(UsageWindow(id: "claude", kind: .model, title: "Claude", usedPercent: used, resetsAt: bucket.resetTime, windowSeconds: 5 * 3600, detail: nil))
            case "3p-weekly":
                windows.append(UsageWindow(id: "claude-weekly", kind: .model, title: "Claude wk", usedPercent: used, resetsAt: bucket.resetTime, windowSeconds: 7 * 86400, detail: nil))
            default:
                Log.write("gemini: unfamiliar quota bucket \(bucketID) (\(bucket.displayName ?? "")) — ignoring")
            }
        }
        // Pools first, in the order the card reads best.
        let order = ["session", "weekly", "claude", "claude-weekly"]
        windows.sort { (order.firstIndex(of: $0.id) ?? 9) < (order.firstIndex(of: $1.id) ?? 9) }
        let plan = tier?.paidTier?.name ?? tier?.currentTier?.name
        let snapshot = AccountSnapshot(
            id: source.accountID, providerID: .gemini,
            label: "Gemini",
            subtitle: ["Antigravity", plan.map(planLabel)].compactMap { $0 }.joined(separator: " · "),
            identity: source.email,
            windows: windows, fetchedAt: .now, problem: nil)
        Log.write("gemini: \(snapshot.identity ?? "?") · \(snapshot.subtitle) · \(windows.map { "\($0.title) \(Int($0.usedPercent))%" })")
        return snapshot
    }

    /// "Google AI Pro" → "Pro"; Google's tier names are long.
    private static func planLabel(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        for keyword in ["Ultra", "Pro", "Free"] where trimmed.localizedCaseInsensitiveContains(keyword) { return keyword }
        return trimmed
    }

    /// POST a Code Assist method, trying Antigravity's daily endpoint first. Auth failures stop at once; anything
    /// else falls through to the next base.
    private static func cloudCode<T: Decodable>(_ method: String, token: String, userAgent: String, body: [String: Any]) async throws -> T {
        var last: Error = ProviderError.decoding("no Code Assist endpoint answered")
        for base in endpoints {
            do {
                return try await HTTP.postJSON("\(base):\(method)", body: body, headers: ["Authorization": "Bearer \(token)", "User-Agent": userAgent])
            } catch ProviderError.http(401, let message) {
                throw ProviderError.http(401, message)
            } catch ProviderError.http(403, let message) {
                throw ProviderError.http(403, message)
            } catch {
                last = error
            }
        }
        throw last
    }

    private static func problemCard(_ error: Error, source: Source) -> AccountSnapshot {
        let problem: AccountProblem
        let email = source.email
        let again: AccountProblem.Action? = source.owned ? .signIn(.gemini(hint: email)) : nil
        switch error {
        case GeminiError.signInAgain:
            problem = AccountProblem(kind: .signedOut, title: "Sign in again",
                                     hint: "This sign-in predates Google's move to Antigravity; sign in once more and the card fills in.",
                                     command: nil, action: again)
        case GeminiError.noClient:
            problem = AccountProblem(kind: .error, title: "Antigravity isn't installed",
                                     hint: "Google meters Gemini for individuals through Antigravity now; install it from antigravity.google and sign in again.",
                                     command: nil)
        case ProviderError.notSignedIn, ProviderError.http(400, _), ProviderError.http(401, _):
            problem = AccountProblem(kind: .signedOut, title: "Gemini sign-in expired",
                                     hint: source.owned ? "Sign in with Google again." : "Sign in to the Antigravity app again.",
                                     command: nil, action: again)
        case ProviderError.http(403, _):
            problem = AccountProblem(kind: .error, title: "Google declined this account",
                                     hint: "Code Assist refused the Antigravity quota for this Google account.", command: nil)
        case ProviderError.http(429, _):
            problem = AccountProblem(kind: .throttled, title: "Rate limited", hint: "Google is throttling quota lookups. Backing off.", command: nil)
        case let ProviderError.http(code, _):
            problem = AccountProblem(kind: .error, title: "HTTP \(code)", hint: "Google's Code Assist endpoint answered with an error.", command: nil)
        case let ProviderError.decoding(msg):
            problem = AccountProblem(kind: .error, title: "Unexpected response", hint: msg, command: nil)
        default:
            problem = AccountProblem(kind: .error, title: "Couldn't reach Google", hint: error.localizedDescription, command: nil)
        }
        return AccountSnapshot(id: source.accountID, providerID: .gemini, label: "Gemini", subtitle: "Antigravity",
                               identity: email, windows: [], fetchedAt: .now, problem: problem)
    }

    enum GeminiError: Error {
        case signInAgain
        case noClient
    }

    // MARK: - Refresh

    private func renew(_ auth: Auth, writeTo file: URL?) async throws -> Auth {
        guard !OAuthClient.candidates.isEmpty else { throw GeminiError.noClient }
        struct TokenResponse: Decodable {
            var accessToken: String
            var expiresIn: Double?
            var idToken: String?
        }
        var token: TokenResponse?
        var lastError: Error = ProviderError.notSignedIn("Google refresh token is no longer valid")
        for client in OAuthClient.candidates {
            do {
                token = try await HTTP.postForm(Self.tokenURL, form: [
                    "grant_type": "refresh_token",
                    "refresh_token": auth.refreshToken,
                    "client_id": client.id,
                    "client_secret": client.secret,
                ])
                break
            } catch ProviderError.http(400, let body) where body.contains("invalid_grant") {
                throw ProviderError.notSignedIn("Google refresh token is no longer valid")
            } catch {
                lastError = error   // invalid_client: the other secret is the right one
            }
        }
        guard let token else { throw lastError }
        var updated = auth
        updated.accessToken = token.accessToken
        updated.idToken = token.idToken ?? auth.idToken
        updated.expiresAt = Date.now.addingTimeInterval(token.expiresIn ?? 3600)
        if let file {
            try updated.write(to: file)
        } else {
            await renewed.store(updated.accessToken, expiresAt: updated.expiresAt, for: auth.refreshToken)   // the app's item stays as it is
        }
        return updated
    }

    /// Renewed access tokens for credentials we must not write back (Antigravity's keychain item).
    private actor RenewedTokens {
        private var tokens: [String: (token: String, expiresAt: Date)] = [:]
        func token(for refresh: String) -> (token: String, expiresAt: Date)? { tokens[refresh] }
        func store(_ token: String, expiresAt: Date, for refresh: String) { tokens[refresh] = (token, expiresAt) }
    }

    // MARK: - Credentials

    struct Auth: Sendable {
        /// The file's other fields, kept as JSON so a write-back preserves them.
        var raw: Data
        var accessToken: String
        var refreshToken: String
        var idToken: String?
        var expiresAt: Date
        var email: String?
        /// Which OAuth client issued the tokens — only Antigravity's are usable now.
        var client: String
        var isUsable: Bool { !accessToken.isEmpty || !refreshToken.isEmpty }

        static var unusable: Auth { Auth(raw: Data(), accessToken: "", refreshToken: "", idToken: nil, expiresAt: .distantPast, email: nil, client: "") }

        /// One of Burn's files (the Gemini CLI's shape, plus `email` and `client`).
        init(file: URL) throws {
            guard let data = FileManager.default.contents(atPath: file.path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String,
                  let refresh = json["refresh_token"] as? String else {
                throw ProviderError.notSignedIn("Unreadable Gemini credential at \(file.lastPathComponent)")
            }
            raw = data
            accessToken = access
            refreshToken = refresh
            idToken = json["id_token"] as? String
            expiresAt = Date(timeIntervalSince1970: ((json["expiry_date"] as? Double) ?? 0) / 1000)
            email = json["email"] as? String
            client = json["client"] as? String ?? "gemini-cli"
        }

        init(raw: Data, accessToken: String, refreshToken: String, idToken: String?, expiresAt: Date, email: String?, client: String) {
            self.raw = raw; self.accessToken = accessToken; self.refreshToken = refreshToken; self.idToken = idToken
            self.expiresAt = expiresAt; self.email = email; self.client = client
        }

        /// The Antigravity app's own sign-in: keychain service `gemini`, account `antigravity`, a go-keyring-wrapped
        /// JSON blob. Read-only.
        static func fromAntigravityKeychain() -> Auth? {
            guard let raw = try? Keychain.readString(service: "gemini", account: "antigravity") else { return nil }
            var text = raw
            let prefix = "go-keyring-base64:"
            if text.hasPrefix(prefix), let data = Data(base64Encoded: String(text.dropFirst(prefix.count))) {
                text = String(decoding: data, as: UTF8.self)
            }
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
            let object = (json["token"] as? [String: Any]) ?? json
            let access = ["access_token", "accessToken", "token"].compactMap { object[$0] as? String }.first ?? ""
            let refresh = ["refresh_token", "refreshToken"].compactMap { object[$0] as? String }.first ?? ""
            guard !access.isEmpty || !refresh.isEmpty else { return nil }
            let expiry = ["expiry", "expires_at", "expiresAt"].compactMap { object[$0] as? String }.first.flatMap(ISO8601.parseLenient) ?? .distantPast
            let email = ["email", "user_email"].compactMap { (object[$0] ?? json[$0]) as? String }.first
                ?? (access.isEmpty ? nil : JWT.claims(access)?["email"] as? String)
            return Auth(raw: Data(text.utf8), accessToken: access, refreshToken: refresh, idToken: nil, expiresAt: expiry, email: email, client: "antigravity")
        }

        var isExpired: Bool { expiresAt.timeIntervalSinceNow < 60 }

        func write(to file: URL) throws {
            var json = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
            json["access_token"] = accessToken
            if let idToken { json["id_token"] = idToken }
            json["expiry_date"] = Int(expiresAt.timeIntervalSince1970 * 1000)
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
        }
    }

    // MARK: - Response shapes

    private struct SummaryResponse: Decodable {
        struct Group: Decodable { var buckets: [Bucket]? }
        struct Bucket: Decodable {
            var bucketId: String?
            var displayName: String?
            var remainingFraction: Double?
            var resetTime: Date?
        }
        struct Root: Decodable { var groups: [Group]? }
        var response: Root?
        var groups: [Group]?
        var raw: [String: AnyCodableValue]?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            response = try? container.decodeIfPresent(Root.self, forKey: .response)
            groups = try? container.decodeIfPresent([Group].self, forKey: .groups)
            raw = try? decoder.singleValueContainer().decode([String: AnyCodableValue].self)
        }

        enum CodingKeys: String, CodingKey { case response, groups }
        var rawDescription: String { raw.map { "\($0)".prefix(500).description } ?? "?" }
    }

    private struct LoadResponse: Decodable {
        struct Tier: Decodable { var id: String?; var name: String? }
        var currentTier: Tier?
        var paidTier: Tier?
    }
}

/// Any JSON value, for logging a response whose shape we don't know yet.
struct AnyCodableValue: Decodable, CustomStringConvertible {
    var value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { value = b }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodableValue].self) { value = a.map(\.value) }
        else if let o = try? container.decode([String: AnyCodableValue].self) { value = o.mapValues(\.value) }
        else { value = NSNull() }
    }

    var description: String { "\(value)" }
}
