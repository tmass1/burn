import Foundation

/// The vendors' own status pages, so an outage on their side shows as theirs: a chip on the rows it affects, and an
/// error card that says "Anthropic is having an incident" instead of blaming the sign-in. Polls the four Statuspage
/// summaries every five minutes while the app runs; nothing is stored between launches.
@MainActor
@Observable
final class VendorStatus {
    static let shared = VendorStatus()

    static let interval: TimeInterval = 5 * 60
    /// How long a last-known condition survives a failed status poll before it becomes unknown.
    static let graceAfterFailure: TimeInterval = 15 * 60

    private(set) var conditions: [ProviderID: VendorCondition] = [:]
    private var fetchedAt: [ProviderID: Date] = [:]
    private var task: Task<Void, Never>?
    /// Fixture conditions while `burn://demo` is showing; nil otherwise.
    var demo: [ProviderID: VendorCondition]?

    var current: [ProviderID: VendorCondition] { demo ?? conditions }

    func condition(for provider: ProviderID) -> VendorCondition {
        current[provider] ?? .unknown
    }

    /// Anything worth a line in the panel header: providers in trouble, in display order.
    var trouble: [(provider: ProviderID, condition: VendorCondition)] {
        ProviderID.allCases.compactMap { id in
            let condition = self.condition(for: id)
            return condition.isTrouble ? (id, condition) : nil
        }
    }

    func start() {
        task?.cancel()
        guard Preferences.shared.showVendorStatus else { conditions = [:]; return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        conditions = [:]
    }

    func refresh() async {
        let pages = ProviderID.allCases.compactMap { id in id.statusPage.map { (id: id, page: $0.page, components: $0.components) } }
        let results = await withTaskGroup(of: (ProviderID, VendorCondition?).self) { group in
            for entry in pages {
                group.addTask { (entry.id, await Self.fetch(page: entry.page, components: entry.components)) }
            }
            var out: [ProviderID: VendorCondition?] = [:]
            for await (id, condition) in group { out[id] = condition }
            return out
        }
        let now = Date.now
        for (id, result) in results {
            let previous = conditions[id]
            if let condition = result {
                conditions[id] = condition
                fetchedAt[id] = now
            } else if let at = fetchedAt[id], now.timeIntervalSince(at) > Self.graceAfterFailure {
                conditions[id] = .unknown
            } else if conditions[id] == nil {
                conditions[id] = .unknown
            }
            if conditions[id] != previous, let condition = conditions[id] {
                Log.write("vendor status: \(id.rawValue) \(condition.title?.lowercased() ?? (condition == .fine ? "fine" : "unknown"))" + (condition.incident.map { " — \($0)" } ?? ""))
            }
        }
    }

    private static func fetch(page: URL, components: [String]) async -> VendorCondition? {
        var request = URLRequest(url: page.appendingPathComponent("api/v2/summary.json"))
        request.timeoutInterval = 10
        request.setValue("Burn", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data, components: components)
    }

    /// Statuspage's `summary.json`: the worst status among our components, named by the first open incident that
    /// touches them. Other components (Anthropic's "Claude Cowork", GitHub's "Actions") never count, whatever the
    /// page's own indicator says — except a page-wide "critical", which is an outage by any reading.
    nonisolated static func parse(_ data: Data, components ours: [String]) -> VendorCondition? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let isOurs = { (name: String) -> Bool in ours.contains { name.lowercased().hasPrefix($0.lowercased()) } }
        let all = (root["components"] as? [[String: Any]]) ?? []
        let relevant = all.filter { ($0["name"] as? String).map(isOurs) == true }
        let incidents = ((root["incidents"] as? [[String: Any]]) ?? []).filter { incident in
            let status = (incident["status"] as? String) ?? ""
            guard status != "resolved", status != "postmortem" else { return false }
            let touched = (incident["components"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            return touched.contains(where: isOurs)
        }
        let worst = relevant.compactMap { $0["status"] as? String }.max { rank($0) < rank($1) } ?? "operational"
        let named = incidents.first.flatMap { $0["name"] as? String }
        switch worst {
        case "major_outage", "partial_outage":
            return .outage(named ?? (worst == "major_outage" ? "Major outage" : "Partial outage"))
        case "degraded_performance":
            return .degraded(named ?? "Degraded performance")
        default:
            if let named { return .degraded(named) }
            if (root["status"] as? [String: Any])?["indicator"] as? String == "critical" {
                return .outage(((root["status"] as? [String: Any])?["description"] as? String) ?? "Critical outage")
            }
            return .fine
        }
    }

    nonisolated private static func rank(_ status: String) -> Int {
        switch status {
        case "major_outage": 3
        case "partial_outage": 2
        case "degraded_performance": 1
        default: 0
        }
    }
}
