import Foundation

/// Utilization samples per account, taken on every successful poll: every poll for a week, then one an hour for
/// ninety days. Feeds the sparkline, the Usage tab and the pace maths.
@MainActor
final class History {
    struct Sample: Codable, Sendable, Hashable {
        var t: Date
        /// The short window — the session, or a daily allowance where the plan has no sessions.
        var session: Double?
        var weekly: Double?
        /// Every pooled window by id, for plans whose pools are neither (a monthly one, say). Absent on old samples.
        var pools: [String: Double]?

        /// The long window: weekly where there is one, else the fullest of the other pools.
        var long: Double? {
            if let weekly { return weekly }
            return pools?.filter { $0.key != "session" && !$0.key.hasPrefix("daily") }.values.max()
        }
    }

    nonisolated static let keepFor: TimeInterval = 90 * 86400
    /// Samples older than this are thinned to one an hour (the last of each hour), which keeps the file small and
    /// the sawtooth recognisable.
    nonisolated static let denseFor: TimeInterval = 7 * 86400

    private(set) var samples: [String: [Sample]] = [:]
    private let file: URL
    private var saveTask: Task<Void, Never>?

    init(directory: URL) {
        file = directory.appendingPathComponent("history.json")
        if let data = FileManager.default.contents(atPath: file.path),
           let decoded = try? JSONDecoder().decode([String: [Sample]].self, from: data) {
            samples = decoded.filter { !$0.key.hasPrefix("demo:") }
        }
    }

    /// Drops the fixture accounts' samples when demo mode ends, so they never mix with the real ones on disk.
    func forget(prefix: String) {
        let before = samples.count
        samples = samples.filter { !$0.key.hasPrefix(prefix) }
        if samples.count != before { scheduleSave() }
    }

    func record(_ snapshots: [AccountSnapshot]) {
        let now = Date.now
        for snapshot in snapshots where snapshot.problem == nil && !snapshot.isStale {
            var list = samples[snapshot.id] ?? []
            // One sample per minute is plenty; polls that come faster (panel opens) collapse into the latest.
            if let last = list.last, now.timeIntervalSince(last.t) < 55 { list.removeLast() }
            let pools = Dictionary(snapshot.windows.filter { $0.kind.isPooled }.map { ($0.id, $0.usedPercent) }, uniquingKeysWith: { a, _ in a })
            list.append(Sample(t: now, session: snapshot.shortest?.usedPercent, weekly: snapshot.weekly?.usedPercent, pools: pools.isEmpty ? nil : pools))
            list.removeAll { now.timeIntervalSince($0.t) > Self.keepFor }
            samples[snapshot.id] = Self.compacted(list, now: now)
        }
        scheduleSave()
    }

    /// Older than `denseFor`: one sample per hour, the last one in that hour. Newer samples are left alone.
    static func compacted(_ list: [Sample], now: Date) -> [Sample] {
        let boundary = now.addingTimeInterval(-denseFor)
        var out: [Sample] = []
        out.reserveCapacity(list.count)
        var lastHour: Int?
        for sample in list {
            if sample.t >= boundary {
                out.append(sample)
                continue
            }
            let hour = Int(sample.t.timeIntervalSince1970 / 3600)
            if hour == lastHour { out.removeLast() }
            out.append(sample)
            lastHour = hour
        }
        return out
    }

    /// In-memory only (no save) — used by demo fixtures so the real history file stays untouched.
    func replace(_ list: [Sample], for id: String) {
        samples[id] = list
    }

    func samples(for id: String, last interval: TimeInterval) -> [Sample] {
        let cutoff = Date.now.addingTimeInterval(-interval)
        return (samples[id] ?? []).filter { $0.t >= cutoff }
    }

    /// One window's readings, oldest first, for the pace maths. Samples from before `pools` was recorded fall back
    /// to the session/weekly fields by kind.
    func points(for id: String, window: UsageWindow, last interval: TimeInterval) -> [(t: Date, used: Double)] {
        samples(for: id, last: interval).compactMap { sample in
            let used: Double? = sample.pools?[window.id] ?? {
                switch window.kind {
                case .session, .daily: sample.session
                case .weekly: sample.weekly
                default: nil
                }
            }()
            return used.map { (t: sample.t, used: $0) }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = samples
        let file = file
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
