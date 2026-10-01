import ApplicationServices
import AVFoundation
import EventKit
import Security
import Speech
import SwiftUI

// Settings window (menu › Settings…, ⌘, in the notch, `notch --settings`),
// the permission checklist that doubles as first-run onboarding, and the
// app-wide animation policy (energy saver on battery, Reduce Motion).

// MARK: - Preferences

enum Prefs {
    static let hudVolume = "hud.volume", hudDevice = "hud.device", hudPower = "hud.power"
    static let playerHover = "player.hover"
    static let hudHealth = "hud.health"
    static let desktopDance = "desktop.dance", desktopReactions = "desktop.reactions", desktopSleep = "desktop.sleep"
    static let energySaver = "energy.saver"
    static let onboardingDone = "onboarding.done"

    /// Every toggle here defaults to on.
    static func on(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
}

// MARK: - Animation policy

/// How lively the per-frame animations may be. Energy saver (default on)
/// drops them to 12 fps on battery or in Low Power Mode; Reduce Motion (the
/// system setting) calms the beat pulses and slows the waves.
@MainActor
final class AnimationPolicy: ObservableObject {
    static let shared = AnimationPolicy()

    @Published private(set) var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published private(set) var eco = false
    /// Fed by `SystemMonitor` (IOKit power notifications).
    var onBattery = false { didSet { refresh() } }
    var fps: Double { eco ? 12 : 24 }
    private var observers: [NSObjectProtocol] = []

    private init() {
        MusicPulse.calm = reduceMotion
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AnimationPolicy.shared.refresh() }
        })
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, UserDefaults.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AnimationPolicy.shared.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let rm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if rm != reduceMotion { reduceMotion = rm }
        MusicPulse.calm = rm
        let e = Prefs.on(Prefs.energySaver) && (onBattery || ProcessInfo.processInfo.isLowPowerModeEnabled)
        if e != eco { eco = e }
    }
}

// MARK: - Window

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, ai, notch, desktop, voice, permissions, shortcuts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .ai: return "AI"
        case .notch: return "Notch"
        case .desktop: return "Desktop Ledge"
        case .voice: return "Voice"
        case .permissions: return "Permissions"
        case .shortcuts: return "Shortcuts"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .ai: return "sparkles"
        case .notch: return "rectangle.topthird.inset.filled"
        case .desktop: return "figure.wave"
        case .voice: return "waveform"
        case .permissions: return "lock.shield"
        case .shortcuts: return "command"
        }
    }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let model = SettingsModel()

    func show(_ tab: SettingsTab = .general, welcome: Bool = false) {
        model.tab = tab
        model.welcome = welcome
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "OpenNotch Settings"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
        }
        model.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
        if model.welcome { UserDefaults.standard.set(true, forKey: Prefs.onboardingDone) }
    }
}

// MARK: - Permissions model

struct PermissionRow: Identifiable {
    enum State { case granted, denied, unknown, notAsked }
    let id: String
    let icon: String
    let title: String
    let why: String
    var state: State
    let fix: () -> Void
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var tab: SettingsTab = .general
    @Published var welcome = false
    @Published var rows: [PermissionRow] = []
    @Published var adHocSigned = false
    private var poll: Timer?

    func startPolling() {
        refresh()
        adHocSigned = Self.isAdHocSigned()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stopPolling() { poll?.invalidate(); poll = nil }

    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let cam = AVCaptureDevice.authorizationStatus(for: .video)
        let speech = SFSpeechRecognizer.authorizationStatus()
        let cal = EKEventStore.authorizationStatus(for: .event)
        let rem = EKEventStore.authorizationStatus(for: .reminder)
        rows = [
            PermissionRow(id: "mic", icon: "mic.fill", title: "Microphone", why: "Hands-free and dictation",
                          state: Self.state(mic == .authorized, asked: mic != .notDetermined)) {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    DispatchQueue.main.async { Self.openPane(mic == .notDetermined ? nil : "Privacy_Microphone") }
                }
            },
            PermissionRow(id: "cam", icon: "web.camera", title: "Camera", why: "Camera mirror (nothing is recorded)",
                          state: Self.state(cam == .authorized, asked: cam != .notDetermined)) {
                if cam == .notDetermined { AVCaptureDevice.requestAccess(for: .video) { _ in } }
                else { Self.openPane("Privacy_Camera") }
            },
            PermissionRow(id: "speech", icon: "waveform", title: "Speech Recognition", why: "Understands what you say",
                          state: Self.state(speech == .authorized, asked: speech != .notDetermined)) {
                if speech == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in } }
                else { Self.openPane("Privacy_SpeechRecognition") }
            },
            PermissionRow(id: "cal", icon: "calendar", title: "Calendars", why: "Today's events, meeting heads-up",
                          state: Self.state(cal == .fullAccess, asked: cal != .notDetermined)) {
                if cal == .notDetermined { EKEventStore().requestFullAccessToEvents { _, _ in } }
                else { Self.openPane("Privacy_Calendars") }
            },
            PermissionRow(id: "rem", icon: "checklist", title: "Reminders", why: "Quick capture “remind me…”",
                          state: Self.state(rem == .fullAccess, asked: rem != .notDetermined)) {
                if rem == .notDetermined { EKEventStore().requestFullAccessToReminders { _, _ in } }
                else { Self.openPane("Privacy_Reminders") }
            },
            PermissionRow(id: "screen", icon: "rectangle.dashed.badge.record", title: "Screen Recording",
                          why: "Captures and “explain my screen”",
                          state: CGPreflightScreenCaptureAccess() ? .granted : .unknown) {
                if !CGRequestScreenCaptureAccess() { Self.openPane("Privacy_ScreenCapture") }
            },
            PermissionRow(id: "ax", icon: "accessibility", title: "Accessibility",
                          why: "Ask about the selected text, Replace in writing tools",
                          state: AXIsProcessTrusted() ? .granted : .unknown) {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                if !AXIsProcessTrustedWithOptions(opts) { Self.openPane("Privacy_Accessibility") }
            },
        ]
    }

    private static func state(_ ok: Bool, asked: Bool) -> PermissionRow.State {
        ok ? .granted : (asked ? .denied : .notAsked)
    }

    static func openPane(_ anchor: String?) {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        if let url = URL(string: anchor.map { "\(base)?\($0)" } ?? base) { NSWorkspace.shared.open(url) }
    }

    /// Ad-hoc signed ⇒ macOS treats every rebuild as a new app and forgets grants.
    static func isAdHocSigned() -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return false }
        return (d[kSecCodeInfoCertificates as String] as? [Any] ?? []).isEmpty
    }
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    AssistantFaceMini()
                    Text("OpenNotch").font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .padding(.bottom, 14).padding(.leading, 6)
                ForEach(SettingsTab.allCases) { t in
                    Button { model.tab = t } label: {
                        Label(t.title, systemImage: t.icon)
                            .font(.system(size: 12.5, weight: model.tab == t ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6).padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(model.tab == t ? AnyShapeStyle(Theme.userBubble.opacity(0.55)) : AnyShapeStyle(Color.clear)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.tab == t ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.top, 44).padding(.horizontal, 12)
            .frame(width: 190)
            .background(Color.white.opacity(0.03))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.welcome { welcome }
                    Text(model.tab.title).font(.system(size: 20, weight: .bold, design: .rounded))
                    switch model.tab {
                    case .general: GeneralPane()
                    case .ai: AIPane()
                    case .notch: NotchPane()
                    case .desktop: DesktopPane()
                    case .voice: VoicePane()
                    case .permissions: PermissionsPane(model: model)
                    case .shortcuts: ShortcutsPane()
                    }
                }
                .padding(.horizontal, 26).padding(.top, 40).padding(.bottom, 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to OpenNotch 👋").font(.system(size: 16, weight: .bold, design: .rounded))
            Text("Ledge lives in your notch. Grant these once and everything works — each row turns green as you go. You can come back any time from the notch menu › Settings.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Button("I'm all set") {
                UserDefaults.standard.set(true, forKey: Prefs.onboardingDone)
                model.welcome = false
            }
            .buttonStyle(.borderedProminent).padding(.top, 4)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.userBubble.opacity(0.35)))
    }
}

/// A tiny static stand-in for the avatar in the sidebar.
private struct AssistantFaceMini: View {
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Theme.glow[0], Theme.glow[1], Theme.glow[2]],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 22, height: 22)
            .overlay(HStack(spacing: 4) { Capsule().frame(width: 3, height: 6); Capsule().frame(width: 3, height: 6) }
                .foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(0.8).foregroundStyle(Theme.tertiary)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
        }
    }
}

private struct PrefToggle: View {
    let title: String
    let sub: String?
    @AppStorage private var on: Bool
    init(_ title: String, _ key: String, sub: String? = nil) {
        self.title = title
        self.sub = sub
        _on = AppStorage(wrappedValue: true, key)
    }
    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let sub { Text(sub).font(.system(size: 11)).foregroundStyle(Theme.secondary) }
            }
        }
        .toggleStyle(.switch).controlSize(.small)
    }
}

private struct GeneralPane: View {
    @AppStorage("assistantName") private var name = "Ledge"
    @AppStorage("avatarPalette") private var palette = "aurora"
    @AppStorage("handsfree.autostart") private var handsFreeAtLaunch = false
    @ObservedObject private var policy = AnimationPolicy.shared

    var body: some View {
        Section(title: "Assistant") {
            HStack {
                Text("Name").font(.system(size: 12.5, weight: .medium))
                Spacer()
                TextField("Ledge", text: $name).textFieldStyle(.roundedBorder).frame(width: 180)
                    .onChange(of: name) { _, v in
                        if v.count > 20 { name = String(v.prefix(20)) }
                        if !v.trimmingCharacters(in: .whitespaces).isEmpty { VoiceTurn.wakeName = v }
                    }
            }
            HStack {
                Text("Notch face colours").font(.system(size: 12.5, weight: .medium))
                Spacer()
                Picker("", selection: $palette) {
                    ForEach(AvatarPalette.all) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 180)
            }
            Toggle("Start hands-free at launch", isOn: $handsFreeAtLaunch).toggleStyle(.switch).controlSize(.small)
                .font(.system(size: 12.5, weight: .medium))
        }
        Section(title: "Motion & energy") {
            PrefToggle("Save energy on battery", Prefs.energySaver,
                       sub: "Animations drop to 12 fps on battery or in Low Power Mode" + (policy.eco ? " — saving now" : ""))
            HStack(spacing: 8) {
                Image(systemName: policy.reduceMotion ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(policy.reduceMotion ? .green : Theme.tertiary)
                Text("Reduce Motion follows System Settings › Accessibility › Display")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct NotchPane: View {
    var body: some View {
        Section(title: "Music") {
            PrefToggle("Hover player", Prefs.playerHover,
                       sub: "Resting on the music ears opens a compact player instead of the full notch")
        }
        Section(title: "System pop-ups") {
            PrefToggle("Volume", Prefs.hudVolume)
            PrefToggle("Headphones & speakers", Prefs.hudDevice, sub: "With AirPods battery when connected")
            PrefToggle("Charging & low battery", Prefs.hudPower)
            PrefToggle("Health alerts", Prefs.hudHealth, sub: "Sustained CPU load, memory pressure, heat, low disk — at most every 30 min each")
        }
        Section(title: "Setup") {
            Button("Show the welcome checklist again") {
                SettingsWindow.shared.show(.permissions, welcome: true)
            }
        }
    }
}

private struct DesktopPane: View {
    @State private var enabled = DesktopCompanion.enabled
    @State private var avatar = DesktopCompanion.avatar
    private let looks: [(id: String, name: String, icon: String, tint: Color)] = [
        ("ledge", "Ledge", "figure.wave", Color(red: 0.72, green: 0.64, blue: 1.0)),
        ("bee", "Bee", "ladybug.fill", Color(red: 1.0, green: 0.62, blue: 0.2)),
        ("cat", "Cat", "cat.fill", Color(red: 0.55, green: 0.95, blue: 0.5)),
    ]

    var body: some View {
        Section(title: "Companion") {
            Toggle("Show Desktop Ledge", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
                .font(.system(size: 12.5, weight: .medium))
                .onChange(of: enabled) { _, v in (NSApp.delegate as? AppDelegate)?.desktop.setEnabled(v) }
            HStack(spacing: 12) {
                ForEach(looks, id: \.id) { l in
                    Button {
                        avatar = l.id
                        (NSApp.delegate as? AppDelegate)?.desktop.setAvatar(l.id)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: l.icon).font(.system(size: 26)).foregroundStyle(l.tint)
                            Text(l.name).font(.system(size: 11.5, weight: .semibold))
                        }
                        .frame(width: 92, height: 76)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(avatar == l.id ? l.tint.opacity(0.18) : Color.white.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(avatar == l.id ? l.tint : Theme.hairline, lineWidth: avatar == l.id ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(l.name) avatar")
                    .accessibilityAddTraits(avatar == l.id ? .isSelected : [])
                }
            }
            .disabled(!enabled).opacity(enabled ? 1 : 0.5)
        }
        Section(title: "Personality") {
            PrefToggle("Dance to music", Prefs.desktopDance, sub: "When Spotify or Music is playing")
            PrefToggle("React to Ledge", Prefs.desktopReactions,
                       sub: "Points at the notch when Ledge needs your OK, celebrates when a task is done")
            PrefToggle("Doze off late at night", Prefs.desktopSleep, sub: "11 pm – 6 am when nothing's going on; hover to wake him")
        }
    }
}

private struct VoicePane: View {
    @State private var rate: Double = Double((UserDefaults.standard.object(forKey: "handsfree.rate") as? Float) ?? 0.52)

    var body: some View {
        Section(title: "Speaking") {
            HStack {
                Text("Voice").font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text("Zoe (Premium)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Speed").font(.system(size: 12.5, weight: .medium))
                HStack {
                    Image(systemName: "tortoise.fill").foregroundStyle(Theme.tertiary).accessibilityHidden(true)
                    Slider(value: $rate, in: 0.40...0.62) { Text("Speaking speed") }
                        .onChange(of: rate) { _, v in (NSApp.delegate as? AppDelegate)?.handsFree.setSpeakingRate(Float(v)) }
                    Image(systemName: "hare.fill").foregroundStyle(Theme.tertiary).accessibilityHidden(true)
                }
                Text("You can also say “slower” or “faster” in hands-free.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
        Section(title: "Hands-free") {
            Text("⌥⇧Space starts and stops it. Say “Ledge” to wake it from standby, “stop listening” to end.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }
}

private struct PermissionsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if model.adHocSigned {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("This build is ad-hoc signed, so macOS forgets these grants after every rebuild. Run `opennotch/app/signing.sh` once to keep them.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.08)))
        }
        Section(title: "OpenNotch app") {
            ForEach(model.rows) { PermissionRowView(row: $0) }
        }
    }
}

private struct PermissionRowView: View {
    let row: PermissionRow
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.icon).font(.system(size: 14)).frame(width: 22).foregroundStyle(Theme.glow[0])
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 12.5, weight: .semibold))
                Text(row.why).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            switch row.state {
            case .granted:
                Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .font(.system(size: 12, weight: .semibold))
            case .denied, .unknown, .notAsked:
                Button(row.state == .notAsked ? "Allow…" : "Open Settings", action: row.fix)
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.state == .granted ? "granted" : "not granted")
    }
}

private struct ShortcutsPane: View {
    private let items: [(String, String)] = [
        ("⌥Space", "Open or close the notch"),
        ("⌥⇧Space", "Hands-free on / off"),
        ("⌘K", "Command palette (in the notch)"),
        ("⌘N", "New chat"),
        ("⌘.", "Stop the running task"),
        ("⌘P", "Pin the notch open"),
        ("⌘,", "Settings"),
        ("⌘K → “mirror”", "Camera mirror"),
        ("⌘K → “awake”", "Keep your Mac awake"),
        ("↑ / ↓", "Recall earlier prompts"),
        ("⌃⌥S", "Screenshot → crop / blur / frame"),
        ("⌃⌥A", "Draw on the screen and ask"),
        ("Esc", "Close the notch / interrupt speech"),
    ]
    var body: some View {
        Section(title: "Keyboard") {
            ForEach(items, id: \.0) { k, v in
                HStack {
                    Text(k).font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
                        .frame(width: 90, alignment: .leading)
                    Text(v).font(.system(size: 12.5))
                    Spacer()
                }
                .accessibilityElement(children: .combine)
            }
        }
        Section(title: "Terminal") {
            Text("opennotch · opennotch \"question\" · opennotch -h · opennotch -m <module> · opennotch -t 10 · opennotch --awake 60 · opennotch --settings")
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondary).textSelection(.enabled)
        }
    }
}


// MARK: - AI

@MainActor
final class AIModel: ObservableObject {
    @Published var active: ProviderKind? = ProviderStore.activeKind
    @Published var model: String = ProviderStore.activeKind.flatMap(ProviderStore.model(for:)) ?? ""
    @Published var models: [String] = []
    @Published var keyKind: ProviderKind = .openai
    @Published var keyText = ""
    @Published var busy: String? = nil            // what's in progress
    @Published var message: (ok: Bool, text: String)? = nil
    @Published var local: [ProviderKind: String] = [:]   // kind → "3 models" / reason

    var connected: Bool { (NSApp.delegate as? AppDelegate)?.backend.aiConnected ?? false }

    func refreshLocal() {
        for k in [ProviderKind.ollama, .lmstudio, .apple] {
            Task {
                do {
                    let m = try await ProviderStore.test(k, key: nil)
                    local[k] = k == .apple ? "Ready" : "\(m.count) model\(m.count == 1 ? "" : "s")"
                } catch {
                    local[k] = k == .apple ? error.localizedDescription : "Not running"
                }
            }
        }
        if let a = active, !a.isLocal || a == .ollama || a == .lmstudio { loadModels(a) }
    }

    func loadModels(_ k: ProviderKind) {
        Task {
            if let m = try? await ProviderStore.test(k, key: ProviderStore.key(for: k)) { models = m }
        }
    }

    /// Test, save, activate.
    func connect(_ k: ProviderKind, key: String?) {
        busy = "Checking \(k.label)…"
        message = nil
        Task {
            do {
                let list = try await ProviderStore.test(k, key: key)
                if let key, !key.isEmpty { Keychain.set(key, for: k.rawValue) }
                let chosen = ProviderStore.model(for: k).flatMap { list.contains($0) ? $0 : nil }
                    ?? ProviderKind.pickDefault(k, from: list) ?? list.first ?? ""
                ProviderStore.setModel(chosen, for: k)
                ProviderStore.activeKind = k
                active = k
                model = chosen
                models = list
                keyText = ""
                apply()
                message = (true, "Connected to \(k.label) · \(chosen)")
            } catch {
                message = (false, error.localizedDescription)
            }
            busy = nil
        }
    }

    func signInOpenRouter() {
        busy = "Waiting for OpenRouter in your browser…"
        message = nil
        OpenRouterLogin.shared.start { [weak self] result in
            guard let self else { return }
            self.busy = nil
            switch result {
            case .success(let key): self.connect(.openrouter, key: key)
            case .failure(let e): self.message = (false, e.localizedDescription)
            }
        }
    }

    func choose(model m: String) {
        guard let k = active else { return }
        ProviderStore.setModel(m, for: k)
        model = m
        apply()
    }

    func disconnect() {
        if let k = active, k.needsKey { Keychain.delete(k.rawValue) }
        ProviderStore.activeKind = nil
        active = nil
        model = ""
        models = []
        apply()
        message = (true, "Disconnected. Your key was removed from the Keychain.")
    }

    private func apply() { (NSApp.delegate as? AppDelegate)?.backend.reloadAI() }
}

private struct AIPane: View {
    @StateObject private var m = AIModel()
    @ObservedObject private var mcp = MCPManager.shared
    private let keyKinds: [ProviderKind] = [.openai, .anthropic, .gemini, .groq, .openrouter]

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(m.active != nil ? Color.green : Color.orange).frame(width: 8, height: 8)
            if let a = m.active {
                Text("Using **\(a.label)** · \(m.model)").font(.system(size: 12.5))
                Spacer()
                Button("Disconnect", action: m.disconnect).controlSize(.small)
            } else {
                Text("No AI connected yet — everything else in the notch still works.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        if let busy = m.busy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy).font(.system(size: 12)) }
        }
        if let msg = m.message {
            Text(msg.text).font(.system(size: 11.5)).foregroundStyle(msg.ok ? Color.green : Color.orange)
                .textSelection(.enabled)
        }

        Section(title: "Sign in") {
            row(icon: "arrow.triangle.branch", title: "Sign in with OpenRouter",
                sub: "One login, hundreds of models — Claude, GPT, Gemini, and free ones. You set the spending limit.") {
                Button("Sign in…", action: m.signInOpenRouter).disabled(m.busy != nil)
            }
            row(icon: "person.crop.circle.badge.checkmark", title: "Sign in with ChatGPT",
                sub: "Use your ChatGPT plan. Coming once OpenAI issues OpenNotch its client ID.") {
                Text("Soon").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
        }

        Section(title: "Paste an API key") {
            HStack {
                Picker("", selection: $m.keyKind) {
                    ForEach(keyKinds) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 180)
                SecureField(ProviderStore.key(for: m.keyKind) != nil ? "Saved — paste to replace" : "API key", text: $m.keyText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { m.connect(m.keyKind, key: m.keyText) }
                Button("Connect") { m.connect(m.keyKind, key: m.keyText.isEmpty ? ProviderStore.key(for: m.keyKind) : m.keyText) }
                    .disabled(m.busy != nil || (m.keyText.isEmpty && ProviderStore.key(for: m.keyKind) == nil))
            }
            HStack(spacing: 4) {
                Text("Stored in your Keychain, sent only to \(m.keyKind.label).")
                if let url = m.keyKind.keyPage { Link("Get a key ↗", destination: url) }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }

        Section(title: "On this Mac — private and free") {
            ForEach([ProviderKind.ollama, .lmstudio, .apple]) { k in
                row(icon: k == .apple ? "apple.logo" : "desktopcomputer", title: k.label, sub: m.local[k] ?? "Checking…") {
                    if (m.local[k] ?? "").contains("model") || m.local[k] == "Ready" {
                        Button(m.active == k ? "In use" : "Use") { m.connect(k, key: nil) }.disabled(m.active == k)
                    } else if let url = k.keyPage {
                        Link("Get it ↗", destination: url).font(.system(size: 11.5))
                    }
                }
            }
        }

        if m.active != nil && m.active != .apple {
            Section(title: "Model") {
                HStack {
                    Picker("", selection: Binding(get: { m.model }, set: { m.choose(model: $0) })) {
                        ForEach(m.models.isEmpty ? [m.model] : m.models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    Button { if let a = m.active { m.loadModels(a) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh the model list")
                }
            }
        }

        Section(title: "Connectors (MCP)") {
            if mcp.status.isEmpty {
                Text("Add tools like GitHub, Gmail or a browser by listing MCP servers in mcp.json.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            ForEach(mcp.status, id: \.name) { s in
                HStack {
                    Text(s.name).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text(s.state).font(.system(size: 11)).foregroundStyle(s.state.hasPrefix("failed") ? Color.orange : Theme.secondary)
                }
            }
            HStack {
                Button("Edit mcp.json") {
                    MCPManager.ensureConfigFile()
                    NSWorkspace.shared.open(URL(fileURLWithPath: MCPManager.configPath))
                }
                Button("Reload") { Task { await MCPManager.shared.reload() } }
            }
            .controlSize(.small)
        }

        Text("Chats are saved only on this Mac (~/Library/Application Support/OpenNotch/sessions). Nothing is sent anywhere except the AI you choose.")
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            .onAppear { m.refreshLocal() }
    }

    private func row<Trailing: View>(icon: String, title: String, sub: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 24).foregroundStyle(Theme.glow[0])
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            trailing()
        }
        .accessibilityElement(children: .combine)
    }
}
