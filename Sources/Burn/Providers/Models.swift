import Foundation

/// Which service an account belongs to. Adding a provider = a new case here plus one file in Providers/.
enum ProviderID: String, Codable, Sendable, CaseIterable {
    case claude, codex, grok, gemini, cursor, copilot

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        case .grok: "Grok"
        case .gemini: "Gemini"
        case .cursor: "Cursor"
        case .copilot: "Copilot"
        }
    }

    /// Who runs the service — for "Anthropic is having an incident".
    var vendorName: String {
        switch self {
        case .claude: "Anthropic"
        case .codex: "OpenAI"
        case .grok: "xAI"
        case .gemini: "Google"
        case .cursor: "Cursor"
        case .copilot: "GitHub"
        }
    }

    /// The vendor's Statuspage and the components that count as ours (matched by prefix, case-insensitively).
    /// Anthropic's page moved from status.anthropic.com to status.claude.com; Google and xAI have no Statuspage.
    var statusPage: (page: URL, components: [String])? {
        switch self {
        case .claude: (URL(string: "https://status.claude.com")!, ["claude.ai", "Claude API", "Claude Code"])
        case .codex: (URL(string: "https://status.openai.com")!, ["Codex", "Login"])
        case .cursor: (URL(string: "https://status.cursor.com")!, ["IDE", "CLI", "cursor.com"])
        case .copilot: (URL(string: "https://www.githubstatus.com")!, ["Copilot"])
        case .grok, .gemini: nil
        }
    }
}

/// What the vendor's status page says about the service behind a provider.
enum VendorCondition: Codable, Sendable, Hashable {
    case fine
    case degraded(String)
    case outage(String)
    case unknown

    var isTrouble: Bool {
        switch self {
        case .degraded, .outage: true
        case .fine, .unknown: false
        }
    }
    var title: String? {
        switch self {
        case .degraded: "Degraded"
        case .outage: "Outage"
        case .fine, .unknown: nil
        }
    }
    var incident: String? {
        switch self {
        case let .degraded(name), let .outage(name): name
        case .fine, .unknown: nil
        }
    }
}

/// One rate-limit window on an account: the 5-hour session, a daily allowance, the weekly cap, a monthly pool,
/// a model-scoped cap, or a spend cap.
struct UsageWindow: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case session, daily, weekly, monthly, model, spend

        /// The windows that decide how an account is doing — the ones the menu bar, sort order and card tint use.
        var isPooled: Bool {
            switch self {
            case .session, .daily, .weekly, .monthly: true
            case .model, .spend: false
            }
        }
    }

    var id: String
    var kind: Kind
    var title: String
    /// 0...100. Fraction of the window already consumed.
    var usedPercent: Double
    var resetsAt: Date?
    var windowSeconds: Int?
    /// Short secondary text, e.g. "$0 of $500" or "resets with weekly".
    var detail: String?

    var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// Secondary windows earn a place on the card only when they say something: a model cap that has started to
    /// fill, spend that has actually happened, or a credit balance (which is room of its own). "$0 of $500" and
    /// "cap $50" are facts about the plan, not about today.
    var isNotable: Bool {
        switch kind {
        case .session, .daily, .weekly, .monthly: true
        case .model: usedPercent >= 5
        case .spend: usedPercent > 0 || id == "credits"
        }
    }
}

/// A sign-in Burn can run itself, through a vendor CLI already on this Mac (see `SignIn`).
enum LoginTarget: Codable, Hashable, Sendable {
    /// Claude Code's default profile (nil), or a profile directory Burn manages (`CLAUDE_CONFIG_DIR`).
    case claude(profile: String?)
    case grok
    /// Google's own sign-in, run by Burn (no CLI involved); `hint` pre-selects an account in the chooser.
    case gemini(hint: String?)

    var providerID: ProviderID {
        switch self {
        case .claude: .claude
        case .grok: .grok
        case .gemini: .gemini
        }
    }

    /// The same thing typed by hand — the fallback when the CLI isn't where Burn looked.
    var command: String {
        switch self {
        case let .claude(profile?): "CLAUDE_CONFIG_DIR=\(NSString(string: profile).abbreviatingWithTildeInPath) claude auth login"
        case .claude(nil): "claude auth login"
        case .grok: "grok login"
        case .gemini: "gemini"
        }
    }

    var cliName: String {
        switch self {
        case .claude: "Claude Code"
        case .grok: "the Grok CLI"
        case .gemini: "the Gemini CLI"
        }
    }
}

/// Why a card has no live numbers, and the one thing the user can do about it.
struct AccountProblem: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        /// Needs the user: sign in, or open the CLI so it renews itself.
        case signedOut
        /// The provider is throttling us; the store backs off and keeps old numbers.
        case throttled
        /// Anything else — network, server error, a response we didn't expect.
        case error
    }

    /// What Burn can do about it from a button, when the vendor's CLI or app is on this Mac.
    enum Action: Codable, Sendable, Hashable {
        case signIn(LoginTarget)
        case openApp(bundleID: String, name: String)
        case openLink(url: String, title: String)
    }

    var kind: Kind
    var title: String
    var hint: String
    /// A shell command shown as copyable text, when the fix is "run this once" (or the button above fails).
    var command: String?
    var action: Action? = nil
}

/// Everything a card needs. Providers return one of these per account, including failed ones, so one broken
/// credential never hides the others.
struct AccountSnapshot: Identifiable, Codable, Sendable, Hashable {
    /// Stable across launches: "claude:<orgUuid>:<accountUuid>", "codex:<accountId>", "grok:<userId>".
    var id: String
    var providerID: ProviderID
    /// "Studio", "Personal", an email — whatever identifies the account at a glance.
    var label: String
    /// Plan line under the label: "Team · Max 5×", "ChatGPT Plus", "SuperGrok".
    var subtitle: String
    /// The signed-in email, when the provider tells us. Shown small; useful when two cards share a label.
    var identity: String?
    var windows: [UsageWindow]
    var fetchedAt: Date
    var problem: AccountProblem?
    /// True when the numbers are from an earlier successful fetch and the latest one failed.
    var isStale: Bool = false

    var session: UsageWindow? { windows.first { $0.kind == .session } }
    var weekly: UsageWindow? { windows.first { $0.kind == .weekly } }
    /// The short window that runs out first: the session, or a daily allowance where the plan has no sessions.
    var shortest: UsageWindow? { session ?? windows.first { $0.kind == .daily } }
    var secondary: [UsageWindow] { windows.filter { !$0.kind.isPooled } }

    /// The window closest to running out — what the menu bar and sort order care about.
    var tightest: UsageWindow? { windows.filter { $0.kind.isPooled }.max { $0.usedPercent < $1.usedPercent } }
}

/// A provider knows where its credentials live on this Mac and how to turn them into snapshots.
protocol Provider: Sendable {
    var id: ProviderID { get }
    func fetch() async -> [AccountSnapshot]
}

enum ProviderError: Error, LocalizedError {
    case http(Int, String)
    case notSignedIn(String)
    case decoding(String)
    /// The vendor's token endpoint refused to renew an otherwise good sign-in.
    case refreshRejected(Int, String)
    /// Skipped this poll: the account failed recently and is waiting its turn, still showing the last problem.
    case backingOff(until: Date, last: AccountProblem)

    var errorDescription: String? {
        switch self {
        case let .http(code, body): "HTTP \(code): \(body.prefix(200))"
        case let .notSignedIn(msg): msg
        case let .decoding(msg): "Unexpected response: \(msg)"
        case let .refreshRejected(code, body): "Token refresh HTTP \(code): \(body.prefix(200))"
        case let .backingOff(until, _): "Backing off until \(until.formatted(date: .omitted, time: .shortened))"
        }
    }
}
