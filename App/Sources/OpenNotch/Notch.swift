import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI

/// Borderless panel that can take keyboard focus without activating the app —
/// the same trick Spotlight uses, so typing in the notch doesn't yank you out
/// of whatever you were doing.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum NotchMode { case collapsed, hello, peek, alert, player, mirror, peekaboo, expanded }

/// One place for every notch motion, so open/close/peek feel like one system.
/// Open overshoots a touch and settles (the "drop"); close is quicker and
/// critically damped so it tucks back into the bezel without wobbling.
enum Motion {
    // Tuned for "butter": open drops with a whisper of bounce and settles fast;
    // close is critically damped (no wobble tucking into the bezel). Content
    // trails the shape in, and leaves before it on the way out.
    static let open = Animation.spring(duration: 0.46, bounce: 0.14)
    static let close = Animation.spring(duration: 0.36, bounce: 0)
    static let peek = Animation.spring(duration: 0.42, bounce: 0.12)
    static let hover = Animation.spring(duration: 0.26, bounce: 0.25)
    static let content = Animation.spring(duration: 0.34, bounce: 0)
    static let contentIn = Animation.easeOut(duration: 0.26)
    static let contentOut = Animation.easeIn(duration: 0.1)
}

/// Geometry + state machine for the notch.
///
/// The window is a fixed-size transparent panel hanging from the top-centre of
/// the notched screen; SwiftUI animates the black shape inside it. Clicks only
/// land on the panel while the pointer is over the visible shape — everywhere
/// else `ignoresMouseEvents` passes them through to the menu bar and apps below.
@MainActor
final class NotchController: ObservableObject {
    @Published var mode: NotchMode = .collapsed {
        didSet {
            // Whatever closed it (collapse, a permission prompt, an alert), the
            // per-frame animations stop with it.
            if mode != .expanded { liveWork?.cancel(); if contentLive { contentLive = false } }
            // The camera is on only while the mirror is showing.
            if oldValue == .mirror && mode != .mirror { camera.stop() }
            if mode != oldValue { FrameProbe.shared.capture("\(oldValue)→\(mode)", in: panel.contentView) }
        }
    }
    @Published var pinned = false          // opened by hotkey/click: don't close on mouse-out
    @Published var focusInput = false
    @Published var hovering = false        // pointer resting on the closed notch: grow a hair
    @Published var alert: NotchAlert?      // what .alert mode is showing
    @Published var fileDrag = false        // a file is being dragged over the notch
    @Published var showPalette = false     // ⌘K command palette over the open notch
    @Published var showHistory = false     // ⌘Y chat history over the open notch
    let camera = CameraIO()
    /// The expanded panel is built once, shortly after launch, and kept.
    @Published var panelWarm = false
    /// True once the open animation has settled; per-frame animations
    /// (avatar, waves) wait for it so they never compete with the open.
    @Published var contentLive = false
    private var liveWork: DispatchWorkItem?

    // Geometry follows the display: recomputed when screens change (external
    // monitor plugged in, lid closed, resolution changed).
    @Published private(set) var notchSize = CGSize(width: 190, height: 30)
    @Published private(set) var hasNotch = false
    let expandedSize = CGSize(width: 700, height: 520)
    var peekSize: CGSize { CGSize(width: max(notchSize.width + 240, 440), height: notchSize.height + 64) }
    let windowSize: CGSize

    let panel: NotchPanel
    private var screenFrame: NSRect = .zero
    private var screenObserver: NSObjectProtocol?
    private var timer: Timer?
    private var leftAt: Date?
    private var hoverSince: Date?
    private var fileDragUntil = Date.distantPast
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var peekTimer: Timer?
    weak var backend: Backend?
    weak var hub: Hub?
    weak var handsFree: HandsFree?

    init() {
        windowSize = CGSize(width: expandedSize.width + 40, height: expandedSize.height + 20)
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: windowSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        relayout()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        }
    }

    /// The built-in (notched) display if there is one, else the main display.
    /// Nil only in the brief moment with no displays at all (lid closing).
    private static func pickScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func relayout() {
        guard let screen = Self.pickScreen() else { return }       // try again on the next change
        let top = screen.safeAreaInsets.top
        hasNotch = top > 0
        if hasNotch, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: screen.frame.width - l.width - r.width, height: top)
        } else {
            let bar = screen.frame.maxY - screen.visibleFrame.maxY    // menu bar height
            notchSize = CGSize(width: 190, height: max(24, min(38, bar)))   // no notch: a fake one
        }
        screenFrame = screen.frame
        panel.setFrame(NSRect(x: screenFrame.midX - windowSize.width / 2, y: screenFrame.maxY - windowSize.height,
                              width: windowSize.width, height: windowSize.height), display: true)
        layoutPerch()
        AppLog.write("layout: \(hasNotch ? "notch" : "no notch") \(Int(notchSize.width))x\(Int(notchSize.height)) on \(Int(screenFrame.width))x\(Int(screenFrame.height))")
    }

    /// Width of the collapsed shape: the notch itself, plus "ears" either side
    /// while the agent is working so there's somewhere to show status.
    var collapsedSize: CGSize {
        let grow: CGFloat = hovering ? 14 : 0
        let ears = hasLiveActivity ? 2 * earWidth : (showsPerch ? 2 * perchEarWidth : 0)
        return CGSize(width: notchSize.width + ears + grow,
                      height: notchSize.height + (hovering ? 4 : 0))
    }

    /// Something worth showing in the closed notch's ears.
    var hasLiveActivity: Bool {
        hud != nil || (backend?.busy ?? false) || !(backend?.approvals.isEmpty ?? true)
            || (handsFree?.isOn ?? false) || (backend?.unseenAnswer ?? false) || hub?.timers.kind != nil
            || (backend?.nowPlaying.playing ?? false) || KeepAwake.shared.isOn || privacy.active
    }

    enum EarActivity { case hud, agent, timer, music, privacy, awake, none }

    private var perchHost: NSView?
    let perchModel = PerchModel()

    /// Keep the perch's own view over the closed notch (geometry changes with the display).
    func layoutPerch() {
        guard let v = perchHost, let box = v.superview?.bounds else { return }
        let w = notchSize.width + 2 * perchEarWidth
        v.frame = NSRect(x: (box.width - w) / 2, y: box.height - notchSize.height, width: w, height: notchSize.height)
        v.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
    }

    /// Puff sits beside the notch when nothing else needs the ears (pref `character.perch`).
    var showsPerch: Bool {
        !hasLiveActivity && Prefs.on(Prefs.characterPerch) && Attention.shared.state != .presenting
            && (UserDefaults.standard.string(forKey: "character.style") ?? "puff") == "puff"
    }
    var perchEarWidth: CGFloat { max(40, notchSize.height + 8) }

    /// Apps using the microphone / camera right now (PrivacyMonitor).
    @Published var privacy = PrivacyState()

    /// A short system pop-up (volume, headphones, power) — outranks everything
    /// for its ~1.6 s.
    @Published private(set) var hud: HUDKind?
    private var hudHide: DispatchWorkItem?

    func showHUD(_ h: HUDKind, for seconds: Double = 1.6) {
        guard mode == .collapsed || mode == .hello else { return }     // don't cover open content
        hudHide?.cancel()
        if hud == nil { withAnimation(Motion.peek) { hud = h } } else { hud = h }
        let w = DispatchWorkItem { [weak self] in withAnimation(Motion.close) { self?.hud = nil } }
        hudHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// The battery lookup for a device pop-up landed — update it in place.
    func updateHUDBattery(device: String, _ text: String) {
        if case .device(let name, let icon, _) = hud, name == device {
            hud = .device(name: name, icon: icon, battery: text)
            showHUD(hud!, for: 2.2)
        }
    }

    /// What the ears are showing, highest priority first.
    var earActivity: EarActivity {
        if hud != nil { return .hud }
        if (backend?.busy ?? false) || !(backend?.approvals.isEmpty ?? true) || (handsFree?.isOn ?? false)
            || (backend?.unseenAnswer ?? false) { return .agent }
        if hub?.timers.kind != nil { return .timer }
        if backend?.nowPlaying.playing ?? false { return .music }
        if privacy.active { return .privacy }
        if KeepAwake.shared.isOn { return .awake }
        return .none
    }

    /// Music gets wider ears for art + wave + title; timers for the ring + clock.
    var earWidth: CGFloat {
        switch earActivity {
        case .music: return 112
        case .timer: return 82
        case .hud:
            if case .health = hud { return 132 }
            return 100
        case .awake: return 62
        case .privacy: return 104
        default: return 65
        }
    }

    var visibleSize: CGSize {
        switch mode {
        case .collapsed: return collapsedSize
        case .hello: return CGSize(width: notchSize.width + 170, height: notchSize.height)
        case .peek: return peekSize
        case .player: return CGSize(width: max(notchSize.width + 2 * 112, 440), height: notchSize.height + 124)
        case .mirror: return CGSize(width: 380, height: notchSize.height + 250)
        case .peekaboo: return CGSize(width: notchSize.width + (peekLine == nil ? 20 : 250), height: notchSize.height + 64)
        case .alert: return CGSize(width: max(notchSize.width + 280, 480), height: notchSize.height + 64)
        case .expanded: return expandedSize
        }
    }

    func show(root: some View, perch: NSView) {
        let host = NSHostingView(rootView: root)
        // The panel has a fixed size: don't derive window min/max/intrinsic sizes from the content.
        host.sizingOptions = []
        // The perch gets its own small hosting view on top: its frames then re-render a
        // 300×38 pt view instead of the whole notch window (≈ 18% → a few % CPU).
        let container = NSView(frame: NSRect(origin: .zero, size: windowSize))
        container.wantsLayer = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.addSubview(perch)
        self.perchHost = perch
        layoutPerch()
        panel.contentView = container
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)

        // Click anywhere else closes it, pinned or not — unless it's waiting
        // on an approval. Global monitors see clicks in *other* apps only, so
        // clicks inside the panel never trigger this. Mouse monitors need no
        // Accessibility permission.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, [.expanded, .player, .mirror, .peekaboo].contains(self.mode),
                      self.backend?.approvals.isEmpty ?? true else { return }
                self.collapse()
            }
        }
        hello()
    }

    /// Screen rect of the currently visible shape (plus a small hover margin).
    private func visibleRect(margin: CGFloat) -> NSRect {
        let s = visibleSize
        let f = screenFrame
        return NSRect(x: f.midX - s.width / 2 - margin, y: f.maxY - s.height - margin,
                      width: s.width + margin * 2, height: s.height + margin + 2)
    }

    private func tick() {
        perchModel.sync(visible: mode == .collapsed && showsPerch, notchSize: notchSize, ear: perchEarWidth)
        let p = NSEvent.mouseLocation
        let over = visibleRect(margin: mode == .collapsed ? 4 : 12).contains(p)
        panel.ignoresMouseEvents = !over

        // A file drag in progress: the drag pasteboard changed since the button
        // went down. Lets you drag a file up to the closed notch to open it.
        let pressed = NSEvent.pressedMouseButtons != 0
        let dragCount = NSPasteboard(name: .drag).changeCount
        if !pressed { dragBaseline = dragCount }
        let dragging = pressed && dragCount != dragBaseline
        // Hold the drop zones up briefly after the button lifts: the drop is
        // delivered on mouse-up, and hiding them first would drop into the chat.
        if dragging && over {
            fileDragUntil = Date().addingTimeInterval(0.6)
            if !fileDrag { fileDrag = true }
        } else if fileDrag && Date() > fileDragUntil {
            fileDrag = false
        }

        if mode == .collapsed && !over { maybePeek() }
        switch mode {
        case .collapsed, .peek, .hello, .alert:
            // Dwell before opening, so sweeping to the menu bar doesn't trigger it.
            // The notch swells slightly during the dwell — feedback that it
            // noticed you, before it commits to opening.
            guard over, !pressed || dragging else {
                hoverSince = nil
                if hovering { withAnimation(Motion.hover) { hovering = false } }
                break
            }
            if hoverSince == nil {
                hoverSince = Date()
                if mode == .collapsed { withAnimation(Motion.hover) { hovering = true } }
            }
            if Date().timeIntervalSince(hoverSince!) > 0.2 {
                hoverSince = nil
                // Music in the ears: drop out the compact player, not the whole panel.
                if mode == .collapsed && earActivity == .music && !dragging && Prefs.on(Prefs.playerHover) { openPlayer() } else { expand(pinned: false) }
            }
        case .peekaboo:
            if over { peekabooUntil = max(peekabooUntil, Date().addingTimeInterval(1.5)) }
            else if Date() > peekabooUntil { withAnimation(Motion.close) { mode = .collapsed } }
        case .player, .mirror:
            if over || pressed || Date() < playerHoldUntil {
                leftAt = nil
            } else if leftAt == nil {
                leftAt = Date()
            } else if Date().timeIntervalSince(leftAt!) > 0.45 {
                leftAt = nil
                withAnimation(Motion.close) { mode = .collapsed }
            }
        case .expanded:
            let holding = pinned || dragging || !(backend?.approvals.isEmpty ?? true)
            if over || holding {
                leftAt = nil
            } else if leftAt == nil {
                leftAt = Date()
            } else if Date().timeIntervalSince(leftAt!) > 0.35 {
                collapse()
            }
        }
    }

    private var playerHoldUntil = Date.distantPast
    private var peekabooUntil = Date.distantPast
    /// What Puff says while peeking (nil = just a wave).
    @Published private(set) var peekLine: String?
    private var nextPeek = Date().addingTimeInterval(150)

    /// Puff pops out of the notch, looks around, and slips back in.
    func peekaboo(hold: TimeInterval = 3.6) {
        guard mode == .collapsed, !hasLiveActivity else { return }    // the perch is fine — Puff hops down from it
        peekabooUntil = Date().addingTimeInterval(hold)
        SoundFX.play(.peek)
        withAnimation(Motion.peek) { mode = .peekaboo }
    }

    /// Now and then, while you're at the Mac and the notch is idle.
    private func maybePeek() {
        guard Date() >= nextPeek else { return }
        nextPeek = Date().addingTimeInterval(Double.random(in: PresenceLogic.peekEvery(Liveliness.current)) * 60)
        let idleFor = min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved),
                          CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown))
        guard Prefs.on(Prefs.characterPeek), UserDefaults.standard.string(forKey: "character.style") ?? "puff" == "puff",
              idleFor < 60, !fileDrag,
              !PresenceLogic.quietHours(Calendar.current.component(.hour, from: Date())),
              !Attention.shared.state.isBusy else { return }
        // Friendly and lively: say something that fits the moment.
        let c = Calendar.current.dateComponents([.hour, .minute, .weekday], from: Date())
        peekLine = Liveliness.current == .calm ? nil
            : PresenceLogic.peekLine(hour: c.hour ?? 12, minute: c.minute ?? 0, weekday: c.weekday ?? 1, seed: Int.random(in: 0..<1000))
        peekaboo(hold: peekLine == nil ? 3.6 : 4.8)
    }

    /// Camera mirror: asks for the camera the first time (with the notch out
    /// of the way of the dialog), then drops the live preview out of the notch.
    func openMirror(hold: TimeInterval = 6) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            camera.start { ok in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard ok else { self.showAlert(.info(icon: "video.slash", text: "No camera found"), for: 4); return }
                        self.playerHoldUntil = Date().addingTimeInterval(hold)
                        self.leftAt = nil
                        self.hovering = false
                        withAnimation(Motion.peek) { self.mode = .mirror }
                    }
                }
            }
        case .notDetermined:
            yieldForSystemPrompt("Camera")
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { if granted { self?.openMirror(hold: hold) } }
                }
            }
        default:
            showAlert(.info(icon: "video.slash", text: "Allow the camera in System Settings › Privacy › Camera › OpenNotch"), for: 6)
        }
    }

    func closeMirror() {
        guard mode == .mirror else { return }
        withAnimation(Motion.close) { mode = .collapsed }
    }

    /// `hold`: stay open that long even without the pointer (CLI / keyboard).
    func openPlayer(hold: TimeInterval = 0) {
        playerHoldUntil = Date().addingTimeInterval(hold)
        leftAt = nil
        hovering = false
        withAnimation(Motion.peek) { mode = .player }
    }

    /// Called when the notch opens (not when it's already open).
    var onOpen: (() -> Void)?

    func expand(pinned pin: Bool, focus: Bool = false) {
        if mode != .expanded { onOpen?() }
        panelWarm = true
        liveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .expanded else { return }
            self.contentLive = true
        }
        liveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: w)
        peekTimer?.invalidate()
        leftAt = nil
        if pin { pinned = true }
        hovering = false
        withAnimation(Motion.open) { mode = .expanded }
        if focus {
            panel.makeKeyAndOrderFront(nil)
            focusInput = true
        }
    }

    func collapse() {
        liveWork?.cancel()
        contentLive = false
        pinned = false
        focusInput = false
        leftAt = nil
        withAnimation(Motion.close) { mode = .collapsed }
        if panel.isKeyWindow {
            panel.resignKey()
            NSWorkspace.shared.frontmostApplication?.activate()
        }
    }

    /// Launch greeting: the notch stretches into ears with the orb and "Ledge",
    /// holds a beat, and tucks back in — so you know it's alive.
    func hello() {
        // Pre-warm the panel off the critical path, so even the first open
        // doesn't pay for building it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in self?.panelWarm = true }   // after the hello, while idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.mode == .collapsed else { return }
            withAnimation(Motion.peek) { self.mode = .hello }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak self] in
                guard let self, self.mode == .hello else { return }
                withAnimation(Motion.close) { self.mode = .collapsed }
            }
        }
    }

    /// Hydration / timer / capture: drop an alert out of the notch, then tuck back.
    func showAlert(_ a: NotchAlert, for seconds: Double = 7) {
        guard mode != .expanded else { return }
        var seconds = seconds
        if case .proposal = a { seconds = max(seconds, 12) }        // give time to read and act
        alert = a
        withAnimation(Motion.peek) { mode = .alert }
        peekTimer?.invalidate()
        peekTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mode == .alert else { return }
                withAnimation(Motion.close) { self.mode = .collapsed }
            }
        }
    }

    /// A macOS permission dialog is about to appear. The notch floats above
    /// almost everything, so an open panel can hide the dialog — tuck away and
    /// say where to look.
    func yieldForSystemPrompt(_ what: String) {
        pinned = false
        focusInput = false
        withAnimation(Motion.close) { mode = .collapsed }
        if panel.isKeyWindow { panel.resignKey() }
        NSApp.activate(ignoringOtherApps: true)            // dialogs attach to the active app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.showAlert(.info(icon: "lock.shield", text: "Allow \(what) in the macOS dialog"), for: 6)
        }
    }

    func toggleFromHotkey() {
        if mode == .expanded && pinned { collapse() } else { expand(pinned: true, focus: true) }
    }

    /// Show the answer briefly when a turn finishes while the notch is closed.
    func peek() {
        guard mode == .collapsed else { return }
        withAnimation(Motion.peek) { mode = .peek }
        peekTimer?.invalidate()
        peekTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mode == .peek else { return }
                withAnimation(Motion.close) { self.mode = .collapsed }
            }
        }
    }
}

/// System-wide hotkeys via Carbon — no Accessibility permission needed.
/// Each registration gets its own id, and a press only fires the action whose
/// id matches (all handlers see every hotkey event on the app target).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    /// Called when the keys are let go (hold-to-talk). nil = press only.
    private let release: (() -> Void)?
    private let id: UInt32
    let name: String
    private(set) var registered = false

    init(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey), id: UInt32 = 1,
         name: String = "", release: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.action = action
        self.release = release
        self.id = id
        self.name = name
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, user in
            guard let user, let event else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<HotKey>.fromOpaque(user).takeUnretainedValue()
            guard hk.id == me.id else { return OSStatus(eventNotHandledErr) }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { me.release?() } else { me.action() }
            return noErr
        }, 2, &specs, me, &handler)
        let hid = EventHotKeyID(signature: OSType(0x4E544348), id: id)   // 'NTCH'
        registered = RegisterEventHotKey(keyCode, modifiers, hid, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
