import AppKit
import SwiftUI

/// Colors encode one thing: how close a window is to running out. The surfaces around them are Fritter's dark
/// design (Figma "Tommy Samples → Fritter — Dark"), token for token: flat slate cards on a slate ground, rows that
/// tint when something is due, `#293039` controls, 12 / 8 / 6 pt radii.
enum Theme {
    /// Severity of a used-percentage. Thresholds are deliberate: 60 % is where a heavy session starts to bite,
    /// 85 % is "plan the switch now".
    enum Tone {
        case fine, warning, critical, stale

        /// For the menu bar, which follows the system's own light/dark rather than the panel's.
        var nsColor: NSColor {
            switch self {
            case .fine: .systemGreen
            case .warning: .systemOrange
            case .critical: .systemRed
            case .stale: .tertiaryLabelColor
            }
        }

        var label: String {
            switch self {
            case .fine: "Plenty"
            case .warning: "Getting low"
            case .critical: "Nearly out"
            case .stale: "Stale"
            }
        }

        /// The ring, the bar, the dot.
        func mark(_ p: Palette) -> Color {
            switch self {
            case .fine: p.markFine
            case .warning: p.markWarning
            case .critical: p.markCritical
            case .stale: p.muted.opacity(0.45)
            }
        }

        /// A card tints like a Fritter row that is due: yellow when a window is getting low, red when nearly out.
        func cardFill(_ p: Palette) -> Color {
            switch self {
            case .warning: p.cardWarning
            case .critical: p.cardCritical
            case .fine, .stale: p.card
            }
        }

        /// The account name follows the tint, like the row text in Fritter.
        func titleColor(_ p: Palette) -> Color {
            switch self {
            case .warning: p.textWarning
            case .critical: p.textCritical
            case .fine, .stale: p.ink
            }
        }

        /// Badge colours: neutral for plenty, tinted for getting low, Fritter's solid red for nearly out.
        func badge(_ p: Palette) -> (background: Color, foreground: Color) {
            switch self {
            case .fine: (p.badge, p.badgeText)
            case .warning: (p.markWarning.opacity(0.22), p.textWarning)
            case .critical: (p.badgeRed, .white)
            case .stale: (p.badge, p.muted)
            }
        }
    }

    static func tone(forUsedPercent percent: Double, stale: Bool = false) -> Tone {
        if stale { return .stale }
        if percent >= 85 { return .critical }
        if percent >= 60 { return .warning }
        return .fine
    }

    /// Provider identity lives in one small tile beside the name — never in the data marks.
    static func tileColor(_ provider: ProviderID, palette: Palette) -> Color {
        switch provider {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)   // Anthropic clay
        case .codex: Color(red: 0.06, green: 0.64, blue: 0.50)    // OpenAI green
        case .grok: palette.ink                                    // xAI ink
        case .gemini: Color(red: 0.26, green: 0.52, blue: 0.96)   // Google blue
        case .cursor: palette.ink                                  // Cursor's black-and-white mark
        case .copilot: Color(hex: "#8250df")                       // GitHub purple
        }
    }

    static func tileSymbolColor(_ provider: ProviderID, palette: Palette) -> Color {
        provider == .grok || provider == .cursor ? palette.ground : .white
    }

    static func tileSymbol(_ provider: ProviderID) -> String {
        switch provider {
        case .claude: "asterisk"
        case .codex: "hexagon"
        case .grok: "line.diagonal"
        case .gemini: "sparkle"
        case .cursor: "cube"
        case .copilot: "sparkles"
        }
    }

    // Shape, from the design: window 12, the well and its cards 8, controls 6.
    static let panelRadius: CGFloat = 12
    static let wellRadius: CGFloat = 8
    static let cardRadius: CGFloat = 8
    static let controlRadius: CGFloat = 6
    static let panelInset: CGFloat = 8
}

/// Fritter's dark tokens, lifted from the design; the light set is derived from them with the same structure.
/// Alphas matter on the ground and the well — a little of the desktop shows through the window.
struct Palette {
    var window: Color        // the panel ground over the window material
    var well: Color          // the list card that holds the account cards
    var card: Color          // an account card
    var cardWarning: Color   // …when its tightest window is getting low
    var cardCritical: Color  // …when it is nearly out
    var ink: Color           // text, active icons
    var title: Color         // the app title
    var muted: Color         // secondary text, labels, inactive icons
    var textWarning: Color   // the name on a getting-low card
    var textCritical: Color  // the name on a nearly-out card
    var control: Color       // buttons and selects
    var controlTop: Color    // top of the raised (hovered) control gradient
    var controlShadow: Color
    var track: Color         // the recessed track under a ring or bar
    var badge: Color         // neutral badge fill
    var badgeText: Color
    var badgeRed: Color      // the count badge, and "nearly out"
    var hairline: Color      // faint borders
    var markFine: Color      // Burn's own green, from the app icon
    var markWarning: Color
    var markCritical: Color
    var ground: Color        // solid slate, for a symbol drawn on an ink-filled tile
    var page: Color          // the solid ground of an ordinary window (Settings)
    var divider: Color       // a hairline between rows in a card

    static let dark = Palette(
        window: Color(hex: "#1b212ae6"), well: Color(hex: "#1b212af7"), card: Color(hex: "#222832f5"),
        cardWarning: Color(hex: "#f2c97226"), cardCritical: Color(hex: "#dd2f2826"),
        ink: Color(hex: "#f3f3f3"), title: Color(hex: "#f5f5f5"), muted: Color(hex: "#a1a1a1"),
        textWarning: Color(hex: "#f1cc71"), textCritical: Color(hex: "#ffa49b"),
        control: Color(hex: "#293039"), controlTop: Color(hex: "#353e4a"), controlShadow: Color(hex: "#0000000d"),
        track: Color(hex: "#00000033"), badge: Color(hex: "#f5f5f51a"), badgeText: Color(hex: "#f3f3f3cc"),
        badgeRed: Color(hex: "#de2f26"), hairline: Color(hex: "#f3f3f340"),
        markFine: Color(hex: "#4ac778"), markWarning: Color(hex: "#f2c972"), markCritical: Color(hex: "#de2f26"),
        ground: Color(hex: "#1b212a"), page: Color(hex: "#1b212a"), divider: Color(hex: "#ffffff0f"))

    static let light = Palette(
        window: Color(hex: "#ffffffeb"), well: Color(hex: "#eef0f3"), card: Color(hex: "#ffffff"),
        cardWarning: Color(hex: "#f2c97238"), cardCritical: Color(hex: "#dd2f281f"),
        ink: Color(hex: "#1c1c1e"), title: Color(hex: "#111114"), muted: Color(hex: "#6b6f76"),
        textWarning: Color(hex: "#8a6100"), textCritical: Color(hex: "#b3261e"),
        control: Color(hex: "#e9ebef"), controlTop: Color(hex: "#f7f8fa"), controlShadow: Color(hex: "#0000001a"),
        track: Color(hex: "#0000001a"), badge: Color(hex: "#0000000f"), badgeText: Color(hex: "#1c1c1ecc"),
        badgeRed: Color(hex: "#de2f26"), hairline: Color(hex: "#00000026"),
        markFine: Color(hex: "#2fa35c"), markWarning: Color(hex: "#d9a520"), markCritical: Color(hex: "#de2f26"),
        ground: .white, page: Color(hex: "#eef0f3"), divider: Color(hex: "#0000000f"))

    static func resolve(_ scheme: ColorScheme) -> Palette { scheme == .dark ? .dark : .light }
}

extension Color {
    /// `#rrggbb` or `#rrggbbaa`.
    init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)
        let hasAlpha = digits.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        let r = Double((value >> (16 + shift)) & 0xff) / 255
        let g = Double((value >> (8 + shift)) & 0xff) / 255
        let b = Double((value >> shift) & 0xff) / 255
        let a = hasAlpha ? Double(value & 0xff) / 255 : 1
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

/// The panel's appearance. Dark is the design; Light and Match System are settings.
enum Appearance: String, CaseIterable, Sendable {
    case dark, light, system

    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Match System"
        }
    }

    @MainActor var nsAppearance: NSAppearance? {
        switch self {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }
}

// MARK: - Surfaces

/// The window material under the ground: sidebar vibrancy, always active, so the 10 % the ground leaves open shows
/// a blur of the desktop. Masked to the window's corners, because a layer mask alone does not clip behind-window blur.
struct WindowMaterial: NSViewRepresentable {
    var radius: CGFloat = Theme.panelRadius

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        let side = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        view.maskImage = mask
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// A control from the design: `#293039`, 6 pt corners, the faintest shadow; raised with the active-tab gradient
/// while hovered.
struct ControlSurface: ViewModifier {
    var hovering: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let p = Palette.resolve(scheme)
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
        content
            .background {
                shape.fill(LinearGradient(colors: [hovering ? p.controlTop : p.control, p.control], startPoint: .top, endPoint: .bottom))
                    .shadow(color: p.controlShadow, radius: 0.75, y: 1)
            }
            .overlay {
                if hovering {
                    shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

extension View {
    func controlSurface(hovering: Bool) -> some View { modifier(ControlSurface(hovering: hovering)) }
}

/// Burn's own tile: the app icon itself — the Midnight tile in dark mode, Porcelain in light — from the brand SVGs
/// shipped in the bundle. Falls back to the mark on slate if the file is missing (a debug build run from `.build`).
struct AppTile: View {
    var size: CGFloat = 28

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let image = Self.icon(dark: scheme == .dark) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color(hex: "#111929"))
                    BurnMark(height: size * 0.62)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    nonisolated(unsafe) private static var cache: [Bool: NSImage] = [:]

    static func icon(dark: Bool) -> NSImage? {
        if let cached = cache[dark] { return cached }
        guard let path = Bundle.main.path(forResource: dark ? "burn-midnight" : "burn-porcelain", ofType: "svg"),
              let image = NSImage(contentsOfFile: path) else { return nil }
        cache[dark] = image
        return image
    }
}

/// The mark on its own — the ring open at one o'clock with its end lifting off as a flame — drawn from the same
/// paths as the icon, in the ember gradient, at any height. The panel header wears it beside the wordmark.
struct BurnMark: View {
    var height: CGFloat = 18

    /// The icon's geometry: a 1024 box; the mark occupies x 180…804, y 139…858 once the stroke is counted.
    private static let box = CGRect(x: 180, y: 139, width: 624, height: 719)
    private static let ring: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 480, y: 326))
        p.addCurve(to: CGPoint(x: 238, y: 550), control1: CGPoint(x: 350, y: 319), control2: CGPoint(x: 242, y: 416))
        p.addCurve(to: CGPoint(x: 483, y: 800), control1: CGPoint(x: 233, y: 694), control2: CGPoint(x: 344, y: 800))
        p.addCurve(to: CGPoint(x: 746, y: 551), control1: CGPoint(x: 632, y: 800), control2: CGPoint(x: 746, y: 692))
        p.addCurve(to: CGPoint(x: 729, y: 449), control1: CGPoint(x: 746, y: 512), control2: CGPoint(x: 740, y: 479))
        return p
    }()
    private static let flame: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 679, y: 139))
        p.addCurve(to: CGPoint(x: 727, y: 261), control1: CGPoint(x: 669, y: 191), control2: CGPoint(x: 720, y: 216))
        p.addCurve(to: CGPoint(x: 674, y: 367), control1: CGPoint(x: 735, y: 303), control2: CGPoint(x: 705, y: 337))
        p.addCurve(to: CGPoint(x: 624, y: 279), control1: CGPoint(x: 668, y: 331), control2: CGPoint(x: 628, y: 319))
        p.addCurve(to: CGPoint(x: 679, y: 139), control1: CGPoint(x: 618, y: 232), control2: CGPoint(x: 654, y: 188))
        p.closeSubpath()
        return p
    }()

    static let ember = LinearGradient(
        colors: [Color(hex: "#BD0029"), Color(hex: "#E20C29"), Color(hex: "#FA3435"), Color(hex: "#FF583F")],
        startPoint: .bottomLeading, endPoint: .topTrailing)

    var body: some View {
        let scale = height / Self.box.height
        let width = Self.box.width * scale
        let transform = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: -Self.box.minX, y: -Self.box.minY)
        ZStack {
            Self.ring.applying(transform)
                .stroke(Self.ember, style: StrokeStyle(lineWidth: 116 * scale, lineCap: .round))
            Self.flame.applying(transform)
                .fill(Self.ember)
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// "burn", the way the icon's companion wordmark sets it: heavy, rounded, lowercase, tight.
struct Wordmark: View {
    var height: CGFloat = 18
    var ink: Color = .primary

    var body: some View {
        HStack(alignment: .center, spacing: height * 0.38) {
            BurnMark(height: height)
            Text("burn")
                .font(.system(size: height * 1.02, weight: .heavy, design: .rounded))
                .tracking(-height * 0.03)
                .foregroundStyle(ink)
                .baselineOffset(-height * 0.02)
        }
        .accessibilityLabel("Burn")
    }
}

/// The design's tabs well: a recessed track with one raised, gradient segment that is the selection.
struct SegmentedWell<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Palette.resolve(scheme)
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? p.ink : p.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                    .fill(LinearGradient(colors: [p.controlTop, p.control], startPoint: .top, endPoint: .bottom))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(p.track, in: RoundedRectangle(cornerRadius: Theme.wellRadius, style: .continuous))
        .animation(.easeOut(duration: 0.18), value: selection)
    }
}

/// An entry in a `SelectMenu`. A separator is an entry with no title.
struct SelectEntry {
    var title: String
    var checked = false
    var enabled = true
    var action: () -> Void = {}

    static var separator: SelectEntry { SelectEntry(title: "") }
}

/// The design's select trigger: the control surface, a title, a chevron. SwiftUI's `Menu` hands its label to AppKit
/// and keeps only the text, so the trigger is drawn here and the menu itself — a native `NSMenu` — pops from it.
struct SelectMenu: View {
    var title: String
    var entries: [SelectEntry]

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var presentations = 0

    var body: some View {
        let p = Palette.resolve(scheme)
        Button { presentations += 1 } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(p.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(p.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .controlSurface(hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .background(MenuPresenter(entries: entries, presentations: presentations))
    }
}

/// Pops a native menu beneath the view it backs, each time `presentations` ticks.
private struct MenuPresenter: NSViewRepresentable {
    var entries: [SelectEntry]
    var presentations: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.entries = entries
        guard presentations != coordinator.presented else { return }
        coordinator.presented = presentations
        guard presentations > 0 else { return }
        let menu = NSMenu()
        for (index, entry) in entries.enumerated() {
            if entry.title.isEmpty { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: #selector(Coordinator.pick(_:)), keyEquivalent: "")
            item.target = coordinator
            item.tag = index
            item.state = entry.checked ? .on : .off
            item.isEnabled = entry.enabled
            menu.addItem(item)
        }
        // Not from inside the update pass: the menu runs its own event loop until it closes. The point is the menu's
        // top-left in the view's own coordinates — just under the trigger, whichever way the view's y axis runs.
        DispatchQueue.main.async {
            let below = NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 4 : -4)
            menu.popUp(positioning: nil, at: below, in: view)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var entries: [SelectEntry] = []
        var presented = 0

        @objc func pick(_ item: NSMenuItem) {
            guard entries.indices.contains(item.tag) else { return }
            entries[item.tag].action()
        }
    }
}

// MARK: - Type helpers

/// A field label: 11 pt medium, muted — "Session", "Weekly".
struct FieldLabel: View {
    var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.resolve(scheme).muted)
            .lineLimit(1)
    }
}

enum Relative {
    /// "2h 14m", "38m", "3d 4h" — the shortest honest countdown.
    static func countdown(to date: Date, from now: Date = .now) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days >= 1 { return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h" }
        if hours >= 1 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(max(1, minutes))m"
    }

    /// "Wed 7:00 AM" — for resets more than a day out, when the weekday matters more than the countdown.
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        let sameDay = Calendar.current.isDateInToday(date)
        f.setLocalizedDateFormatFromTemplate(sameDay ? "jmm" : "EEE jmm")
        return f.string(from: date)
    }

    /// "Sep 29" — for resets more than a few days out, when the weekday alone would be ambiguous.
    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: date)
    }

    static func ago(_ date: Date, from now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}
