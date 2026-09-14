import Foundation
import SQLite3

/// The Cursor account, through the sign-in the Cursor app keeps in its state database and the dashboard RPCs the
/// app itself calls: the current billing period's plan usage (a monthly pool against the plan's included amount)
/// and the plan's name. A short-lived access token is renewed with the app's own client and kept in memory only —
/// nothing is ever written back into Cursor's database. Endpoints and fields after openusage (MIT).
struct CursorProvider: Provider {
    let id = ProviderID.cursor

    static let stateDB = NSString(string: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb").expandingTildeInPath
    static let usageURL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    static let planURL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo"
    static let tokenURL = "https://api2.cursor.sh/oauth/token"
    static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    static let app = (bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor")

    private let renewed = RenewedToken()

    func fetch() async -> [AccountSnapshot] {
        do {
            let auth = try Auth(database: Self.stateDB)
            var token = await renewed.token(issuedFor: auth.refreshToken) ?? auth.accessToken
            if Self.isExpiring(token) { token = try await renew(auth) }
            do {
                return [try await Self.load(token, auth: auth)]
            } catch ProviderError.http(401, _), ProviderError.http(403, _) {
                token = try await renew(auth)
                return [try await Self.load(token, auth: auth)]
            }
        } catch {
            Log.write("cursor: \(error.localizedDescription)")
            return [Self.problemCard(error)]
        }
    }

    private static func load(_ token: String, auth: Auth) async throws -> AccountSnapshot {
        let headers = ["Authorization": "Bearer \(token)", "Connect-Protocol-Version": "1"]
        async let usage: UsageResponse = HTTP.postJSON(usageURL, body: [:], headers: headers)
        // The plan name is decoration; a failure there must not hide the numbers.
        let plan: PlanResponse? = try? await HTTP.postJSON(planURL, body: [:], headers: headers)
        let snapshot = try snapshot(usage: try await usage, plan: plan, auth: auth)
        Log.write("cursor: \(snapshot.identity ?? "?") · \(snapshot.subtitle) · \(snapshot.windows.count) windows")
        return snapshot
    }

    private static func snapshot(usage: UsageResponse, plan: PlanResponse?, auth: Auth) throws -> AccountSnapshot {
        guard usage.enabled != false, let planUsage = usage.planUsage else {
            throw ProviderError.decoding("No active Cursor subscription")
        }
        // The pool is dollars: `limit`, `totalSpend` and `remaining` (cents) agree with each other and with the
        // dashboard's "included usage" bar. `totalPercentUsed` (and the auto/api splits) are on another scale
        // entirely — 2.6 against a 47 % pool, on this account — so they are not used.
        let limit = planUsage.limit?.value ?? 0
        let spent = planUsage.totalSpend?.value ?? max(0, limit - (planUsage.remaining?.value ?? limit))
        guard limit > 0 else { throw ProviderError.decoding("Cursor didn't report the plan's included usage") }
        let percent = spent / limit * 100
        let cycleEnd = usage.billingCycleEnd?.value.map { Date(timeIntervalSince1970: $0 / 1000) }
        let cycleStart = usage.billingCycleStart?.value.map { Date(timeIntervalSince1970: $0 / 1000) }
        let period = zip(cycleStart, cycleEnd).map { Int($1.timeIntervalSince($0)) } ?? 30 * 86400

        var windows = [UsageWindow(id: "monthly", kind: .monthly, title: "Monthly", usedPercent: min(100, max(0, percent)),
                                   resetsAt: cycleEnd, windowSeconds: period,
                                   detail: limit > 0 ? "\(money(spent)) of \(money(limit))" : nil)]
        if let spend = usage.spendLimitUsage {
            let cap = spend.individualLimit?.value ?? spend.pooledLimit?.value ?? 0
            let used = spend.individualUsed?.value ?? spend.pooledUsed?.value ?? spend.totalSpend?.value
                ?? max(0, cap - (spend.individualRemaining?.value ?? spend.pooledRemaining?.value ?? cap))
            if cap > 0 || used > 0 {
                windows.append(UsageWindow(id: "ondemand", kind: .spend, title: "On-demand", usedPercent: cap > 0 ? min(100, used / cap * 100) : 0,
                                           resetsAt: cycleEnd, windowSeconds: period,
                                           detail: cap > 0 ? "\(money(used)) of \(money(cap))" : money(used)))
            }
        }

        let planName = plan?.planInfo?.planName.map { $0.capitalized } ?? Self.planLabel(auth.membership)
        return AccountSnapshot(
            id: "cursor:\(auth.userID)", providerID: .cursor,
            label: "Cursor",
            subtitle: planName.isEmpty ? "Included usage" : "\(planName) · included usage",
            identity: auth.email,
            windows: windows, fetchedAt: .now, problem: nil)
    }

    private static func planLabel(_ membership: String?) -> String {
        switch membership?.lowercased() {
        case "pro_plus": "Pro+"
        case "pro": "Pro"
        case "ultra": "Ultra"
        case "free": "Hobby"
        case "team", "enterprise": membership?.capitalized ?? ""
        default: membership?.replacingOccurrences(of: "_", with: " ").capitalized ?? ""
        }
    }

    /// Cents to dollars, whole when whole.
    private static func money(_ cents: Double) -> String {
        let value = cents / 100
        return value == value.rounded() ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    private static func problemCard(_ error: Error) -> AccountSnapshot {
        let problem: AccountProblem
        let open = AccountProblem.Action.openApp(bundleID: app.bundleID, name: app.name)
        switch error {
        case ProviderError.notSignedIn, ProviderError.http(401, _), ProviderError.http(403, _):
            problem = AccountProblem(kind: .signedOut, title: "Cursor isn't signed in",
                                     hint: "Sign in to the Cursor app once; this card takes over.", command: nil, action: open)
        case ProviderError.http(429, _):
            problem = AccountProblem(kind: .throttled, title: "Rate limited", hint: "Cursor is throttling usage lookups. Backing off.", command: nil)
        case let ProviderError.http(code, _):
            problem = AccountProblem(kind: .error, title: "HTTP \(code)", hint: "Cursor's dashboard endpoint answered with an error.", command: nil)
        case let ProviderError.decoding(msg):
            problem = AccountProblem(kind: .error, title: "Unexpected response", hint: msg, command: nil)
        default:
            problem = AccountProblem(kind: .error, title: "Couldn't reach Cursor", hint: error.localizedDescription, command: nil)
        }
        return AccountSnapshot(id: "cursor:unknown", providerID: .cursor, label: "Cursor", subtitle: "Included usage",
                               windows: [], fetchedAt: .now, problem: problem)
    }

    // MARK: - Renewal (in memory only)

    private static func isExpiring(_ token: String) -> Bool {
        guard let exp = JWT.claims(token)?["exp"] as? Double else { return true }
        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow < 5 * 60
    }

    private func renew(_ auth: Auth) async throws -> String {
        struct TokenResponse: Decodable { var accessToken: String }
        let token: TokenResponse
        do {
            token = try await HTTP.postJSON(Self.tokenURL, body: [
                "grant_type": "refresh_token",
                "client_id": Self.clientID,
                "refresh_token": auth.refreshToken,
            ])
        } catch ProviderError.http(400, _), ProviderError.http(401, _) {
            throw ProviderError.notSignedIn("The Cursor sign-in can't be renewed any more")
        }
        await renewed.store(token.accessToken, issuedFor: auth.refreshToken)
        Log.write("cursor: token renewed")
        return token.accessToken
    }

    /// One renewed access token, tied to the refresh token that produced it, so a new sign-in in Cursor is noticed.
    private actor RenewedToken {
        private var token: String?
        private var refreshToken: String?

        func token(issuedFor refresh: String) -> String? { refreshToken == refresh ? token : nil }

        func store(_ token: String, issuedFor refresh: String) {
            self.token = token
            refreshToken = refresh
        }
    }

    // MARK: - state.vscdb (read-only)

    private struct Auth {
        var accessToken: String
        var refreshToken: String
        var email: String?
        var membership: String?
        var userID: String

        init(database path: String) throws {
            guard FileManager.default.fileExists(atPath: path) else {
                throw ProviderError.notSignedIn("No Cursor state database at \(path)")
            }
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                throw ProviderError.decoding("Couldn't open Cursor's state database")
            }
            defer { sqlite3_close(db) }
            func value(_ key: String) -> String? {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
                let string = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                return string.isEmpty ? nil : string
            }
            guard let access = value("cursorAuth/accessToken"), let refresh = value("cursorAuth/refreshToken") else {
                throw ProviderError.notSignedIn("Cursor isn't signed in")
            }
            accessToken = access
            refreshToken = refresh
            email = value("cursorAuth/cachedEmail")
            membership = value("cursorAuth/stripeMembershipType")
            let subject = JWT.claims(access)?["sub"] as? String ?? ""
            userID = subject.split(separator: "|").last.map(String.init) ?? subject
        }
    }

    // MARK: - Response shapes (protobuf JSON: 64-bit numbers arrive as strings)

    private struct UsageResponse: Decodable {
        struct PlanUsage: Decodable {
            var limit: LenientNumber?
            var totalSpend: LenientNumber?
            var remaining: LenientNumber?
        }
        struct SpendLimit: Decodable {
            var individualLimit: LenientNumber?
            var pooledLimit: LenientNumber?
            var individualUsed: LenientNumber?
            var pooledUsed: LenientNumber?
            var totalSpend: LenientNumber?
            var individualRemaining: LenientNumber?
            var pooledRemaining: LenientNumber?
        }
        var enabled: Bool?
        var planUsage: PlanUsage?
        var spendLimitUsage: SpendLimit?
        var billingCycleStart: LenientNumber?
        var billingCycleEnd: LenientNumber?
    }

    private struct PlanResponse: Decodable {
        struct PlanInfo: Decodable { var planName: String? }
        var planInfo: PlanInfo?
    }
}

/// A JSON number that may arrive as a string (protobuf's int64) — nil when it is neither.
struct LenientNumber: Decodable {
    var value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) { value = number }
        else if let text = try? container.decode(String.self) { value = Double(text) }
        else { value = nil }
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
