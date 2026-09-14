import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, appearance, accounts, usage

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .accounts: "Accounts"
        case .usage: "Usage"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .accounts: "person.2"
        case .usage: "chart.xyaxis.line"
        }
    }

    @MainActor @ViewBuilder var pane: some View {
        switch self {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .accounts: AccountsPane()
        case .usage: UsagePane()
        }
    }
}

/// One settings window with System-Settings-style toolbar tabs. Hosted by AppKit so it behaves the same whether
/// opened from the panel, the status-item menu, or `burn://settings`, and so the window can resize per pane.
@MainActor
enum SettingsOpener {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("settings")
    private static var controller: NSWindowController?
    private static var tabs: SettingsTabController?

    static var window: NSWindow? { controller?.window }

    static func open(tab: SettingsTab? = nil) {
        if controller == nil {
            let tabController = SettingsTabController()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.identifier = windowIdentifier
            window.toolbarStyle = .preference
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(Palette.dark.page) : NSColor(Palette.light.page)
            }
            window.contentViewController = tabController
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
            tabs = tabController
        }
        NSApp.activate()
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        // After the window is up: a selection made before it appears is lost.
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabs?.selectedTabViewItemIndex = index
        }
        Log.write("settings window shown: tab=\(tabs.map { SettingsTab.allCases[$0.selectedTabViewItemIndex].rawValue } ?? "?")")
    }
}

/// Toolbar-style tabs, one SwiftUI pane each. The window takes each pane's ideal height, so no pane scrolls.
final class SettingsTabController: NSTabViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let hosting = NSHostingController(rootView: tab.pane)
            hosting.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            addTabViewItem(item)
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateTitle()
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        updateTitle()
    }

    /// macOS convention: the window is titled after the pane.
    private func updateTitle() {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return }
        view.window?.title = tabViewItems[selectedTabViewItemIndex].label
    }
}
