import Foundation

/// What a plan costs a month — list prices as of 2026, in US dollars, by the plan name the provider reports. No
/// vendor returns this over its API, so these are starting points; the real figure lives in Settings, per account.
enum PlanPricing {
    static func estimate(for snapshot: AccountSnapshot) -> Double? {
        let plan = snapshot.subtitle.lowercased()
        switch snapshot.providerID {
        case .claude:
            if plan.contains("enterprise") { return nil }
            if plan.contains("team") { return plan.contains("max") ? 150 : 30 }   // premium seat (with Claude Code) vs standard
            if plan.contains("max 20") { return 200 }
            if plan.contains("max") { return 100 }
            if plan.contains("pro") { return 20 }
            return nil
        case .codex:
            if plan.contains("pro") { return 200 }
            if plan.contains("plus") { return 20 }
            if plan.contains("business") || plan.contains("team") { return 30 }
            if plan.contains("go") { return 8 }
            if plan.contains("free") { return 0 }
            return nil
        case .grok:
            if plan.contains("heavy") { return 300 }
            if plan.contains("supergrok") { return 30 }
            if plan.contains("premium+") { return 40 }
            if plan.contains("premium") { return 8 }
            return nil
        case .gemini:
            if plan.contains("standard") { return 22.80 }
            if plan.contains("free") { return 0 }
            return nil
        case .cursor:
            if plan.contains("ultra") { return 200 }
            if plan.contains("pro+") { return 60 }
            if plan.contains("pro") { return 20 }
            if plan.contains("team") { return 40 }
            if plan.contains("hobby") || plan.contains("free") { return 0 }
            return nil
        case .copilot:
            if plan.contains("pro+") { return 39 }
            if plan.contains("pro") { return 10 }
            if plan.contains("enterprise") { return 39 }
            if plan.contains("business") { return 19 }
            if plan.contains("free") { return 0 }
            return nil
        }
    }

    /// "$100/mo", "$22.80/mo".
    static func label(_ cost: Double) -> String {
        (cost == cost.rounded() ? String(format: "$%.0f", cost) : String(format: "$%.2f", cost)) + "/mo"
    }
}
