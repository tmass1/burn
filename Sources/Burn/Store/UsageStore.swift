import Foundation

/// Owns the snapshots every view reads. Polls providers on a timer, refreshes eagerly when the panel opens, and
/// never lets a failed fetch blank a card: the last good numbers stay, flagged stale, with the new problem attached.
@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var snapshots: [AccountSnapshot] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false

    let history: History
    private let providers: [any Provider] = [ClaudeProvider(), CodexProvider(), GrokProvider(), GeminiProvider(), CursorProvider(), CopilotProvider()]
    private let cacheFile: URL
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var backoffUntil: [ProviderID: Date] = [:]
    private var failures: [ProviderID: Int] = [:]
    /// Rate, run-out and pace marker per pooled window — account id, then window id — from the history, after every
    /// refresh. Nothing is persisted; stale cards get none.
    private(set) var paces: [String: [String: Pace]] = [:]

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Burn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        cacheFile = Self.supportDirectory.appendingPathComponent("snapshots.json")
        history = History(directory: Self.supportDirectory)
        if let data = FileManager.default.contents(atPath: cacheFile.path),
           let cached = try? JSONDecoder().decode([AccountSnapshot].self, from: data) {
            snapshots = cached.map { var s = $0; s.isStale = true; return s }
            lastRefresh = cached.map(\.fetchedAt).max()
        }
    }

    /// Cards in display order: Claude's default profile first, then its other accounts, then the other providers.
    var visibleSnapshots: [AccountSnapshot] {
        let hidden = Preferences.shared.hiddenAccountIDs
        return snapshots.filter { !hidden.contains($0.id) }
    }

    /// What the menu bar shows: the chosen primary account, else whichever card is closest to its limit.
    var headline: AccountSnapshot? {
        let candidates = visibleSnapshots.filter { $0.tightest != nil }
        if let id = Preferences.shared.primaryAccountID, let chosen = candidates.first(where: { $0.id == id }) { return chosen }
        return candidates.max { ($0.tightest?.usedPercent ?? 0) < ($1.tightest?.usedPercent ?? 0) }
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let seconds = await MainActor.run { Preferences.shared.pollIntervalSeconds }
                try? await Task.sleep(for: .seconds(max(60, seconds)))
            }
        }
    }

    func refreshIfStale(olderThan seconds: TimeInterval = 30) {
        guard let last = lastRefresh else { Task { await refresh() }; return }
        if Date.now.timeIntervalSince(last) > seconds { Task { await refresh() } }
    }

    /// `force` is the user pressing refresh: every provider and account tries again now, backoffs or not.
    func refresh(force: Bool = false) async {
        if let running = refreshTask { await running.value; return }
        let task = Task { await performRefresh(force: force) }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    // MARK: - Demo fixtures (design review only; never persisted)

    private(set) var isDemo = false

    func loadDemo(calm: Bool = false) {
        isDemo = true
        snapshots = Self.ordered(calm ? DemoData.calm : DemoData.snapshots)
        lastRefresh = .now
        DemoData.seedHistory(into: history)
        computePaces(now: .now)
        VendorStatus.shared.demo = calm ? [:] : [.claude: .degraded("Elevated errors on claude.ai")]
    }

    func leaveDemo() {
        guard isDemo else { return }
        isDemo = false
        paces = [:]
        VendorStatus.shared.demo = nil
        history.forget(prefix: "demo:")
        // Back to the last live numbers (stale until the refresh lands), so a provider that fails on the way back
        // keeps real windows, not fixtures — and no fixture ever reaches the notifications.
        if let data = FileManager.default.contents(atPath: cacheFile.path),
           let cached = try? JSONDecoder().decode([AccountSnapshot].self, from: data) {
            snapshots = cached.map { var s = $0; s.isStale = true; return s }
        } else {
            snapshots = []
        }
        Task { await refresh() }
    }

    private func performRefresh(force: Bool = false) async {
        guard !isDemo else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date.now
        let settings = Preferences.shared
        if force {
            backoffUntil = [:]
            await RetrySchedule.shared.reset()
        }
        let active = providers.filter { (backoffUntil[$0.id] ?? .distantPast) <= now && !settings.removedAccountKeys.contains($0.id.rawValue) }
        let fetched = await withTaskGroup(of: (ProviderID, [AccountSnapshot]).self) { group in
            for provider in active {
                group.addTask { (provider.id, await provider.fetch()) }
            }
            var out: [ProviderID: [AccountSnapshot]] = [:]
            for await (id, snaps) in group { out[id] = snaps }
            return out
        }

        var merged: [AccountSnapshot] = []
        for provider in providers {
            let previous = snapshots.filter { $0.providerID == provider.id }
            guard let fresh = fetched[provider.id] else { merged.append(contentsOf: previous); continue }

            // The provider as a whole backs off only when the vendor is throttling every account; a single account
            // it won't serve keeps its own retry schedule and must not slow the healthy ones down.
            let throttled = !fresh.isEmpty && fresh.allSatisfy { $0.problem?.kind == .throttled }
            if throttled {
                let count = (failures[provider.id] ?? 0) + 1
                failures[provider.id] = count
                backoffUntil[provider.id] = now.addingTimeInterval(min(1800, 120 * pow(2, Double(count - 1))))
            } else {
                failures[provider.id] = 0
                backoffUntil[provider.id] = nil
            }
            // A failure while the vendor's own status page reports an incident is their outage, not our sign-in:
            // the card says so, links to the page, and the provider waits at least five minutes before trying again.
            let condition = VendorStatus.shared.condition(for: provider.id)
            let failed = fresh.contains { $0.problem?.kind == .throttled || $0.problem?.kind == .error }
            if failed, condition.isTrouble {
                backoffUntil[provider.id] = max(backoffUntil[provider.id] ?? now, now.addingTimeInterval(300))
            }

            for var snapshot in fresh {
                if let problem = snapshot.problem, problem.kind != .signedOut, condition.isTrouble, let page = provider.id.statusPage?.page {
                    snapshot.problem = AccountProblem(
                        kind: problem.kind,
                        title: "\(provider.id.vendorName) is having an incident",
                        hint: "\(condition.incident ?? condition.title ?? "Degraded"). Backing off until it clears.",
                        command: nil,
                        action: .openLink(url: page.absoluteString, title: "Status page"))
                }
                var old = previous.first { $0.id == snapshot.id }
                // A single-account provider that fails before it can identify the account reports "<provider>:unknown";
                // that is still the one account we already know about.
                if old == nil, snapshot.id.hasSuffix(":unknown"), previous.count == 1 { old = previous.first }
                if snapshot.problem != nil, let old, !old.windows.isEmpty {
                    snapshot.id = old.id
                    snapshot.windows = old.windows
                    snapshot.fetchedAt = old.fetchedAt
                    snapshot.isStale = true
                    snapshot.label = old.label
                    snapshot.subtitle = old.subtitle
                    snapshot.identity = old.identity
                }
                merged.append(snapshot)
            }
        }

        let previous = snapshots
        snapshots = Self.ordered(merged.filter { !settings.isRemoved($0) })
        lastRefresh = now
        history.record(snapshots)
        computePaces(now: now)
        persist()
        Alerts.shared.evaluate(previous: previous, current: snapshots)
        Alerts.shared.evaluatePace(snapshots: snapshots, paces: paces)
        Alerts.shared.evaluateSurge(snapshots: snapshots, paces: paces)
    }

    func pace(for snapshot: AccountSnapshot, window: UsageWindow) -> Pace? {
        paces[snapshot.id]?[window.id]
    }

    private func computePaces(now: Date) {
        var out: [String: [String: Pace]] = [:]
        for snapshot in snapshots where snapshot.problem == nil && !snapshot.isStale {
            for window in snapshot.windows where window.kind.isPooled {
                let points = history.points(for: snapshot.id, window: window, last: History.denseFor)
                var pace = Pace.compute(points: points, window: window, now: now)
                pace.typical = Baseline.typicalRate(points: points, kind: window.kind, now: now)
                out[snapshot.id, default: [:]][window.id] = pace
            }
        }
        // A line in the log when a verdict changes, not on every poll.
        for (account, windows) in out {
            for (id, pace) in windows where paces[account]?[id]?.verdict != pace.verdict {
                Log.write("pace: \(account) \(id) \(pace.rateText) \(pace.verdict.rawValue)" + (pace.runOut.map { " · out \(Relative.clock($0))" } ?? ""))
            }
        }
        paces = out
        // For the command-line tool, which reads what the app knows rather than fetching anything itself.
        if let data = try? JSONEncoder().encode(out) {
            try? data.write(to: Self.supportDirectory.appendingPathComponent("paces.json"), options: .atomic)
        }
    }

    /// Stop showing and checking an account. The sign-in on this Mac is left alone; `restore` brings it back.
    func forget(_ snapshot: AccountSnapshot) {
        Launchers.remove(snapshot)
        Preferences.shared.remove(snapshot)
        snapshots.removeAll { Preferences.shared.isRemoved($0) }
        persist()
        Log.write("removed account \(snapshot.id)")
    }

    func restore(key: String) {
        Preferences.shared.restore(key: key)
        Log.write("restored account \(key)")
        Task { await refresh() }
    }

    private static func ordered(_ list: [AccountSnapshot]) -> [AccountSnapshot] {
        let defaultClaudeID = KnownAccounts.load()[ClaudeProvider.defaultService]?.id
        let providerRank: [ProviderID: Int] = Dictionary(uniqueKeysWithValues: ProviderID.allCases.enumerated().map { ($1, $0) })
        return list.sorted { a, b in
            let ra = providerRank[a.providerID] ?? 99, rb = providerRank[b.providerID] ?? 99
            if ra != rb { return ra < rb }
            if a.id == defaultClaudeID { return true }
            if b.id == defaultClaudeID { return false }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: cacheFile, options: .atomic)
    }
}
