import AppKit
import Combine
import UniformTypeIdentifiers
import WebKit

/// Ledge's body on the desktop: the Dreamer (opennotch/desktop/, three.js in a
/// WKWebView) wandering over a transparent, click-through overlay.
///
///   * Perches = the visible top edges of your app windows (he rides a window
///     when you drag it; springs off when it closes or gets covered).
///   * Floor = the top of the Dock; he never enters the menu bar.
///   * Ledge link: while the notch is open, Ledge is working, an approval is
///     waiting, or hands-free is on, he hovers beside the notch ("attend").
///     Clicking him opens the notch; right-click for a small menu.
///   * Quiet by design: pauses in full-screen apps and while the screen sleeps.
@MainActor
final class DesktopCompanion: NSObject {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "desktop.on") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "desktop.on") }
    }

    /// Which character walks the desktop: "ledge", "bee" or "cat".
    static let avatarNames = [("ledge", "Ledge"), ("bee", "Bee"), ("cat", "Cat")]
    static let avatars = avatarNames.map(\.0)
    static var avatar: String {
        get {
            let v = UserDefaults.standard.string(forKey: "desktop.avatar") ?? "ledge"
            return avatars.contains(v) ? v : "ledge"
        }
        set { UserDefaults.standard.set(newValue, forKey: "desktop.avatar") }
    }

    weak var notch: NotchController?
    weak var backend: Backend?
    weak var handsFree: HandsFree?
    weak var hub: Hub?

    private var window: NSWindow?
    private var web: WKWebView?
    private var ready = false
    private var hitBox = NSRect.zero                 // overlay points, y from the top
    private var perchTimer: Timer?
    private var mouseTimer: Timer?
    private var subs: Set<AnyCancellable> = []
    private var lastPerchJSON = ""
    private var lastIntentAt = Date.distantPast
    private var paused = false
    private var screenAsleep = false
    private var frame = NSRect.zero                  // overlay frame (Cocoa, global)
    private var needsWorld = true                    // he's on / heading to a window
    private var bubbleBox = NSRect.zero              // his speech bubble, same coords as hitBox
    private var dragging = false
    private var hovering = false
    private var hiddenUntil = Date.distantPast
    private var lastWaveAt = Date.distantPast
    private var nextSlowPoll = Date.distantPast

    // MARK: lifecycle

    func start() {
        guard DesktopCompanion.enabled, window == nil, let screen = Self.screen() else { return }
        frame = screen.frame
        let w = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .floating                           // above app windows, under the menu bar and the notch
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        w.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(DesktopAssets(), forURLScheme: "opennotch")
        config.userContentController.add(WeakScriptHandler(self), name: "dreamer")
        let web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
        web.setValue(false, forKey: "drawsBackground")   // transparent page
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        w.contentView = web
        web.load(URLRequest(url: Self.pageURL))
        w.orderFrontRegardless()
        window = w
        self.web = web

        perchTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWorld() }
        }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        RunLoop.main.add(perchTimer!, forMode: .common)
        RunLoop.main.add(mouseTimer!, forMode: .common)
        observe()
        AppLog.write("desktop companion started on \(Int(frame.width))x\(Int(frame.height))")
    }

    func stop() {
        perchTimer?.invalidate(); perchTimer = nil
        mouseTimer?.invalidate(); mouseTimer = nil
        subs.removeAll()
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "dreamer")
        window?.orderOut(nil)
        window = nil
        web = nil
        ready = false
    }

    /// On screen and not hidden/paused — he, not the notch, announces results.
    var isActive: Bool { window != nil && ready && !paused && !screenAsleep && Date() >= hiddenUntil }

    private static var pageURL: URL {
        URL(string: "opennotch://desktop/index.html?avatar=\(avatar)")!
    }

    /// Swap the character in place (reloads the page; position is kept via its saved state).
    func setAvatar(_ name: String) {
        DesktopCompanion.avatar = name
        if !DesktopCompanion.enabled { setEnabled(true); return }
        ready = false
        web?.load(URLRequest(url: Self.pageURL))
    }

    /// Drop out of the notch onto the desktop (first launch, or after picking an avatar).
    /// If the page is still loading, it happens as soon as it's ready.
    func entrance() {
        if !DesktopCompanion.enabled { setEnabled(true) }
        guard ready else { pendingEntrance = true; return }
        pendingEntrance = false
        UserDefaults.standard.set(true, forKey: "desktop.introDone")
        notch?.peekaboo(hold: 2.4)                                 // Puff pops out as he drops
        js("dreamer.entrance(\(frame.width / 2))")
    }

    func setEnabled(_ on: Bool) {
        DesktopCompanion.enabled = on
        on ? start() : stop()
    }

    /// Built-in (notched) display if present, else the main one.
    private static func screen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func js(_ code: String) {
        guard ready, let web else { return }
        web.evaluateJavaScript("window.dreamer && (\(code))", completionHandler: nil)
    }

    // MARK: Ledge link

    private func observe() {
        guard let notch, let backend else { return }
        let hf = handsFree?.$phase.map { $0 != .off }.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()
        Publishers.CombineLatest(backend.$busy, backend.$approvals.map { !$0.isEmpty })
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] busy, approval in
                MainActor.assumeIsolated { self?.statusChanged(busy: busy, approval: approval) }
            }
            .store(in: &subs)
        notch.$mode.map { $0 == .expanded }.removeDuplicates().filter { $0 }
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.hideBubble() } }
            .store(in: &subs)
        Publishers.CombineLatest4(notch.$mode, backend.$busy, backend.$approvals.map { !$0.isEmpty }, hf)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] mode, busy, approval, handsFree in
                self?.updateAttend(open: mode == .expanded, busy: busy, approval: approval, voice: handsFree)
            }
            .store(in: &subs)

        // Hands-free: he captions the conversation and his mouth moves with Ledge's voice.
        if let hf = handsFree {
            Publishers.CombineLatest(hf.$phase.removeDuplicates(),
                                     hf.$transcript.throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true))
                .sink { [weak self] phase, transcript in
                    MainActor.assumeIsolated { self?.voiceChanged(phase, transcript) }
                }
                .store(in: &subs)
            hf.$speechLevel
                .map { ($0 * 10).rounded() / 10 }          // 0.1 steps: ≤ ~10 JS calls/s
                .removeDuplicates()
                .sink { [weak self] l in MainActor.assumeIsolated { self?.js("dreamer.setTalk(\(min(1, l * 1.6)))") } }
                .store(in: &subs)
        }

        // Music playing: he dances when he's standing about.
        backend.$nowPlaying.map(\.playing).removeDuplicates()
            .sink { [weak self] on in MainActor.assumeIsolated { self?.musicOn = on; self?.pushMood() } }
            .store(in: &subs)
        // Reactions: point at the notch while Ledge needs your OK, celebrate when it's done.
        Publishers.CombineLatest(backend.$busy.removeDuplicates(), backend.$approvals.map { !$0.isEmpty }.removeDuplicates())
            .sink { [weak self] busy, approval in MainActor.assumeIsolated { self?.react(busy: busy, approval: approval) } }
            .store(in: &subs)
        // Late at night with nothing going on, he dozes (checked once a minute).
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSleepy() }
        }
        // Settings toggles and energy saver.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .throttle(for: .milliseconds(300), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.pushMood() } }
            .store(in: &subs)
        AnimationPolicy.shared.$eco.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.pushMood() } }
            .store(in: &subs)

        let ws = NSWorkspace.shared.notificationCenter
        ws.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.appActivated(app) }
            }
            .store(in: &subs)
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                               (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            ws.publisher(for: name).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenAsleep = asleep
                    self?.applyPause()
                }
            }.store(in: &subs)
        }
        // Dev: `notch --closeup` renders a portrait to ~/Library/Application Support/OpenNotch/dreamer_closeup.png
        DistributedNotificationCenter.default().publisher(for: .init("dev.opennotch.closeup"))
            .sink { [weak self] n in
                let yaw = Double(n.object as? String ?? "") ?? 0.35
                MainActor.assumeIsolated { self?.js("dreamer.closeup(\(yaw))") }
            }
            .store(in: &subs)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.relayout() } }
            .store(in: &subs)
    }

    private var lastVoicePhase: HandsFree.Phase = .off
    private var musicOn = false
    private var pendingEntrance = false
    private var lastMood = ""
    private var wasBusy = false
    private var pointing = false
    private var sleepTimer: Timer?
    private var sleepySent = false

    private func react(busy: Bool, approval: Bool) {
        defer { wasBusy = busy }
        guard ready, let backend else { return }
        guard Prefs.on(Prefs.desktopReactions) else {
            if pointing { pointing = false; js("dreamer.react(null)") }
            return
        }
        if approval {
            pointing = true
            js("dreamer.react(\"point\")")
        } else if pointing {
            pointing = false
            js("dreamer.react(null)")
        }
        // A turn just finished cleanly: a little celebration.
        if wasBusy && !busy && !approval, !backend.lastAnswer.isEmpty,
           Date().timeIntervalSince(backend.lastErrorAt ?? .distantPast) > 5 {
            js("dreamer.react(\"celebrate\")")
        }
        checkSleepy()
    }

    /// 11 pm – 6 am, nothing running, no music, no voice: doze.
    private func checkSleepy() {
        guard ready, let backend else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        let sleepy = Prefs.on(Prefs.desktopSleep) && (hour >= 23 || hour < 6)
            && !backend.busy && backend.approvals.isEmpty && !musicOn && !(handsFree?.isOn ?? false)
        // Resent every minute while true: after a hover wakes him the page
        // ignores it for 2 minutes, then he nods off again.
        if sleepy || sleepySent { js("dreamer.setSleepy(\(sleepy))") }
        sleepySent = sleepy
    }

    /// Music (if he may dance) and energy saver → the page. Sent only on change.
    private func pushMood() {
        let dance = musicOn && Prefs.on(Prefs.desktopDance)
        let eco = AnimationPolicy.shared.eco
        let mood = "\(dance)|\(eco)"
        guard mood != lastMood, ready else { return }
        lastMood = mood
        js("dreamer.setMusic(\(dance)), dreamer.setEco && dreamer.setEco(\(eco))")
    }

    /// Live captions in his bubble while hands-free runs (the notch is usually
    /// closed then, so this is where you see what it heard).
    private func voiceChanged(_ phase: HandsFree.Phase, _ transcript: String) {
        defer { lastVoicePhase = phase }
        guard Date() >= hiddenUntil, notch?.mode != .expanded else { return }
        switch phase {
        case .listening:
            bubble("Listening…", sub: "Say “show me”, “repeat that”, “slower”, or “goodbye”.")
        case .hearing:
            let t = transcript.count > 140 ? "…" + transcript.suffix(140) : transcript
            bubble("🎙 " + t, live: lastVoicePhase == .hearing)
        case .thinking:
            bubble("Thinking", dots: true)
        case .standby:
            bubble("Resting", sub: "Say “Ledge” when you need me.", ttl: 4)
        case .speaking, .starting:
            hideBubble()
        case .off:
            if lastVoicePhase != .off { hideBubble(); js("dreamer.setTalk(0)") }
        }
    }

    /// Where to hover: beside the open panel, or beside the closed notch.
    private func updateAttend(open: Bool, busy: Bool, approval: Bool, voice: Bool) {
        guard let notch else { return }
        let want = open || busy || approval || voice
        guard want else { js("dreamer.attend(null)"); return }
        let side = open ? notch.expandedSize.width / 2 + 80 : notch.notchSize.width / 2 + 90
        let y = open ? 170.0 : notch.notchSize.height + 110
        js("dreamer.attend({x: \(frame.width / 2), y: \(y), side: \(side)})")
    }

    /// Switched apps: sometimes he flies over and stands on that app's window.
    private func appActivated(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              Date().timeIntervalSince(lastIntentAt) > 25, Double.random(in: 0...1) < 0.4 else { return }
        let pid = app.processIdentifier
        // Give the window list a moment to reorder.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let id = self.perches(frontmostOf: pid) else { return }
            self.lastIntentAt = Date()
            self.js("dreamer.intent(\"\(id)\", \"focus\")")
        }
    }

    // MARK: world (perches, floor, full-screen)

    private func relayout() {
        guard let screen = Self.screen(), let window else { return }
        frame = screen.frame
        window.setFrame(frame, display: true)
        pushWorld(screen)
    }

    private func pushWorld(_ screen: NSScreen) {
        // Floor = top of the Dock (if it's at the bottom); ceiling = menu bar.
        let dock = max(0, screen.visibleFrame.minY - screen.frame.minY)
        let menu = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        js("dreamer.setWorld({w: \(frame.width), h: \(frame.height), floor: \(dock > 4 ? dock + 2 : 14), ceil: \(menu + 4)})")
    }

    private struct Win { let id: Int; let pid: pid_t; let r: CGRect }

    /// On-screen normal windows, front to back, in overlay points (y from the top).
    private func windows() -> [Win] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryH = NSScreen.screens.first?.frame.height ?? frame.height
        let originX = frame.minX
        let originY = primaryH - frame.maxY                       // overlay top, in CG (y-down) space
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let num = d[kCGWindowNumber as String] as? Int,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
                  w >= 160, h >= 100 else { return nil }
            return Win(id: num, pid: pid, r: CGRect(x: x - originX, y: y - originY, width: w, height: h))
        }
    }

    /// The part of each window's top edge that isn't covered by a window in front.
    private func perchList(_ wins: [Win]) -> [(id: Int, x1: CGFloat, x2: CGFloat, top: CGFloat)] {
        var out: [(Int, CGFloat, CGFloat, CGFloat)] = []
        for (i, w) in wins.enumerated() {
            let top = w.r.minY
            guard top > 0, top < frame.height else { continue }
            var segs: [(CGFloat, CGFloat)] = [(max(0, w.r.minX), min(frame.width, w.r.maxX))]
            for f in wins[..<i] where f.r.minY <= top + 2 && f.r.maxY >= top - 8 {
                segs = segs.flatMap { s -> [(CGFloat, CGFloat)] in
                    if f.r.maxX <= s.0 || f.r.minX >= s.1 { return [s] }
                    var parts: [(CGFloat, CGFloat)] = []
                    if f.r.minX > s.0 { parts.append((s.0, f.r.minX)) }
                    if f.r.maxX < s.1 { parts.append((f.r.maxX, s.1)) }
                    return parts
                }
            }
            if let best = segs.max(by: { ($0.1 - $0.0) < ($1.1 - $1.0) }), best.1 - best.0 >= 120 {
                out.append((w.id, best.0, best.1, top))
            }
        }
        return out
    }

    private func perches(frontmostOf pid: pid_t) -> Int? {
        let wins = windows()
        let visible = Set(perchList(wins).map(\.id))
        return wins.first { $0.pid == pid && visible.contains($0.id) }?.id
    }

    private func refreshWorld() {
        guard ready else { return }
        // Reading the window list costs a few ms; do it 5x/s only while windows
        // matter to him (perched or landing), otherwise once a second.
        if !needsWorld && Date() < nextSlowPoll { return }
        nextSlowPoll = Date().addingTimeInterval(1)
        let wins = windows()
        // A full-screen app (video, presentation, focus): step out of the way.
        let fullScreen = wins.first.map { abs($0.r.width - frame.width) < 2 && abs($0.r.height - frame.height) < 2 && $0.r.minY <= 1 } ?? false
        if fullScreen != paused { paused = fullScreen; applyPause() }
        let list = perchList(wins)
        let json = "[" + list.map { "{id:\($0.id),x1:\(Int($0.x1)),x2:\(Int($0.x2)),top:\(Int($0.top))}" }.joined(separator: ",") + "]"
        if json != lastPerchJSON {
            lastPerchJSON = json
            js("dreamer.setPerches(\(json))")
        }
    }

    private func applyPause() {
        let off = paused || screenAsleep || Date() < hiddenUntil
        js("dreamer.setPaused(\(off))")
        if off { window?.ignoresMouseEvents = true }
    }

    // MARK: mouse (click-through except on him)

    private func trackMouse() {
        guard let window, ready, !paused, Date() >= hiddenUntil else { return }
        let m = NSEvent.mouseLocation
        let local = CGPoint(x: m.x - frame.minX, y: frame.maxY - m.y)   // y from the top
        let onHim = hitBox.insetBy(dx: -4, dy: -4).contains(local)
        let onBubble = !bubbleBox.isEmpty && bubbleBox.insetBy(dx: -6, dy: -6).contains(local)
        // While dragging, keep the mouse even if the pointer outruns him.
        let take = onHim || onBubble || dragging
        if window.ignoresMouseEvents == take { window.ignoresMouseEvents = !take }
        // Hover → he stops, faces you and waves (at most every 8s).
        let hoverNow = onHim && !dragging
        if hoverNow != hovering {
            hovering = hoverNow
            if !hoverNow || Date().timeIntervalSince(lastWaveAt) > 8 {
                if hoverNow { lastWaveAt = Date() }
                js("dreamer.setHover(\(hoverNow))")
            }
        }
    }

    // MARK: bubbles

    private struct BubbleAction { let id: String; let label: String; var primary = false }

    private func bubble(_ title: String, sub: String? = nil, actions: [BubbleAction] = [],
                        ttl: Double? = nil, dots: Bool = false, avatarSwitcher: Bool = false,
                        live: Bool = false) {
        var o: [String: Any] = ["title": title, "dots": dots, "live": live]
        if avatarSwitcher {
            o["avatars"] = ["current": DesktopCompanion.avatar,
                            "items": DesktopCompanion.avatarNames.map { ["id": $0.0, "name": $0.1] }]
        }
        if let sub { o["sub"] = sub }
        if let ttl { o["ttl"] = ttl }
        o["actions"] = actions.map { ["id": $0.id, "label": $0.label, "primary": $0.primary] }
        guard let data = try? JSONSerialization.data(withJSONObject: o),
              let json = String(data: data, encoding: .utf8) else { return }
        js("dreamer.bubble(\(json))")
    }

    private func hideBubble() { js("dreamer.bubble(null)") }

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 5 ? "Still up" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
        return firstName.isEmpty ? "\(part)!" : "\(part), \(firstName)!"
    }

    /// Click: a greeting, the most useful thing right now, and quick actions.
    private func showMenuBubble() {
        var actions = [BubbleAction(id: "ask", label: "Ask", primary: true), BubbleAction(id: "talk", label: "🎙 Talk")]
        var sub = "What can I do for you?"
        if backend?.busy == true {
            sub = backend?.lastTool.isEmpty == false ? "Working on it — \(backend!.lastTool.lowercased())…" : "Working on your request…"
            actions.append(BubbleAction(id: "stop", label: "Stop"))
        } else if let p = hub?.proactive.proposals.first {
            sub = p.title
            actions.insert(BubbleAction(id: "proposal", label: p.actionLabel, primary: true), at: 0)
            actions[1].primary = false
        } else {
            actions.append(BubbleAction(id: "plan", label: "Plan my day"))
        }
        actions.append(BubbleAction(id: "hide", label: "Hide 1h"))
        bubble(greeting, sub: sub, actions: actions, ttl: 12, avatarSwitcher: true)
    }

    private func perform(_ id: String) {
        switch id {
        case "ask": notch?.expand(pinned: true, focus: true)
        case "talk": handsFree?.start()
        case "stop": backend?.stop()
        case "plan":
            hub?.module = .chat
            notch?.expand(pinned: true)
            backend?.send("Plan my day: look at today's calendar, reminders and email that needs me, and give me a short, focused plan.")
        case "proposal":
            if let p = hub?.proactive.proposals.first { hub?.proactive.act(p) }
        case let a where a.hasPrefix("avatar:"):
            let name = String(a.dropFirst("avatar:".count))
            if DesktopCompanion.avatars.contains(name) { setAvatar(name) }
        case "hide":
            hiddenUntil = Date().addingTimeInterval(3600)
            js("dreamer.setPaused(true)")
            window?.ignoresMouseEvents = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3600) { [weak self] in
                guard let self, Date() >= self.hiddenUntil else { return }
                self.applyPause()
            }
        default: break
        }
    }

    /// Ledge's status, said by him — only while the notch is closed (when it's
    /// open, the notch already shows everything).
    private func statusChanged(busy: Bool, approval: Bool) {
        guard let notch, notch.mode != .expanded, handsFree?.isOn != true, Date() >= hiddenUntil else { return }
        if approval {
            bubble("Need your OK", sub: backend?.approvals.first.map { "Ledge wants to run \($0.tool)" },
                   actions: [BubbleAction(id: "ask", label: "Review", primary: true)])
        } else if busy {
            bubble("Thinking", dots: true)
        } else if let answer = backend?.lastAnswer, !answer.isEmpty {
            let line = SpeechText.clean(answer).components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first ?? ""
            bubble("Done ✓", sub: String(line.prefix(90)), actions: [BubbleAction(id: "ask", label: "Open")], ttl: 7)
        } else {
            hideBubble()
        }
    }

    /// A long turn's progress notice. Returns false if he isn't on screen
    /// (the caller then uses the notch instead).
    func showSlowNotice(_ text: String) -> Bool {
        guard isActive, notch?.mode != .expanded, handsFree?.isOn != true else { return false }
        let parts = text.components(separatedBy: " — ")
        bubble(parts.first ?? text, sub: parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : nil,
               actions: [BubbleAction(id: "stop", label: "Stop"), BubbleAction(id: "ask", label: "Open")],
               dots: true)
        return true
    }

    fileprivate func received(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            lastMood = ""
            pushMood()                                  // page (re)loaded, e.g. avatar switch
            sleepySent = false; pointing = false
            checkSleepy()
            if let screen = Self.screen() { pushWorld(screen) }
            lastPerchJSON = ""
            refreshWorld()
            if let notch, let backend {
                updateAttend(open: notch.mode == .expanded, busy: backend.busy,
                             approval: !backend.approvals.isEmpty, voice: handsFree?.isOn ?? false)
            }
            AppLog.write("desktop companion ready")
            // First launch (or a freshly picked avatar): make an entrance.
            if pendingEntrance || !UserDefaults.standard.bool(forKey: "desktop.introDone") {
                DispatchQueue.main.asyncAfter(deadline: .now() + (pendingEntrance ? 0.6 : 3.0)) { [weak self] in
                    self?.pendingEntrance = false
                    self?.ready = true
                    self?.entrance()
                }
            }
        case "state":
            if let b = msg["box"] as? [String: Double] {
                hitBox = NSRect(x: b["x"] ?? 0, y: b["y"] ?? 0, width: b["w"] ?? 0, height: b["h"] ?? 0)
            }
            needsWorld = msg["needsWorld"] as? Bool ?? true
            if let b = msg["bubble"] as? [String: Double] {
                bubbleBox = NSRect(x: b["x"] ?? 0, y: b["y"] ?? 0, width: b["w"] ?? 0, height: b["h"] ?? 0)
            } else {
                bubbleBox = .zero
            }
            dragging = msg["dragging"] as? Bool ?? false
        case "closeup":
            if let url = msg["data"] as? String, let comma = url.firstIndex(of: ","),
               let data = Data(base64Encoded: String(url[url.index(after: comma)...])) {
                try? data.write(to: URL(fileURLWithPath: opennotchDir("") + "/dreamer_closeup.png"))
                AppLog.write("desktop companion: close-up saved")
            }
        case "click":
            if (msg["button"] as? Int) == 2 { showMenu(); break }
            // Poked: the first click opens his menu; poke him fast and he gets dizzy.
            if msg["reaction"] as? String == "dizzy" {
                hideBubble()
                SoundFX.play(.dizzy)
            } else {
                SoundFX.play(.boop)
                showMenuBubble()
            }
        case "petted":
            SoundFX.play(.love)
        case "landed":
            if msg["entrance"] as? Bool == true {
                SoundFX.play(.yay)
                let name = DesktopCompanion.avatarNames.first { $0.0 == DesktopCompanion.avatar }?.1 ?? "Ledge"
                bubble("Hi! I'm \(name) 👋", sub: "Click me for a menu · drag me anywhere · double-click to talk", ttl: 7)
            }
        case "dblclick":
            handsFree?.toggle()
            bubble(handsFree?.isOn == true ? "I'm listening…" : "Okay, going quiet", ttl: 3)
        case "action":
            if let id = msg["id"] as? String { perform(id) }
        case "drag":
            dragging = msg["on"] as? Bool ?? false
            if dragging { window?.ignoresMouseEvents = false }
        default:
            break
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Ledge", action: #selector(openLedge), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Land", action: #selector(landNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Take off", action: #selector(takeOffNow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide desktop Ledge", action: #selector(hide), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func openLedge() { notch?.expand(pinned: true, focus: true) }
    @objc private func landNow() { js("dreamer.command('land')") }
    @objc private func takeOffNow() { js("dreamer.command('takeoff')") }
    @objc private func hide() { setEnabled(false) }
}

extension DesktopCompanion: WKNavigationDelegate {
    /// The web process can die (memory pressure, a GPU reset): come back.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        AppLog.write("desktop companion: web process terminated — reloading")
        ready = false
        webView.reload()
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: DesktopCompanion?
    init(_ t: DesktopCompanion) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.received(body) }
    }
}

/// Serves opennotch/desktop over opennotch:// — ES-module imports need a real
/// origin and a JavaScript MIME type, which file:// URLs don't reliably give.
private final class DesktopAssets: NSObject, WKURLSchemeHandler {
    static var root: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("desktop"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("index.html").path) { return r }
        // Dev fallback: the repo checkout the app was built from.
        if let repo = Bundle.main.infoDictionary?["OpenNotchRepo"] as? String {
            return URL(fileURLWithPath: repo).appendingPathComponent("opennotch/desktop")
        }
        return nil
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = Self.root else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        // Only files inside the desktop folder, never ../ out of it.
        let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let file = root.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
            ?? (file.pathExtension == "js" || file.pathExtension == "mjs" ? "text/javascript" : "application/octet-stream")
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
