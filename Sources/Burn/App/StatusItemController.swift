import AppKit
import SwiftUI

/// The menu-bar ring. Left click toggles the panel under it; right click gets the utility menu. Pinned accounts get
/// a ring each beside it, drawn the same way for their own numbers.
@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private var pinned: [String: NSStatusItem] = [:]
    private let store: UsageStore
    private let panel: PanelController

    init(store: UsageStore, panel: PanelController) {
        self.store = store
        self.panel = panel
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }
        render()
        observe()
        PanelActions.shared.statusButton = { [weak self] in self?.item.button }
        if let button = item.button {
            Log.write("status item appearance: \(button.effectiveAppearance.name.rawValue) (app: \(NSApp.effectiveAppearance.name.rawValue))")
        }
    }

    private func observe() {
        withObservationTracking {
            _ = store.headline
            _ = store.snapshots
            _ = store.isRefreshing
            _ = Preferences.shared.showPercentInMenuBar
            _ = Preferences.shared.primaryAccountID
            _ = Preferences.shared.pinnedAccountIDs
            _ = Preferences.shared.customLabels
        } onChange: {
            Task { @MainActor [weak self] in
                self?.render()
                self?.observe()
            }
        }
    }

    private func render() {
        if let button = item.button { draw(store.headline, on: button) }
        syncPinned()
    }

    /// One account's ring, percentage and tooltip on a status button.
    private func draw(_ snapshot: AccountSnapshot?, on button: NSStatusBarButton) {
        let window = snapshot?.tightest
        let percent = window?.usedPercent
        let tone = Theme.tone(forUsedPercent: percent ?? 0, stale: snapshot?.isStale ?? true)
        button.image = MenuBarIcon.ring(percent: percent, color: tone.nsColor, symbol: snapshot.map { Theme.tileSymbol($0.providerID) })
        if Preferences.shared.showPercentInMenuBar, let percent {
            button.attributedTitle = NSAttributedString(
                string: " \(Int(percent.rounded()))%",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                             .foregroundColor: NSColor.labelColor])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
        if let snapshot, let window {
            var tip = "\(Preferences.shared.label(for: snapshot)) — \(window.title.lowercased()) \(Int(window.usedPercent.rounded()))% used"
            if let pace = store.pace(for: snapshot, window: window) {
                switch pace.verdict {
                case .early: break
                case .stalled: tip += " · idle"
                case .onPace: tip += " · \(pace.rateText) · on pace"
                case .fast: tip += " · \(pace.rateText) · out \(pace.runOut.map { Relative.clock($0) } ?? "soon"), before the reset"
                }
            }
            button.toolTip = tip
        } else if let snapshot {
            button.toolTip = Preferences.shared.label(for: snapshot) + (snapshot.problem.map { " — \($0.title)" } ?? "")
        } else {
            button.toolTip = "Burn"
        }
    }

    /// Creates, redraws and removes the pinned accounts' items to match the preference.
    private func syncPinned() {
        let wanted = Preferences.shared.pinnedAccountIDs
        for id in pinned.keys where !wanted.contains(id) {
            if let item = pinned.removeValue(forKey: id) { NSStatusBar.system.removeStatusItem(item) }
        }
        for id in wanted {
            let item = pinned[id] ?? {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                if let button = item.button {
                    button.target = self
                    button.action = #selector(clicked(_:))
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                    button.imagePosition = .imageLeading
                    button.imageHugsTitle = true
                    button.identifier = NSUserInterfaceItemIdentifier(id)
                }
                pinned[id] = item
                return item
            }()
            if let button = item.button { draw(store.snapshots.first { $0.id == id }, on: button) }
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)
            return
        }
        // The click that lands on the status item already made the panel resign key (and hide); don't bounce it back.
        if Date.now.timeIntervalSince(panel.lastHiddenAt) < 0.3 { return }
        panel.toggle(anchor: .below(sender))
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        if let id = button.identifier?.rawValue, Preferences.shared.pinnedAccountIDs.contains(id) {
            let label = store.snapshots.first { $0.id == id }.map { Preferences.shared.label(for: $0) } ?? "this account"
            let unpin = menu.addItem(withTitle: "Unpin \(label)", action: #selector(unpin(_:)), keyEquivalent: "")
            unpin.target = self
            unpin.representedObject = id
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = Preferences.shared.launchAtLogin ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Burn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.height + 4 : -4), in: button)
    }

    @objc private func refreshNow() { Task { await store.refresh(force: true) } }
    @objc private func unpin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Preferences.shared.pinnedAccountIDs.removeAll { $0 == id }
    }
    @objc private func toggleLaunchAtLogin() { Preferences.shared.launchAtLogin.toggle() }
    @objc private func openSettings() {
        panel.hide()
        NSApp.activate()
        SettingsOpener.open()
    }
}

enum MenuBarIcon {
    /// An 18-pt ring: quiet track, bold arc from 12 o'clock clockwise, the account's provider glyph inside so the
    /// ring says whose number it is. Drawn on demand — inside the status bar's own appearance — so the dynamic
    /// colors follow the menu bar, not the app's theme.
    static func ring(percent: Double?, color: NSColor, symbol: String? = nil) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let lineWidth: CGFloat = 2.4
            let inset = lineWidth / 2 + 1
            let circle = rect.insetBy(dx: inset, dy: inset)
            let track = NSBezierPath(ovalIn: circle)
            track.lineWidth = lineWidth
            NSColor.labelColor.withAlphaComponent(0.22).setStroke()
            track.stroke()

            if let percent, percent > 0 {
                let arc = NSBezierPath()
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                let sweep = 360 * min(1, max(0, percent / 100))
                arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: circle.width / 2,
                              startAngle: 90, endAngle: 90 - sweep, clockwise: true)
                color.setStroke()
                arc.stroke()
            }

            // Size and colour in one configuration: a second `withSymbolConfiguration` replaces the first.
            let glyphConfiguration = NSImage.SymbolConfiguration(pointSize: 6, weight: .black)
                .applying(.init(paletteColors: [NSColor.labelColor.withAlphaComponent(0.9)]))
            if let symbol, let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(glyphConfiguration) {
                let size = glyph.size
                let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
                glyph.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
