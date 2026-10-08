import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Look & feel

enum Theme {
    static let glow: [Color] = [
        Color(red: 0.36, green: 0.55, blue: 1.00),
        Color(red: 0.69, green: 0.40, blue: 1.00),
        Color(red: 1.00, green: 0.40, blue: 0.67),
        Color(red: 1.00, green: 0.62, blue: 0.30),
        Color(red: 0.36, green: 0.55, blue: 1.00),
    ]
    static let userBubble = LinearGradient(
        colors: [Color(red: 0.23, green: 0.42, blue: 1.0), Color(red: 0.45, green: 0.30, blue: 0.95)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let panel = Color(white: 0.035)
    static let hairline = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
}

/// Black shape hanging from the top edge: rounded bottom corners, and concave
/// "shoulders" at the top that flare out into the bezel, so an open panel looks
/// like it pours out of the notch instead of a box sliding down. The shoulders
/// grow with the radius (≈ 1 pt closed, ≈ 10 pt open), so they animate with it
/// and the closed notch keeps the hardware outline. They're drawn just outside
/// `rect`; the window leaves room for them.
struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    static func shoulder(for radius: CGFloat) -> CGFloat { min(10, max(0, (radius - 8) * 0.55)) }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let rad = min(radius, r.height / 2, r.width / 2)
        let sh = min(Self.shoulder(for: radius), r.height / 2)
        p.move(to: CGPoint(x: r.minX - sh, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX + sh, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + sh), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.maxX - rad, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - rad), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + sh))
        p.addQuadCurve(to: CGPoint(x: r.minX - sh, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Apple-Intelligence-style glow that runs round the panel edge while busy.
///
/// Performance: the rainbow is a conic gradient rendered **once** into an
/// image; the animation only rotates that image (a cheap GPU transform) under a
/// static stroke mask. The old version animated the gradient's angle under a
/// blur, which re-rasterised a full-panel conic on the CPU every frame and made
/// opening/closing the notch stutter whenever the AI was working.
struct GlowBorder: View {
    var radius: CGFloat
    /// 0…1. Fixed at 1 while a turn runs; follows the voice in hands-free.
    var intensity: CGFloat = 1
    @State private var spin = false
    @ObservedObject private var policy = AnimationPolicy.shared

    @MainActor static let wheel: NSImage = {
        let r = ImageRenderer(content: Circle()
            .fill(AngularGradient(colors: Theme.glow + [Theme.glow[0]], center: .center))
            .frame(width: 256, height: 256))
        r.scale = 1
        return r.nsImage ?? NSImage()
    }()

    var body: some View {
        let k = max(0.25, min(1, intensity))
        GeometryReader { g in
            let side = (g.size.width * g.size.width + g.size.height * g.size.height).squareRoot()
            Image(nsImage: Self.wheel)
                .resizable()
                .frame(width: side, height: side)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .frame(width: g.size.width, height: g.size.height)
                .mask {
                    ZStack {
                        NotchShape(radius: radius).stroke(lineWidth: 14 + 10 * k).opacity(0.10 + 0.12 * k)
                        NotchShape(radius: radius).stroke(lineWidth: 6 + 5 * k).opacity(0.25 + 0.3 * k)
                        NotchShape(radius: radius).stroke(lineWidth: 1.5 + 1.5 * k)
                    }
                }
        }
        .animation(.easeOut(duration: 0.12), value: k)
        .onAppear {
            guard !policy.reduceMotion else { return }
            withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) { spin = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Root

struct RootView: View {
    @ObservedObject var backend: Backend
    @ObservedObject var notch: NotchController
    @ObservedObject var dictation: Dictation
    @ObservedObject var hub: Hub
    @ObservedObject var handsFree: HandsFree
    @State private var dropTargeted = false

    private var radius: CGFloat {
        switch notch.mode {
        case .collapsed: return 10
        case .hello: return 12
        case .peek, .alert: return 18
        case .player: return 24
        case .mirror: return 22
        case .peekaboo: return 20
        case .expanded: return 26
        }
    }

    private var isTucked: Bool { notch.mode == .collapsed || notch.mode == .hello }
    private var isOpen: Bool { notch.mode == .expanded }

    private var voiceGlow: Color {
        switch handsFree.waveMode {
        case .listening: return Color(red: 0.25, green: 0.8, blue: 1.0)
        case .speaking: return Color(red: 0.85, green: 0.4, blue: 1.0)
        case .thinking: return Theme.glow[1]
        case .idle: return Theme.glow[0].opacity(0.5)
        }
    }

    var body: some View {
        let size = notch.visibleSize
        ZStack(alignment: .top) {
            ZStack {
                NotchShape(radius: radius).fill(Color.black)
                    .opacity(isTucked ? 1 : 0)
                // Always mounted, cross-faded by opacity. Swapping views here made SwiftUI fade
                // the open surface in (and out) at its *final* size, so the panel never grew out
                // of the notch or shrank back into it — only the hidden black shape did.
                NotchSurface(radius: radius, notchHeight: notch.notchSize.height)
                    .opacity(isTucked ? 0 : 1)
                NotchShape(radius: radius)
                    .stroke(dropTargeted ? Theme.glow[0] : Theme.hairline, lineWidth: dropTargeted ? 2 : 1)
                    .opacity(isTucked ? 0 : 1)
                // Removed instantly: a fading glow would linger at the old size as a ghost frame.
                if handsFree.isOn && !isTucked {
                    GlowBorder(radius: radius, intensity: handsFree.phase == .thinking ? 0.6 : handsFree.waveLevel * 1.6)
                        .transition(.identity)
                } else if backend.busy && notch.mode != .collapsed {
                    GlowBorder(radius: radius).transition(.identity)
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay {
                // A tool is waiting for an OK while the notch is closed: pulse yellow.
                if isTucked && backend.needsUser { ApprovalGlow(radius: radius) }
            }
            // Fixed radius, animated opacity only: re-blurring a changing
            // radius every frame is what made the old open stutter.
            .shadow(color: .black.opacity(isTucked ? 0 : 0.55), radius: 24, y: 10)
            // Hands-free with the notch closed: a Siri-like glow breathes
            // out from under the notch with the voice.
            // Fixed radius, opacity follows the voice (a changing radius re-blurs every frame).
            .shadow(color: voiceGlow.opacity(isTucked && handsFree.isOn ? 0.3 + 0.7 * Double(min(1, handsFree.waveLevel * 1.5)) : 0),
                    radius: 14, y: 3)
            .animation(.easeOut(duration: 0.12), value: handsFree.waveLevel)

            // Small states are tiny — rebuilt per mode with a quick cross-fade.
            ZStack(alignment: .top) {
                switch notch.mode {
                case .collapsed: CollapsedView(backend: backend, notch: notch, hub: hub, timers: hub.timers,
                                               handsFree: handsFree)
                case .hello: HelloView(notch: notch, backend: backend)
                case .peek: PeekView(backend: backend, notch: notch)
                case .player: PlayerView(backend: backend, notch: notch)
                case .mirror: MirrorView(notch: notch)
                case .peekaboo: PeekabooView(notch: notch, backend: backend)
                case .alert: AlertPeek(alert: notch.alert ?? .hydration, backend: backend, notch: notch,
                                       drank: { hub.timers.drank() })
                case .expanded: Color.clear
                }
            }
            .id(notch.mode == .expanded ? NotchMode.collapsed : notch.mode)
            .transition(.opacity.animation(.easeOut(duration: 0.14)))
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(NotchShape(radius: radius))

            // The panel is built once (pre-warmed just after launch), laid out
            // at its full size, and *revealed* by the growing notch shape —
            // like the Dynamic Island. No view construction and no text
            // reflow happens during the animation, which is what keeps it smooth.
            if notch.panelWarm {
                ExpandedView(backend: backend, notch: notch, dictation: dictation, hub: hub,
                             handsFree: handsFree, isOpen: isOpen)
                    .frame(width: notch.expandedSize.width, height: notch.expandedSize.height, alignment: .top)
                    .opacity(isOpen ? 1 : 0)
                    .animation(isOpen ? Motion.contentIn : Motion.contentOut, value: isOpen)
                    .allowsHitTesting(isOpen)
                    .environment(\.notchContentVisible, isOpen && notch.contentLive && !notch.onboarding)
                    .mask(alignment: .top) {
                        NotchShape(radius: radius).frame(width: size.width, height: size.height)
                    }
            }
        }
        .animation(Motion.open, value: backend.busy)
        .animation(Motion.open, value: backend.needsUser)
        .animation(Motion.open, value: notch.hasLiveActivity)
        .animation(Motion.open, value: notch.showsPerch)
        .animation(Motion.open, value: notch.earWidth)
        .overlay(alignment: .top) {
            // More than one thing live: the extras ride in a small pill beside the notch.
            let others = notch.mode == .collapsed && notch.hasLiveActivity ? notch.otherActivities : []
            if !others.isEmpty {
                let w = others.map(NotchController.pillItemWidth).reduce(0, +) + CGFloat(others.count - 1) * 4 + 16
                SidePill(items: others, notch: notch, backend: backend, timers: hub.timers, handsFree: handsFree)
                    .frame(width: w, height: notch.notchSize.height)
                    .offset(x: size.width / 2 + 7 + w / 2)
                    .transition(.scale(scale: 0.3, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(Motion.peek, value: notch.mode == .collapsed ? notch.otherActivities : [])
        .frame(width: notch.windowSize.width, height: notch.windowSize.height, alignment: .top)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .top) {
            // Mid-drag: choose where the file goes. Falls through to the chat
            // if dropped outside the zones.
            if notch.fileDrag && notch.mode == .expanded {
                DropZones(hub: hub, backend: backend, notch: notch)
                    .frame(width: notch.expandedSize.width - 2, height: notch.expandedSize.height - 60)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .padding(.top, 50)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: notch.fileDrag)
        .onDrop(of: [.fileURL, .url], isTargeted: $dropTargeted) { providers in
            loadURLs(providers) { urls in
                backend.attachDropped(urls)
                hub.module = .chat
                notch.expand(pinned: true, focus: true)
            }
            return true
        }
    }
}

/// Launch greeting: orb in the left ear, "Ledge" in the right.
struct HelloView: View {
    @ObservedObject var notch: NotchController
    @ObservedObject var backend: Backend
    @AppStorage("assistantName") private var assistantName = "Ledge"
    @State private var shown = false

    var body: some View {
        HStack(spacing: 0) {
            HStack { Spacer(); AssistantFace(size: 24, backend: backend); Spacer() }
                .frame(width: 85)
                .scaleEffect(shown ? 1 : 0.3)
                .opacity(shown ? 1 : 0)
            Spacer().frame(width: notch.notchSize.width)
            Text(assistantName)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(LinearGradient(colors: [Theme.glow[0], Theme.glow[1], Theme.glow[2]],
                                                startPoint: .leading, endPoint: .trailing))
                .frame(width: 85)
                .offset(x: shown ? 0 : -10)
                .opacity(shown ? 1 : 0)
        }
        .frame(height: notch.notchSize.height)
        .onAppear {
            withAnimation(Motion.open.delay(0.12)) { shown = true }
        }
    }
}

struct AppMenu: View {
    @ObservedObject var backend: Backend
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var handsFree: HandsFree
    @State private var keepRunning = !Supervisor.disabled && Supervisor.installed
    @AppStorage("avatarPalette") private var paletteID = "aurora"
    @AppStorage("assistantName") private var assistantName = "Ledge"
    @AppStorage("handsfree.autostart") private var handsFreeAtLaunch = false

    private func renameAssistant() {
        let alert = NSAlert()
        alert.messageText = "Name your assistant"
        alert.informativeText = "Shown in the notch and the greeting."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = assistantName
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { assistantName = String(name.prefix(20)); VoiceTurn.wakeName = assistantName }
        }
    }

    var body: some View {
        Button("Settings…") { SettingsWindow.shared.show() }
        if let app = MeetingNotes.shared.recordingApp {
            Button("Stop taking notes (\(app))") { MeetingNotes.shared.stop() }
        }
        if Updater.available { Button("Check for Updates…") { Updater.shared.checkNow() } }
        Menu(KeepAwake.shared.isOn ? "☕ Keeping awake" : "Keep awake") {
            Button("For 30 minutes") { KeepAwake.shared.start(minutes: 30) }
            Button("For 1 hour") { KeepAwake.shared.start(minutes: 60) }
            Button("For 2 hours") { KeepAwake.shared.start(minutes: 120) }
            Button("Until I turn it off") { KeepAwake.shared.start(minutes: nil) }
            if KeepAwake.shared.isOn { Divider(); Button("Stop — sleep as usual") { KeepAwake.shared.stop() } }
        }
        Button("Camera mirror") { (NSApp.delegate as? AppDelegate)?.notch.openMirror() }
        Button("New chat") { backend.newChat() }
        Button(handsFree.isOn ? "End hands-free  ⌥⇧Space" : "Hands-free mode  ⌥⇧Space") { handsFree.toggle() }
        Button((DesktopCompanion.enabled ? "✓ " : "   ") + "\(Prefs.name) on the desktop") {
            (NSApp.delegate as? AppDelegate)?.desktop.setEnabled(!DesktopCompanion.enabled)
        }
        Menu("Desktop avatar") {
            ForEach([("ledge", "Classic (hoodie)"), ("bee", "Bee"), ("cat", "Cat (hoodie + glasses)")], id: \.0) { id, label in
                Button((DesktopCompanion.avatar == id ? "✓ " : "   ") + label) {
                    (NSApp.delegate as? AppDelegate)?.desktop.setAvatar(id)
                }
            }
        }
        Button((handsFreeAtLaunch ? "✓ " : "") + "Start hands-free at launch") { handsFreeAtLaunch.toggle() }
        Menu("Modules") {
            ForEach(Module.allCases.filter { $0 != .chat }) { m in
                Button((hub.disabled.contains(m.rawValue) ? "   " : "✓ ") + m.title) { hub.toggle(m) }
            }
        }
        Menu("Proactive") {
            Button((hub.proactive.briefOn ? "✓ " : "   ") + "Morning brief (\(hub.proactive.briefHour):00)") { hub.proactive.briefOn.toggle() }
            Menu("Brief time") {
                ForEach([6, 7, 8, 9, 10], id: \.self) { h in
                    Button((hub.proactive.briefHour == h ? "✓ " : "   ") + "\(h):00") { hub.proactive.briefHour = h }
                }
            }
            Button((hub.proactive.meetingsOn ? "✓ " : "   ") + "Meeting heads-up (10 min before)") { hub.proactive.meetingsOn.toggle() }
            Divider()
            Button("Brief me now") { hub.proactive.briefNow() }
            Button((hub.proactive.recapOn ? "✓ " : "   ") + "End-of-day wrap-up (\(hub.proactive.recapHour):00)") { hub.proactive.recapOn.toggle() }
            Button("Wrap up my day now") { hub.proactive.recapNow() }
            Button("Share my week with \(Prefs.name)") {
                if let path = ValueLedger.shared.share() {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    backend.notice("Your week card is copied — paste it into a message or post.")
                }
            }
            Button(hub.proactive.paused ? "Resume suggestions" : "Pause all suggestions") { hub.proactive.paused.toggle() }
        }
        Button("AI & models…") { SettingsWindow.shared.show(.ai) }
        Menu("Avatar") {
            ForEach(AvatarPalette.all) { pal in
                Button((paletteID == pal.id ? "✓ " : "") + pal.name) { paletteID = pal.id }
            }
            Divider()
            Button("Rename assistant…") { renameAssistant() }
        }
        Divider()
        Button((keepRunning ? "✓ " : "") + "Keep OpenNotch running (restart on crash, start at login)") {
            if keepRunning {
                Supervisor.disabled = true
                Supervisor.uninstall()
            } else {
                Supervisor.disabled = false
                if !Supervisor.canSupervise {
                    backend.notice("Install to ~/Applications first (scripts/build.sh --install).")
                } else if Supervisor.writePlist() {
                    (NSApp.delegate as? AppDelegate)?.prepareForExit()
                    Supervisor.handOverAndExit()     // comes straight back, now supervised
                }
            }
            keepRunning = !Supervisor.disabled && Supervisor.installed
        }
        Button("Open app log") { NSWorkspace.shared.open(URL(fileURLWithPath: AppLog.path)) }
        Button("Show my data folder") { NSWorkspace.shared.open(URL(fileURLWithPath: AppPaths.root)) }
        Divider()
        Button("Quit OpenNotch") { NSApp.terminate(nil) }
    }
}

// MARK: - Collapsed

struct CollapsedView: View {
    @ObservedObject private var policy = AnimationPolicy.shared
    @ObservedObject var backend: Backend
    @ObservedObject var notch: NotchController
    @ObservedObject var hub: Hub
    @ObservedObject var timers: TimerStore
    @ObservedObject var handsFree: HandsFree

    var body: some View {
        HStack(spacing: 0) {
            if notch.hasLiveActivity {
                let ear = notch.earWidth
                switch notch.earActivity {
                case .hud:
                    if let h = notch.hud {
                        HStack { Spacer(); HUDLeftEar(hud: h) }.padding(.trailing, 14).frame(width: ear)
                        Spacer().frame(width: notch.notchSize.width)
                        HUDRightEar(hud: h).frame(width: ear)
                    }
                case .timer:
                    TimerRingEar(timers: timers).frame(width: ear)
                    Spacer().frame(width: notch.notchSize.width)
                    TimerClockEar(timers: timers).frame(width: ear)
                case .privacy:
                    HStack { Spacer(); PrivacyLeftEar(state: notch.privacy) }.padding(.trailing, 14).frame(width: ear)
                    Spacer().frame(width: notch.notchSize.width)
                    PrivacyRightEar(state: notch.privacy).frame(width: ear)
                case .awake:
                    AwakeEars(side: false).frame(width: ear)
                    Spacer().frame(width: notch.notchSize.width)
                    AwakeEars(side: true).frame(width: ear)
                case .music:
                    // One wave across the whole width, from the art to the title — the
                    // stretch behind the camera is simply hidden, so it reads as one
                    // ribbon passing behind the notch.
                    let art: CGFloat = 22, artPad: CGFloat = 12, titleW = ear - 30
                    TimelineView(.animation(minimumInterval: 1.0 / policy.fps)) { ctx in
                        ZStack {
                            MusicWave(backend: backend, date: ctx.date)
                                .padding(.leading, artPad + art + 6)
                                .padding(.trailing, titleW + 12)
                            HStack(spacing: 0) {
                                MusicArtEar(backend: backend, date: ctx.date, size: art)
                                    .padding(.leading, artPad)
                                Spacer()
                                MusicInfoEar(backend: backend, date: ctx.date)
                                    .frame(width: titleW)
                                    .padding(.trailing, 12)
                            }
                        }
                        .frame(width: notch.notchSize.width + 2 * ear, height: notch.notchSize.height)
                    }
                default:
                    left.frame(width: ear)
                    Spacer().frame(width: notch.notchSize.width)
                    right
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .frame(width: ear)
                        .contentTransition(.numericText())
                }
            }
        }
        .overlay(alignment: .trailing) {
            // Mic / camera in use while something else owns the ears: the system-style dots.
            if notch.privacy.active && notch.earActivity != .privacy && notch.hasLiveActivity {
                PrivacyDots(state: notch.privacy).padding(.trailing, 7)
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenStatus)
        .animation(.easeOut(duration: 0.25), value: notch.earActivity)
        .frame(height: notch.notchSize.height)
        .contextMenu { AppMenu(backend: backend) }
    }

    /// What VoiceOver reads for the closed notch.
    private var spokenStatus: String {
        switch notch.earActivity {
        case .hud:
            switch notch.hud {
            case .volume(let l, let m)?: return m ? "Muted" : "Volume \(Int((l * 100).rounded())) percent"
            case .device(let n, _, let b)?: return "Connected \(n)" + (b.map { ", battery \($0)" } ?? "")
            case .power(let c, let p, let pct)?: return (p ? (c ? "Charging" : "Plugged in") : "On battery") + ", \(pct) percent"
            case .health(_, let t, let d, _)?: return "\(t). \(d)"
            case .awake(let on, let label)?: return on ? "Keeping your Mac awake, \(label)" : "Keep awake off"
            case nil: return ""
            }
        case .timer:
            return "\(timers.kind?.rawValue ?? "Timer")\(timers.onBreak ? " break" : ""), \(TimerStore.clock(timers.remaining))\(timers.kind == .stopwatch ? " elapsed" : " left")\(timers.paused ? ", paused" : "")"
        case .music:
            let np = backend.nowPlaying
            return "Now playing \(np.track)" + (np.artist.isEmpty ? "" : " by \(np.artist)")
        case .agent:
            return !backend.approvals.isEmpty ? "\(Prefs.name) needs your approval" : backend.question != nil ? "\(Prefs.name) has a question" : backend.busy ? "\(Prefs.name) is working"
                : handsFree.isOn ? "Hands-free on" : "\(Prefs.name)'s answer is ready"
        case .privacy:
            let p = notch.privacy
            return (p.micApps.isEmpty ? "" : "\(p.micApps.joined(separator: ", ")) is using the microphone. ")
                + (p.camera ? "Camera is on." : "")
        case .awake:
            return "Keeping your Mac awake, " + HealthLogic.awakeLabel(until: KeepAwake.shared.until)
                .replacingOccurrences(of: "∞", with: "until you stop it")
        case .none:
            return Prefs.name
        }
    }

    /// Left ear while Ledge is involved: the face.
    @ViewBuilder private var left: some View {
        AssistantFace(size: 22, backend: backend, tracksCursor: false)
    }

    /// Right ear while Ledge is involved: one word of status, highest priority first.
    @ViewBuilder private var right: some View {
        if backend.approvals.isEmpty, backend.question != nil {
            VStack(alignment: .leading, spacing: -1) {
                Text("QUESTION").font(.system(size: 8.5, weight: .heavy, design: .rounded)).tracking(0.8)
                    .foregroundStyle(.cyan)
                Text("Pick one").font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
        } else if let a = backend.approvals.first {
            VStack(alignment: .leading, spacing: -1) {
                Text("NEEDS YOUR OK").font(.system(size: 8.5, weight: .heavy, design: .rounded)).tracking(0.8)
                    .foregroundStyle(.yellow)
                Text(VoiceTurn.approvalShort(a.tool)).font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
        } else if backend.busy {
            if let p = backend.planProgress {
                Text("Step \(min(p.total, p.done + 1))/\(p.total)").monospacedDigit().foregroundStyle(.white.opacity(0.85))
            } else {
                Text(backend.lastTool.isEmpty ? (backend.thinkingNow ? "Thinking…" : "Working") : backend.lastTool)
                    .foregroundStyle(.white.opacity(0.75))
            }
        } else if backend.unseenAnswer && !handsFree.isOn {
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
                Text("Ready").foregroundStyle(.white.opacity(0.85))
            }
        } else if handsFree.isOn {
            if handsFree.phase == .standby || handsFree.phase == .starting {
                Text(handsFreeLabel).foregroundStyle(Theme.secondary)
            } else {
                SiriWave(mode: handsFree.waveMode, level: handsFree.waveLevel, ribbons: 3)
                    .frame(width: 56, height: 22)
            }
        }
    }

    private var handsFreeLabel: String {
        switch handsFree.phase {
        case .listening: return "Listening"
        case .hearing: return "Hearing…"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .standby: return "“\(Prefs.name)”"
        case .starting: return "Starting"
        case .off: return ""
        }
    }
}

// MARK: - Peek

struct PeekView: View {
    @ObservedObject var backend: Backend
    @ObservedObject var notch: NotchController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: notch.notchSize.height + 6)
            HStack(alignment: .top, spacing: 10) {
                AssistantFace(size: 26, backend: backend, tracksCursor: false)
                Text(inlineMD(backend.lastAnswer.replacingOccurrences(of: "\n", with: " ")))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
        .contentShape(Rectangle())
        .onTapGesture { notch.expand(pinned: true, focus: true) }
    }
}

// MARK: - Expanded

struct QuickAction: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let prompt: String
    var screenshot = false
    var clipboard = false
}

let quickActions: [QuickAction] = [
    QuickAction(icon: "sun.max", title: "Plan my day",
                prompt: "Plan my day: look at today's calendar events, my open reminders and the weather where I am, then give me a short, focused plan."),
    QuickAction(icon: "tray.full", title: "Catch up on email",
                prompt: "Catch up on my email from the last day in Mail: group it into needs a reply, FYI and noise. Offer to draft replies."),
    QuickAction(icon: "safari", title: "Summarise this page",
                prompt: "Summarise the page I'm looking at in my browser in a few bullet points, then tell me the one thing worth remembering."),
    QuickAction(icon: "camera.viewfinder", title: "Explain my screen",
                prompt: "What's on my screen? Explain it briefly and suggest the next step.", screenshot: true),
    QuickAction(icon: "doc.on.clipboard", title: "Work on clipboard",
                prompt: "Explain what's in my clipboard, then improve or fix it.", clipboard: true),
    QuickAction(icon: "arrowshape.turn.up.left", title: "Draft a reply",
                prompt: "Draft a friendly, concise reply to the message in my clipboard. Match its language and tone.", clipboard: true),
]

struct ExpandedView: View {
    @ObservedObject var backend: Backend
    @ObservedObject var notch: NotchController
    @ObservedObject var dictation: Dictation
    @ObservedObject var hub: Hub
    @ObservedObject var handsFree: HandsFree
    /// Mounted permanently; this says whether it's actually on screen.
    let isOpen: Bool
    @State private var draft = ""
    @State private var recallIndex: Int? = nil
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Header(backend: backend, notch: notch, handsFree: handsFree)
                .modifier(Cascade(shown: isOpen, step: 0))
            ModuleBar(hub: hub)
                .modifier(Cascade(shown: isOpen, step: 1))
            Group {
                if hub.module != .chat {
                    ModuleHost(hub: hub, backend: backend, notch: notch)
                } else if handsFree.isOn {
                    HandsFreeStage(handsFree: handsFree, backend: backend)
                } else {
                    Transcript(backend: backend, run: run)
                }
            }
            .modifier(Cascade(shown: isOpen, step: 2))
            // Writing tools for whatever text was selected when the notch opened.
            // (The card observes the context itself and shows only with a selection —
            // a nested ObservableObject wouldn't re-render this view.)
            if hub.module == .chat && !handsFree.isOn && !backend.busy {
                WritingToolsCard(model: hub.context)
            }
            if !backend.approvals.isEmpty {
                VStack(spacing: 6) {
                    ForEach(backend.approvals) { ApprovalCard(approval: $0, backend: backend) }
                }
                .padding(.horizontal, 14).padding(.top, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let q = backend.question {
                QuestionCard(question: q, backend: backend)
                    .padding(.horizontal, 14).padding(.top, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if hub.module == .chat && !handsFree.isOn {
                composer
                    .modifier(Cascade(shown: isOpen, step: 3))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: backend.approvals)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: backend.question)
        .onAppear { if isOpen && notch.focusInput { focusSoon() } }
        .onChange(of: isOpen) { open in
            if open { if notch.focusInput { focusSoon() } } else { inputFocused = false }
        }
        .overlay(alignment: .top) {
            if notch.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.45).onTapGesture { closePalette() }
                    CommandPalette(items: paletteItems, onAsk: { q in
                        hub.module = .chat
                        backend.send(q)
                    }, onAttachFile: { path in
                        backend.attach(Attachment(kind: .file, value: path))
                        hub.module = .chat
                        focusSoon()
                    }, close: closePalette)
                    .padding(.top, 56)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .overlay(alignment: .top) {
            if notch.showHistory {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.45).onTapGesture { withAnimation(.easeOut(duration: 0.15)) { notch.showHistory = false } }
                    ChatHistoryView(backend: backend) {
                        withAnimation(.easeOut(duration: 0.15)) { notch.showHistory = false }
                        hub.module = .chat
                    }
                    .padding(.top, 56)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .overlay {
            if notch.onboarding {
                OnboardingView(notch: notch, backend: backend, hub: hub)
                    .padding(.top, max(notch.notchSize.height, 32))
                    .transition(.opacity)
            }
        }
        .onChange(of: isOpen) { open in if !open { notch.showPalette = false; notch.showHistory = false } }
        .onChange(of: notch.focusInput) { v in if v { focusSoon() } }
        .onChange(of: inputFocused) { v in if v { notch.pinned = true } }
        .onChange(of: dictation.transcript) { t in if dictation.listening { draft = t } }
        .onExitCommand {
            if handsFree.phase == .speaking { handsFree.interrupt() } else { notch.collapse() }
        }
        .background {
            // Invisible buttons that carry the app's keyboard shortcuts.
            Group {
                Button("") { backend.newChat() }.keyboardShortcut("n", modifiers: .command)
                Button("") { backend.stop() }.keyboardShortcut(".", modifiers: .command)
                Button("") { notch.pinned.toggle() }.keyboardShortcut("p", modifiers: .command)
                Button("") { SettingsWindow.shared.show() }.keyboardShortcut(",", modifiers: .command)
                Button("") { withAnimation(.spring(duration: 0.25, bounce: 0.15)) { notch.showPalette.toggle() } }
                    .keyboardShortcut("k", modifiers: .command)
                Button("") { withAnimation(.spring(duration: 0.25, bounce: 0.15)) { notch.showHistory.toggle() } }
                    .keyboardShortcut("y", modifiers: .command)
            }
            .opacity(0).allowsHitTesting(false)
            .disabled(!isOpen)                      // no ⌘N / ⌘. while the notch is closed
        }
    }

    private func closePalette() {
        withAnimation(.easeOut(duration: 0.15)) { notch.showPalette = false }
    }

    /// Everything ⌘K can do, in the order shown before you type.
    private var paletteItems: [PaletteItem] {
        let app = NSApp.delegate as? AppDelegate
        let t = hub.timers
        var items: [PaletteItem] = [
            PaletteItem(id: "new", group: .action, icon: "square.and.pencil", title: "New chat", subtitle: "⌘N") {
                backend.newChat(); hub.module = .chat },
            PaletteItem(id: "hf", group: .action, icon: "waveform.circle", title: handsFree.isOn ? "End hands-free" : "Hands-free mode",
                        subtitle: "⌥⇧Space", keywords: "voice talk speak") { handsFree.toggle() },
            PaletteItem(id: "history", group: .action, icon: "clock.arrow.circlepath", title: "Chat history", subtitle: "⌘Y",
                        keywords: "previous conversations past chats") {
                withAnimation(.spring(duration: 0.25)) { notch.showHistory = true } },
            PaletteItem(id: "settings", group: .action, icon: "gearshape", title: "Settings", subtitle: "⌘,", keywords: "preferences") {
                SettingsWindow.shared.show() },
            PaletteItem(id: "perms", group: .action, icon: "lock.shield", title: "Permissions checklist", keywords: "privacy allow") {
                SettingsWindow.shared.show(.permissions) },
            PaletteItem(id: "clip", group: .action, icon: "doc.on.clipboard", title: "Paste clipboard as context") {
                hub.module = .chat; backend.attachClipboard(); focusSoon() },
            PaletteItem(id: "focus", group: .action, icon: "brain.head.profile", title: "Start a focus session",
                        subtitle: "\(t.focusMinutes) min", keywords: "pomodoro timer") { t.startPomodoro() },
            PaletteItem(id: "t5", group: .action, icon: "timer", title: "5-minute timer", keywords: "countdown") {
                t.startCountdown(seconds: 300) },
            PaletteItem(id: "sw", group: .action, icon: "stopwatch", title: "Stopwatch") { t.startStopwatch() },
            PaletteItem(id: "play", group: .action, icon: backend.nowPlaying.playing ? "pause.fill" : "play.fill",
                        title: backend.nowPlaying.playing ? "Pause music" : "Play music", keywords: "spotify song") {
                backend.media(backend.nowPlaying.playing ? "pause" : "play") },
            PaletteItem(id: "next", group: .action, icon: "forward.fill", title: "Next song", keywords: "skip track music") {
                backend.media("next") },
            PaletteItem(id: "awake", group: .action, icon: "cup.and.saucer",
                        title: KeepAwake.shared.isOn ? "Stop keeping awake" : "Keep awake — until I turn it off",
                        keywords: "caffeinate sleep display amphetamine") { KeepAwake.shared.toggle() },
            PaletteItem(id: "awake1h", group: .action, icon: "cup.and.saucer", title: "Keep awake for 1 hour",
                        keywords: "caffeinate sleep") { KeepAwake.shared.start(minutes: 60) },
            PaletteItem(id: "mirror", group: .action, icon: "web.camera", title: "Camera mirror",
                        subtitle: "Check yourself before a call", keywords: "camera selfie video call facetime zoom") {
                notch.collapse()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { notch.openMirror() } },
            PaletteItem(id: "desk", group: .action, icon: "figure.wave",
                        title: DesktopCompanion.enabled ? "Hide \(Prefs.name) from the desktop" : "Show \(Prefs.name) on the desktop", keywords: "avatar companion") {
                app?.desktop.setEnabled(!DesktopCompanion.enabled) },
        ]
        if t.kind != nil {
            items.insert(PaletteItem(id: "tstop", group: .action, icon: "xmark.circle", title: "Stop the timer") { t.reset() }, at: 0)
        }
        if backend.busy {
            items.insert(PaletteItem(id: "stop", group: .action, icon: "stop.circle", title: "Stop the running task", subtitle: "⌘.") {
                backend.stop() }, at: 0)
        }
        for (id, name) in DesktopCompanion.avatarNames where id != DesktopCompanion.avatar {
            items.append(PaletteItem(id: "av-" + id, group: .action, icon: "person.crop.circle", title: "Desktop avatar: \(name)",
                                     keywords: "switch character") { app?.desktop.setAvatar(id) })
        }
        items += Module.allCases.filter { !hub.disabled.contains($0.rawValue) }.map { m in
            PaletteItem(id: "m-" + m.rawValue, group: .module, icon: m.icon, title: m.title, keywords: "open module") { hub.module = m }
        }
        items += quickActions.map { a in
            PaletteItem(id: "q-" + a.title, group: .quick, icon: a.icon, title: a.title) { hub.module = .chat; run(a) }
        }
        var seen = Set<String>()
        for p in backend.sentHistory.reversed() where seen.insert(p).inserted && seen.count <= 6 {
            items.append(PaletteItem(id: "r-" + p, group: .recent, icon: "clock.arrow.circlepath",
                                     title: String(p.prefix(80))) { hub.module = .chat; backend.send(p) })
        }
        return items
    }

    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { inputFocused = true }
    }

    /// Runs a quick action: attaches what it needs, then sends.
    private func run(_ a: QuickAction) {
        Task { @MainActor in
            if a.screenshot {
                guard let path = await ScreenGrab.capture(hiding: notch.panel) else {
                    backend.notice("Screen capture failed — allow OpenNotch in System Settings › Privacy › Screen Recording.")
                    return
                }
                backend.attach(Attachment(kind: .screenshot, value: path))
            }
            if a.clipboard { backend.attachClipboard() }
            backend.send(a.prompt)
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            ContextSuggestions(model: hub.context, backend: backend)
            if !backend.attachments.isEmpty && draft.isEmpty && !backend.busy {
                AttachmentSuggestions(backend: backend)
            }
            if !backend.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(backend.attachments) { a in
                            HStack(spacing: 5) {
                                Image(systemName: a.icon).font(.system(size: 10))
                                Text(a.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Button {
                                    backend.attachments.removeAll { $0.id == a.id }
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.1)))
                            .overlay(Capsule().stroke(Theme.hairline))
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .transition(.opacity)
            }

            HStack(alignment: .bottom, spacing: 8) {
                attachMenu
                TextField(dictation.listening ? "Listening…" :
                            backend.busy ? "Add to the running task…" : "Ask \(Prefs.name) anything…",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(submit)
                    .onKeyPress(.upArrow) { recall(-1) }
                    .onKeyPress(.downArrow) { recall(1) }
                    .padding(.vertical, 3)
                talkButton
                micButton
                sendButton
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(inputFocused ? Color.white.opacity(0.22) : Theme.hairline, lineWidth: 1))
            // Little Puff walking on the bar's top edge, in the empty space at the right
            // (the suggestion chips sit on the left). Cached frames on a CALayer — cheap.
            .overlay(alignment: .topTrailing) {
                ComposerWalker(backend: backend, active: isOpen && hub.module == .chat && !handsFree.isOn)
                    .frame(width: 220, height: 30)
                    .padding(.trailing, 16)
                    .offset(y: -30)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 6)
    }

    private var attachMenu: some View {
        Menu {
            Button { pickFiles() } label: { Label("Attach files…", systemImage: "paperclip") }
            Button {
                Task { @MainActor in
                    if let p = await ScreenGrab.capture(hiding: notch.panel) {
                        backend.attach(Attachment(kind: .screenshot, value: p))
                    } else {
                        backend.notice("Screen capture failed — allow OpenNotch in System Settings › Privacy › Screen Recording.")
                    }
                }
            } label: { Label("Screenshot my screen", systemImage: "camera.viewfinder") }
            Button { backend.attachClipboard() } label: { Label("Paste clipboard as context", systemImage: "doc.on.clipboard") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.08)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attach files, a screenshot or your clipboard")
    }

    /// Hands-free from the input bar: the "stop typing, just talk" button.
    private var talkButton: some View {
        Button { handsFree.start() } label: {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Theme.glow[0], Theme.glow[2]],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(HoverLift())
        .help("Hands-free — talk instead of typing (⌥⇧Space)")
    }

    private var micButton: some View {
        Button { dictation.toggle() } label: {
            ZStack {
                if dictation.listening {
                    Circle().fill(Color.red.opacity(0.25))
                        .frame(width: 24 + dictation.level * 14, height: 24 + dictation.level * 14)
                        .animation(.easeOut(duration: 0.08), value: dictation.level)
                }
                Image(systemName: dictation.listening ? "waveform" : "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(dictation.listening ? .red : Theme.secondary)
                    .symbolEffect(.variableColor.iterative, isActive: dictation.listening)
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(dictation.listening ? "Stop and send" : "Dictate")
    }

    @ViewBuilder
    private var sendButton: some View {
        if backend.busy && draft.isEmpty {
            Button { backend.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white))
            }
            .buttonStyle(.plain)
            .help("Stop (⌘.)")
        } else {
            let ready = !draft.isEmpty || !backend.attachments.isEmpty
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ready ? .white : .white.opacity(0.35))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(ready ? AnyShapeStyle(Theme.userBubble)
                                                    : AnyShapeStyle(Color.white.opacity(0.08))))
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .help("Send (↩)")
        }
    }

    private func recall(_ step: Int) -> KeyPress.Result {
        let hist = backend.sentHistory
        guard !hist.isEmpty, draft.isEmpty || recallIndex != nil else { return .ignored }
        let next = (recallIndex ?? hist.count) + step
        if next >= hist.count { recallIndex = nil; draft = ""; return .handled }
        guard next >= 0 else { return .handled }
        recallIndex = next
        draft = hist[next]
        return .handled
    }

    private func submit() {
        if dictation.listening { dictation.stop(); return }
        backend.send(draft)
        draft = ""
        recallIndex = nil
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        notch.pinned = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls { backend.attach(Attachment(kind: .file, value: url.path)) }
        }
        notch.expand(pinned: true, focus: true)
    }
}

/// Header, transcript, composer land one after another — a ~40ms cascade
/// behind the shape, which is what makes the open read as one gesture.
struct Cascade: ViewModifier {
    let shown: Bool
    let step: Int
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -8 - CGFloat(step) * 2)
            .animation(shown ? Motion.contentIn.delay(0.05 + Double(step) * 0.04) : Motion.contentOut, value: shown)
    }
}

struct Header: View {
    @ObservedObject var backend: Backend
    @ObservedObject var notch: NotchController
    @ObservedObject var handsFree: HandsFree
    @AppStorage("assistantName") private var assistantName = "Ledge"
    @State private var menuHover = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                AssistantFace(size: 26, backend: backend)
                Text(assistantName).font(Typo.brand(14))
                    .fixedSize()
                    .layoutPriority(2)
                modelMenu

            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer().frame(width: notch.notchSize.width)

            HStack(spacing: 6) {
                HandsFreeSwitch(handsFree: handsFree).padding(.trailing, 6)
                iconButton("clock.arrow.circlepath", "Chat history (⌘Y)") {
                    withAnimation(.spring(duration: 0.25, bounce: 0.15)) { notch.showHistory.toggle() }
                }
                iconButton("square.and.pencil", "New chat (⌘N)") { backend.newChat() }
                iconButton(notch.pinned ? "pin.fill" : "pin", notch.pinned ? "Unpin (⌘P)" : "Keep open (⌘P)") {
                    notch.pinned.toggle()
                }
                // The label needs its own frame + content shape like the other header
                // buttons: without them only the three dots' pixels took the click.
                Menu { AppMenu(backend: backend) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(menuHover ? .white : Theme.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.white.opacity(menuHover ? 0.10 : 0)))
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .onHover { menuHover = $0 }
                .animation(.easeOut(duration: 0.15), value: menuHover)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(height: max(notch.notchSize.height, 32))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 14) }
    }

    private var modelMenu: some View {
        Menu {
            Button(backend.aiConnected ? "Switch AI or model…" : "Connect an AI…") { SettingsWindow.shared.show(.ai) }
        } label: {
            HStack(spacing: 3) {
                Text(backend.model.isEmpty ? "Connect an AI" : shortModel(backend.model))
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.08)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch model")
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        HoverIconButton(icon: icon, help: help, action: action)
    }
}

// MARK: - Transcript

struct Transcript: View {
    @ObservedObject var backend: Backend
    let run: (QuickAction) -> Void

    // A plain VStack, not Lazy: LazyVStack + scrollTo("bottom") + rows that change
    // height (streaming text, the working row) can loop in layout forever and hang
    // the app. Long chats render only their tail.
    @State private var shown = 150
    /// Keeps the empty state a moment after the first message so Puff can hand off (spring out).
    @State private var handoff = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if backend.items.isEmpty || handoff {
                        EmptyState(backend: backend, run: run, leaving: handoff)
                            .transition(.opacity)
                    }
                    if backend.items.count > shown {
                        Button("Show earlier messages") { shown += 150 }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondary).frame(maxWidth: .infinity)
                    }
                    ForEach(StepGroup.segments(Array(backend.items.suffix(shown)), live: backend.busy)) { seg in
                        if seg.items.count == 1 { ItemRow(item: seg.items[0]) } else { StepsRow(group: seg) }
                    }
                    if backend.busy, !(backend.items.last?.streaming ?? false) {
                        WorkingRow(backend: backend, started: backend.turnStarted, tool: backend.lastTool)
                    }
                    if !backend.busy, !backend.followUps.isEmpty, backend.items.last?.kind == .assistant {
                        FollowUpChips(items: backend.followUps) { backend.send($0) }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)
            .onChange(of: backend.items) { _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: backend.items.isEmpty) { was, now in
                guard was, !now, (backend.items.first?.kind == .user) else { return }
                handoff = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
                    withAnimation(.easeOut(duration: 0.2)) { handoff = false }
                }
            }
        }
    }
}

/// A run of two or more tool/thinking rows between messages. Finished runs fold into
/// one "5 steps" row (tap to see them); the run in progress stays open so you can watch.
struct StepGroup: Identifiable {
    let items: [Item]
    let live: Bool
    var id: String { items[0].id }

    static func isStep(_ i: Item) -> Bool {
        switch i.kind {
        case .tool, .thinking: return true
        default: return false
        }
    }

    static func segments(_ items: [Item], live busy: Bool) -> [StepGroup] {
        var out: [StepGroup] = []
        var run: [Item] = []
        func flush(trailing: Bool) {
            guard !run.isEmpty else { return }
            out.append(StepGroup(items: run, live: trailing && busy))
            run = []
        }
        for i in items {
            if isStep(i) { run.append(i) } else { flush(trailing: false); out.append(StepGroup(items: [i], live: false)) }
        }
        flush(trailing: true)
        return out
    }

    var toolVerbs: [String] {
        var seen = Set<String>(), out: [String] = []
        for i in items { if case let .tool(_, _, verb, _, _) = i.kind, !verb.isEmpty, seen.insert(verb).inserted { out.append(verb) } }
        return out
    }
    var failed: Int {
        items.filter { if case let .tool(state, _, _, _, _) = $0.kind { return state == "error" } else { return false } }.count
    }
    var steps: Int {
        items.filter { if case .tool = $0.kind { return true } else { return false } }.count
    }
}

struct StepsRow: View {
    let group: StepGroup
    @State private var open = false

    var body: some View {
        if group.live {
            VStack(alignment: .leading, spacing: 10) { ForEach(group.items) { ItemRow(item: $0) } }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(.spring(duration: 0.25)) { open.toggle() } } label: { summary }
                    .buttonStyle(.plain)
                    .accessibilityHint(open ? "Hide the steps" : "Show the steps")
                if open {
                    VStack(alignment: .leading, spacing: 8) { ForEach(group.items) { ItemRow(item: $0) } }
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.glow[0])
                .frame(width: 16)
            Text(group.steps == 0 ? "Thought it through" : "\(group.steps) step\(group.steps == 1 ? "" : "s")")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            if group.failed > 0 {
                Text("\(group.failed) failed").font(.system(size: 11, weight: .medium)).foregroundStyle(.red.opacity(0.85))
            }
            Text(group.toolVerbs.joined(separator: " · "))
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.tertiary).rotationEffect(.degrees(open ? 90 : 0))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.04)))
        .contentShape(Rectangle())
    }
}

/// "What next?" — the model's suggested follow-ups, one tap to send.
struct FollowUpChips: View {
    let items: [String]
    let send: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) { chips }
        }
        .transition(.opacity)
    }

    @ViewBuilder private var chips: some View {
        ForEach(items, id: \.self) { t in
            Button { send(t) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .semibold))
                    Text(t).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.06)))
                .overlay(Capsule().stroke(Theme.hairline))
            }
            .buttonStyle(.plain)
        }
    }
}

struct EmptyState: View {
    @ObservedObject var backend: Backend
    @EnvironmentObject var handsFree: HandsFree
    @EnvironmentObject var hub: Hub
    @AppStorage("assistantName") private var assistantName = "Ledge"
    let run: (QuickAction) -> Void
    /// The first message is on its way: Puff leaves, the rest fades.
    var leaving = false
    // Only Puff animates here; the text, button and grid are simply there.
    private var shown: Bool { !leaving }

    var body: some View {
        VStack(spacing: 16) {
            ForYouSection(engine: hub.proactive).opacity(leaving ? 0 : 1)
            HeroAvatar(proactive: hub.proactive, backend: backend, leaving: leaving)
            VStack(spacing: 4) {
                Text("Hi, I'm \(assistantName). What can I do for you?")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("⌥Space from anywhere · drop files on the notch · Esc to close")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
            .opacity(leaving ? 0 : 1)
            Button { handsFree.start() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 13, weight: .bold))
                    Text("Talk to \(assistantName)").font(.system(size: 13, weight: .semibold))
                    Text("⌥⇧Space").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(0.15)))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(Capsule().fill(Theme.userBubble))
                .shadow(color: Theme.glow[1].opacity(0.45), radius: 12, y: 3)
            }
            .buttonStyle(HoverLift())
            .opacity(shown ? 1 : 0)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(quickActions) { a in
                    Button { run(a) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: a.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(LinearGradient(colors: [Theme.glow[0], Theme.glow[1]],
                                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            Text(a.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(HoverLift())
                    .opacity(shown ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.22), value: leaving)
    }
}

struct HoverLift: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(hover ? 0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: hover)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .onHover { hover = $0 }
    }
}

struct WorkingRow: View {
    @ObservedObject var backend: Backend
    let started: Date?
    let tool: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            HStack(spacing: 8) {
                AssistantFace(size: 22, backend: backend, tracksCursor: false)
                Text(tool.isEmpty ? "Thinking" : tool)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                if let started {
                    Text("\(Int(ctx.date.timeIntervalSince(started)))s")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
}

/// "nemotron-3-super-120b-a12b" → "nemotron-3-super" — the chip has ~110pt.
func shortModel(_ m: String) -> String {
    let parts = m.split(separator: "-")
    var out = ""
    for p in parts {
        let next = out.isEmpty ? String(p) : out + "-" + p
        if next.count > 16 { break }
        out = next
    }
    return out.isEmpty ? String(m.prefix(16)) : out
}

/// SF Symbol for a tool's display verb (the loop reports verbs, not names).
func toolSymbol(_ verb: String) -> String {
    let v = verb.lowercased()
    let table: [(String, String)] = [
        ("read", "doc.text"), ("writ", "square.and.pencil"), ("edit", "pencil"), ("replac", "pencil"),
        ("delet", "trash"), ("mov", "arrow.right.doc.on.clipboard"), ("cop", "doc.on.doc"),
        ("search", "magnifyingglass"), ("find", "magnifyingglass"), ("grep", "magnifyingglass"),
        ("explor", "folder"), ("list", "list.bullet"), ("tree", "folder"),
        ("run", "terminal"), ("exec", "terminal"), ("test", "checkmark.seal"), ("command", "terminal"),
        ("git", "arrow.triangle.branch"), ("mail", "envelope"), ("gmail", "envelope"), ("draft", "envelope"),
        ("brows", "globe"), ("web", "globe"), ("http", "network"), ("fetch", "network"),
        ("job", "briefcase"), ("appl", "briefcase"), ("schedul", "clock"), ("remember", "brain"),
        ("memor", "brain"), ("recall", "brain"), ("telegram", "paperplane"), ("screen", "camera.viewfinder"),
        ("image", "photo"), ("pdf", "doc.richtext"), ("agent", "person.2"), ("plan", "checklist"),
        ("todo", "checklist"), ("python", "chevron.left.forwardslash.chevron.right"), ("outlin", "list.bullet.indent"),
        ("meeting", "waveform"), ("ollama", "cpu"), ("process", "gearshape.2"), ("sql", "cylinder"),
        ("json", "curlybraces"), ("clipboard", "doc.on.clipboard"), ("desktop", "macwindow"),
    ]
    return table.first { v.contains($0.0) }?.1 ?? "sparkle"
}

struct ItemRow: View {
    let item: Item
    @State private var hover = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 70)
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.userBubble))
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .assistant:
            VStack(alignment: .leading, spacing: 5) {
                MarkdownView(text: item.text, streaming: item.streaming)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.93))
                    .textSelection(.enabled)
                    .lineSpacing(2)
                HStack(spacing: 10) {
                    if let meta = item.meta {
                        Text(meta).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.tertiary)
                    }
                    if hover && !item.streaming {
                        Button { copyToClipboard(item.text) } label: {
                            Label("Copy", systemImage: "doc.on.doc").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.secondary)
                    }
                }
                .frame(height: 12)
            }
            .onHover { hover = $0 }
        case let .tool(state, _, verb, detail, error):
            ToolRow(state: state, verb: verb, detail: detail, error: error, details: item.details)
        case .thinking:
            ThinkingRow(item: item)
        case let .plan(steps):
            PlanCard(steps: steps)
        case let .files(files):
            ChangedFilesCard(files: files)
        case .info:
            Text(item.text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
        case .error:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(item.text).foregroundStyle(.white.opacity(0.85)).textSelection(.enabled)
            }
            .font(.system(size: 12))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
        }
    }
}

/// `ask_user`: the question and up to four answers as buttons (⌘1–⌘4). Typing in the
/// composer answers it too; Skip tells the assistant to go on without.
struct QuestionCard: View {
    let question: Question
    @ObservedObject var backend: Backend

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.cyan)
                Text(question.text).foregroundStyle(.white).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12.5))
            if let d = question.detail {
                Text(d).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(4)
            }
            VStack(spacing: 5) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { i, o in
                    Button { backend.answer(question, with: o, chosen: true) } label: {
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(.black.opacity(0.7))
                                .frame(width: 17, height: 17).background(Circle().fill(.cyan.opacity(0.85)))
                            Text(o).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.07)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)   // not bare digits: they'd fire while typing
                }
            }
            HStack {
                Text("Or type your own answer below").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                Spacer()
                Button { backend.answer(question, with: nil, chosen: false) } label: {
                    Text("Skip").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.cyan.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cyan.opacity(0.3)))
    }
}

struct ApprovalCard: View {
    let approval: Approval
    @ObservedObject var backend: Backend

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.yellow)
                Text("\(Prefs.name) wants to run").foregroundStyle(Theme.secondary)
                Text(approval.tool).foregroundStyle(.white).fontWeight(.bold)
            }
            .font(.system(size: 12))
            Text(approval.preview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35)))
            HStack(spacing: 8) {
                if let label = approval.allowLabel {
                    Button { backend.answer(approval, allow: true, forChat: true) } label: {
                        Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Approve this, and don't ask again for calls like it until you start or open another chat")
                }
                Spacer()
                Button { backend.answer(approval, allow: false) } label: {
                    Text("Deny").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                Button { backend.answer(approval, allow: true) } label: {
                    Text("Approve").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Color.green))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.yellow.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.yellow.opacity(0.3)))
    }
}

// MARK: - Hands-free stage

/// What the panel shows during a voice conversation: the face, what it heard,
/// and what it's saying. The chat keeps the full record underneath.
struct HandsFreeStage: View {
    @ObservedObject var handsFree: HandsFree
    @ObservedObject var backend: Backend

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 6)
            ZStack {
                // Soft halo that breathes with whoever is talking.
                Circle().fill(RadialGradient(colors: [haloColor.opacity(0.35), .clear], center: .center,
                                             startRadius: 10, endRadius: 110))
                    .frame(width: 200 + handsFree.waveLevel * 70, height: 200 + handsFree.waveLevel * 70)
                    .blur(radius: 10)
                    .animation(.easeOut(duration: 0.12), value: handsFree.waveLevel)
                AssistantFace(size: 104, backend: backend)
            }
            .frame(height: 150)
            SiriWave(mode: handsFree.waveMode, level: handsFree.waveLevel)
                .frame(height: 74)
                .padding(.horizontal, 60)
                .animation(.easeInOut(duration: 0.4), value: handsFree.waveMode)
            Text(caption)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: caption)
            Text(bodyText)
                .font(.system(size: handsFree.transcript.isEmpty ? 13 : 16, weight: .medium))
                .foregroundStyle(.white.opacity(handsFree.transcript.isEmpty ? 0.6 : 0.95))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, 40)
                .frame(minHeight: 60, alignment: .top)
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                if handsFree.phase == .speaking {
                    PillButton(label: "Stop talking", icon: "speaker.slash") { handsFree.interrupt() }
                }
                if backend.busy {
                    PillButton(label: "Stop task", icon: "stop.fill") { backend.stop() }
                }
                PillButton(label: "End hands-free", icon: "xmark") { handsFree.stop(say: "Going quiet.") }
            }
            Text(handsFree.echoCancelling ? "Talk over me any time to interrupt · say “stop listening” to end"
                                          : "Say “stop listening” to end · wear headphones to interrupt by voice")
                .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var haloColor: Color {
        switch handsFree.waveMode {
        case .listening: return Color(red: 0.25, green: 0.8, blue: 1.0)
        case .speaking: return Color(red: 0.85, green: 0.4, blue: 1.0)
        case .thinking: return Theme.glow[1]
        case .idle: return Theme.glow[0]
        }
    }

    private var caption: String {
        switch handsFree.phase {
        case .listening: return "Listening…"
        case .hearing: return "Go on…"
        case .thinking: return backend.lastTool.isEmpty ? "Thinking…" : backend.lastTool + "…"
        case .speaking: return "Speaking"
        case .standby: return "Say “\(Prefs.name)” when you need me"
        case .starting: return "Getting ready…"
        case .off: return ""
        }
    }

    private var bodyText: String {
        if !handsFree.transcript.isEmpty { return "“\(handsFree.transcript)”" }
        if handsFree.phase == .speaking || handsFree.phase == .thinking { return backend.lastAnswer.isEmpty ? "" : SpeechText.clean(String(backend.lastAnswer.prefix(220))) }
        return "Try “what's on my calendar”, “play some music”, or “find my offer letter”."
    }
}

// MARK: - Hands-free switch

/// The header's on/off switch for hands-free: a real toggle, labeled, and
/// alive while it's listening — so the mode is obvious at a glance.
struct HandsFreeSwitch: View {
    @ObservedObject var handsFree: HandsFree

    var body: some View {
        let on = handsFree.isOn
        Button { handsFree.toggle() } label: {
            HStack(spacing: 6) {
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule()
                        .fill(on ? AnyShapeStyle(LinearGradient(colors: [Theme.glow[0], Theme.glow[2]],
                                                                startPoint: .leading, endPoint: .trailing))
                                 : AnyShapeStyle(Color.white.opacity(0.16)))
                        .frame(width: 28, height: 16)
                    Circle().fill(.white).frame(width: 12, height: 12).padding(2)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                }
                Image(systemName: on ? "waveform" : "mic.fill")
                    .font(.system(size: 10, weight: .bold))
                    .symbolEffect(.variableColor.iterative,
                                  isActive: handsFree.phase == .listening || handsFree.phase == .hearing)
                Text(on ? label : "Talk").font(.system(size: 11, weight: .semibold))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(on ? .white : Theme.secondary)
            .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 3)
            .background(Capsule().fill(on ? Color.white.opacity(0.1) : Color.clear))
            .overlay(Capsule().stroke(on ? Theme.glow[1].opacity(0.5) : Theme.hairline))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
        }
        .buttonStyle(.plain)
        .help(on ? "Hands-free is on — click to turn off (⌥⇧Space)" : "Hands-free: just talk (⌥⇧Space)")
    }

    private var label: String {
        switch handsFree.phase {
        case .speaking: return "Speaking"
        case .thinking: return "Thinking"
        case .standby: return "Standby"
        case .starting: return "Starting"
        default: return "Listening"
        }
    }
}

/// Start-screen avatar: smaller when "For you" cards need the room.
struct HeroAvatar: View {
    @ObservedObject var proactive: ProactiveEngine
    @ObservedObject var backend: Backend
    var leaving = false
    var onImpact: (() -> Void)? = nil
    var onStand: (() -> Void)? = nil
    @Environment(\.notchContentVisible) private var visible
    @AppStorage("character.style") private var style = "puff"
    var body: some View {
        if style == "puff" {
            // Puff drops in (a different hero entrance each time — Entrances.swift) and settles here.
            HeroStage(visible: visible, size: 74, leaving: leaving, onImpact: onImpact, onStand: onStand)
                .frame(maxWidth: .infinity)
                .frame(height: proactive.proposals.isEmpty ? 132 : 100)
                .padding(.top, 2)
        } else {
            AssistantFace(size: proactive.proposals.isEmpty ? 86 : 60, backend: backend)
                .padding(.top, 6)
                .animation(.spring(duration: 0.35, bounce: 0.1), value: proactive.proposals.isEmpty)
        }
    }
}


/// Puff dropping out of the notch to say hi.
struct PeekabooView: View {
    @ObservedObject var notch: NotchController
    @ObservedObject var backend: Backend
    @State private var out = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            HStack(alignment: .center, spacing: 8) {
                AssistantFace(size: 46, backend: backend, greets: true)
                    .scaleEffect(out ? 1 : 0.6, anchor: .top)
                if let line = notch.peekLine {
                    // A little speech bubble from Puff.
                    Text(line)
                        .font(Typo.brand(12.5))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(Module.chat.accent.opacity(0.45), lineWidth: 0.75))
                        .opacity(out ? 1 : 0)
                        .offset(x: out ? 0 : -14)
                }
            }
            .offset(y: out ? notch.notchSize.height + 6 : -30)
        }
        .onAppear { withAnimation(.spring(duration: 0.55, bounce: 0.45).delay(0.08)) { out = true } }
    }
}


// MARK: - Seeing the agent work

/// A tool call. Tap to see what was sent and what came back.
struct ToolRow: View {
    let state: String
    let verb: String
    let detail: String
    let error: String?
    let details: String?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ZStack {
                    if state == "running" {
                        ProgressView().controlSize(.mini).scaleEffect(0.8)
                    } else {
                        Image(systemName: toolSymbol(verb))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(state == "done" ? Theme.secondary : .red)
                    }
                }
                .frame(width: 16, height: 16)
                Text(verb).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Text(error ?? detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(error == nil ? Theme.tertiary : .red.opacity(0.85))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if state == "done" {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.green.opacity(0.8))
                }
                if details != nil {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                }
            }
            if open, let details {
                Text(details)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { if details != nil { withAnimation(.spring(duration: 0.25)) { open.toggle() } } }
        .accessibilityElement(children: .combine)
        .accessibilityHint(details != nil ? "Tap to show details" : "")
    }
}

/// The model's reasoning: streams live (latest lines), then folds into "Thought for 6s".
struct ThinkingRow: View {
    let item: Item
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Theme.glow[0], Theme.glow[1]], startPoint: .leading, endPoint: .trailing))
                    .symbolEffect(.pulse, isActive: item.streaming)
                if item.streaming {
                    ShimmerText(text: "Thinking…")
                } else {
                    Text(item.meta ?? "Thought").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                }
                Spacer(minLength: 0)
            }
            if item.streaming || open {
                Text(item.streaming ? Self.tail(item.text) : item.text)
                    .font(.system(size: 11.5))
                    .italic()
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(item.streaming ? 3 : nil)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.glow[1].opacity(0.4)).frame(width: 2)
                    }
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !item.streaming { withAnimation(.spring(duration: 0.25)) { open.toggle() } } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.streaming ? "Thinking" : (item.meta ?? "Thought"))
    }

    /// The last ~240 characters, starting at a word.
    static func tail(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 240 else { return t }
        let cut = t.suffix(240)
        return "…" + (cut.firstIndex(of: " ").map { String(cut[$0...]) } ?? String(cut))
    }
}

/// A soft light sweeping across the text while something is in progress.
struct ShimmerText: View {
    let text: String
    @ObservedObject private var policy = AnimationPolicy.shared

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / policy.fps, paused: policy.reduceMotion)) { ctx in
            let x = CGFloat((ctx.date.timeIntervalSinceReferenceDate * 0.8).truncatingRemainder(dividingBy: 1)) * 1.6 - 0.3
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LinearGradient(stops: [.init(color: Theme.secondary, location: 0),
                                                        .init(color: Theme.secondary, location: max(0, x - 0.15)),
                                                        .init(color: .white, location: min(1, max(0, x))),
                                                        .init(color: Theme.secondary, location: min(1, x + 0.15)),
                                                        .init(color: Theme.secondary, location: 1)],
                                                startPoint: .leading, endPoint: .trailing))
        }
    }
}

/// The agent's plan, as a live checklist with progress.
/// What a turn made or changed: open, show in Finder, drag out, or park on the Shelf.
struct ChangedFilesCard: View {
    let files: [ChangedFile]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.glow[0])
                Text(files.count == 1 ? "1 file changed" : "\(files.count) files changed").font(.system(size: 12, weight: .bold))
                Spacer()
                if files.count > 1 {
                    Button("Add all to Shelf") { Self.shelve(files) }
                        .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            ForEach(files.prefix(8)) { FileLine(file: $0) }
            if files.count > 8 {
                Text("and \(files.count - 8) more").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
    }

    static func shelve(_ files: [ChangedFile]) {
        let urls = files.map { URL(fileURLWithPath: $0.path) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        (NSApp.delegate as? AppDelegate)?.hub.shelf.add(urls)
    }

    private struct FileLine: View {
        let file: ChangedFile
        @State private var hover = false

        var body: some View {
            let exists = FileManager.default.fileExists(atPath: file.path)
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(file.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    Text((file.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 6)
                if hover && exists {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) } label: {
                        Image(systemName: "folder").font(.system(size: 11))
                    }.buttonStyle(.plain).help("Show in Finder")
                    Button { ChangedFilesCard.shelve([file]) } label: {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 11))
                    }.buttonStyle(.plain).help("Add to Shelf")
                }
                Group {
                    if !exists { Text("deleted").foregroundStyle(.orange) }
                    else if file.created { Text("new").foregroundStyle(.green) }
                    else if file.uncounted { Text("changed").foregroundStyle(Theme.secondary) }
                    else {
                        HStack(spacing: 4) {
                            Text("+\(file.added)").foregroundStyle(.green)
                            Text("−\(file.deleted)").foregroundStyle(.red.opacity(0.85))
                        }
                    }
                }
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { if exists { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) } }
            .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: file.path)) ?? NSItemProvider() }
            .help(exists ? "Open · drag it anywhere" : file.path)
        }
    }
}

struct PlanCard: View {
    let steps: [PlanStep]

    var body: some View {
        let done = steps.filter { $0.status == "completed" }.count
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "checklist").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.glow[0])
                Text("Plan").font(.system(size: 12, weight: .bold))
                Spacer()
                Text("\(done) of \(steps.count)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: [Theme.glow[0], Theme.glow[1]], startPoint: .leading, endPoint: .trailing))
                        .frame(width: steps.isEmpty ? 0 : g.size.width * CGFloat(done) / CGFloat(steps.count))
                }
            }
            .frame(height: 3)
            .animation(.spring(duration: 0.4), value: done)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 8) {
                    Group {
                        switch step.status {
                        case "completed": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case "in_progress": ProgressView().controlSize(.mini).scaleEffect(0.75)
                        default: Image(systemName: "circle").foregroundStyle(Theme.tertiary)
                        }
                    }
                    .font(.system(size: 11))
                    .frame(width: 14, height: 14)
                    Text(step.content)
                        .font(.system(size: 12, weight: step.status == "in_progress" ? .semibold : .regular))
                        .foregroundStyle(step.status == "completed" ? Theme.tertiary : .white.opacity(0.9))
                        .strikethrough(step.status == "completed", color: Theme.tertiary)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(step.status.replacingOccurrences(of: "_", with: " "))
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        .animation(.spring(duration: 0.3), value: steps)
    }
}


// MARK: - Chat history

/// Every earlier conversation on this Mac: search, reopen, delete.
struct ChatHistoryView: View {
    @ObservedObject var backend: Backend
    let close: () -> Void
    @State private var query = ""
    @State private var chats: [SessionStore.Summary] = []
    @State private var confirmDelete: String? = nil
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary).accessibilityHidden(true)
                TextField("Search your chats", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .focused($focused)
                    .onKeyPress(.escape) { close(); return .handled }
                    .accessibilityLabel("Search chats")
                Button { backend.newChat(); close() } label: {
                    Label("New chat", systemImage: "square.and.pencil").font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.glow[0])
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().overlay(Theme.hairline)
            if chats.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 22)).foregroundStyle(Theme.tertiary)
                    Text(query.isEmpty ? "No earlier chats yet." : "No chats match “\(query)”.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Self.grouped(chats), id: \.0) { section, list in
                            Text(section.uppercased())
                                .font(.system(size: 9.5, weight: .heavy, design: .rounded)).tracking(0.7)
                                .foregroundStyle(Theme.tertiary)
                                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
                            ForEach(list) { c in row(c) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(width: 540)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .onAppear { refresh(); DispatchQueue.main.async { focused = true } }
        .onChange(of: query) { _, _ in refresh() }
    }

    private func row(_ c: SessionStore.Summary) -> some View {
        let current = c.id == backend.currentChatID
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: current ? "bubble.left.fill" : "bubble.left")
                .font(.system(size: 12)).foregroundStyle(current ? Theme.glow[0] : Theme.tertiary)
                .frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(c.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if current { Text("Open").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.glow[0]) }
                }
                Text(c.preview.isEmpty ? "\(c.messages) messages" : c.preview)
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(c.updated, format: .relative(presentation: .named))
                .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
            Button {
                if confirmDelete == c.id { backend.deleteChat(c.id); confirmDelete = nil; refresh() }
                else { confirmDelete = c.id }
            } label: {
                Image(systemName: confirmDelete == c.id ? "trash.fill" : "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(confirmDelete == c.id ? .red : Theme.tertiary)
            }
            .buttonStyle(.plain)
            .help(confirmDelete == c.id ? "Click again to delete" : "Delete this chat")
            .accessibilityLabel(confirmDelete == c.id ? "Confirm delete" : "Delete chat")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(current ? AnyShapeStyle(Theme.userBubble.opacity(0.25)) : AnyShapeStyle(Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture { backend.openChat(c.id); close() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func refresh() { chats = backend.chats(matching: query) }

    /// Today / Yesterday / This week / Earlier.
    static func grouped(_ list: [SessionStore.Summary]) -> [(String, [SessionStore.Summary])] {
        let cal = Calendar.current
        var out: [(String, [SessionStore.Summary])] = []
        func put(_ k: String, _ c: SessionStore.Summary) {
            if let i = out.firstIndex(where: { $0.0 == k }) { out[i].1.append(c) } else { out.append((k, [c])) }
        }
        for c in list {
            if cal.isDateInToday(c.updated) { put("Today", c) }
            else if cal.isDateInYesterday(c.updated) { put("Yesterday", c) }
            else if c.updated > Date().addingTimeInterval(-7 * 86400) { put("This week", c) }
            else { put("Earlier", c) }
        }
        return out
    }
}


/// The closed notch asking for attention: a soft yellow rim that pulses.
/// Fixed shadow radius, animated opacity only (no per-frame blur changes).
struct ApprovalGlow: View {
    let radius: CGFloat
    @State private var on = false
    @ObservedObject private var policy = AnimationPolicy.shared

    var body: some View {
        NotchShape(radius: radius)
            .stroke(Color.yellow.opacity(0.9), lineWidth: 1.5)
            .shadow(color: .yellow.opacity(0.8), radius: 9)
            .opacity(on ? 1 : 0.3)
            .onAppear {
                guard !policy.reduceMotion else { on = true; return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { on = true }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
