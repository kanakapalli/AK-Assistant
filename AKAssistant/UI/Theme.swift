import SwiftUI
import AppKit

// Duck Keyboard's look, taken from the app icon: a warm duck-bill orange, light keycaps with a
// dark outline and a soft drop shadow, and rounded, friendly shapes.
// Everything here is shared by the main window, the menu bar popover and Learn.

enum Duck {
    /// The bill orange. Also the app's AccentColor (toggles, selection, prominent buttons).
    static let orange = Color.adaptive(light: NSColor(srgbRed: 0.949, green: 0.502, blue: 0.098, alpha: 1),
                                       dark: NSColor(srgbRed: 0.980, green: 0.580, blue: 0.200, alpha: 1))
    /// The icon's outline colour.
    static let ink = Color.adaptive(light: NSColor(srgbRed: 0.16, green: 0.15, blue: 0.21, alpha: 1),
                                    dark: NSColor(white: 0.92, alpha: 1))

    // Keycaps
    static let keyTop = Color.adaptive(light: NSColor(white: 0.985, alpha: 1), dark: NSColor(white: 0.34, alpha: 1))
    static let keyBottom = Color.adaptive(light: NSColor(white: 0.875, alpha: 1), dark: NSColor(white: 0.25, alpha: 1))
    static let keyBorder = Color.adaptive(light: NSColor(srgbRed: 0.16, green: 0.15, blue: 0.21, alpha: 0.85),
                                          dark: NSColor(white: 0.06, alpha: 1))
    static let keyBase = Color.adaptive(light: NSColor(white: 0.60, alpha: 1), dark: NSColor(white: 0.02, alpha: 1))

    // Kinds of history entry and other recurring meanings.
    static let dictation = orange
    static let assistant = Color.indigo
    static let writing = Color.teal
    static let good = Color.green
    static let warning = Color.orange
    static let recording = Color.red

    static let cardRadius: CGFloat = 14
    static var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: cardRadius, style: .continuous) }
}

extension Color {
    /// A colour that follows light / dark mode.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - Keycap

/// A key drawn like the keys in the app icon: light face, dark outline, a solid base below it.
struct DuckKeycap: View {
    let label: String
    var size: Size = .small

    enum Size { case small, regular, large }

    init(_ label: String, size: Size = .small) {
        self.label = label
        self.size = size
    }

    private var font: Font {
        switch size {
        case .small: return .system(.caption, design: .rounded).weight(.semibold)
        case .regular: return .system(.callout, design: .rounded).weight(.semibold)
        case .large: return .system(.title3, design: .rounded).weight(.semibold)
        }
    }

    private var radius: CGFloat { size == .small ? 5 : (size == .regular ? 7 : 9) }
    private var depth: CGFloat { size == .small ? 2 : 3 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Text(label)
            .font(font)
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .padding(.horizontal, size == .small ? 6 : (size == .regular ? 9 : 12))
            .padding(.vertical, size == .small ? 1.5 : (size == .regular ? 3.5 : 6))
            .frame(minWidth: size == .small ? 20 : (size == .regular ? 28 : 38))
            .background(shape.fill(LinearGradient(colors: [Duck.keyTop, Duck.keyBottom], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(Duck.keyBorder, lineWidth: size == .large ? 1.5 : 1))
            .background(shape.fill(Duck.keyBase).offset(x: depth * 0.6, y: depth))
            .padding(.bottom, depth)
            .padding(.trailing, depth * 0.6)
            .fixedSize()
    }
}

// MARK: - Cards, tiles and headers

private struct DuckCardModifier: ViewModifier {
    var tint: Color?
    var padding: CGFloat
    var highlighted: Bool

    func body(content: Content) -> some View {
        let base = tint ?? Color.primary
        content
            .padding(padding)
            .background(base.opacity(tint == nil ? (highlighted ? 0.06 : 0.035) : (highlighted ? 0.12 : 0.07)), in: Duck.cardShape)
            .overlay(Duck.cardShape.strokeBorder(base.opacity(tint == nil ? (highlighted ? 0.14 : 0.08) : 0.25)))
    }
}

extension View {
    /// The rounded card used across the app. A tint colours it lightly (e.g. green for "done").
    func duckCard(tint: Color? = nil, padding: CGFloat = 14, highlighted: Bool = false) -> some View {
        modifier(DuckCardModifier(tint: tint, padding: padding, highlighted: highlighted))
    }
}

/// A rounded square with a coloured symbol, like a small app icon.
struct IconTile: View {
    let symbol: String
    var tint: Color = Duck.orange
    var size: CGFloat = 28
    var filled = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(filled ? Color.white : tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.15)))
            )
    }
}

/// The app icon, for headers.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Big number with a label, for the top of History.
struct DuckStatTile: View {
    let value: String
    let title: String
    let symbol: String
    var tint: Color = Duck.orange

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .duckCard(padding: 10)
    }
}

/// Title, one line of explanation and an icon tile, at the top of a page.
struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String
    var tint: Color = Duck.orange
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 38, filled: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        // Capped, never fixedSize: a fixed-height wrapping line reports a huge
                        // minimum height when the window measures it narrow, which pushed the
                        // whole window (sidebar included) up under the title bar on Settings.
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String, tint: Color = Duck.orange) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, tint: tint) { EmptyView() }
    }
}

/// Small uppercase label above a group of things.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// A coloured capsule with a dot: "Ready", "Listening", "Recording".
struct StatusPill: View {
    let title: String
    var tint: Color = Duck.good

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

/// A friendly empty page: icon tile, title, message and optional actions.
struct DuckEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var tint: Color = Duck.orange
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 64)
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: 420)
            actions
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension DuckEmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String? = nil, tint: Color = Duck.orange) {
        self.init(symbol: symbol, title: title, message: message, tint: tint) { EmptyView() }
    }
}

// MARK: - Tabs and chips

/// The tab bar used by Settings, Learn and a meeting's detail.
/// `.toolbar`: icon over label (like macOS Settings). `.pills`: icon + label in a capsule.
struct DuckTabBar<Tab: Hashable & Identifiable>: View {
    enum Style { case toolbar, pills }

    let tabs: [Tab]
    @Binding var selection: Tab
    var style: Style = .toolbar
    let title: (Tab) -> String
    let symbol: (Tab) -> String
    var badge: (Tab) -> String? = { _ in nil }

    var body: some View {
        HStack(spacing: style == .toolbar ? 2 : 6) {
            ForEach(tabs) { tab in
                DuckTabButton(
                    title: title(tab),
                    symbol: symbol(tab),
                    badge: badge(tab),
                    selected: tab == selection,
                    isToolbar: style == .toolbar
                ) {
                    withAnimation(.snappy(duration: 0.2)) { selection = tab }
                }
            }
        }
    }
}

private struct DuckTabButton: View {
    let title: String
    let symbol: String
    let badge: String?
    let selected: Bool
    let isToolbar: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if isToolbar {
                    VStack(spacing: 3) {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(height: 18)
                        Text(title)
                            .font(.caption.weight(selected ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .frame(minWidth: 70)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                        Text(title).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(selected ? Color.white.opacity(0.25) : Duck.orange.opacity(0.18)))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
            }
            .foregroundStyle(selected ? (isToolbar ? Duck.orange : Color.white) : Color.primary.opacity(0.8))
            .background(background)
            .overlay(alignment: .topTrailing) {
                if isToolbar, let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Duck.orange))
                        .offset(x: -4, y: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var background: some View {
        if isToolbar {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Duck.orange.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        } else {
            Capsule()
                .fill(selected ? AnyShapeStyle(Duck.orange.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.09 : 0.05)))
        }
    }
}

/// A filter chip with an optional count: "AI · 12".
struct DuckChip: View {
    let title: String
    var symbol: String? = nil
    var count: Int? = nil
    var tint: Color = Duck.orange
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    init(title: String, symbol: String? = nil, count: Int? = nil, tint: Color = Duck.orange,
         selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.count = count
        self.tint = tint
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.callout.weight(selected ? .semibold : .regular))
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.09 : 0.05))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Short label for a hotkey, for keycaps ("⌥", "fn", "Shortcut").
extension HotkeyChoice {
    var keycapLabel: String {
        switch self {
        case .fn: return "fn"
        case .custom: return "Shortcut"
        case .off: return "Off"
        default: return shortTitle
        }
    }
}
