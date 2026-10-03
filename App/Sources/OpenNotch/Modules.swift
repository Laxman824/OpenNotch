import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything the notch can show besides the chat. Each can be switched off
/// (right-click › Modules) so the bar only carries what fits your day.
enum Module: String, CaseIterable, Identifiable {
    case chat, files, menubar, clipboard, shelf, notes, timers, calendar, media, system, screenTime, convert, usage, captures

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return Prefs.name
        case .files: return "Find files"
        case .menubar: return "Menu bar"
        case .clipboard: return "Clipboard"
        case .shelf: return "Shelf"
        case .notes: return "Notes"
        case .timers: return "Timers"
        case .calendar: return "Calendar"
        case .media: return "Music"
        case .system: return "System"
        case .screenTime: return "Screen time"
        case .convert: return "Convert"
        case .usage: return "AI usage"
        case .captures: return "Captures"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "sparkles"
        case .files: return "magnifyingglass"
        case .menubar: return "menubar.dock.rectangle"
        case .clipboard: return "doc.on.clipboard"
        case .shelf: return "tray.and.arrow.down"
        case .notes: return "note.text"
        case .timers: return "timer"
        case .calendar: return "calendar"
        case .media: return "music.note"
        case .system: return "gauge.with.dots.needle.33percent"
        case .screenTime: return "hourglass"
        case .convert: return "photo.on.rectangle.angled"
        case .usage: return "square.grid.3x3.fill"
        case .captures: return "camera.viewfinder"
        }
    }
}

/// Owns the module stores. One per app.
@MainActor
final class Hub: ObservableObject {
    @Published var module: Module = .chat
    @Published var disabled: Set<String> = Set((UserDefaults.standard.string(forKey: "modules.disabled") ?? "")
        .split(separator: ",").map(String.init))

    let clipboard = ClipboardStore()
    let shelf = ShelfStore()
    let notes = NotesStore()
    let timers = TimerStore()
    let calendar = CalendarStore()
    let system = SystemStats()
    let screenTime = ScreenTimeTracker()
    let usage = UsageStore()
    let captures = CaptureStore()
    let files = FileSearch()
    let menubar = MenuBarStore()
    let convert = ConvertStore()
    let context = ContextModel()
    let proactive = ProactiveEngine()
    lazy var quick = QuickCaptureRunner(calendar: calendar, notes: notes)

    var enabled: [Module] { Module.allCases.filter { $0 == .chat || !disabled.contains($0.rawValue) } }

    func toggle(_ m: Module) {
        guard m != .chat else { return }
        if disabled.contains(m.rawValue) { disabled.remove(m.rawValue) } else { disabled.insert(m.rawValue) }
        UserDefaults.standard.set(disabled.sorted().joined(separator: ","), forKey: "modules.disabled")
        if disabled.contains(module.rawValue) { module = .chat }
    }

    func start() {
        clipboard.start()
        timers.start()
        screenTime.start()
    }
}

// MARK: - Module bar

struct ModuleBar: View {
    @ObservedObject var hub: Hub
    @Namespace private var ns
    @State private var hovered: Module?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(hub.enabled) { m in
                    ModuleTab(module: m, selected: hub.module == m, hovered: $hovered, ns: ns) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { hub.module = m }
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 34)
        // Pointing at a tab says what it is, in its colour, at the end of the bar.
        .overlay(alignment: .trailing) {
            if let m = hovered, m != hub.module {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(m.title).font(Typo.label(11).width(.expanded)).foregroundStyle(m.accent)
                    Text(m.blurb).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
                .lineLimit(1)
                .padding(.leading, 14).padding(.trailing, 18)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.55)],
                                           startPoint: .leading, endPoint: .trailing))
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .offset(x: 6)))
                .id(m)
            }
        }
        .animation(.easeOut(duration: 0.16), value: hovered)
    }
}

/// Non-chat module content.
struct ModuleHost: View {
    @ObservedObject var hub: Hub
    @ObservedObject var backend: Backend
    @ObservedObject var notch: NotchController

    var body: some View {
        Group {
            switch hub.module {
            case .chat: EmptyView()
            case .files: FilesView(store: hub.files, backend: backend, hub: hub)
            case .menubar: MenuBarView(store: hub.menubar, notch: notch)
            case .clipboard: ClipboardView(store: hub.clipboard, backend: backend, hub: hub)
            case .shelf: ShelfView(store: hub.shelf, backend: backend, hub: hub)
            case .notes: NotesView(store: hub.notes, backend: backend, notch: notch, hub: hub)
            case .timers: TimersView(store: hub.timers)
            case .calendar: CalendarView(store: hub.calendar, notch: notch)
            case .media: MediaView(backend: backend)
            case .system: SystemView(stats: hub.system)
            case .screenTime: ScreenTimeView(tracker: hub.screenTime)
            case .convert: ConvertView(store: hub.convert)
            case .usage: UsageView(store: hub.usage)
            case .captures: CapturesView(store: hub.captures, backend: backend, hub: hub)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A faint wash of the module's colour from the top: static, cross-fades with the module.
        .background(alignment: .top) {
            RadialGradient(colors: [hub.module.accent.opacity(0.13), .clear], center: .top, startRadius: 0, endRadius: 260)
                .frame(height: 170)
                .allowsHitTesting(false)
        }
        .environment(\.moduleAccent, hub.module.accent)
        .id(hub.module)
        // One short, explicit cross-fade — however the module changed (tab,
        // `notch -m`, a drop zone), so the old one can't linger underneath.
        .transition(.opacity.animation(.easeOut(duration: 0.14)))
    }
}

// MARK: - Shared bits

struct ModuleHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.moduleAccent) private var accent

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    RoundedRectangle(cornerRadius: 1.5).fill(accent).frame(width: 3, height: 13)
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                    Text(title).font(Typo.title(16))
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                        .padding(.leading, 10)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 6)
    }
}

struct Chip: View {
    let label: String
    var icon: String? = nil
    var selected = false
    let action: () -> Void
    @Environment(\.moduleAccent) private var accent
    @State private var over = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? .black.opacity(0.85) : (over ? .white : Theme.secondary))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(selected ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(over ? 0.13 : 0.07))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
        .animation(.easeOut(duration: 0.12), value: over)
    }
}

struct PillButton: View {
    let label: String
    var icon: String? = nil
    var primary = false
    let action: () -> Void
    @Environment(\.moduleAccent) private var accent
    @State private var over = false
    @State private var bumps = 0

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                        .symbolEffect(.bounce, options: .speed(1.4), value: bumps)
                }
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            // Primary: a solid accent pill with dark text, like Apple's prominent buttons on dark glass.
            .foregroundStyle(primary ? AnyShapeStyle(Color.black.opacity(0.85)) : AnyShapeStyle(Color.white.opacity(over ? 1 : 0.85)))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(primary ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(over ? 0.16 : 0.1))))
            .brightness(primary && over ? 0.06 : 0)
            .scaleEffect(over ? 1.03 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            over = inside
            if inside { bumps += 1 }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: over)
    }
}

struct EmptyHint: View {
    let icon: String
    let text: String
    @Environment(\.moduleAccent) private var accent
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(accent.opacity(0.7))
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

func appIcon(forPath path: String, size: CGFloat) -> Image {
    let img = NSWorkspace.shared.icon(forFile: path)
    img.size = NSSize(width: size, height: size)
    return Image(nsImage: img)
}

func relativeTime(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: d, relativeTo: Date())
}

/// Everything OpenNotch keeps lives on this Mac, under one folder.
enum AppPaths {
    static let root = NSHomeDirectory() + "/Library/Application Support/OpenNotch"
}

func opennotchDir(_ sub: String) -> String {
    let dir = "\(AppPaths.root)/\(sub)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Drop zones

/// Shown while a file is dragged over the open notch: pick where it goes.
struct DropZones: View {
    @ObservedObject var hub: Hub
    @ObservedObject var backend: Backend
    @ObservedObject var notch: NotchController

    var body: some View {
        HStack(spacing: 10) {
            zone("Ask \(Prefs.name)", icon: "sparkles") { urls in
                backend.attachDropped(urls)
                hub.module = .chat
                notch.expand(pinned: true, focus: true)
            }
            zone("Keep on Shelf", icon: "tray.and.arrow.down") { urls in
                hub.shelf.add(urls.filter(\.isFileURL))
                hub.module = .shelf
            }
            zone("Convert images", icon: "photo.on.rectangle.angled") { urls in
                hub.convert.add(urls.filter(\.isFileURL))
                hub.module = .convert
            }
        }
        .padding(16)
        .background(Theme.panel.opacity(0.92))
    }

    private func zone(_ title: String, icon: String, _ handle: @escaping ([URL]) -> Void) -> some View {
        DropZone(title: title, icon: icon, handle: handle)
    }
}

struct DropZone: View {
    let title: String
    let icon: String
    let handle: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 24, weight: .medium))
            Text(title).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(targeted ? .white : Theme.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(targeted ? AnyShapeStyle(Theme.userBubble.opacity(0.5)) : AnyShapeStyle(Color.white.opacity(0.05))))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(targeted ? Color.white.opacity(0.6) : Theme.hairline))
        .scaleEffect(targeted ? 1.03 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: targeted)
        .onDrop(of: [.fileURL, .url], isTargeted: $targeted) { providers in
            loadURLs(providers) { handle($0) }
            return true
        }
    }
}

func loadURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { done(urls) }
}
