import SwiftUI

// The notch's visual language, after Apple's own system UI:
// • SF Pro **Expanded** for titles (the wide display face of the Dynamic Island,
//   Apple Sports and Fitness), SF Pro Rounded with fixed-width digits for numbers,
//   small tracked capitals for section labels, SF Mono for code.
// • Every module has its own accent colour and its own way of reacting to the
//   pointer (an SF Symbols effect played once on hover — no running loops).

// MARK: - Type

enum Typo {
    /// Module and panel titles.
    static func title(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .semibold).width(.expanded) }
    /// Big numbers (timers, stats): rounded, digits that don't jiggle.
    static func numeric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    /// The assistant's name and other friendly labels.
    static func brand(_ size: CGFloat = 14) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    /// Tab and button labels.
    static func label(_ size: CGFloat = 11.5) -> Font { .system(size: size, weight: .semibold) }
    /// "FOR YOU", "DURATIONS": tiny, heavy, tracked — use with `.eyebrow()`.
    static let eyebrow: Font = .system(size: 9.5, weight: .bold).width(.expanded)
    static func body(_ size: CGFloat = 13) -> Font { .system(size: size) }
    static func mono(_ size: CGFloat = 11) -> Font { .system(size: size, design: .monospaced) }
}

extension View {
    /// Small-caps section label: `Text("Durations").eyebrow()`.
    func eyebrow(_ color: Color = Theme.tertiary) -> some View {
        self.font(Typo.eyebrow).tracking(1.1).textCase(.uppercase).foregroundStyle(color)
    }
}

// MARK: - Module identity

extension Module {
    /// Each module's colour (Apple system hues, tuned for a dark surface).
    var accent: Color {
        switch self {
        case .chat: return Color(red: 0.69, green: 0.45, blue: 1.00)
        case .files: return Color(red: 0.30, green: 0.62, blue: 1.00)
        case .menubar: return Color(white: 0.80)
        case .clipboard: return Color(red: 0.42, green: 0.48, blue: 1.00)
        case .shelf: return Color(red: 0.30, green: 0.82, blue: 0.95)
        case .notes: return Color(red: 1.00, green: 0.83, blue: 0.25)
        case .timers: return Color(red: 1.00, green: 0.62, blue: 0.20)
        case .calendar: return Color(red: 1.00, green: 0.36, blue: 0.36)
        case .media: return Color(red: 1.00, green: 0.38, blue: 0.62)
        case .system: return Color(red: 0.35, green: 0.86, blue: 0.48)
        case .screenTime: return Color(red: 0.30, green: 0.80, blue: 0.78)
        case .convert: return Color(red: 0.45, green: 0.90, blue: 0.75)
        case .usage: return Color(red: 0.78, green: 0.58, blue: 1.00)
        case .captures: return Color(red: 0.55, green: 0.76, blue: 1.00)
        }
    }

    /// One line under the name when you hover its tab.
    var blurb: String {
        switch self {
        case .chat: return "Ask anything"
        case .files: return "Spotlight, faster"
        case .menubar: return "Icons the notch hides"
        case .clipboard: return "Everything you copied"
        case .shelf: return "Drop files here"
        case .notes: return "Quick notes"
        case .timers: return "Focus & breaks"
        case .calendar: return "Today & reminders"
        case .media: return "Now playing"
        case .system: return "CPU, memory, battery"
        case .screenTime: return "Where time went"
        case .convert: return "Images in any format"
        case .usage: return "Your AI activity"
        case .captures: return "Screenshots & clips"
        }
    }

    /// How the icon reacts to the pointer — something that suits it.
    var hover: HoverMotion {
        switch self {
        case .chat, .usage: return .breathe
        case .files, .notes, .calendar: return .wiggle
        case .timers, .system: return .rotate
        case .menubar, .shelf: return .bounceDown
        case .media, .screenTime: return .pulse
        case .clipboard, .convert, .captures: return .bounceUp
        }
    }
}

enum HoverMotion { case bounceUp, bounceDown, wiggle, rotate, breathe, pulse }

/// Plays a module's motion once each time `trigger` changes. Wiggle, rotate and
/// breathe are macOS 15+; older systems bounce instead.
struct HoverSymbol: ViewModifier {
    let motion: HoverMotion
    let trigger: Int

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            switch motion {
            case .bounceUp: content.symbolEffect(.bounce.up, options: .speed(1.3), value: trigger)
            case .bounceDown: content.symbolEffect(.bounce.down, options: .speed(1.3), value: trigger)
            case .wiggle: content.symbolEffect(.wiggle, options: .speed(1.4), value: trigger)
            case .rotate: content.symbolEffect(.rotate, options: .speed(1.6), value: trigger)
            case .breathe: content.symbolEffect(.breathe, options: .speed(1.8), value: trigger)
            case .pulse: content.symbolEffect(.pulse, options: .speed(1.5), value: trigger)
            }
        } else {
            content.symbolEffect(.bounce, value: trigger)
        }
    }
}

// MARK: - Accent through the view tree

private struct AccentKey: EnvironmentKey {
    static let defaultValue = Color(red: 0.42, green: 0.48, blue: 1.00)
}

extension EnvironmentValues {
    /// The open module's colour (chips, titles, highlights pick it up).
    var moduleAccent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}

// MARK: - Tab

/// One module in the tab bar: tinted pill when selected; on hover the icon takes
/// its colour, plays its motion and a soft pill fades in (opacity only).
struct ModuleTab: View {
    let module: Module
    let selected: Bool
    @Binding var hovered: Module?
    let ns: Namespace.ID
    let select: () -> Void
    @State private var bumps = 0

    private var isHover: Bool { hovered == module }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Image(systemName: module.icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .modifier(HoverSymbol(motion: module.hover, trigger: bumps))
                    .frame(width: 15)
                if selected {
                    Text(module.title).font(Typo.label(11).width(.expanded)).lineLimit(1)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .foregroundStyle(selected ? module.accent : (isHover ? module.accent : Theme.secondary))
            .padding(.horizontal, selected ? 10 : 8).padding(.vertical, 5)
            .background {
                if selected {
                    Capsule()
                        .fill(LinearGradient(colors: [module.accent.opacity(0.30), module.accent.opacity(0.14)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(module.accent.opacity(0.38), lineWidth: 0.75))
                        .matchedGeometryEffect(id: "tab", in: ns)
                } else {
                    Capsule().fill(module.accent.opacity(0.13)).opacity(isHover ? 1 : 0)
                }
            }
            .scaleEffect(isHover && !selected ? 1.07 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = module; bumps += 1 } else if hovered == module { hovered = nil }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHover)
        .accessibilityLabel(module.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Small hover helpers

/// A header icon button that brightens and bounces when pointed at.
struct HoverIconButton: View {
    let icon: String
    let help: String
    var tint: Color = .white
    let action: () -> Void
    @State private var over = false
    @State private var bumps = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(over ? tint : Theme.secondary)
                .symbolEffect(.bounce, options: .speed(1.4), value: bumps)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(over ? 0.10 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            over = inside
            if inside { bumps += 1 }
        }
        .animation(.easeOut(duration: 0.15), value: over)
    }
}
