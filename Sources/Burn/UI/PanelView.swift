import AppKit
import SwiftUI

/// Root of the floating panel: the wordmark and the forecast's legend, then one section per account, on frosted
/// glass with 18 pt corners.
struct PanelRoot: View {
    var store: UsageStore

    var body: some View {
        PanelView(store: store)
            .frame(width: PanelController.width)
            .background { PanelGlass() }
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
            .overlay { PanelRim() }
            .padding(1)
    }
}

struct PanelView: View {
    var store: UsageStore

    @Environment(\.colorScheme) private var scheme
    private var p: Palette { .resolve(scheme) }

    var body: some View {
        let cards = store.visibleSnapshots
        VStack(spacing: 0) {
            header
            if !VendorStatus.shared.trouble.isEmpty { vendorNotice }
            VStack(spacing: 0) {
                if cards.isEmpty {
                    emptyState
                } else {
                    ForEach(cards) { snapshot in
                        AccountCard(snapshot: snapshot, paces: store.paces[snapshot.id] ?? [:])
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
        }
    }

    /// One muted line when a vendor is having an incident, so the panel explains itself before the rows do.
    private var vendorNotice: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(VendorStatus.shared.trouble, id: \.provider) { item in
                Button {
                    if let page = item.provider.statusPage?.page { NSWorkspace.shared.open(page) }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill({ if case .outage = item.condition { p.markCritical } else { p.markWarning } }())
                            .frame(width: 5, height: 5)
                        (Text("\(item.provider.vendorName): \(item.condition.title?.lowercased() ?? "incident")").foregroundStyle(p.ink)
                         + Text(item.condition.incident.map { " — \($0)" } ?? "").foregroundStyle(p.muted))
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Open \(item.provider.vendorName)'s status page")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            HStack(spacing: 6) {
                Wordmark(height: 17, ink: p.title)
                Spacer(minLength: 10)
                if let version = Updater.shared.available {
                    UpdatePill(version: version)
                } else {
                    // The legend at full length when it fits beside the buttons, shorter when it doesn't.
                    ViewThatFits(in: .horizontal) {
                        legend(full: true)
                        legend(full: false)
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                HeaderButton(symbol: "arrow.clockwise",
                             help: store.lastRefresh.map { "Refresh now — updated \(Relative.ago($0, from: context.date))" } ?? "Refresh now",
                             spinning: store.isRefreshing) {
                    Task { await store.refresh(force: true) }
                }
                HeaderButton(symbol: "gearshape", help: "Settings") {
                    PanelActions.shared.hide()
                    NSApp.activate()
                    SettingsOpener.open()
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
    }

    /// How to read a bar: solid is used now, hatched is where this pace lands by the reset.
    private func legend(full: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(p.markFine).frame(width: 14, height: 6)
            Text(full ? "used now" : "now")
            Hatch(color: p.markFine)
                .frame(width: 14, height: 6)
                .clipShape(Capsule())
                .padding(.leading, 7)
            Text(full ? "by the reset, at this pace" : "by the reset")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(p.muted)
        .lineLimit(1)
        .fixedSize()
        .help("Each bar is solid to what's used now and hatched on to where the current pace lands by the reset. Hatching that ends at a red cap means that window runs out first.")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(p.muted)
            Text(store.isRefreshing ? "Looking for your accounts…" : "No accounts to show")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(p.ink)
            Text("Burn reads the sign-ins Claude Code, Codex and the Grok CLI already keep on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(p.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// Header action: a bare 14 pt glyph, muted until hovered, the control fill appearing under it.
struct HeaderButton: View {
    var symbol: String
    var help: String
    var spinning: Bool = false
    var action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let p = Palette.resolve(scheme)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? p.ink : p.muted)
                .frame(width: 28, height: 28)
                .background(hovering ? p.control : .clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spinning)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
    }
}

/// "Update" in the panel's header: a scheduled check found a newer Burn while nothing of Burn's was in front.
struct UpdatePill: View {
    var version: String
    @State private var hovering = false

    var body: some View {
        Button {
            PanelActions.shared.hide()
            Updater.shared.checkForUpdates()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Update")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(BurnMark.ember, in: Capsule())
            .opacity(hovering ? 0.88 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Burn \(version) is available — see what's new and install it")
    }
}
