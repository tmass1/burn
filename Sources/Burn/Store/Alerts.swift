import AppKit
import UserNotifications

/// Four things worth interrupting for: a window crossing the threshold, a window that was getting low resetting —
/// room is back — a window that won't last at its pace, and usage running at several times this account's usual.
/// Anything else is what the panel is for.
@MainActor
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Alerts()

    /// Where "nearly out" begins — the user's threshold.
    static var criticalPercent: Double { Double(Preferences.shared.notifyThresholdPercent) }
    /// A window only counts as "reset" if it was worth watching (getting low) and dropped by a lot at once.
    static let watchedPercent: Double = 60
    static let resetDrop: Double = 40

    /// One notification per window per reset period; the key carries the reset time so the next period counts again.
    private var delivered: Set<String> = []
    private var authorized = false

    func start() {
        UNUserNotificationCenter.current().delegate = self
        guard Preferences.shared.notificationsEnabled else { return }
        requestAuthorization()
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                Alerts.shared.authorized = granted
                Log.write("notifications: \(granted ? "allowed" : "not allowed")\(error.map { " (\($0.localizedDescription))" } ?? "")")
            }
        }
    }

    /// Compare a refresh with the one before it. Cached numbers from an earlier launch are stale and never count as
    /// "before", so a launch after a day away doesn't announce every reset that happened meanwhile.
    func evaluate(previous: [AccountSnapshot], current: [AccountSnapshot]) {
        let settings = Preferences.shared
        guard settings.notificationsEnabled, !settings.isQuiet() else { return }
        let hidden = settings.hiddenAccountIDs
        let before = Dictionary(uniqueKeysWithValues: previous.filter { !$0.isStale && $0.problem == nil }.map { ($0.id, $0) })
        for snapshot in current where !snapshot.isStale && snapshot.problem == nil && !hidden.contains(snapshot.id) && !snapshot.id.hasPrefix("demo:") {
            guard let old = before[snapshot.id] else { continue }
            let label = Preferences.shared.label(for: snapshot)
            for window in snapshot.windows where window.kind.isPooled {
                guard let was = old.windows.first(where: { $0.id == window.id }) else { continue }
                let period = window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
                if was.usedPercent < Self.criticalPercent, window.usedPercent >= Self.criticalPercent {
                    deliver(key: "\(snapshot.id)|\(window.id)|critical|\(period)",
                            title: "\(label) \(window.title.lowercased()) nearly out",
                            body: "\(Int(window.usedPercent.rounded())) % used" + (window.resetsAt.map { " · resets \(Self.when($0))" } ?? ""),
                            sound: true, account: snapshot.id)
                }
                if settings.notifyOnReset, was.usedPercent >= Self.watchedPercent, window.usedPercent <= was.usedPercent - Self.resetDrop {
                    deliver(key: "\(snapshot.id)|\(window.id)|reset|\(period)",
                            title: "\(label) has room again",
                            body: "\(window.title) reset · \(Int(window.usedPercent.rounded())) % used",
                            sound: false, account: snapshot.id)
                }
            }
        }
    }

    /// The third thing worth interrupting for: a window that, at its current rate, runs out well before it resets.
    /// Only once it is half used — early in a window the rate says little — and once per window per reset period.
    func evaluatePace(snapshots: [AccountSnapshot], paces: [String: [String: Pace]]) {
        let settings = Preferences.shared
        guard settings.notificationsEnabled, settings.notifyOnPace, !settings.isQuiet() else { return }
        let hidden = settings.hiddenAccountIDs
        for snapshot in snapshots where !snapshot.isStale && snapshot.problem == nil && !hidden.contains(snapshot.id) && !snapshot.id.hasPrefix("demo:") {
            let label = settings.label(for: snapshot)
            for window in snapshot.windows where window.kind.isPooled {
                guard let pace = paces[snapshot.id]?[window.id], pace.verdict == .fast, window.usedPercent >= 50,
                      let runOut = pace.runOut, let reset = window.resetsAt else { continue }
                deliver(key: "\(snapshot.id)|\(window.id)|pace|\(Int(reset.timeIntervalSince1970))",
                        title: "\(label) \(window.title.lowercased()) runs out before it resets",
                        body: "\(pace.rateText) at this pace · out \(Self.when(runOut)) · resets \(Self.when(reset))",
                        sound: false, account: snapshot.id)
            }
        }
    }

    /// The fourth: a window burning at several times this account's usual busy hour — a loop nobody meant to leave
    /// running — before it is a threshold or run-out problem. Once per window per reset period.
    func evaluateSurge(snapshots: [AccountSnapshot], paces: [String: [String: Pace]]) {
        let settings = Preferences.shared
        guard settings.notificationsEnabled, settings.notifyOnSurge, !settings.isQuiet() else { return }
        let hidden = settings.hiddenAccountIDs
        for snapshot in snapshots where !snapshot.isStale && snapshot.problem == nil && !hidden.contains(snapshot.id) && !snapshot.id.hasPrefix("demo:") {
            let label = settings.label(for: snapshot)
            for window in snapshot.windows where window.kind.isPooled {
                guard let pace = paces[snapshot.id]?[window.id], Self.isSurging(pace, kind: window.kind, threshold: settings.surgeMultiple),
                      let multiple = pace.multiple else { continue }
                let period = window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
                deliver(key: "\(snapshot.id)|\(window.id)|surge|\(period)",
                        title: "\(label) \(window.title.lowercased()) is burning \(Baseline.multipleText(multiple)) your usual",
                        body: "\(pace.rateText) now · \(Pace(rate: pace.typical ?? 0, runOut: nil, expectedNow: nil, verdict: .onPace, shortfall: nil).rateText) is typical"
                            + (window.resetsAt.map { " · resets \(Self.when($0))" } ?? ""),
                        sound: false, account: snapshot.id)
            }
        }
    }

    /// A window counts as surging when its rate is a real number (above the floor for its kind) and at least the
    /// user's multiple of the typical busy hour.
    nonisolated static func isSurging(_ pace: Pace, kind: UsageWindow.Kind, threshold: Double) -> Bool {
        guard pace.verdict != .early, pace.verdict != .stalled, let multiple = pace.multiple else { return false }
        return pace.rate >= Baseline.rateFloor(kind: kind) && multiple >= threshold
    }

    /// And on the model side: a model, or an account, doing several times a typical day's API-priced work today.
    /// One banner per model per day; the account total only speaks when no single model already did.
    func evaluateSpend(_ surges: [APISpend.Surge]) {
        let settings = Preferences.shared
        guard settings.notificationsEnabled, settings.notifyOnSurge, !settings.isQuiet(), !surges.isEmpty else { return }
        let hidden = settings.hiddenAccountIDs
        let labels = Dictionary(uniqueKeysWithValues: UsageStore.shared.snapshots.map { ($0.id, settings.label(for: $0)) })
        let day = APISpend.dayKey(.now)
        for surge in surges where !hidden.contains(surge.account) && !surge.account.hasPrefix("demo:") {
            let label = labels[surge.account] ?? "Claude"
            let typical = "\(Baseline.multipleText(surge.multiple)) a typical day (\(APISpend.label(surge.typical)))"
            if let model = surge.model {
                deliver(key: "spend|model|\(surge.account)|\(model)|\(day)",
                        title: "\(Self.modelName(model)) on \(label): \(APISpend.label(surge.today)) of API work today",
                        body: "\(typical) · \(Self.tokens(surge.tokens)) tokens", sound: false, account: surge.account)
            } else {
                // Model banners come first in `surges`, so by now today's have been delivered (or were, earlier).
                let aModelSpoke = delivered.contains { $0.hasPrefix("spend|model|\(surge.account)|") && $0.hasSuffix("|\(day)") }
                guard !aModelSpoke else { continue }
                deliver(key: "spend|account|\(surge.account)|\(day)",
                        title: "\(label): \(APISpend.label(surge.today)) of API work today",
                        body: typical, sound: false, account: surge.account)
            }
        }
    }

    /// "claude-opus-5" → "Opus 5", "claude-sonnet-4-5-20250929" → "Sonnet 4.5".
    nonisolated static func modelName(_ model: String) -> String {
        var parts = model.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        parts.removeAll { $0.count == 8 && Int($0) != nil }   // a date suffix
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().filter { Int($0) != nil }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " \(version)")
    }

    /// "27M", "840K", "512".
    nonisolated static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? "\(Int((Double(count) / 1_000_000).rounded()))M"
            : count >= 1_000 ? "\(Int((Double(count) / 1_000).rounded()))K" : "\(count)"
    }

    /// Sample banners, for checking permission, sound and the click-through (`burn://alerts?test=1`).
    func deliverSample() {
        let stamp = Int(Date.now.timeIntervalSince1970)
        deliver(key: "sample-critical-\(stamp)", title: "ChatGPT session nearly out", body: "92 % used · resets in 1h 12m", sound: true, account: nil)
        deliver(key: "sample-reset-\(stamp)", title: "Studio has room again", body: "Session reset · 3 % used", sound: false, account: nil)
        deliver(key: "sample-pace-\(stamp)", title: "Personal session runs out before it resets", body: "28 %/h at this pace · out in 26m · resets in 2h 10m", sound: false, account: nil)
        deliver(key: "sample-surge-\(stamp)", title: "Opus 5 on Personal: $310 of API work today", body: "4× a typical day ($75) · 27M tokens", sound: false, account: nil)
    }

    private func deliver(key: String, title: String, body: String, sound: Bool, account: String?) {
        guard delivered.insert(key).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        if let account {
            content.threadIdentifier = account
            content.userInfo = ["account": account]
        }
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.write("notification failed: \(error.localizedDescription)") }
        }
        Log.write("notified: \(title) — \(body)")
    }

    private static func when(_ date: Date) -> String {
        date.timeIntervalSinceNow < 20 * 3600 ? "in \(Relative.countdown(to: date))" : Relative.clock(date)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show banners even while the app is frontmost (a menu-bar app is "frontmost" whenever its panel is open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Clicking a banner is a request to look: open the panel.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { PanelActions.shared.show() }
    }
}
