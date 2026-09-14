import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PanelController!
    private var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Migration.runIfNeeded()
        NSApp.setActivationPolicy(.accessory)
        Preferences.shared.apply()

        let store = UsageStore.shared
        panel = PanelController(store: store)
        statusItem = StatusItemController(store: store, panel: panel)

        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.panel.toggle(anchor: .screenTop)
        }
        Log.write("launched; hotkey = \(KeyboardShortcuts.getShortcut(for: .togglePanel).map(String.init(describing:)) ?? "none")")

        // Coming back from sleep, the windows have moved on; don't show numbers from before the lid closed.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in store.refreshIfStale(olderThan: 0) }
        }

        Alerts.shared.start()
        VendorStatus.shared.start()
        APISpend.shared.start()
        store.start()
    }

    /// `burn://toggle`, `burn://show`, `burn://hide`, `burn://refresh`, `burn://settings[?tab=accounts]`
    /// — for Shortcuts and scripts.
    /// `burn://capture?path=/tmp/panel.png` writes a PNG of the panel; `burn://demo` fills it with fixture
    /// accounts (every state at once) for design work; `burn://live` goes back to real data.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Log.write("url: \(url.absoluteString)")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "toggle": panel.toggle(anchor: .screenTop)
            case "show": panel.show(anchor: .screenTop)
            case "hide": panel.hide()
            case "refresh": Task { await UsageStore.shared.refresh(force: true) }
            case "demo": UsageStore.shared.loadDemo(calm: query.contains { $0.name == "calm" }); panel.show(anchor: .screenTop)
            case "live": UsageStore.shared.leaveDemo()
            case "settings":
                panel.hide()
                NSApp.activate()
                SettingsOpener.open(tab: query.first { $0.name == "tab" }?.value.flatMap(SettingsTab.init(rawValue:)))
            case "alerts":
                if query.contains(where: { $0.name == "test" }) { Alerts.shared.deliverSample() }
            case "appearance":
                let mode = query.first { $0.name == "mode" }?.value ?? "system"
                panel.setAppearance(mode == "dark" ? .darkAqua : mode == "light" ? .aqua : nil)
            case "capture":
                let path = query.first { $0.name == "path" }?.value
                    ?? UsageStore.supportDirectory.appendingPathComponent("capture.png").path
                let target = query.first { $0.name == "target" }?.value ?? "panel"
                PanelController.preferBuiltInScreen = query.contains { $0.name == "screen" && $0.value == "builtin" }
                if PanelController.preferBuiltInScreen, target == "panel" { panel.hide() }  // re-shown on that screen by the capture
                // Design review: a taller settings window shows the whole form at once instead of scrolling.
                if target == "settings", let height = query.first(where: { $0.name == "height" })?.value.flatMap(Double.init),
                   let window = SettingsOpener.window {
                    window.setContentSize(NSSize(width: window.frame.width, height: height))
                }
                panel.capture(to: URL(fileURLWithPath: path), target: target)
            default: break
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
