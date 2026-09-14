import AppKit
import SwiftUI

/// The Spotlight-style panel, one column of cards. Non-activating, so the app you were in keeps focus; key, so Esc closes it;
/// floats over full-screen Spaces; hides the moment you click anywhere else.
@MainActor
final class PanelController {
    enum Anchor {
        case screenTop
        case below(NSView)
    }

    static let width: CGFloat = 420

    private let panel: FloatingPanel
    private let host: NSHostingView<PanelRoot>
    private let store: UsageStore
    private(set) var lastHiddenAt: Date = .distantPast

    var isVisible: Bool { panel.isVisible }

    init(store: UsageStore) {
        self.store = store
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        host = NSHostingView(rootView: PanelRoot(store: store))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host

        panel.onCancel = { [weak self] in self?.hide() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        PanelActions.shared.hide = { [weak self] in self?.hide() }
        PanelActions.shared.show = { [weak self] in self?.show(anchor: .screenTop) }
    }

    func toggle(anchor: Anchor) {
        if panel.isVisible { hide() } else { show(anchor: anchor) }
    }

    /// `key: false` shows the panel without taking focus — for captures while another window is up, where an app
    /// activation would otherwise hand key status straight back and the panel would hide itself.
    func show(anchor: Anchor, key: Bool = true) {
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: max(120, host.fittingSize.height))
        panel.setContentSize(size)

        let screen = Self.screenUnderMouse()
        let visible = screen.visibleFrame
        var origin: NSPoint
        switch anchor {
        case .screenTop:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 14)
        case let .below(view):
            if let window = view.window {
                let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
                origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 6)
            } else {
                origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 14)
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = max(origin.y, visible.minY + 8)

        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + 6))
        panel.alphaValue = 0
        if key { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        Log.write("panel shown at \(origin)")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }
        store.refreshIfStale()
    }

    func hide() {
        guard panel.isVisible else { return }
        lastHiddenAt = .now
        panel.orderOut(nil)
        Log.write("panel hidden")
        panel.alphaValue = 1
    }

    /// Design review only: pin the panel to light or dark regardless of the system setting (nil follows the system).
    func setAppearance(_ name: NSAppearance.Name?) {
        panel.appearance = name.flatMap(NSAppearance.init(named:))
    }

    /// Writes a PNG of the panel as it is on screen (shows it first if needed). An app may capture its own windows
    /// without the screen-recording permission, which makes this a cheap way to review the design from a script.
    func capture(to file: URL, target: String = "panel") {
        if target == "menubar" {
            // The status item is hosted by the system, not by this process, so draw the button view directly.
            guard let button = PanelActions.shared.statusButton() else { Log.write("capture failed: no status button"); return }
            let scaled = NSRect(origin: .zero, size: button.bounds.size)
            guard let rep = button.bitmapImageRepForCachingDisplay(in: scaled) else { return }
            // In the menu bar's own appearance, not the app's — that is what the user sees.
            button.effectiveAppearance.performAsCurrentDrawingAppearance { button.cacheDisplay(in: scaled, to: rep) }
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: file) }
            Log.write("captured status item (\(Int(button.bounds.width))×\(Int(button.bounds.height))) to \(file.path)")
            return
        }
        let window: NSWindow?
        if target == "settings" {
            window = SettingsOpener.window
        } else {
            if !panel.isVisible { show(anchor: .screenTop, key: false) }
            window = panel
        }
        let number = window?.windowNumber ?? -1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard number > 0, number <= Int(UInt32.max) else { Log.write("capture failed: no window for target \(target)"); return }
            let id = CGWindowID(number)
            guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
                Log.write("capture failed: no image for window \(id)")
                return
            }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: file)
            Log.write("captured window \(id) to \(file.path)")
        }
    }

    /// Design review: pin the panel to the built-in (Retina) display so captures come out at 2×.
    nonisolated(unsafe) static var preferBuiltInScreen = false

    private static func screenUnderMouse() -> NSScreen {
        if preferBuiltInScreen, let builtIn = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("built-in") }) {
            return builtIn
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return } // Escape, in case a responder swallowed cancelOperation
        super.keyDown(with: event)
    }
}

/// Lets SwiftUI views inside the panel ask for it to close without holding the controller.
@MainActor
final class PanelActions {
    static let shared = PanelActions()
    var hide: () -> Void = {}
    var show: () -> Void = {}
    var statusButton: () -> NSStatusBarButton? = { nil }
}
