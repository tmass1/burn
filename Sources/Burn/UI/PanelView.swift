import AppKit
import SwiftUI

/// Root of the floating panel: a header with the app tile and title, then one flat row per account. The ground is
/// Fritter's slate at 90 % over the window material, 12 pt corners.
struct PanelRoot: View {
    var store: UsageStore

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.resolve(scheme)
        PanelView(store: store)
            .frame(width: PanelController.width)
            .background { WindowMaterial().overlay(p.window) }
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
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
            VStack(spacing: 6) {
                if cards.isEmpty {
                    emptyState
                } else {
                    ForEach(cards) { snapshot in
                        AccountCard(snapshot: snapshot, samples: store.history.samples(for: snapshot.id, last: 24 * 3600), paces: store.paces[snapshot.id] ?? [:])
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
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
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            HStack(spacing: 10) {
                Wordmark(height: 17, ink: p.title)
                    .padding(.leading, 2)
                Spacer()
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
            .padding(.trailing, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
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
