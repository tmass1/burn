import Foundation

/// What Claude Code's work would have cost at API list prices — the plan-value stat: "your $150 plan did $1,400 of
/// API work this month". Read from the session logs Claude Code keeps under each profile's `projects/` folder
/// (`type: assistant` lines carry `message.usage` and `message.model`), incrementally: every file's offset is
/// remembered, so a scan after the first reads only what is new. Tokens are stored per day and model; prices are
/// applied when asked, so a price change re-prices history.
@MainActor
@Observable
final class APISpend {
    static let shared = APISpend()

    struct Totals: Codable, Sendable, Hashable {
        var input = 0, output = 0, cacheWrite5m = 0, cacheWrite1h = 0, cacheRead = 0
        var messages = 0

        static func += (lhs: inout Totals, rhs: Totals) {
            lhs.input += rhs.input; lhs.output += rhs.output
            lhs.cacheWrite5m += rhs.cacheWrite5m; lhs.cacheWrite1h += rhs.cacheWrite1h
            lhs.cacheRead += rhs.cacheRead; lhs.messages += rhs.messages
        }
    }

    /// Dollars per million tokens, Anthropic list prices (September 2026). Cache writes are 1.25× input for the
    /// five-minute cache and 2× for the one-hour cache; cache reads are a tenth of input, except Fable 5.1's $0.25.
    struct Price: Sendable {
        var input: Double, output: Double, cacheRead: Double
        var cacheWrite5m: Double { input * 1.25 }
        var cacheWrite1h: Double { input * 2 }

        static func forModel(_ model: String) -> Price? {
            let m = model.lowercased()
            if m.contains("fable-5-1") || m.contains("mythos-5-1") { return Price(input: 10, output: 50, cacheRead: 0.25) }
            if m.contains("fable") || m.contains("mythos") { return Price(input: 10, output: 50, cacheRead: 1) }
            if m.contains("opus") { return Price(input: 5, output: 25, cacheRead: 0.5) }
            if m.contains("sonnet-5") { return Price(input: 2, output: 10, cacheRead: 0.2) }
            if m.contains("sonnet") { return Price(input: 3, output: 15, cacheRead: 0.3) }
            if m.contains("haiku") { return Price(input: 1, output: 5, cacheRead: 0.1) }
            return nil
        }

        func cost(_ t: Totals) -> Double {
            (Double(t.input) * input + Double(t.output) * output + Double(t.cacheWrite5m) * cacheWrite5m
             + Double(t.cacheWrite1h) * cacheWrite1h + Double(t.cacheRead) * cacheRead) / 1_000_000
        }
    }

    /// Persisted: where each log file was read up to, the last message counted in it, and tokens per config dir →
    /// day → model.
    struct State: Codable, Sendable {
        var offsets: [String: Int] = [:]
        var lastKeys: [String: String] = [:]
        var days: [String: [String: [String: Totals]]] = [:]
    }

    private(set) var state = State()
    private(set) var lastScan: Date?
    private(set) var isScanning = false
    private var timer: Task<Void, Never>?
    private let file = UsageStore.supportDirectory.appendingPathComponent("spend.json")

    private init() {
        if let data = FileManager.default.contents(atPath: file.path),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        }
    }

    /// Scans at launch and every quarter hour (only new bytes are read); the Usage tab asks for a fresh scan when
    /// it opens.
    func start() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    /// The config dirs whose logs to read: every Claude account's profile, and `~/.claude` for the default one.
    static func configDirs(for snapshots: [AccountSnapshot]) -> [String: String] {
        var out: [String: String] = [:]
        for snapshot in snapshots where snapshot.providerID == .claude {
            if let profile = ClaudeProfiles.profile(matching: snapshot) { out[snapshot.id] = profile.path }
            else if KnownAccounts.load()[ClaudeProvider.defaultService]?.id == snapshot.id { out[snapshot.id] = NSString(string: "~/.claude").expandingTildeInPath }
        }
        return out
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let dirs = Array(Set(Self.configDirs(for: UsageStore.shared.snapshots).values))
        let before = state
        let after = await Task.detached(priority: .utility) { Scanner.scan(dirs: dirs, state: before) }.value
        state = after
        lastScan = .now
        if let data = try? JSONEncoder().encode(after) { try? data.write(to: file, options: .atomic) }
        Alerts.shared.evaluateSpend(surges(for: UsageStore.shared.snapshots, multiple: Preferences.shared.surgeMultiple))
    }

    // MARK: - Today against a typical day

    /// A model, or a whole account (`model == nil`), doing several times a typical day's work today.
    struct Surge: Sendable, Hashable {
        var account: String
        var model: String?
        var today: Double
        var typical: Double
        var tokens: Int
        var multiple: Double { today / typical }
    }

    /// Today's API-priced dollars per model and in total for one account, keyed by model ("" for the total).
    func today(for snapshot: AccountSnapshot, now: Date = .now) -> [String: (dollars: Double, tokens: Int)] {
        guard let dir = Self.configDirs(for: [snapshot])[snapshot.id], let models = state.days[dir]?[Self.dayKey(now)] else { return [:] }
        var out: [String: (dollars: Double, tokens: Int)] = [:]
        for (model, totals) in models {
            guard let price = Price.forModel(model) else { continue }
            let tokens = totals.input + totals.output + totals.cacheRead + totals.cacheWrite5m + totals.cacheWrite1h
            out[model] = (price.cost(totals), tokens)
            out["", default: (0, 0)].dollars += price.cost(totals)
            out["", default: (0, 0)].tokens += tokens
        }
        return out
    }

    /// Everything at or past `multiple` times its typical day, above the floors in `Baseline`. Model-level entries
    /// come first, then the account totals.
    func surges(for snapshots: [AccountSnapshot], multiple: Double, now: Date = .now) -> [Surge] {
        var out: [Surge] = []
        let todayKey = Self.dayKey(now)
        let cutoff = Self.dayKey(now.addingTimeInterval(-30 * 86400))
        for snapshot in snapshots where snapshot.providerID == .claude {
            guard let dir = Self.configDirs(for: [snapshot])[snapshot.id], let byDay = state.days[dir] else { continue }
            // Dollars per day per model, and per day in total, over the trailing month.
            var perModel: [String: [String: Double]] = [:]
            var perDay: [String: Double] = [:]
            for (day, models) in byDay where day >= cutoff {
                for (model, totals) in models {
                    guard let price = Price.forModel(model) else { continue }
                    let dollars = price.cost(totals)
                    perModel[model, default: [:]][day, default: 0] += dollars
                    perDay[day, default: 0] += dollars
                }
            }
            let current = today(for: snapshot, now: now)
            for (model, days) in perModel {
                guard let usage = current[model], usage.dollars >= Baseline.modelSpendFloor,
                      let typical = Baseline.typicalDaily(costs: days, today: todayKey), usage.dollars >= multiple * typical else { continue }
                out.append(Surge(account: snapshot.id, model: model, today: usage.dollars, typical: typical, tokens: usage.tokens))
            }
            if let usage = current[""], usage.dollars >= Baseline.accountSpendFloor,
               let typical = Baseline.typicalDaily(costs: perDay, today: todayKey), usage.dollars >= multiple * typical {
                out.append(Surge(account: snapshot.id, model: nil, today: usage.dollars, typical: typical, tokens: usage.tokens))
            }
        }
        return out.sorted { ($0.model == nil ? 1 : 0, -$0.multiple) < ($1.model == nil ? 1 : 0, -$1.multiple) }
    }

    /// API-priced dollars for one account over the last `days`, and the tokens that had no price.
    func cost(for snapshot: AccountSnapshot, days: Int, now: Date = .now) -> (dollars: Double, unpricedTokens: Int, messages: Int)? {
        guard let dir = Self.configDirs(for: [snapshot])[snapshot.id], let byDay = state.days[dir] else { return nil }
        let cutoff = Self.dayKey(now.addingTimeInterval(-Double(days) * 86400))
        var dollars = 0.0, unpriced = 0, messages = 0
        for (day, models) in byDay where day >= cutoff {
            for (model, totals) in models {
                messages += totals.messages
                if let price = Price.forModel(model) { dollars += price.cost(totals) }
                else { unpriced += totals.input + totals.output + totals.cacheRead + totals.cacheWrite5m + totals.cacheWrite1h }
            }
        }
        return messages == 0 ? nil : (dollars, unpriced, messages)
    }

    /// Across every Claude account.
    func total(days: Int, snapshots: [AccountSnapshot]) -> Double {
        snapshots.filter { $0.providerID == .claude }.compactMap { cost(for: $0, days: days)?.dollars }.reduce(0, +)
    }

    nonisolated static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func label(_ dollars: Double) -> String {
        dollars >= 100 ? "$\(Int(dollars.rounded()))" : String(format: "$%.0f", dollars)
    }

    // MARK: - The scan, off the main actor

    enum Scanner {
        static let keepDays = 90
        static let marker = Data("\"type\":\"assistant\"".utf8)

        nonisolated static func scan(dirs: [String], state: State) -> State {
            var state = state
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let plain = ISO8601DateFormatter()
            let cutoff = Date.now.addingTimeInterval(-Double(keepDays) * 86400)
            let fm = FileManager.default
            for dir in dirs {
                let root = dir + "/projects"
                guard let walker = fm.enumerator(atPath: root) else { continue }
                while let rel = walker.nextObject() as? String {
                    guard rel.hasSuffix(".jsonl") else { continue }
                    let path = root + "/" + rel
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let modified = attrs[.modificationDate] as? Date, modified >= cutoff,
                          let size = attrs[.size] as? Int else { continue }
                    let start = state.offsets[path] ?? 0
                    guard size > start, let handle = FileHandle(forReadingAtPath: path) else { continue }
                    defer { try? handle.close() }
                    try? handle.seek(toOffset: UInt64(start))
                    guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }
                    // Only whole lines; the tail of a line still being written waits for the next scan.
                    let end = data.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? 0
                    guard end > 0 else { continue }
                    let chunk = data[data.startIndex..<data.startIndex + end]
                    var consumed = 0
                    var last = state.lastKeys[path]
                    for line in chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                        consumed += line.count + 1
                        guard line.range(of: marker) != nil,
                              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              object["type"] as? String == "assistant",
                              let message = object["message"] as? [String: Any],
                              let usage = message["usage"] as? [String: Any] else { continue }
                        // Streaming writes one line per content block of a message, each repeating the message's whole
                        // usage; consecutive lines with the same message and request ids count once.
                        let key = "\((message["id"] as? String) ?? "")|\((object["requestId"] as? String) ?? "")"
                        if key == last { continue }
                        last = key
                        let model = (message["model"] as? String) ?? "unknown"
                        let stamp = (object["timestamp"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) } ?? modified
                        let day = dayKey(stamp)
                        var totals = Totals(
                            input: usage["input_tokens"] as? Int ?? 0,
                            output: usage["output_tokens"] as? Int ?? 0,
                            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0)
                        let creation = usage["cache_creation"] as? [String: Any]
                        let write1h = creation?["ephemeral_1h_input_tokens"] as? Int ?? 0
                        let writeAll = usage["cache_creation_input_tokens"] as? Int ?? 0
                        totals.cacheWrite1h = write1h
                        totals.cacheWrite5m = max(0, writeAll - write1h)
                        totals.messages = 1
                        var bucket = state.days[dir]?[day]?[model] ?? Totals()
                        bucket += totals
                        state.days[dir, default: [:]][day, default: [:]][model] = bucket
                    }
                    state.offsets[path] = start + consumed
                    if let last { state.lastKeys[path] = last }
                }
            }
            // Forget days beyond the window and files that are gone.
            let oldest = dayKey(cutoff)
            for (dir, days) in state.days { state.days[dir] = days.filter { $0.key >= oldest } }
            state.offsets = state.offsets.filter { fm.fileExists(atPath: $0.key) }
            state.lastKeys = state.lastKeys.filter { state.offsets[$0.key] != nil }
            return state
        }
    }
}
