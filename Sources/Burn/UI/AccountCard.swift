import AppKit
import SwiftUI

/// One account, as a row in the list. The first line says who; each line under it is one window as a thin bar
/// with its number and, like a Fritter due date, a clock and the time it resets. The bars of every account line up,
/// so the panel reads as a table. Like a Fritter row the card tints when something is due: yellow when the tightest
/// window is getting low, red when it is nearly out, and the name follows.
struct AccountCard: View {
    var snapshot: AccountSnapshot
    var samples: [History.Sample]
    /// Rate and run-out per pooled window id, from the store; empty for stale cards.
    var paces: [String: Pace] = [:]

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    /// A one-line reply to a row action ("Copied claude-atlas…"), in the subtitle's place for a moment.
    @State private var notice: String?
    private var p: Palette { .resolve(scheme) }
    private var settings: Preferences { Preferences.shared }

    /// The pooled windows first (session, daily, weekly), then model caps that have started to fill.
    private var bars: [UsageWindow] {
        snapshot.windows.filter { $0.kind.isPooled || ($0.kind == .model && $0.isNotable) }
    }
    /// Spend and credits have no meaningful bar; they get a line of words, only when they say something.
    private var notes: [String] {
        var out: [String] = []
        if let detail = snapshot.session?.detail { out.append(detail) }
        for w in snapshot.windows where w.kind == .spend && w.isNotable {
            out.append([w.title, w.detail ?? "\(Int(w.usedPercent.rounded()))%"].joined(separator: " "))
        }
        return out
    }
    /// What the row as a whole says: the state of whichever pooled window is closest to its limit.
    private var cardTone: Theme.Tone {
        Theme.tone(forUsedPercent: snapshot.tightest?.usedPercent ?? 0, stale: snapshot.isStale || snapshot.tightest == nil)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 8) {
                header
                if !bars.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(bars) { barRow($0, now: context.date) }
                        if !notes.isEmpty {
                            Text(notes.joined(separator: " · "))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(p.muted)
                                .lineLimit(1)
                        }
                    }
                    .opacity(snapshot.isStale ? 0.55 : 1)
                }
                if let problem = snapshot.problem {
                    problemLine(problem, standalone: bars.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardTone.cardFill(p), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .onHover { hovering = $0 }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            ProviderTile(provider: snapshot.providerID, size: 22)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(settings.label(for: snapshot))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(cardTone.titleColor(p))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(notice ?? subtitleLine)
                    .font(.system(size: 11))
                    .foregroundStyle(p.muted)
                    .lineLimit(1)
            }
            if let condition = Optional(VendorStatus.shared.condition(for: snapshot.providerID)), condition.isTrouble {
                VendorChip(provider: snapshot.providerID, condition: condition)
            }
            if let surge {
                SurgeChip(text: surge.text, help: surge.help)
            }
            Spacer(minLength: 8)
            if bars.isEmpty, let problem = snapshot.problem {
                ProblemFix(problem: problem)
            } else if snapshot.isStale {
                StaleBadge(since: snapshot.fetchedAt)
            } else if samples.count >= 3, let first = samples.first, Date.now.timeIntervalSince(first.t) >= 6 * 3600 {
                // A 24-hour glyph needs a few hours of history before it has a shape; a blip at the edge just looks broken.
                Sparkline(samples: samples)
                    .frame(width: 64)
                    .help("Session usage over the last 24 hours")
            }
        }
        .help(snapshot.identity ?? "")
        // The row's menu floats over the trailing edge on hover, so it costs the subtitle no room the rest of the time.
        .overlay(alignment: .trailing) {
            rowMenu
                .background(cardTone.cardFill(p).opacity(0.9), in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .opacity(hovering ? 1 : 0)
        }
    }

    /// What to do with this account, on hover: open it where it lives, or hide the row.
    private var rowMenu: some View {
        Menu {
            if Launchers.canLaunch(snapshot) {
                Button("Open Terminal with This Account") { say(Launchers.open(snapshot)) }
                Button("Copy Command") {
                    do {
                        let name = Launchers.isInstalled(snapshot) ? settings.installedLaunchers[snapshot.id]! : try Launchers.install(snapshot)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(name, forType: .string)
                        say("Copied \(name)")
                    } catch { say((error as? Launchers.LauncherError)?.message ?? error.localizedDescription) }
                }
            } else if let app = Launchers.vendorApp(for: snapshot.providerID) {
                Button("Open \(app.name)") { if !Launchers.openVendorApp(for: snapshot.providerID) { say("\(app.name) isn't installed") } }
            }
            Divider()
            Button("Hide") { settings.hiddenAccountIDs.insert(snapshot.id) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(p.muted)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private func say(_ message: String?) {
        guard let message else { return }
        notice = message
        Task { try? await Task.sleep(for: .seconds(4)); if notice == message { notice = nil } }
    }

    /// The plan and what it costs. The tile beside the name already says which provider this is.
    private var subtitleLine: String {
        var parts: [String] = []
        if !snapshot.subtitle.isEmpty { parts.append(snapshot.subtitle) }
        if let cost = settings.monthlyCost(for: snapshot), cost > 0 { parts.append(PlanPricing.label(cost)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Bars

    private func barRow(_ w: UsageWindow, now: Date) -> some View {
        let tone = Theme.tone(forUsedPercent: w.usedPercent, stale: snapshot.isStale)
        let pace = paces[w.id]
        let fast = pace?.verdict == .fast
        return HStack(spacing: 8) {
            FieldLabel(text: w.title)
                .frame(width: 60, alignment: .leading)
                .help(w.title)
            MeterBar(usedPercent: w.usedPercent, tone: tone, height: 6, marker: pace?.expectedNow)
            Text("\(Int(w.usedPercent.rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(p.ink)
                .frame(width: 34, alignment: .trailing)
            HStack(spacing: 3) {
                if w.resetsAt != nil {
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .medium))
                }
                Text(resetText(w, now: now))
                    .font(.system(size: 11).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(fast ? p.textWarning : p.muted)
            .frame(width: 96, alignment: .leading)
            .help(paceHelp(w, pace: pace, now: now))
        }
    }

    /// The reset time, and what the recent rate says about it.
    private func paceHelp(_ w: UsageWindow, pace: Pace?, now: Date) -> String {
        var parts: [String] = []
        if let reset = w.resetsAt { parts.append("Resets \(Relative.clock(reset))") }
        if let pace {
            switch pace.verdict {
            case .early: break
            case .stalled: parts.append("nothing used lately")
            case .onPace: parts.append("\(pace.rateText) — lasts until the reset at this pace")
            case .fast:
                if let runOut = pace.runOut, let shortfall = pace.shortfall {
                    parts.append("at \(pace.rateText) it runs out \(Relative.clock(runOut)), \(Relative.countdown(to: now.addingTimeInterval(shortfall), from: now)) before it resets")
                }
            }
            if let expected = pace.expectedNow { parts.append("even pace would be \(Int(expected.rounded())) %") }
            if let multiple = pace.multiple, let typical = pace.typical, pace.verdict != .early, pace.verdict != .stalled {
                parts.append("\(Baseline.multipleText(multiple)) your usual \(Pace(rate: typical, runOut: nil, expectedNow: nil, verdict: .onPace, shortfall: nil).rateText)")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// The account's strongest surge, if any: a window at the user's multiple of its typical busy hour, or a model
    /// (or the account) at that multiple of a typical day's API work.
    private var surge: (text: String, help: String)? {
        let threshold = settings.surgeMultiple
        var best: (multiple: Double, help: String)?
        for window in snapshot.windows where window.kind.isPooled {
            guard let pace = paces[window.id], Alerts.isSurging(pace, kind: window.kind, threshold: threshold),
                  let multiple = pace.multiple, let typical = pace.typical else { continue }
            if multiple > (best?.multiple ?? 0) {
                best = (multiple, "\(window.title) at \(pace.rateText); \(Pace(rate: typical, runOut: nil, expectedNow: nil, verdict: .onPace, shortfall: nil).rateText) is typical for this account")
            }
        }
        for s in APISpend.shared.surges(for: [snapshot], multiple: threshold) where s.multiple > (best?.multiple ?? 0) {
            let what = s.model.map { "\(Alerts.modelName($0)) " } ?? ""
            best = (s.multiple, "\(what)\(APISpend.label(s.today)) of API work today; \(APISpend.label(s.typical)) is a typical day")
        }
        return best.map { ("\(Baseline.multipleText($0.multiple)) usual", $0.help) }
    }

    /// A countdown while it is today, a weekday and time within the week, a date beyond that.
    private func resetText(_ w: UsageWindow, now: Date) -> String {
        guard let reset = w.resetsAt else { return "" }
        if reset <= now { return "resetting" }
        let remaining = reset.timeIntervalSince(now)
        if remaining < 20 * 3600 { return Relative.countdown(to: reset, from: now) }
        if remaining < 6 * 86400 { return Relative.clock(reset) }
        return Relative.day(reset)
    }

    // MARK: - Problem states

    /// Under the bars when the numbers are stale; the whole story when there are no numbers at all.
    private func problemLine(_ problem: AccountProblem, standalone: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: problem.kind == .throttled ? "hourglass" : "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(p.markWarning)
            (Text(problem.title).foregroundStyle(p.ink) + Text(standalone ? " — " : ". ").foregroundStyle(p.muted) + Text(problem.hint).foregroundStyle(p.muted))
                .font(.system(size: 11))
                .lineLimit(standalone ? 3 : 2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The fix beside a problem: a button when Burn can run it itself (a CLI sign-in, or opening the app that
/// owns the account), the command to copy when it can't — and both when the button's attempt failed.
struct ProblemFix: View {
    var problem: AccountProblem

    @Environment(\.colorScheme) private var scheme
    private var signIn: SignIn { .shared }

    var body: some View {
        let p = Palette.resolve(scheme)
        switch problem.action {
        case let .signIn(target):
            if signIn.isRunning(target) {
                if signIn.job?.awaitingCode == true {
                    CodeField()
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Finish in your browser…")
                            .font(.system(size: 11))
                            .foregroundStyle(p.muted)
                        ControlButton("Cancel") { signIn.cancel() }
                    }
                }
            } else if signIn.failure(for: target) != nil {
                HStack(spacing: 6) {
                    ControlButton("Try again") { signIn.start(target) }
                        .help(signIn.failure(for: target) ?? "")
                    CommandPill(command: target.command)
                }
            } else {
                ControlButton("Sign in…") { signIn.start(target) }
            }
        case let .openApp(bundleID, name):
            ControlButton("Open \(name)") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        case let .openLink(url, title):
            ControlButton(title) {
                if let url = URL(string: url) { NSWorkspace.shared.open(url) }
            }
        case nil:
            if let command = problem.command {
                CommandPill(command: command)
            }
        }
    }
}

/// Where the browser's authentication code goes when Claude's login ends on one instead of returning.
struct CodeField: View {
    @State private var code = ""
    private var signIn: SignIn { .shared }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Paste the authentication code", text: $code)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { signIn.submitCode(code); code = "" }
            ControlButton("Submit") { signIn.submitCode(code); code = "" }
            ControlButton("Cancel") { signIn.cancel() }
        }
    }
}

/// A text button on the design's control surface.
struct ControlButton: View {
    var title: String
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.resolve(scheme).ink)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .controlSurface(hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ProviderTile: View {
    var provider: ProviderID
    var size: CGFloat = 22

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.resolve(scheme)
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.tileColor(provider, palette: p))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: Theme.tileSymbol(provider))
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(Theme.tileSymbolColor(provider, palette: p))
            )
            .accessibilityLabel(provider.displayName)
    }
}

/// "Degraded" or "Outage", from the vendor's own status page; the incident is the tooltip, the page is a click away.
struct VendorChip: View {
    var provider: ProviderID
    var condition: VendorCondition

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.resolve(scheme)
        let outage = { if case .outage = condition { true } else { false } }()
        Button {
            if let page = provider.statusPage?.page { NSWorkspace.shared.open(page) }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(outage ? p.markCritical : p.markWarning).frame(width: 5, height: 5)
                Text(condition.title ?? "")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(outage ? p.textCritical : p.textWarning)
            }
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(outage ? p.cardCritical : p.cardWarning, in: Capsule())
        }
        .buttonStyle(.plain)
        .help("\(provider.vendorName): \(condition.incident ?? condition.title ?? "") — click for the status page")
    }
}

/// "3× usual" — this account is burning well past its own norm; the tooltip says which window or model.
struct SurgeChip: View {
    var text: String
    var help: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.resolve(scheme)
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(p.markWarning)
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(p.textWarning)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(p.cardWarning, in: Capsule())
        .help(help)
    }
}

struct StaleBadge: View {
    var since: Date

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.resolve(scheme)
        HStack(spacing: 4) {
            Circle().fill(p.markWarning).frame(width: 5, height: 5)
            Text("Stale · \(Relative.ago(since))")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(p.badgeText)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(p.badge, in: Capsule())
    }
}

/// A one-line shell command with a copy affordance, on the control surface — the fix for every sign-in problem is
/// "run this once".
struct CommandPill: View {
    var command: String

    @Environment(\.colorScheme) private var scheme
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        let p = Palette.resolve(scheme)
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
        } label: {
            HStack(spacing: 6) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(p.ink)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(p.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .controlSurface(hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(copied ? "Copied" : "Copy command")
    }
}
