import AppKit
import Sparkle

/// Burn keeps itself up to date with Sparkle. It reads the appcast attached to the latest GitHub release and installs
/// only an archive signed with Burn's own EdDSA key — the public half is `SUPublicEDKey` in Info.plist, the private
/// half lives in the release machine's login keychain — and Sparkle also refuses a new copy whose code signature
/// doesn't match this one's. It looks shortly after launch and once a day after; Settings can turn that off.
///
/// A menu-bar app has no window in front most of the time, so a scheduled check that finds something doesn't throw
/// Sparkle's window over whatever you're doing: it puts an Update pill in the panel's header and posts one banner.
/// Either of those, Check for Updates… or `burn://update` opens the Software Update window — what's new, then Install
/// and Relaunch, Remind Me Later or Skip This Version.
@MainActor
@Observable
final class Updater: NSObject {
    static let shared = Updater()

    /// A version a scheduled check found that hasn't been looked at yet.
    private(set) var available: String?
    /// Mirrors Sparkle's setting so the Settings switch redraws when it changes.
    private(set) var checksAutomatically = true
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        checksAutomatically = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    /// Check for Updates…: always answers with a window — the update, "You're up to date", or what went wrong.
    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }
    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    func setChecksAutomatically(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        checksAutomatically = on
    }
}

extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.write("update: found \(item.displayVersionString) (\(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Log.write("update: \(Self.version) is the latest")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // "No update" arrives here too (SUNoUpdateError, 1001); only real failures are worth a log line.
        guard (error as NSError).code != 1001 else { return }
        Log.write("update: \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Log.write("update: downloaded \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Log.write("update: download of \(item.displayVersionString) failed — \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        Log.write("update: unpacked \(item.displayVersionString); its signature is checked before it installs")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Log.write("update: installing \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        let what = switch choice {
        case .install: "install"
        case .dismiss: "remind me later"
        case .skip: "skip"
        @unknown default: "choice \(choice.rawValue)"
        }
        Log.write("update: \(what) — \(updateItem.displayVersionString), stage \(state.stage.rawValue)")
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle's window only when Burn is the active app (you just opened it, or Settings is in front). Sparkle counts
    /// any launch as "immediate focus", but Burn usually starts at login in the background, where the window would
    /// open behind everything else; then the reminder is ours.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus && NSApp.isActive
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        Log.write("update: showing \(update.displayVersionString) — \(handleShowingUpdate ? "Sparkle's window" : "Burn's reminder")\(state.userInitiated ? ", asked for" : "")")
        guard !handleShowingUpdate, !state.userInitiated else { return }
        available = update.displayVersionString
        Alerts.shared.deliverUpdate(version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        available = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        available = nil
    }
}
