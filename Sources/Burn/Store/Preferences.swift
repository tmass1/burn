import AppKit
import Foundation
import KeyboardShortcuts
import ServiceManagement

extension KeyboardShortcuts.Name {
    /// ⌥Space by default — free on this Mac (no Raycast/Alfred), and the closest thing to Spotlight muscle memory.
    static let togglePanel = Self("togglePanel", default: .init(.space, modifiers: [.option]))
}

/// User preferences, each backed by UserDefaults so they survive relaunches without a settings file.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    var pollIntervalSeconds: Int {
        didSet { defaults.set(pollIntervalSeconds, forKey: "pollIntervalSeconds") }
    }
    /// Which account the menu-bar ring reflects. Nil = the most constrained account at the moment.
    var primaryAccountID: String? {
        didSet { defaults.set(primaryAccountID, forKey: "primaryAccountID") }
    }
    var showPercentInMenuBar: Bool {
        didSet { defaults.set(showPercentInMenuBar, forKey: "showPercentInMenuBar") }
    }
    /// Accounts with a ring of their own in the menu bar, beside the main one; in the order they were pinned.
    var pinnedAccountIDs: [String] {
        didSet { defaults.set(pinnedAccountIDs, forKey: "pinnedAccountIDs") }
    }
    var hiddenAccountIDs: Set<String> {
        didSet { defaults.set(Array(hiddenAccountIDs), forKey: "hiddenAccountIDs") }
    }
    var customLabels: [String: String] {
        didSet { defaults.set(customLabels, forKey: "customLabels") }
    }
    /// What an account really costs a month, where the user has told us; otherwise `PlanPricing` guesses from the plan.
    var monthlyCosts: [String: Double] {
        didSet { defaults.set(monthlyCosts, forKey: "monthlyCosts") }
    }
    /// Accounts the user removed: Burn neither shows nor checks them. Keyed by account id for Claude (several
    /// accounts share the provider) and by provider for the single-account providers, so a later error card for the
    /// same provider stays removed too. The sign-in itself, on disk or in the keychain, is never touched.
    private(set) var removedAccountKeys: Set<String> {
        didSet { defaults.set(Array(removedAccountKeys), forKey: Self.removedKey) }
    }
    /// What to call a removed account in the "show again" menu, since there is no snapshot to ask any more.
    private(set) var removedAccountLabels: [String: String] {
        didSet { defaults.set(removedAccountLabels, forKey: "removedAccountLabels") }
    }
    nonisolated private static let removedKey = "removedAccountKeys"

    static func removalKey(for snapshot: AccountSnapshot) -> String {
        switch snapshot.providerID {
        case .claude, .gemini: snapshot.id   // several accounts share the provider
        default: snapshot.providerID.rawValue
        }
    }

    func isRemoved(_ snapshot: AccountSnapshot) -> Bool {
        removedAccountKeys.contains(snapshot.id) || removedAccountKeys.contains(snapshot.providerID.rawValue)
    }

    func remove(_ snapshot: AccountSnapshot) {
        let key = Self.removalKey(for: snapshot)
        removedAccountLabels[key] = [label(for: snapshot), snapshot.identity].compactMap { $0 }.joined(separator: " · ")
        removedAccountKeys.insert(key)
    }

    func restore(key: String) {
        removedAccountKeys.remove(key)
        removedAccountLabels.removeValue(forKey: key)
    }

    /// For providers, which run off the main actor: the same set, straight from the defaults.
    nonisolated static func removedKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: removedKey) ?? [])
    }
    /// Banners when a window passes the threshold and when a low one resets. On by default; macOS asks once.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    /// Where "nearly out" begins for notifications (and the rule on the history charts).
    var notifyThresholdPercent: Int {
        didSet { defaults.set(notifyThresholdPercent, forKey: "notifyThresholdPercent") }
    }
    var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: "notifyOnReset") }
    }
    /// A window that, at its current rate, runs out well before it resets.
    var notifyOnPace: Bool {
        didSet { defaults.set(notifyOnPace, forKey: "notifyOnPace") }
    }
    /// Usage at several times this account's usual — a window's rate against its typical busy hour, a model's
    /// day against its typical day.
    var notifyOnSurge: Bool {
        didSet { defaults.set(notifyOnSurge, forKey: "notifyOnSurge") }
    }
    /// How many times the usual counts as unusual: 2, 3 or 5.
    var surgeMultiple: Double {
        didSet { defaults.set(surgeMultiple, forKey: "surgeMultiple") }
    }
    static let surgeMultiples: [Double] = [2, 3, 5]
    /// Shell shims Burn wrote to ~/.local/bin, by account id → command name, so renames and removals reconcile.
    var installedLaunchers: [String: String] {
        didSet { defaults.set(installedLaunchers, forKey: "installedLaunchers") }
    }
    /// Where "Open Terminal with this account" opens.
    var terminalApp: Launchers.TerminalApp {
        didSet { defaults.set(terminalApp.rawValue, forKey: "terminalApp") }
    }
    /// Poll the vendors' status pages and show a chip when one is having an incident.
    var showVendorStatus: Bool {
        didSet {
            defaults.set(showVendorStatus, forKey: "showVendorStatus")
            if showVendorStatus { VendorStatus.shared.start() } else { VendorStatus.shared.stop() }
        }
    }
    /// A nightly window with no banners at all; minutes after midnight, and it may wrap past it.
    var quietHoursEnabled: Bool {
        didSet { defaults.set(quietHoursEnabled, forKey: "quietHoursEnabled") }
    }
    var quietStartMinute: Int {
        didSet { defaults.set(quietStartMinute, forKey: "quietStartMinute") }
    }
    var quietEndMinute: Int {
        didSet { defaults.set(quietEndMinute, forKey: "quietEndMinute") }
    }

    func isQuiet(at date: Date = .now) -> Bool {
        guard quietHoursEnabled else { return false }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return quietStartMinute <= quietEndMinute
            ? (quietStartMinute..<quietEndMinute).contains(minute)
            : minute >= quietStartMinute || minute < quietEndMinute
    }
    /// Dark by default. Applied to the whole app so Settings and menus agree with the panel.
    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            apply()
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login change failed: \(error)")
            }
        }
    }

    private init() {
        let stored = defaults.integer(forKey: "pollIntervalSeconds")
        pollIntervalSeconds = stored > 0 ? stored : 180
        primaryAccountID = defaults.string(forKey: "primaryAccountID")
        showPercentInMenuBar = defaults.object(forKey: "showPercentInMenuBar") as? Bool ?? true
        pinnedAccountIDs = defaults.stringArray(forKey: "pinnedAccountIDs") ?? []
        hiddenAccountIDs = Set(defaults.stringArray(forKey: "hiddenAccountIDs") ?? [])
        customLabels = defaults.dictionary(forKey: "customLabels") as? [String: String] ?? [:]
        monthlyCosts = defaults.dictionary(forKey: "monthlyCosts") as? [String: Double] ?? [:]
        removedAccountKeys = Set(defaults.stringArray(forKey: Self.removedKey) ?? [])
        removedAccountLabels = defaults.dictionary(forKey: "removedAccountLabels") as? [String: String] ?? [:]
        appearance = defaults.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .dark
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        let threshold = defaults.integer(forKey: "notifyThresholdPercent")
        notifyThresholdPercent = threshold > 0 ? threshold : 85
        notifyOnReset = defaults.object(forKey: "notifyOnReset") as? Bool ?? true
        notifyOnPace = defaults.object(forKey: "notifyOnPace") as? Bool ?? true
        notifyOnSurge = defaults.object(forKey: "notifyOnSurge") as? Bool ?? true
        let multiple = defaults.double(forKey: "surgeMultiple")
        surgeMultiple = Self.surgeMultiples.contains(multiple) ? multiple : 3
        showVendorStatus = defaults.object(forKey: "showVendorStatus") as? Bool ?? true
        installedLaunchers = defaults.dictionary(forKey: "installedLaunchers") as? [String: String] ?? [:]
        terminalApp = defaults.string(forKey: "terminalApp").flatMap(Launchers.TerminalApp.init(rawValue:)) ?? .terminal
        quietHoursEnabled = defaults.bool(forKey: "quietHoursEnabled")
        quietStartMinute = defaults.object(forKey: "quietStartMinute") as? Int ?? 22 * 60
        quietEndMinute = defaults.object(forKey: "quietEndMinute") as? Int ?? 8 * 60
    }

    func apply() {
        NSApp.appearance = appearance.nsAppearance
    }

    func label(for snapshot: AccountSnapshot) -> String {
        customLabels[snapshot.id] ?? snapshot.label
    }

    func monthlyCost(for snapshot: AccountSnapshot) -> Double? {
        monthlyCosts[snapshot.id] ?? PlanPricing.estimate(for: snapshot)
    }

    var isCostEstimated: (AccountSnapshot) -> Bool { { self.monthlyCosts[$0.id] == nil } }
}
