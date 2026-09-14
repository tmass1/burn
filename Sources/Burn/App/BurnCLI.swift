import AppKit
import Foundation

/// `burn` on the command line: a reader of what the app last wrote (`snapshots.json`, `paces.json`), never a
/// fetcher. Runs inside the app binary (`Burn cli …`) so it shares every type without a second target.
enum BurnCLI {
    static let usage = """
    usage: burn [command] [options]

      (no command)          one line per account: windows, used %, resets
      status [account]      one line for an account (default: the one the menu bar shows)
      json                  everything the app knows, as JSON
      statusline            a segment for the Claude Code status line (reads Claude Code's JSON on stdin)
      statusline --install  add the segment to the Claude Code status line (--dry-run shows the plan)
      refresh               ask the app to refresh now
      open                  show the panel
      install               write ~/.local/bin/burn
      launchers [install|remove] [account]
                            the claude-<account> commands: list them, install (all, or one), remove one

    options: --no-color   (NO_COLOR is respected too)
    exit codes: 2 the app has never run, 3 account not found
    """

    struct Data_ {
        var snapshots: [AccountSnapshot]
        var paces: [String: [String: Pace]]
        var fetchedAt: Date?
        var pollInterval: TimeInterval
        /// The user's "unusual" multiple from Settings, for the "3× usual" mark.
        var surgeMultiple: Double = 3
        var stale: Bool { (fetchedAt.map { Date.now.timeIntervalSince($0) } ?? .infinity) > 2 * pollInterval }
    }

    @MainActor
    static func run(_ args: [String]) -> Int32 {
        var args = args
        let color = !(args.contains("--no-color") || ProcessInfo.processInfo.environment["NO_COLOR"] != nil)
        args.removeAll { $0 == "--no-color" }
        let command = args.first ?? "table"
        switch command {
        case "-h", "--help", "help":
            print(usage); return 0
        case "refresh", "open":
            return openURL("burn://\(command == "open" ? "show" : "refresh")")
        case "install":
            do { print("installed \(try CommandLineTool.installTool())"); return 0 }
            catch { fputs("could not write \(CommandLineTool.toolPath): \(error.localizedDescription)\n", stderr); return 1 }
        case "statusline" where args.contains("--install"):
            let plan = CommandLineTool.statuslinePlan()
            if args.contains("--dry-run") { print(plan.map { "would " + $0 }.joined(separator: "\n")); return 0 }
            do {
                try CommandLineTool.installStatusline()
                print(plan.map { "did " + $0 }.joined(separator: "\n"))
                print("Open a new Claude Code session to see it.")
                return 0
            } catch { fputs("could not install: \(error.localizedDescription)\n", stderr); return 1 }
        default: break
        }

        guard let data = load() else {
            fputs("Burn hasn't written anything yet — open the app once, or its data could not be read.\n", stderr)
            return 2
        }
        let tty = isatty(STDOUT_FILENO) != 0
        switch command {
        case "table":
            print(table(data, color: color && tty))
            return 0
        case "status":
            let wanted = args.dropFirst().first
            guard let account = pick(wanted, from: data) else {
                fputs(wanted.map { "no account matches \"\($0)\"\n" } ?? "no accounts\n", stderr); return 3
            }
            print(line(account, data: data, color: color && tty)); return 0
        case "json":
            print(json(data)); return 0
        case "launchers":
            return launchers(Array(args.dropFirst()), data: data)
        case "statusline":
            _ = FileHandle.standardInput.readDataToEndOfFile()  // Claude Code's context; the account comes from the environment
            if let segment = statusline(data, color: color) { print(segment) }
            return 0
        default:
            fputs("unknown command \(command)\n\n\(usage)\n", stderr); return 64
        }
    }

    // MARK: - Data

    @MainActor
    static func load() -> Data_? {
        let dir = UsageStore.supportDirectory
        guard let raw = FileManager.default.contents(atPath: dir.appendingPathComponent("snapshots.json").path),
              let snapshots = try? JSONDecoder().decode([AccountSnapshot].self, from: raw) else { return nil }
        let paces = FileManager.default.contents(atPath: dir.appendingPathComponent("paces.json").path)
            .flatMap { try? JSONDecoder().decode([String: [String: Pace]].self, from: $0) } ?? [:]
        let defaults = UserDefaults.standard
        let hidden = Set(defaults.stringArray(forKey: "hiddenAccountIDs") ?? [])
        let interval = defaults.integer(forKey: "pollIntervalSeconds")
        let multiple = defaults.double(forKey: "surgeMultiple")
        return Data_(snapshots: snapshots.filter { !hidden.contains($0.id) }, paces: paces,
                     fetchedAt: snapshots.map(\.fetchedAt).max(), pollInterval: TimeInterval(interval > 0 ? interval : 180),
                     surgeMultiple: multiple > 0 ? multiple : 3)
    }

    static func label(_ snapshot: AccountSnapshot) -> String {
        (UserDefaults.standard.dictionary(forKey: "customLabels") as? [String: String])?[snapshot.id] ?? snapshot.label
    }

    /// The account named on the command line, else the one the menu bar shows.
    static func pick(_ wanted: String?, from data: Data_) -> AccountSnapshot? {
        if let wanted {
            let needle = wanted.lowercased()
            return data.snapshots.first { $0.id.lowercased() == needle }
                ?? data.snapshots.first { label($0).lowercased() == needle }
                ?? data.snapshots.first { label($0).lowercased().hasPrefix(needle) || $0.identity?.lowercased().contains(needle) == true }
        }
        let candidates = data.snapshots.filter { $0.tightest != nil }
        if let id = UserDefaults.standard.string(forKey: "primaryAccountID"), let chosen = candidates.first(where: { $0.id == id }) { return chosen }
        return candidates.max { ($0.tightest?.usedPercent ?? 0) < ($1.tightest?.usedPercent ?? 0) }
    }

    // MARK: - Text

    static func table(_ data: Data_, color: Bool) -> String {
        let width = data.snapshots.map { label($0).count }.max() ?? 8
        var lines = data.snapshots.map { snapshot -> String in
            let name = label(snapshot).padding(toLength: width, withPad: " ", startingAt: 0)
            return "\(name)  \(windows(snapshot, data: data, color: color))"
        }
        if data.stale, let at = data.fetchedAt { lines.append(paint("last refreshed \(Relative.ago(at)) — the app may not be running", .dim, color)) }
        return lines.joined(separator: "\n")
    }

    static func line(_ snapshot: AccountSnapshot, data: Data_, color: Bool) -> String {
        "\(label(snapshot)) · \(windows(snapshot, data: data, color: color, separator: " · "))"
    }

    /// "session 25% · resets 2h 27m   weekly 15% · Thu 9:00 AM", with the problem instead when there are no numbers.
    static func windows(_ snapshot: AccountSnapshot, data: Data_, color: Bool, separator: String = "   ") -> String {
        let pooled = snapshot.windows.filter { $0.kind.isPooled }
        if pooled.isEmpty, let problem = snapshot.problem { return paint(problem.title, .dim, color) }
        var parts = pooled.map { w -> String in
            var part = "\(w.title.lowercased()) \(percent(w, stale: snapshot.isStale, color: color))"
            if let reset = w.resetsAt { part += " · resets \(resetText(reset))" }
            if let pace = data.paces[snapshot.id]?[w.id] {
                if pace.verdict == .fast, let out = pace.runOut { part += " · " + paint("runs out \(resetText(out))", .amber, color) }
                if Alerts.isSurging(pace, kind: w.kind, threshold: data.surgeMultiple), let multiple = pace.multiple {
                    part += " · " + paint("\(Baseline.multipleText(multiple)) usual", .amber, color)
                }
            }
            return part
        }
        if snapshot.isStale, let problem = snapshot.problem { parts.append(paint("stale — \(problem.title.lowercased())", .dim, color)) }
        else if snapshot.isStale { parts.append(paint("stale", .dim, color)) }
        return parts.joined(separator: separator)
    }

    static func percent(_ w: UsageWindow, stale: Bool, color: Bool) -> String {
        let text = "\(Int(w.usedPercent.rounded()))%"
        switch Theme.tone(forUsedPercent: w.usedPercent, stale: stale) {
        case .fine: return paint(text, .green, color)
        case .warning: return paint(text, .amber, color)
        case .critical: return paint(text, .red, color)
        case .stale: return paint(text, .dim, color)
        }
    }

    /// The same shape as the panel: a countdown today, a weekday and time within the week, a date beyond.
    static func resetText(_ date: Date, now: Date = .now, countdownPrefix: String = "in ") -> String {
        if date <= now { return "now" }
        let remaining = date.timeIntervalSince(now)
        if remaining < 20 * 3600 { return countdownPrefix + Relative.countdown(to: date, from: now) }
        if remaining < 6 * 86400 { return Relative.clock(date) }
        return Relative.day(date)
    }

    // MARK: - Status line

    /// A segment for the Claude Code status line: the Claude account whose profile is `CLAUDE_CONFIG_DIR`, else the
    /// default profile's. Nothing at all when there is no match, so the line never shows an error.
    static func statusline(_ data: Data_, color: Bool) -> String? {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { NSString(string: $0).standardizingPath }
        let known = KnownAccounts.load()
        let id: String? = {
            if let env {
                let profile = ClaudeProfiles.load().first { NSString(string: $0.path).standardizingPath == env }
                return profile?.service.flatMap { known[$0]?.id }
            }
            return known[ClaudeProvider.defaultService]?.id
        }()
        guard let id, let snapshot = data.snapshots.first(where: { $0.id == id }) else { return nil }
        let short = label(snapshot).split(separator: " ").first.map(String.init) ?? label(snapshot)
        var parts = ["\u{25D0} \(short)"]
        if let s = snapshot.shortest {
            var part = percent(s, stale: snapshot.isStale, color: color)
            if let reset = s.resetsAt { part += " · \(resetText(reset, countdownPrefix: ""))" }
            parts.append(part)
        }
        if let w = snapshot.weekly { parts.append("wk \(percent(w, stale: snapshot.isStale, color: color))") }
        if snapshot.shortest == nil, snapshot.weekly == nil, let problem = snapshot.problem {
            parts.append(paint(problem.title.lowercased(), .dim, color))
        }
        if let pace = data.paces[snapshot.id]?[snapshot.shortest?.id ?? ""], pace.verdict == .fast, let out = pace.runOut {
            parts.append(paint("out \(resetText(out))", .amber, color))
        }
        if data.stale, let at = data.fetchedAt { parts.append(paint("\(Relative.ago(at))", .dim, color)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Launchers

    @MainActor
    static func launchers(_ args: [String], data: Data_) -> Int32 {
        let launchable = data.snapshots.filter { Launchers.canLaunch($0) }
        switch args.first {
        case nil:
            if launchable.isEmpty { print("No Claude accounts with a profile yet."); return 0 }
            for snapshot in launchable {
                let name = Launchers.command(for: snapshot)
                print("\(name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(label(snapshot))  \(Launchers.isInstalled(snapshot) ? "installed" : "not installed")")
            }
            if !Launchers.binOnPath { print("~/.local/bin is not on your PATH.") }
            return 0
        case "install":
            let targets = args.count > 1 ? [pick(args[1], from: Data_(snapshots: launchable, paces: [:], fetchedAt: nil, pollInterval: 1))].compactMap { $0 } : launchable
            guard !targets.isEmpty else { fputs("no such account\n", stderr); return 3 }
            for snapshot in targets {
                do { print("installed \(Launchers.binDirectory)/\(try Launchers.install(snapshot))") }
                catch { fputs("\(label(snapshot)): \((error as? Launchers.LauncherError)?.message ?? error.localizedDescription)\n", stderr); return 1 }
            }
            return 0
        case "remove":
            guard args.count > 1, let snapshot = pick(args[1], from: Data_(snapshots: launchable, paces: [:], fetchedAt: nil, pollInterval: 1)) else {
                fputs("which one? burn launchers remove <account>\n", stderr); return 3
            }
            Launchers.remove(snapshot); print("removed"); return 0
        default:
            fputs("usage: burn launchers [install|remove] [account]\n", stderr); return 64
        }
    }

    // MARK: - JSON

    @MainActor
    static func json(_ data: Data_) -> String {
        let iso = ISO8601DateFormatter()
        let accounts: [[String: Any]] = data.snapshots.map { snapshot in
            var entry: [String: Any] = [
                "id": snapshot.id, "provider": snapshot.providerID.rawValue, "label": label(snapshot),
                "plan": snapshot.subtitle, "stale": snapshot.isStale, "fetchedAt": iso.string(from: snapshot.fetchedAt),
                "windows": snapshot.windows.map { w -> [String: Any] in
                    var win: [String: Any] = ["id": w.id, "kind": w.kind.rawValue, "title": w.title, "usedPercent": w.usedPercent]
                    if let reset = w.resetsAt { win["resetsAt"] = iso.string(from: reset) }
                    if let length = w.windowSeconds { win["windowSeconds"] = length }
                    if let detail = w.detail { win["detail"] = detail }
                    if let pace = data.paces[snapshot.id]?[w.id] {
                        var p: [String: Any] = ["ratePerHour": pace.rate, "verdict": pace.verdict.rawValue]
                        if let out = pace.runOut { p["runOut"] = iso.string(from: out) }
                        if let expected = pace.expectedNow { p["expectedNow"] = expected }
                        if let typical = pace.typical { p["typicalPerHour"] = typical }
                        if let multiple = pace.multiple { p["multiple"] = multiple }
                        win["pace"] = p
                    }
                    return win
                },
            ]
            if let identity = snapshot.identity { entry["identity"] = identity }
            if let problem = snapshot.problem { entry["problem"] = problem.title }
            if snapshot.providerID == .claude, let week = APISpend.shared.cost(for: snapshot, days: 7), let month = APISpend.shared.cost(for: snapshot, days: 30) {
                entry["apiPriced"] = ["days7": (week.dollars * 100).rounded() / 100, "days30": (month.dollars * 100).rounded() / 100, "messages30": month.messages]
            }
            return entry
        }
        var root: [String: Any] = ["accounts": accounts]
        if let at = data.fetchedAt {
            root["fetchedAt"] = iso.string(from: at)
            root["ageSeconds"] = Int(Date.now.timeIntervalSince(at))
        }
        root["stale"] = data.stale
        let bytes = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Helpers

    enum Paint { case green, amber, red, dim }

    static func paint(_ text: String, _ paint: Paint, _ on: Bool) -> String {
        guard on else { return text }
        let code = switch paint { case .green: "32"; case .amber: "33"; case .red: "31"; case .dim: "2" }
        return "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }

    static func openURL(_ url: String) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [url]
        do { try task.run(); task.waitUntilExit(); return task.terminationStatus } catch { return 1 }
    }
}
