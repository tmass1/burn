import Foundation

/// Fixture accounts covering every card state at once — plenty, getting low, nearly out, stale, signed out —
/// so the panel can be reviewed without waiting for real limits to move. Loaded by `burn://demo`.
enum DemoData {
    /// The same accounts with nothing wrong — for the website and README, where a panel full of errors would be
    /// the wrong first impression. Adds the providers the review set leaves out.
    static var calm: [AccountSnapshot] {
        let now = Date.now
        var list = snapshots.map { snapshot -> AccountSnapshot in
            var s = snapshot
            s.problem = nil
            s.isStale = false
            s.fetchedAt = now
            return s
        }
        list[3] = AccountSnapshot(
            id: "demo:grok", providerID: .grok, label: "Grok", subtitle: "SuperGrok · weekly pool", identity: "you@example.com",
            windows: [UsageWindow(id: "pool", kind: .weekly, title: "Weekly", usedPercent: 7, resetsAt: now.addingTimeInterval(3.2 * 86400), windowSeconds: 604800, detail: nil)],
            fetchedAt: now, problem: nil)
        list.append(AccountSnapshot(
            id: "demo:cursor", providerID: .cursor, label: "Cursor", subtitle: "Pro+ · included usage", identity: "you@example.com",
            windows: [UsageWindow(id: "monthly", kind: .monthly, title: "Monthly", usedPercent: 51, resetsAt: now.addingTimeInterval(17 * 86400), windowSeconds: 30 * 86400, detail: nil)],
            fetchedAt: now, problem: nil))
        list.append(AccountSnapshot(
            id: "demo:copilot", providerID: .copilot, label: "Copilot", subtitle: "Pro · monthly", identity: "@you",
            windows: [UsageWindow(id: "premium", kind: .monthly, title: "Premium", usedPercent: 22, resetsAt: now.addingTimeInterval(17 * 86400), windowSeconds: 30 * 86400, detail: nil)],
            fetchedAt: now, problem: nil))
        return list
    }

    static var snapshots: [AccountSnapshot] {
        let now = Date.now
        return [
            AccountSnapshot(
                id: "demo:claude:studio", providerID: .claude, label: "Studio", subtitle: "Team · Max 5×",
                identity: "you@studio.example",
                windows: [
                    UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: 31, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60), windowSeconds: 18000, detail: nil),
                    UsageWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 44, resetsAt: now.addingTimeInterval(4.6 * 86400), windowSeconds: 604800, detail: nil),
                    UsageWindow(id: "weekly:Fable", kind: .model, title: "Fable", usedPercent: 12, resetsAt: now.addingTimeInterval(4.6 * 86400), windowSeconds: 604800, detail: nil),
                    UsageWindow(id: "spend", kind: .spend, title: "Extra usage", usedPercent: 0, resetsAt: nil, windowSeconds: nil, detail: "$0 of $500"),
                ],
                fetchedAt: now, problem: nil),
            AccountSnapshot(
                id: "demo:claude:personal", providerID: .claude, label: "Personal", subtitle: "Max 5×",
                identity: "you@example.com",
                windows: [
                    UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: 88, resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60), windowSeconds: 18000, detail: nil),
                    UsageWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 63, resetsAt: now.addingTimeInterval(1.3 * 86400), windowSeconds: 604800, detail: nil),
                ],
                fetchedAt: now, problem: nil),
            AccountSnapshot(
                id: "demo:codex", providerID: .codex, label: "ChatGPT", subtitle: "Plus · Codex quota",
                identity: "you@example.com",
                windows: [
                    UsageWindow(id: "session", kind: .session, title: "Session", usedPercent: 53, resetsAt: now.addingTimeInterval(4 * 3600 + 5 * 60), windowSeconds: 18000, detail: "2 reset credits"),
                    UsageWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: 66, resetsAt: now.addingTimeInterval(4.8 * 86400), windowSeconds: 604800, detail: nil),
                    UsageWindow(id: "extra:gpt-5.6-luna", kind: .model, title: "gpt-5.6-luna", usedPercent: 1, resetsAt: now.addingTimeInterval(4.8 * 86400), windowSeconds: 604800, detail: nil),
                ],
                fetchedAt: now.addingTimeInterval(-11 * 60),
                problem: AccountProblem(kind: .throttled, title: "Rate limited", hint: "OpenAI is throttling usage lookups. Backing off.", command: nil),
                isStale: true),
            AccountSnapshot(
                id: "demo:grok", providerID: .grok, label: "Grok", subtitle: "Weekly pool",
                identity: nil, windows: [], fetchedAt: now,
                problem: AccountProblem(kind: .signedOut, title: "Grok session expired",
                                     hint: "Sign in once and this card takes over.",
                                        command: "grok login", action: .signIn(.grok))),
        ]
    }

    /// A day of sawtooth session usage per demo account, and six hours of slow climb on the longer windows and model
    /// caps, so every bar has a pace and a forecast to draw.
    @MainActor
    static func seedHistory(into history: History) {
        let now = Date.now
        for (index, snapshot) in calm.enumerated() {
            var samples: [History.Sample] = []
            let period = 5.0 * 3600
            let phase = Double(index) * 4000
            var t = now.addingTimeInterval(-24 * 3600)
            while t <= now, snapshot.session != nil {
                let age = t.timeIntervalSince1970 + phase
                let inWindow = age.truncatingRemainder(dividingBy: period) / period
                let peak = 40 + Double((index * 23) % 50)
                samples.append(History.Sample(t: t, session: min(100, inWindow * peak * 1.4), weekly: nil))
                t = t.addingTimeInterval(5 * 60)
            }
            // The Personal account has been burning through its session for the last hour: 60 % → 88 %, which at
            // 28 %/h runs out well before its reset — the fast case, for reviewing the marker, tint and banner. The
            // three days before that were a gentle 6 %/h, so the hour is also a surge ("4.7× usual") for the chip.
            if snapshot.id == "demo:claude:personal", let used = snapshot.session?.usedPercent {
                samples.removeAll()
                var t = now.addingTimeInterval(-3 * 86400)
                while t < now.addingTimeInterval(-3600) {
                    let inWindow = (t.timeIntervalSince1970 + phase).truncatingRemainder(dividingBy: period) / period
                    samples.append(History.Sample(t: t, session: inWindow * 30, weekly: nil))
                    t = t.addingTimeInterval(5 * 60)
                }
                for minute in stride(from: 60, through: 0, by: -5) {
                    let fraction = 1 - Double(minute) / 60
                    samples.append(History.Sample(t: now.addingTimeInterval(-Double(minute) * 60), session: used - 28 + 28 * fraction, weekly: nil))
                }
            }
            // Points an hour: gentle on a week, gentler on a month, a trickle on a model cap.
            let slow = snapshot.windows.filter { ($0.kind.isPooled && $0.kind != .session && $0.kind != .daily) || $0.kind == .model }
            if !slow.isEmpty {
                var t = now.addingTimeInterval(-6 * 3600)
                while t <= now {
                    // On the same five-minute grid as the session's samples: each one gains the slow windows.
                    let session = samples.firstIndex { abs($0.t.timeIntervalSince(t)) < 150 }.flatMap { samples.remove(at: $0).session }
                    let hoursAgo = now.timeIntervalSince(t) / 3600
                    func climb(_ w: UsageWindow) -> Double {
                        let rate = switch w.kind { case .monthly: 0.08; case .model: 0.1; default: 0.25 }
                        return max(0, w.usedPercent - rate * hoursAgo)
                    }
                    let pools = Dictionary(slow.filter(\.kind.isPooled).map { ($0.id, climb($0)) }, uniquingKeysWith: { a, _ in a })
                    let models = Dictionary(slow.filter { $0.kind == .model }.map { ($0.id, climb($0)) }, uniquingKeysWith: { a, _ in a })
                    samples.append(History.Sample(t: t, session: session, weekly: pools["weekly"], pools: pools.isEmpty ? nil : pools, models: models.isEmpty ? nil : models))
                    t = t.addingTimeInterval(5 * 60)
                }
                samples.sort { $0.t < $1.t }
            }
            history.replace(samples, for: snapshot.id)
        }
    }
}
