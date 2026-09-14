import AppKit
import KeyboardShortcuts
import SwiftUI

// MARK: - Panes

struct GeneralPane: View {
    @State private var settings = Preferences.shared
    @State private var launchAtLogin = Preferences.shared.launchAtLogin
    @State private var toolInstalled = CommandLineTool.isToolInstalled
    @State private var statuslineInstalled = CommandLineTool.isStatuslineInstalled
    @State private var toolMessage: String?
    @Environment(\.colorScheme) private var scheme

    /// "10 PM", "8 AM" — whole hours are all quiet hours need.
    static func hourLabel(_ minute: Int) -> String {
        let hour = (minute / 60) % 24
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("j")
        return f.string(from: Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now)
    }

    static func hourEntries(_ pick: @escaping (Int) -> Void) -> [SelectEntry] {
        (0..<24).map { hour in SelectEntry(title: hourLabel(hour * 60)) { pick(hour * 60) } }
    }

    private let intervals: [(seconds: Int, title: String)] = [
        (60, "1 minute"), (180, "3 minutes"), (300, "5 minutes"), (600, "10 minutes"),
    ]

    var body: some View {
        SettingsPage {
            SettingsSection("Shortcut") {
                SettingsRow("Toggle panel") {
                    KeyboardShortcuts.Recorder(for: .togglePanel)
                        .controlSize(.small)
                }
                SettingsNote("Press it anywhere to show the panel; press again, Esc, or click away to hide it.")
            }
            SettingsSection("Behavior") {
                SettingsRow("Launch at login") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .onChange(of: launchAtLogin) { _, new in settings.launchAtLogin = new }
                }
                Hairline()
                SettingsRow("Check usage every") {
                    SelectMenu(
                        title: intervals.first { $0.seconds == settings.pollIntervalSeconds }?.title ?? "\(settings.pollIntervalSeconds) s",
                        entries: intervals.map { interval in
                            SelectEntry(title: interval.title, checked: interval.seconds == settings.pollIntervalSeconds) {
                                settings.pollIntervalSeconds = interval.seconds
                            }
                        })
                }
                Hairline()
                SettingsRow("Show vendor status") {
                    Toggle("Show vendor status", isOn: $settings.showVendorStatus)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                SettingsNote(settings.showVendorStatus ? "Opening the panel refreshes anything older than 30 seconds. Anthropic, OpenAI, Cursor and GitHub status pages are checked every five minutes; an incident shows as a chip on the rows it affects." : "Opening the panel refreshes anything older than 30 seconds.")
            }
            SettingsSection("Notifications") {
                SettingsRow("Notify me") {
                    Toggle("Notify me", isOn: $settings.notificationsEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .onChange(of: settings.notificationsEnabled) { _, on in if on { Alerts.shared.requestAuthorization() } }
                }
                Hairline()
                SettingsRow("Nearly out at") {
                    SelectMenu(title: "\(settings.notifyThresholdPercent) %", entries: [60, 75, 85, 95].map { percent in
                        SelectEntry(title: "\(percent) %", checked: settings.notifyThresholdPercent == percent) { settings.notifyThresholdPercent = percent }
                    })
                }
                Hairline()
                SettingsRow("When a low window resets") {
                    Toggle("When a low window resets", isOn: $settings.notifyOnReset)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                Hairline()
                SettingsRow("When a window will run out before it resets") {
                    Toggle("When a window will run out before it resets", isOn: $settings.notifyOnPace)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                Hairline()
                SettingsRow("When usage is unusually high") {
                    HStack(spacing: 6) {
                        if settings.notifyOnSurge {
                            SelectMenu(title: "\(Baseline.multipleText(settings.surgeMultiple)) my usual", entries: Preferences.surgeMultiples.map { multiple in
                                SelectEntry(title: "\(Baseline.multipleText(multiple)) my usual", checked: settings.surgeMultiple == multiple) { settings.surgeMultiple = multiple }
                            })
                        }
                        Toggle("When usage is unusually high", isOn: $settings.notifyOnSurge)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                }
                Hairline()
                SettingsRow("Quiet hours") {
                    HStack(spacing: 6) {
                        if settings.quietHoursEnabled {
                            SelectMenu(title: Self.hourLabel(settings.quietStartMinute), entries: Self.hourEntries { settings.quietStartMinute = $0 })
                            Text("to").font(.system(size: 11)).foregroundStyle(Palette.resolve(scheme).muted)
                            SelectMenu(title: Self.hourLabel(settings.quietEndMinute), entries: Self.hourEntries { settings.quietEndMinute = $0 })
                        }
                        Toggle("Quiet hours", isOn: $settings.quietHoursEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                }
                SettingsNote(settings.notificationsEnabled ? "Banners are quiet while the panel would tell you the same thing anyway: the same window, the same reset period. \"Unusual\" is measured against your own week: a window burning at \(Baseline.multipleText(settings.surgeMultiple)) its typical busy hour, or a model doing \(Baseline.multipleText(settings.surgeMultiple)) a typical day's API work — the latter from Claude Code's logs, so it doesn't see the desktop app." : "Burn stays silent; the panel and the menu-bar ring still update.")
            }
            SettingsSection("Command line") {
                SettingsRow(toolInstalled ? "~/.local/bin/burn" : "The burn command") {
                    ControlButton(toolInstalled ? "Reinstall" : "Install") {
                        toolMessage = (try? CommandLineTool.installTool()).map { _ in "Installed. Open a new shell and run burn." } ?? "Could not write ~/.local/bin/burn."
                        toolInstalled = CommandLineTool.isToolInstalled
                    }
                }
                Hairline()
                SettingsRow(statuslineInstalled ? "Claude Code status line" : "Add to the Claude Code status line") {
                    ControlButton(statuslineInstalled ? "Reinstall" : "Add") {
                        do {
                            try CommandLineTool.installStatusline()
                            toolMessage = "Added. Your own status line still runs first; Burn's segment follows it. Takes effect in new Claude Code sessions."
                        } catch {
                            toolMessage = "Could not update ~/.claude/settings.json: \(error.localizedDescription)"
                        }
                        statuslineInstalled = CommandLineTool.isStatuslineInstalled
                    }
                }
                Hairline()
                SettingsRow("Open terminals in") {
                    SelectMenu(title: settings.terminalApp.title, entries: Launchers.TerminalApp.allCases.filter(\.isInstalled).map { app in
                        SelectEntry(title: app.title, checked: settings.terminalApp == app) { settings.terminalApp = app }
                    })
                }
                SettingsNote(toolMessage ?? "burn prints what the panel knows — one line per account, `status`, `json` — and `burn statusline` is a segment for Claude Code's status line, picking the account whose profile the session runs as.")
            }
        }
    }
}

struct AppearancePane: View {
    @State private var settings = Preferences.shared
    @State private var store = UsageStore.shared

    var body: some View {
        SettingsPage {
            SettingsSection("Panel") {
                SettingsRow("Theme") {
                    SegmentedWell(options: Appearance.allCases.map { ($0, $0.title) }, selection: $settings.appearance)
                        .frame(width: 260)
                }
                SettingsNote("The menu-bar ring always follows the system.")
            }
            SettingsSection("Menu bar") {
                SettingsRow("Ring shows") {
                    SelectMenu(title: ringTitle, entries: ringEntries)
                }
                Hairline()
                SettingsRow("Also pin") {
                    SelectMenu(title: pinnedTitle, entries: pinnedEntries)
                }
                Hairline()
                SettingsRow("Show percentage next to the ring") {
                    Toggle("Show percentage next to the ring", isOn: $settings.showPercentInMenuBar)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                SettingsNote("A pinned account gets a ring of its own beside the main one, in the order pinned; right-click a ring to unpin it.")
            }
        }
    }

    private var pinnedEntries: [SelectEntry] {
        store.snapshots.map { snapshot in
            let pinned = settings.pinnedAccountIDs.contains(snapshot.id)
            return SelectEntry(title: settings.label(for: snapshot) + " · " + snapshot.providerID.displayName, checked: pinned) {
                if pinned { settings.pinnedAccountIDs.removeAll { $0 == snapshot.id } } else { settings.pinnedAccountIDs.append(snapshot.id) }
            }
        }
    }

    private var pinnedTitle: String {
        let names = settings.pinnedAccountIDs.compactMap { id in store.snapshots.first { $0.id == id }.map { settings.label(for: $0) } }
        switch names.count {
        case 0: return "Nothing else"
        case 1: return names[0]
        default: return "\(names.count) accounts"
        }
    }

    private var ringEntries: [SelectEntry] {
        var entries = [SelectEntry(title: "Whichever account is closest to its limit", checked: settings.primaryAccountID == nil) {
            settings.primaryAccountID = nil
        }]
        if !store.snapshots.isEmpty { entries.append(.separator) }
        for snapshot in store.snapshots {
            entries.append(SelectEntry(title: settings.label(for: snapshot) + " · " + snapshot.providerID.displayName,
                                       checked: settings.primaryAccountID == snapshot.id) { settings.primaryAccountID = snapshot.id })
        }
        return entries
    }

    private var ringTitle: String {
        guard let id = settings.primaryAccountID, let snapshot = store.snapshots.first(where: { $0.id == id }) else {
            return "Closest to its limit"
        }
        return settings.label(for: snapshot)
    }
}

struct AccountsPane: View {
    @State private var store = UsageStore.shared
    @State private var addingClaude = false
    @State private var addingGemini = false
    @State private var launcherNotice: String?
    @Environment(\.colorScheme) private var scheme
    private var signIn: SignIn { .shared }

    var body: some View {
        let p = Palette.resolve(scheme)
        SettingsPage {
            SettingsSection(nil) {
                if store.snapshots.isEmpty {
                    SettingsNote("No accounts found yet.")
                }
                ForEach(Array(store.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                    if index > 0 { Hairline() }
                    AccountRow(snapshot: snapshot)
                }
                if let job = signIn.job {
                    Hairline()
                    SignInRow(job: job)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SelectMenu(title: "Add Account…", entries: addEntries)
                    .disabled(signIn.isRunning)
                Text("Claude, Gemini and Grok accounts sign in right here, in your browser — no other sign-in needed. ChatGPT, Cursor and Copilot are picked up from their own apps and CLIs.")
                    .font(.system(size: 11))
                    .foregroundStyle(p.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let total = monthlyTotal {
                    Text(total)
                        .font(.system(size: 11))
                        .foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let value = planValue {
                    Text(value)
                        .font(.system(size: 11))
                        .foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let missing = Launchers.missing(in: store.snapshots)
                if !missing.isEmpty {
                    HStack(spacing: 8) {
                        ControlButton(missing.count == 1 ? "Install `\(Launchers.command(for: missing[0]))`" : "Install all \(missing.count) commands") {
                            for snapshot in missing { try? Launchers.install(snapshot) }
                            launcherNotice = Launchers.binOnPath ? "Installed in ~/.local/bin. Open a new shell to use them." : "Installed in ~/.local/bin — add it to your PATH: export PATH=\"$HOME/.local/bin:$PATH\""
                        }
                        Text(launcherNotice ?? "A claude-<account> command per Claude account: Claude Code signed in as that account, no switching.")
                            .font(.system(size: 11))
                            .foregroundStyle(p.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let launcherNotice {
                    Text(launcherNotice)
                        .font(.system(size: 11))
                        .foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, -6)
            .padding(.leading, 2)
        }
        .sheet(isPresented: $addingClaude) {
            AddClaudeSheet { email in
                signIn.start(.claude(profile: ClaudeProfiles.nextDirectory().path), email: email)
            }
        }
        .sheet(isPresented: $addingGemini) {
            AddGeminiSheet { email in
                signIn.start(.gemini(hint: nil), email: email)
            }
        }
    }

    /// "About $260/mo across 4 paid plans" — with the caveat while any of it is still a guess.
    /// "Claude Code did $2,100 of API-priced work in the last 30 days on these accounts."
    private var planValue: String? {
        let month = APISpend.shared.total(days: 30, snapshots: store.snapshots)
        guard month > 0 else { return nil }
        let plans = store.snapshots.filter { $0.providerID == .claude }.compactMap { Preferences.shared.monthlyCost(for: $0) }.reduce(0, +)
        var line = "Claude Code did \(APISpend.label(month)) of API-priced work in the last 30 days on these accounts"
        if plans > 0 { line += String(format: " — %.1f× what the Claude plans cost.", month / plans) } else { line += "." }
        return line
    }

    private var monthlyTotal: String? {
        let settings = Preferences.shared
        let costs = store.snapshots.compactMap { snapshot in settings.monthlyCost(for: snapshot).map { (snapshot, $0) } }.filter { $0.1 > 0 }
        guard !costs.isEmpty else { return nil }
        let sum = costs.reduce(0) { $0 + $1.1 }
        let guessed = costs.contains { settings.isCostEstimated($0.0) }
        return "About \(PlanPricing.label(sum)) across \(costs.count) paid plan\(costs.count == 1 ? "" : "s")"
            + (guessed ? " — list prices guessed from plan names; set the real figure from an account's ⋯ menu." : ".")
    }

    /// New sign-ins first; then, when any account has been removed, a way to have it back.
    private var addEntries: [SelectEntry] {
        let settings = Preferences.shared
        var entries = [
            SelectEntry(title: "Claude…") { addingClaude = true },
            SelectEntry(title: "Grok…") {
                settings.restore(key: ProviderID.grok.rawValue)
                signIn.start(.grok)
            },
            SelectEntry(title: "Gemini…") { addingGemini = true },
            SelectEntry(title: "ChatGPT…", enabled: false),
        ]
        let removed = settings.removedAccountKeys.sorted { (settings.removedAccountLabels[$0] ?? $0) < (settings.removedAccountLabels[$1] ?? $1) }
        if !removed.isEmpty {
            entries.append(.separator)
            for key in removed {
                let name = settings.removedAccountLabels[key] ?? ProviderID(rawValue: key)?.displayName ?? key
                entries.append(SelectEntry(title: "Show \(name) again") { store.restore(key: key) })
            }
        }
        return entries
    }
}

/// The week of history Burn keeps, one chart per account.
struct UsagePane: View {
    @State private var store = UsageStore.shared
    @State private var days = 7
    @Environment(\.colorScheme) private var scheme

    /// "API-priced $310 today   $412 · 7 d   $1,380 · 30 d" for a Claude account, from Claude Code's logs — and
    /// "· 4× typical" on the day figure when today is a surge.
    private func spendLine(for snapshot: AccountSnapshot) -> String? {
        guard snapshot.providerID == .claude else { return nil }
        let spend = APISpend.shared
        guard let week = spend.cost(for: snapshot, days: 7), let month = spend.cost(for: snapshot, days: 30) else { return nil }
        var line = "API-priced "
        if let today = spend.today(for: snapshot)[""], today.dollars >= 1 {
            line += "\(APISpend.label(today.dollars)) today"
            if let surge = spend.surges(for: [snapshot], multiple: Preferences.shared.surgeMultiple).first(where: { $0.model == nil }) {
                line += " · \(Baseline.multipleText(surge.multiple)) typical"
            }
            line += "   "
        }
        line += "\(APISpend.label(week.dollars)) · 7 d   \(APISpend.label(month.dollars)) · 30 d"
        if let cost = Preferences.shared.monthlyCost(for: snapshot), cost > 0, month.dollars > 0 {
            line += String(format: "   %.1f× the plan", month.dollars / cost)
        }
        return line
    }

    /// " · 3× usual" when the window is burning at the user's multiple of its typical busy hour.
    private func surgeSuffix(_ pace: Pace, kind: UsageWindow.Kind) -> String {
        guard Alerts.isSurging(pace, kind: kind, threshold: Preferences.shared.surgeMultiple), let multiple = pace.multiple else { return "" }
        return " · \(Baseline.multipleText(multiple)) usual"
    }

    /// The current rate and verdict of each pooled window, one muted line under the chart.
    private func paceLine(for snapshot: AccountSnapshot) -> String? {
        let paces = store.paces[snapshot.id] ?? [:]
        let parts: [String] = snapshot.windows.filter { $0.kind.isPooled }.compactMap { window in
            guard let pace = paces[window.id] else { return nil }
            switch pace.verdict {
            case .early: return nil
            case .stalled: return "\(window.title) idle"
            case .onPace: return "\(window.title) \(pace.rateText) · on pace" + surgeSuffix(pace, kind: window.kind)
            case .fast: return "\(window.title) \(pace.rateText) · out \(pace.runOut.map { Relative.clock($0) } ?? "soon")" + surgeSuffix(pace, kind: window.kind)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }

var body: some View {
        let p = Palette.resolve(scheme)
        let accounts = store.visibleSnapshots
        SettingsPage {
            HStack {
                FieldLabel(text: "Show")
                Spacer()
                SegmentedWell(options: [(1, "24 hours"), (7, "7 days"), (30, "30 days"), (90, "90 days")], selection: $days)
                    .task { await APISpend.shared.scan() }
                    .frame(width: 200)
            }
            .padding(.horizontal, 2)
            if accounts.isEmpty {
                SettingsSection(nil) { SettingsNote("No accounts to chart yet.") }
            }
            ForEach(accounts) { snapshot in
                let samples = store.history.samples(for: snapshot.id, last: TimeInterval(days) * 86400)
                SettingsSection(nil) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            ProviderTile(provider: snapshot.providerID, size: 20)
                            Text(Preferences.shared.label(for: snapshot))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(p.ink)
                            Text(snapshot.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(p.muted)
                                .lineLimit(1)
                            Spacer()
                            if let peak = samples.compactMap({ max($0.session ?? 0, $0.long ?? 0) }).max(), samples.count >= 3 {
                                Text("peak \(Int(peak.rounded()))%")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(p.muted)
                            }
                        }
                        if samples.count >= 3 {
                            HistoryChart(samples: samples, range: TimeInterval(days) * 86400,
                                         shortTitle: snapshot.shortest?.title ?? "Session",
                                         longTitle: snapshot.weekly?.title ?? snapshot.windows.first { $0.kind == .monthly }?.title ?? "Weekly")
                            if let line = paceLine(for: snapshot) {
                                Text(line)
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(p.muted)
                                    .lineLimit(1)
                            }
                            if let line = spendLine(for: snapshot) {
                                Text(line)
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(p.muted)
                                    .lineLimit(1)
                                    .help("What Claude Code's work on this account would have cost at API list prices, from its session logs — the plan-value stat.")
                            }
                        } else {
                            Text("Not enough history yet — a few polls in, a line appears here.")
                                .font(.system(size: 11))
                                .foregroundStyle(p.muted)
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .scrollIfTall()
    }
}

/// A pane that may outgrow the screen scrolls inside a fixed height instead.
private struct ScrollIfTall: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView { content }
            .frame(maxHeight: 640)
    }
}

private extension View {
    func scrollIfTall() -> some View { modifier(ScrollIfTall()) }
}

// MARK: - Settings layout, on the panel's tokens

/// A pane: sections stacked on the slate page, one width.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .background(Palette.resolve(scheme).page)
    }
}

/// A titled card of rows.
struct SettingsSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    init(_ title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let p = Palette.resolve(scheme)
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                FieldLabel(text: title)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
    }
}

/// One setting: its name on the left, its control on the right.
struct SettingsRow<Control: View>: View {
    var label: String
    @ViewBuilder var control: Control
    @Environment(\.colorScheme) private var scheme

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Palette.resolve(scheme).ink)
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
    }
}

/// A line of explanation at the bottom of a card.
struct SettingsNote: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.resolve(scheme).muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.top, -2)
            .padding(.bottom, 10)
    }
}

struct Hairline: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Palette.resolve(scheme).divider
            .frame(height: 1)
            .padding(.leading, 12)
    }
}

// MARK: - Accounts

/// One account: who it is, whether it is live, and what can be done to it.
struct AccountRow: View {
    var snapshot: AccountSnapshot

    @State private var settings = Preferences.shared
    @State private var renaming = false
    @State private var draft = ""
    @State private var pricing = false
    @State private var costDraft = ""
    @State private var confirmingRemoval = false
    @State private var hoveringMenu = false
    @State private var launchNotice: String?
    @Environment(\.colorScheme) private var scheme
    private var signIn: SignIn { .shared }

    private var profile: ClaudeProfiles.Profile? { ClaudeProfiles.profile(matching: snapshot) }
    private var geminiAccount: GeminiAccounts.Account? { GeminiAccounts.account(matching: snapshot) }

    /// A sign-in Burn can run for this row: the card's own fix when it has one, else the profile we know.
    private var loginTarget: LoginTarget? {
        if case let .signIn(target)? = snapshot.problem?.action { return target }
        switch snapshot.providerID {
        case .grok: return .grok
        case .claude:
            if let profile { return .claude(profile: profile.path) }
            return KnownAccounts.load()[ClaudeProvider.defaultService]?.id == snapshot.id ? .claude(profile: nil) : nil
        case .gemini: return geminiAccount.map { .gemini(hint: $0.email) }
        case .codex, .cursor, .copilot: return nil
        }
    }

    /// What removing does depends on who owns the sign-in: a profile Burn made is signed out and deleted; anything
    /// else is simply forgotten here, and its CLI or app keeps its own sign-in.
    private var removalMessage: String {
        if let profile {
            return "Signs Claude Code out of \(profile.displayPath) and deletes that folder. The account itself is untouched."
        }
        if geminiAccount != nil {
            return "Signs this Google account out of Burn and forgets it. The account itself is untouched."
        }
        let owner: String
        switch snapshot.providerID {
        case .claude: owner = "Claude Code"
        case .codex: owner = "the ChatGPT app"
        case .grok: owner = "the Grok CLI"
        case .gemini: owner = "the Gemini CLI"
        case .cursor: owner = "the Cursor app"
        case .copilot: owner = "the GitHub CLI"
        }
        return "Burn stops showing and checking this account. Its sign-in stays as it is in \(owner) — switch accounts there if that's what you're after. Add Account… can bring it back."
    }

    private var details: String {
        var parts = [snapshot.identity, snapshot.subtitle.isEmpty ? nil : snapshot.subtitle].compactMap { $0 }
        if let profile { parts.append(profile.displayPath) }
        if Launchers.isInstalled(snapshot), let name = settings.installedLaunchers[snapshot.id] { parts.append(name) }
        if let launchNotice { parts.append(launchNotice) }
        return parts.joined(separator: " · ")
    }

    /// "$150/mo", "≈ $150/mo" while it is Burn's guess, "free" for a plan that costs nothing.
    private var costLabel: String? {
        guard let cost = settings.monthlyCost(for: snapshot) else { return nil }
        if cost == 0 { return "free" }
        return (settings.isCostEstimated(snapshot) ? "≈ " : "") + PlanPricing.label(cost)
    }

    var body: some View {
        let p = Palette.resolve(scheme)
        HStack(spacing: 10) {
            ProviderTile(provider: snapshot.providerID, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(settings.label(for: snapshot))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.ink)
                        .lineLimit(1)
                    StatusLabel(snapshot: snapshot)
                }
                Text(details)
                    .font(.system(size: 11))
                    .foregroundStyle(p.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            if let costLabel {
                Text(costLabel)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(p.muted)
                    .help(settings.isCostEstimated(snapshot) ? "Burn's guess from the plan name — set the real figure from the ⋯ menu" : "Set by you")
            }
            Toggle("Show", isOn: Binding(
                get: { !settings.hiddenAccountIDs.contains(snapshot.id) },
                set: { shown in
                    if shown { settings.hiddenAccountIDs.remove(snapshot.id) } else { settings.hiddenAccountIDs.insert(snapshot.id) }
                }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            Menu {
                Button("Rename…") {
                    draft = settings.customLabels[snapshot.id] ?? ""
                    renaming = true
                }
                Button("Monthly Cost…") {
                    costDraft = settings.monthlyCosts[snapshot.id].map { $0 == $0.rounded() ? String(format: "%.0f", $0) : String(format: "%.2f", $0) } ?? ""
                    pricing = true
                }
                if let target = loginTarget {
                    Button(snapshot.problem?.kind == .signedOut ? "Sign In…" : "Sign In Again…") { signIn.start(target) }
                        .disabled(signIn.isRunning)
                }
                if let profile {
                    Button("Show Profile in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: profile.path)])
                    }
                }
                if Launchers.canLaunch(snapshot) {
                    Divider()
                    Button("Open Terminal with This Account") { launchNotice = Launchers.open(snapshot) }
                    if Launchers.isInstalled(snapshot) {
                        Button("Remove `\(Launchers.command(for: snapshot))` Command") { Launchers.remove(snapshot) }
                    } else {
                        Button("Install `\(Launchers.command(for: snapshot))` Command") {
                            do { try Launchers.install(snapshot); launchNotice = nil } catch { launchNotice = (error as? Launchers.LauncherError)?.message ?? error.localizedDescription }
                        }
                    }
                } else if let app = Launchers.vendorApp(for: snapshot.providerID) {
                    Divider()
                    Button("Open \(app.name)") { _ = Launchers.openVendorApp(for: snapshot.providerID) }
                }
                Divider()
                Button("Remove Account…", role: .destructive) { confirmingRemoval = true }
                    .disabled(signIn.isRunning)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hoveringMenu ? p.ink : p.muted)
                    .frame(width: 26, height: 26)
                    .background(hoveringMenu ? p.control : .clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hoveringMenu = $0 }
            .help("More")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .alert("Rename \(snapshot.label)", isPresented: $renaming) {
            TextField("Name", text: $draft)
            Button("Save") {
                let trimmed = draft.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { settings.customLabels.removeValue(forKey: snapshot.id) } else { settings.customLabels[snapshot.id] = trimmed }
                if Launchers.isInstalled(snapshot) { try? Launchers.install(snapshot) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Shown on the card and in the menu bar. Leave it empty to go back to “\(snapshot.label)”.")
        }
        .alert("Monthly cost of \(settings.label(for: snapshot))", isPresented: $pricing) {
            TextField("Dollars a month", text: $costDraft)
            Button("Save") {
                let cleaned = costDraft.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                if let value = Double(cleaned), value >= 0 { settings.monthlyCosts[snapshot.id] = value } else { settings.monthlyCosts.removeValue(forKey: snapshot.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PlanPricing.estimate(for: snapshot).map { "Burn's guess from the plan name is \(PlanPricing.label($0)). Leave it empty to go back to that." } ?? "What this plan costs you a month.")
        }
        .confirmationDialog("Remove \(settings.label(for: snapshot))?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let profile {
                    Task { await signIn.removeProfile(profile) }
                } else if let geminiAccount {
                    Task { await signIn.removeGemini(geminiAccount) }
                } else {
                    UsageStore.shared.forget(snapshot)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
    }
}

struct StatusLabel: View {
    var snapshot: AccountSnapshot
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.resolve(scheme)
        let (text, color) = status(p)
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(p.muted)
        }
    }

    private func status(_ p: Palette) -> (String, Color) {
        if let problem = snapshot.problem {
            switch problem.kind {
            case .signedOut: return ("Signed out", p.markWarning)
            case .throttled: return ("Rate limited", p.markWarning)
            case .error: return ("Error", p.markCritical)
            }
        }
        if snapshot.isStale { return ("Stale · \(Relative.ago(snapshot.fetchedAt))", p.markWarning) }
        return ("Live", p.markFine)
    }
}

/// A sign-in in flight, or how it ended, with the CLI's own output a click away.
struct SignInRow: View {
    var job: SignIn.Job

    @State private var showOutput = false
    @State private var code = ""
    @Environment(\.colorScheme) private var scheme
    private var signIn: SignIn { .shared }

    var body: some View {
        let p = Palette.resolve(scheme)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                switch job.status {
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Signing in to \(job.target.providerID.displayName) — finish in your browser.")
                        .foregroundStyle(p.ink)
                case let .succeeded(message):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(p.markFine)
                    Text(message).foregroundStyle(p.ink)
                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(p.markWarning)
                    Text(message).foregroundStyle(p.ink).lineLimit(2)
                case let .duplicate(message):
                    Image(systemName: "person.crop.circle.badge.xmark").foregroundStyle(p.markWarning)
                    Text(message).foregroundStyle(p.ink).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if job.status == .running {
                    ControlButton("Cancel") { signIn.cancel() }
                } else {
                    ControlButton("Done") { signIn.dismiss() }
                }
            }
            .font(.system(size: 12))
            if job.status == .running, job.awaitingCode {
                HStack(spacing: 6) {
                    TextField("Paste the authentication code the browser showed", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit { signIn.submitCode(code); code = "" }
                    ControlButton("Submit") { signIn.submitCode(code); code = "" }
                }
            }
            if job.status == .running, let url = job.loginURL {
                HStack(spacing: 6) {
                    Text("Browser signed in to the wrong account?")
                    ControlButton("Copy sign-in link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Text("and paste it into a private window.")
                }
                .font(.system(size: 11))
                .foregroundStyle(p.muted)
            }
            if case .failed = job.status {
                HStack(spacing: 6) {
                    Text("Or run it yourself:")
                        .font(.system(size: 11))
                        .foregroundStyle(p.muted)
                    CommandPill(command: job.target.command)
                }
            }
            if !job.output.isEmpty {
                DisclosureGroup(isExpanded: $showOutput) {
                    ScrollView {
                        Text(job.output)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(p.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                } label: {
                    Text("CLI output")
                        .font(.system(size: 11))
                        .foregroundStyle(p.muted)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Google's sign-in, run by Burn: the browser opens Google's account chooser, and the account lands here.
struct AddGeminiSheet: View {
    var start: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var email = ""

    var body: some View {
        let p = Palette.resolve(scheme)
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Gemini account")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(p.title)
            Text("Your browser will open Google's account chooser; pick the account and allow access. Burn keeps the sign-in itself. Google now meters Gemini for individuals through Antigravity, so Burn signs in as Antigravity does and shows its Gemini session and weekly pools (Antigravity must be installed — it is).")
                .font(.system(size: 12))
                .foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Email")
                    .font(.system(size: 12))
                    .foregroundStyle(p.ink)
                TextField("optional — pre-selects the account", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(open)
            }
            HStack(spacing: 8) {
                Spacer()
                ControlButton("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                ControlButton("Open Browser", action: open)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(p.page)
    }

    private func open() {
        start(email)
        dismiss()
    }
}

/// What to expect before the browser opens — claude.ai signs in whoever the browser already is, which is exactly
/// the wrong account when you are adding a second one.
struct AddClaudeSheet: View {
    var start: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var email = ""

    var body: some View {
        let p = Palette.resolve(scheme)
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Claude account")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(p.title)
            Text("Your browser will open claude.ai and you sign in there — the account doesn't need to be signed in anywhere else; Burn keeps this sign-in in a profile of its own. If the browser ends on an *authentication code* instead of returning here, paste it into the field that appears in the Accounts list. One catch: claude.ai signs in whichever account the browser already has a session for — to add a different account, sign out at claude.ai first, or paste the copied sign-in link into a private window.")
                .font(.system(size: 12))
                .foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Email")
                    .font(.system(size: 12))
                    .foregroundStyle(p.ink)
                TextField("optional — pre-fills the sign-in page", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(open)
            }
            HStack(spacing: 8) {
                Spacer()
                ControlButton("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                ControlButton("Open Browser", action: open)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(p.page)
    }

    private func open() {
        start(email)
        dismiss()
    }
}
