import AppKit
import ApplicationServices
import SwiftUI

// The menu bar icons the notch hides. On notched Macs, status icons that don't
// fit between the app's menus and the notch simply vanish — the #1 complaint
// about the notch. This lists every app's menu bar icon (via Accessibility),
// marks the hidden ones, and clicks them for you.

/// One menu bar icon. Holds its Accessibility element so we can press it.
final class MenuExtra: Identifiable, @unchecked Sendable {
    let id: String
    let appName: String
    let label: String
    let icon: NSImage?
    let frame: CGRect           // global, top-left origin (Accessibility coordinates)
    let hidden: Bool
    fileprivate let element: AXUIElement

    init(id: String, appName: String, label: String, icon: NSImage?, frame: CGRect, hidden: Bool, element: AXUIElement) {
        self.id = id; self.appName = appName; self.label = label; self.icon = icon
        self.frame = frame; self.hidden = hidden; self.element = element
    }
}

@MainActor
final class MenuBarStore: ObservableObject {
    @Published private(set) var items: [MenuExtra] = []
    @Published private(set) var loading = false
    @Published private(set) var trusted = AXIsProcessTrusted()

    var hiddenCount: Int { items.filter(\.hidden).count }

    func refresh() {
        trusted = AXIsProcessTrusted()
        guard trusted, !loading else { return }
        loading = true
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited || $0.bundleIdentifier?.hasPrefix("com.apple.") == true }
            .map { ($0.processIdentifier, $0.localizedName ?? "App", $0.icon) }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let geometry = Self.notchGeometry()
        Task.detached(priority: .userInitiated) {
            let found = Self.scan(apps: apps, front: front, geometry: geometry)
            await MainActor.run {
                self.items = found
                self.loading = false
            }
        }
    }

    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Click the icon (opens its menu).
    func press(_ item: MenuExtra) {
        let el = item.element
        Task.detached {
            AXUIElementPerformAction(el, kAXPressAction as CFString)
        }
    }

    // MARK: scanning (off the main thread — every AX call is a round trip to another app)

    struct Geometry: Sendable {
        var notchGap: ClosedRange<CGFloat>?   // x range the camera housing covers
        var screenMinX: CGFloat
        var screenMaxX: CGFloat
    }

    static func notchGeometry() -> Geometry {
        guard let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else {
            return Geometry(notchGap: nil, screenMinX: 0, screenMaxX: 0)
        }
        var gap: ClosedRange<CGFloat>?
        if let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            gap = (s.frame.minX + l.width)...(s.frame.maxX - r.width)
        }
        return Geometry(notchGap: gap, screenMinX: s.frame.minX, screenMaxX: s.frame.maxX)
    }

    nonisolated static func scan(apps: [(pid_t, String, NSImage?)], front: pid_t?, geometry g: Geometry) -> [MenuExtra] {
        // Where the frontmost app's menus end: status icons left of this are covered.
        var menuEnd: CGFloat = g.screenMinX
        if let front {
            let app = AXUIElementCreateApplication(front)
            if let bar: AXUIElement = attr(app, kAXMenuBarAttribute as String),
               let kids: [AXUIElement] = attr(bar, kAXChildrenAttribute as String) {
                for k in kids { if let f = frame(k) { menuEnd = max(menuEnd, f.maxX) } }
            }
        }
        var out: [MenuExtra] = []
        for (pid, name, icon) in apps {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.4)                 // a hung app can't stall us
            guard let bar: AXUIElement = attr(app, "AXExtrasMenuBar"),
                  let kids: [AXUIElement] = attr(bar, kAXChildrenAttribute as String) else { continue }
            for (i, k) in kids.enumerated() {
                let f = frame(k) ?? .zero
                // Control Center keeps zero-size placeholders for modules that aren't shown.
                if f.width < 1 && ["Control Center", "SystemUIServer"].contains(name) { continue }
                let title: String? = attr(k, kAXTitleAttribute as String)
                let desc: String? = attr(k, kAXDescriptionAttribute as String)
                let label = [title, desc].compactMap { $0 }.first { !$0.isEmpty } ?? name
                let underNotch = g.notchGap.map { f.maxX > $0.lowerBound && f.minX < $0.upperBound } ?? false
                let covered = f.minX < menuEnd + 2
                let offscreen = f.width < 2 || f.maxX <= g.screenMinX || f.minX >= g.screenMaxX
                out.append(MenuExtra(id: "\(pid)-\(i)", appName: name, label: label, icon: icon, frame: f,
                                     hidden: underNotch || covered || offscreen, element: k))
            }
        }
        // Right-to-left like the menu bar, hidden ones first.
        return out.sorted { a, b in a.hidden != b.hidden ? a.hidden : a.frame.minX > b.frame.minX }
    }

    nonisolated private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }

    nonisolated private static func frame(_ el: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
              let pv = p, let sv = s else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
}

// MARK: - View

struct MenuBarView: View {
    @ObservedObject var store: MenuBarStore
    @ObservedObject var notch: NotchController
    private let cols = [GridItem(.adaptive(minimum: 112), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.trusted {
                VStack(alignment: .leading, spacing: 8) {
                    Label("See the menu bar icons the notch hides", systemImage: "menubar.dock.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                    Text("OpenNotch needs Accessibility to list and click other apps' menu bar icons. Nothing else is read.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    Button("Allow Accessibility…") {
                        notch.yieldForSystemPrompt("Accessibility")
                        store.requestAccess()
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            } else {
                HStack {
                    Text(store.items.isEmpty ? "Looking at your menu bar…"
                         : "\(store.items.count) icons · \(store.hiddenCount) hidden by the notch or menus")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                    Spacer()
                    if store.loading { ProgressView().controlSize(.small) }
                    Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh").accessibilityLabel("Refresh")
                }
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(store.items) { item in
                            Button { store.press(item) } label: { tile(item) }
                                .buttonStyle(HoverLift())
                                .help(item.hidden ? "Hidden — click to open its menu" : "Click to open its menu")
                                .accessibilityLabel("\(item.appName): \(item.label)\(item.hidden ? ", hidden" : "")")
                        }
                    }
                }
            }
        }
        .padding(16)
        .onAppear { store.refresh() }
    }

    private func tile(_ item: MenuExtra) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                } else {
                    Image(systemName: "menubar.rectangle").font(.system(size: 22))
                }
                if item.hidden {
                    Circle().fill(Color.orange).frame(width: 8, height: 8).offset(x: 4, y: -2)
                }
            }
            Text(item.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
            Text(item.hidden ? "Hidden" : item.appName).font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(item.hidden ? Color.orange : Theme.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(item.hidden ? 0.07 : 0.04)))
    }
}
