import AppKit
import Speech
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let backend = Backend()
    let dictation = Dictation()
    let dictate = DictateAnywhere()
    let handsFree = HandsFree()
    let hub = Hub()
    let desktop = DesktopCompanion()
    var notch: NotchController!
    private var hotKeys: [HotKey] = []
    private var subs: Set<AnyCancellable> = []
    private var mediaPoll: Timer?
    private let systemMonitor = SystemMonitor()
    private let health = HealthMonitor()
    private let privacyMonitor = PrivacyMonitor()
    private var scheduleTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        // ── Resilience: run under the launchd supervisor, one copy only ──
        if !Supervisor.disabled && Supervisor.canSupervise && !Supervisor.isSupervised && Supervisor.writePlist() {
            if Supervisor.isDuplicateInstance() {
                DistributedNotificationCenter.default().postNotificationName(
                    .init("dev.opennotch.toggle"), object: nil, userInfo: nil, deliverImmediately: true)
                exit(0)
            }
            Supervisor.handOverAndExit()
        }
        if Supervisor.isDuplicateInstance() {
            // A copy handing over may still be exiting — give it a moment.
            Thread.sleep(forTimeInterval: 1.2)
            if Supervisor.isDuplicateInstance() { AppLog.write("duplicate instance — exiting"); exit(0) }
        }
        AppLog.write("launch \(Bundle.main.bundlePath) supervised=\(Supervisor.isSupervised)")

        notch = NotchController()
        notch.backend = backend
        notch.hub = hub
        notch.handsFree = handsFree
        handsFree.backend = backend

        backend.onDone = { [weak self] _ in
            guard let self, self.notch.mode != .expanded, !self.handsFree.isOn else { return }
            // Finished in the background: keep a "Ready" ear until the notch is opened.
            self.backend.unseenAnswer = true
            let finished = self.backend.lastDoneAt
            DispatchQueue.main.asyncAfter(deadline: .now() + 30 * 60) { [weak self] in
                if self?.backend.lastDoneAt == finished { self?.backend.unseenAnswer = false }
            }
            // Desktop Ledge says it in his bubble; one voice, not two.
            if self.desktop.isActive { return }
            Chime.done()
            self.notch.peek()
        }
        backend.onApproval = { [weak self] in
            guard let self else { return }
            Chime.attention()
            if let a = self.backend.approvals.last {
                self.handsFree.approvalRequested(a)
                // Not answered yet? Nudge again (the closed notch keeps glowing meanwhile).
                for delay in [25.0, 50.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        if self?.backend.approvals.contains(where: { $0.id == a.id }) == true { Chime.attention() }
                    }
                }
            }
            self.notch.expand(pinned: true)
        }
        backend.onTextDelta = { [weak self] d in self?.handsFree.feed(d) }
        backend.onTurnFinished = { [weak self] text, streamed in self?.handsFree.turnFinished(text, streamed: streamed) }
        backend.onToolStarted = { [weak self] verb in self?.handsFree.toolStarted(verb) }
        startSlowTurnWatch()
        handsFree.onShow = { [weak self] in self?.hub.module = .chat; self?.notch.expand(pinned: true) }
        handsFree.onNewChat = { [weak self] in self?.backend.newChat() }

        dictation.$listening.sink { [weak self] v in self?.backend.listening = v }.store(in: &subs)
        dictation.$level.sink { [weak self] v in self?.backend.micLevel = v }.store(in: &subs)
        handsFree.$phase.sink { [weak self] p in self?.backend.voicePhase = p }.store(in: &subs)
        // Say so when hands-free flips while the notch is closed (hotkey, `notch -h`).
        handsFree.$phase.map { $0 != .off }.removeDuplicates().dropFirst().sink { [weak self] on in
            guard let self, self.notch.mode != .expanded else { return }
            self.notch.showAlert(on ? .info(icon: "waveform", text: "Hands-free on — just talk")
                                    : .info(icon: "mic.slash", text: "Hands-free off"), for: 2.2)
        }.store(in: &subs)
        handsFree.$speechLevel.sink { [weak self] l in self?.backend.speechLevel = l }.store(in: &subs)
        dictate.dictation = dictation
        dictate.backend = backend
        dictate.notch = notch
        dictate.hub = hub
        dictation.onFinish = { [weak self] text in
            guard let self else { return }
            if self.dictate.active { self.dictate.finished(text) } else { self.backend.send(text) }
        }
        dictation.onEmpty = { [weak self] in
            if self?.dictate.active == true { self?.dictate.cancelled(); self?.notch.collapse() }
        }
        // One owner of the mic at a time.
        dictation.canStart = { [weak self] in
            guard let self, self.handsFree.isOn else { return true }
            self.backend.notice("Hands-free is listening already — just talk.")
            return false
        }
        handsFree.willPrompt = { [weak self] in self?.notch.yieldForSystemPrompt("Microphone & Speech Recognition") }
        dictation.willPrompt = { [weak self] in self?.notch.yieldForSystemPrompt("Microphone & Speech Recognition") }
        hub.files.willPrompt = { [weak self] what in self?.notch.yieldForSystemPrompt(what) }
        handsFree.willStart = { [weak self] in
            if self?.dictation.listening == true { self?.dictation.stop() }
        }
        dictation.onError = { [weak self] msg in self?.dictate.cancelled(); self?.backend.notice(msg) }

        hub.timers.onAlert = { [weak self] alert in
            Chime.attention()
            self?.notch.showAlert(alert)
        }
        hub.captures.clipboard = hub.clipboard
        hub.captures.panel = notch.panel
        hub.captures.onCaptured = { [weak self] c in
            guard let self else { return }
            if c.path.isEmpty { self.backend.notice(c.transcript ?? "Capture failed."); return }
            self.notch.showAlert(.capture(c.path), for: 5)
            self.hub.captures.editing = c.annotated ? nil : c
            self.hub.module = .captures
        }

        notch.show(root: RootView(backend: backend, notch: notch, dictation: dictation, hub: hub, handsFree: handsFree)
            .environmentObject(hub)
            .environmentObject(handsFree),
                   perch: PerchHostView(model: notch.perchModel, backend: backend, hub: hub))

        let keys = [
            HotKey(id: 1, name: "⌥Space") { [weak self] in Task { @MainActor in self?.notch.toggleFromHotkey() } },
            HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), id: 4, name: "⌥⇧Space") { [weak self] in
                Task { @MainActor in self?.handsFree.toggle() }
            },
            // Dictate into any app: hold to talk, or tap to start / tap to finish.
            HotKey(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey | shiftKey), id: 5, name: "⌥⇧D",
                   release: { [weak self] in Task { @MainActor in self?.dictate.keyUp() } }) { [weak self] in
                Task { @MainActor in self?.dictate.keyDown() }
            },
        ]
        hotKeys = keys
        for k in keys where !k.registered {
            AppLog.write("hotkey \(k.name) could not be registered (taken by another app?)")
            backend.notice("\(k.name) is already used by another app, so that shortcut won't work. The notch and right-click menu still do.")
        }
        hub.start()
        hub.captures.install()
        wireAssist()

        // Ledge's body on the desktop (the Dreamer), after the notch is up.
        desktop.notch = notch
        desktop.backend = backend
        desktop.handsFree = handsFree
        desktop.hub = hub
        // The desktop companion is opt-in now; people who had it before (by the old default) keep it.
        if UserDefaults.standard.object(forKey: "desktop.on") == nil, UserDefaults.standard.bool(forKey: Prefs.onboardingDone) {
            DesktopCompanion.enabled = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.desktop.start() }
        for k in hub.captures.hotKeysFailed { backend.notice("\(k) is already used by another app.") }

        // Crashes since last launch: keep the report, say so once. macOS writes
        // the report a few seconds after the crash — by then launchd has
        // already restarted us — so look again shortly after launch.
        reportCrashes(after: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.reportCrashes(after: 0) }

        // Sleep kills audio engines; end hands-free cleanly instead of leaving it deaf.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handsFree.stop()
                if self?.dictation.listening == true { self?.dictation.stop() }
            }
        }
        listenForExternalTriggers()
        systemMonitor.onHUD = { [weak self] h in
            let key: String
            switch h {
            case .volume: key = Prefs.hudVolume
            case .device: key = Prefs.hudDevice
            case .power: key = Prefs.hudPower
            case .health: key = Prefs.hudHealth
            case .awake: key = ""
            }
            if key.isEmpty || Prefs.on(key) { self?.notch.showHUD(h) }
        }
        systemMonitor.onPowerState = { plugged in AnimationPolicy.shared.onBattery = !plugged }
        systemMonitor.onBattery = { [weak self] name, text in self?.notch.updateHUDBattery(device: name, text) }
        systemMonitor.start()
        health.onAlert = { [weak self] h in
            if Prefs.on(Prefs.hudHealth) { self?.notch.showHUD(h, for: 4.5) }
        }
        health.start()
        privacyMonitor.onChange = { [weak self] s in
            guard let self else { return }
            var state = s
            if self.notch.mode == .mirror { state.camera = false }          // that's our own mirror
            if !Prefs.on(Prefs.hudPrivacy) { state = PrivacyState() }
            let new = state.micApps.filter { !self.notch.privacy.micApps.contains($0) }
            let cameraStarted = state.camera && !self.notch.privacy.camera
            withAnimation(Motion.open) { self.notch.privacy = state }
            // If something else owns the ears, still say who just started listening.
            if (!new.isEmpty || cameraStarted) && self.notch.earActivity != .privacy {
                let who = new.first ?? "An app"
                self.notch.showHUD(.health(icon: new.isEmpty ? "video.fill" : "mic.fill",
                                           title: new.isEmpty ? "Camera on" : "\(who) · mic on",
                                           detail: new.isEmpty ? "An app started the camera" : "Using your microphone", tone: 1), for: 3)
            }
        }
        privacyMonitor.start()
        // Scheduled prompts ("every weekday at 9 …"): run when due and the agent is free.
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.backend.busy, self.backend.aiConnected else { return }
                guard let task = ScheduleStore.shared.takeDue().first else {
                    self.backend.core.learnIfIdle()            // a quiet chat: anything worth remembering?
                    return
                }
                self.backend.core.send(task.prompt, display: "⏰ " + task.prompt)
            }
        }
        KeepAwake.shared.onChange = { [weak self] on in
            self?.notch.objectWillChange.send()
            self?.notch.showHUD(.awake(on: on, label: HealthLogic.awakeLabel(until: KeepAwake.shared.until)
                .replacingOccurrences(of: "∞", with: "Until you stop it")), for: 1.8)
        }
        if ProviderStore.adoptFreeDefault() {                 // free + private out of the box, where possible
            backend.core.reloadProvider()
            AppLog.write("no AI set up: using Apple's on-device model")
        }
        backend.start()
        Updater.shared.start()
        Presence.shared.notch = notch
        Presence.shared.backend = backend
        Presence.shared.hub = hub
        hub.clipboard.onCopied = { text in Presence.shared.copied(text) }
        Attention.shared.inCall = { [weak self] in self?.notch.privacy.active ?? false }
        Attention.shared.onCallStart = { [weak self] in
            MeetingNotes.shared.callStarted(micApps: self?.notch.privacy.micApps ?? [])
        }
        MeetingNotes.shared.notch = notch
        MeetingNotes.shared.backend = backend
        MeetingNotes.shared.proactive = hub.proactive
        Attention.shared.start()
        Presence.shared.start()
        ToolHost.hub = hub
        ToolHost.notch = notch
        Task { await MCPManager.shared.reload() }
        // First run: the welcome steps inside the notch, once, after the hello.
        // Permissions are asked when a feature first needs them.
        if !UserDefaults.standard.bool(forKey: Prefs.onboardingDone) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.notch.startOnboarding() }
        }
        if UserDefaults.standard.bool(forKey: "handsfree.autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.handsFree.start() }
        }

        // Keep "now playing" fresh for the notch's ears (pgrep first — cheap
        // when nothing is running).
        mediaPoll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.backend.refreshNowPlaying() }
        }
    }

    /// `opennotch/notch` (Terminal, Raycast, Shortcuts…) talks to the app over
    /// distributed notifications — no port, no permissions.
    private func listenForExternalTriggers() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("dev.opennotch.toggle"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.notch.toggleFromHotkey() }
        }
        center.addObserver(forName: .init("dev.opennotch.handsfree"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handsFree.toggle() }
        }
        center.addObserver(forName: .init("dev.opennotch.module"), object: nil, queue: .main) { [weak self] n in
            let name = (n.object as? String ?? "").lowercased()
            Task { @MainActor in
                guard let self else { return }
                if name == "player" { self.notch.openPlayer(hold: 5); return }     // the hover music player
                if name == "mirror" { self.notch.openMirror(hold: 6); return }     // camera mirror
                if name == "peek" { self.notch.peekaboo(); return }                // Puff says hi
                if name == "welcome" { self.notch.startOnboarding(); return }      // the first-run steps again
                if name == "notestest" {                                          // dev: 20 s of call notes, no call needed
                    MeetingNotes.shared.start(app: "Test call")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { MeetingNotes.shared.stop() }
                    return
                }
                if name == "busytest" {                                           // dev: the "AI working" look, no AI call
                    self.backend.busy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.backend.busy = false }
                    return
                }
                if name == "palette" {                                             // ⌘K
                    self.notch.expand(pinned: true, focus: true)
                    self.notch.showPalette = true
                    return
                }
                if let m = Module.allCases.first(where: { $0.rawValue.lowercased() == name || $0.title.lowercased() == name }) {
                    self.hub.module = m
                    self.notch.expand(pinned: true)
                }
            }
        }
        // `notch -t 10` / `90s` / `focus` / `stopwatch` / `pause` / `stop` — runs
        // in the closed notch's ears without opening anything.
        center.addObserver(forName: .init("dev.opennotch.timer"), object: nil, queue: .main) { [weak self] n in
            let spec = (n.object as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            Task { @MainActor in
                guard let t = self?.hub.timers else { return }
                switch spec {
                case "focus", "pomodoro": t.startPomodoro()
                case "stopwatch": t.startStopwatch()
                case "pause", "resume": if t.kind != nil { t.pauseResume() }
                case "stop", "reset", "cancel": t.reset()
                default:
                    let secs = spec.hasSuffix("s") ? Double(spec.dropLast()) : Double(spec.replacingOccurrences(of: "m", with: "")).map { $0 * 60 }
                    if let secs, secs >= 1, secs <= 24 * 3600 { t.startCountdown(seconds: secs) }
                    else { AppLog.write("notch -t: didn't understand \"\(spec)\"") }
                }
            }
        }
        // `notch --awake [minutes|on|off]`
        center.addObserver(forName: .init("dev.opennotch.awake"), object: nil, queue: .main) { n in
            let spec = (n.object as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            Task { @MainActor in
                let k = KeepAwake.shared
                switch spec {
                case "off", "stop": k.stop()
                case "", "on", "toggle": spec == "on" ? k.start(minutes: nil) : k.toggle()
                default:
                    if let m = Int(spec.replacingOccurrences(of: "m", with: "")), m > 0, m <= 24 * 60 { k.start(minutes: m) }
                }
            }
        }
        center.addObserver(forName: .init("dev.opennotch.update"), object: nil, queue: .main) { _ in
            Task { @MainActor in Updater.shared.checkNow() }
        }
        center.addObserver(forName: .init("dev.opennotch.settings"), object: nil, queue: .main) { n in
            let tab = SettingsTab(rawValue: (n.object as? String ?? "").lowercased()) ?? .general
            Task { @MainActor in SettingsWindow.shared.show(tab) }
        }
        center.addObserver(forName: .init("dev.opennotch.ask"), object: nil, queue: .main) { [weak self] n in
            let text = n.object as? String ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.hub.module = .chat
                self.notch.expand(pinned: true)
                if !text.isEmpty { self.backend.send(text) }
            }
        }
    }

    private func reportCrashes(after delay: Double) {
        guard let c = Supervisor.collectCrashes().first else { return }
        AppLog.write("recovered from crash: \(c.exception) | \(c.frame) | \(c.saved)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.notch.showAlert(.info(icon: "bandage", text: "OpenNotch restarted after a crash — report saved"), for: 5)
        }
    }

    // MARK: Ask about this · writing tools · proactive · quick capture

    private func wireAssist() {
        let ctx = hub.context
        ctx.backend = backend
        ctx.clipboard = hub.clipboard
        ctx.notch = notch
        ctx.captures = hub.captures
        // Snapshot what you're working on the moment the notch opens.
        notch.onOpen = { [weak ctx, weak self] in
            ctx?.refresh()
            if self?.backend.unseenAnswer == true {               // opened to see the result
                self?.backend.unseenAnswer = false
                self?.hub.module = .chat
            }
        }

        let pro = hub.proactive
        pro.backend = backend
        pro.calendar = hub.calendar
        pro.screenTime = hub.screenTime
        pro.present = { [weak self] p in
            guard let self else { return }
            Chime.attention()
            self.notch.showAlert(.proposal(p))
        }
        pro.openChat = { [weak self] in
            self?.hub.module = .chat
            self?.notch.expand(pinned: true)
        }
        backend.core.onLearned = { [weak pro] facts in pro?.proposeMemory(facts) }
        hub.calendar.refreshAuth()
        pro.start()

        backend.interceptor = { [weak self] text in self?.quickCapture(text) }
    }

    /// Quick capture: returns the confirmation if handled, nil to send to Ledge.
    private func quickCapture(_ text: String) -> String? {
        let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!"))
        if ["undo", "undo that", "undo the last one", "cancel that reminder"].contains(lower) {
            return hub.quick.undo() ? "Undone." : nil
        }
        guard let intent = QuickCapture.parse(text) else { return nil }
        let (ok, message) = hub.quick.run(intent)
        if ok {
            if notch.mode != .expanded {
                notch.showAlert(.info(icon: "checkmark.circle", text: message), for: 3.5)
            }
            return message + " Say “undo” to take it back."
        }
        guard message.hasPrefix("needs-") else { return message }
        // First use: ask macOS, then finish the capture once allowed.
        let what = message == "needs-reminders" ? "Reminders" : "Calendars"
        notch.yieldForSystemPrompt("\(what) for OpenNotch")
        hub.calendar.requestAccess { [weak self] in
            guard let self else { return }
            let (ok2, msg2) = self.hub.quick.run(intent)
            self.backend.showLocalExchange(user: "↻ " + text,
                                           reply: ok2 ? msg2 : "I still don't have \(what) access — allow it in System Settings › Privacy & Security.")
        }
        return "One moment — allow \(what) access in the macOS dialog and I'll save it."
    }

    /// Save everything that's buffered. Safe to call more than once.
    func prepareForExit() {
        hub.notes.flush()
        hub.screenTime.save()
    }

    func applicationWillTerminate(_ note: Notification) {
        AppLog.write("quit")
        prepareForExit()
        handsFree.stop()
        backend.shutdown()
        MCPManager.shared.stopAll()
    }
}

@main
struct OpenNotchMain {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--render-character") {
            let out = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "character.png"
            exit(MainActor.assumeIsolated { CharacterSheet.render(to: out) })
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-ears") {
            let out = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "ears.png"
            exit(MainActor.assumeIsolated { EarsSheet.render(to: out) })
        }
        if CommandLine.arguments.contains("--probe-menubar") {          // dev: list menu bar icons (read-only)
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { print("not trusted for Accessibility"); exit(1) }
                let apps = NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.localizedName ?? "App", $0.icon) }
                let items = MenuBarStore.scan(apps: apps, front: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                              geometry: MenuBarStore.notchGeometry())
                for i in items { print(i.hidden ? "HIDDEN " : "       ", i.appName, "—", i.label, "x:", Int(i.frame.minX), "w:", Int(i.frame.width)) }
                print("\(items.count) icons, \(items.filter(\.hidden).count) hidden; notch gap:", MenuBarStore.notchGeometry().notchGap as Any)
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--probe-privacy") {          // dev: who's using mic / camera now
            print("mic:", PrivacyMonitor.micApps(), "camera:", PrivacyMonitor.cameraOn())
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-week") {      // dev: the shareable card, sample numbers
            let out = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "week.png"
            MainActor.assumeIsolated {
                let r = ImageRenderer(content: WeekCard(counts: [.drafts: 9, .explained: 6, .answers: 41, .dictatedWords: 2300,
                                                                  .summaries: 7, .briefs: 4, .meetingNotes: 2]))
                r.scale = 2
                if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
                   let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: out)) }
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--probe-notes") {             // dev: transcribe 12 s of the Mac's sound
            guard CGPreflightScreenCaptureAccess() else { print("screen recording not allowed for this process — skipped"); exit(2) }
            let rec = MeetingRecorder()
            rec.start(withMic: false, onLine: { who, text in print("\(who): \(text)") }, done: { err in
                if let err { print("start failed:", err); exit(1) }
                print("recording 12 s…")
            })
            print("speech auth:", SFSpeechRecognizer.authorizationStatus().rawValue, "(3 = authorized)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { rec.stop { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { print("done"); exit(0) } } }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--probe-attention") {        // dev: is something being watched / full screen?
            MainActor.assumeIsolated {
                print("watching:", Attention.mediaApp() ?? "nothing", "· full screen in front:", Presence.frontmostIsFullScreen())
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--checks") {
            Task { @MainActor in exit(await AgentChecks.run()) }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.start()
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--eval") {
            Task { @MainActor in exit(await Evals.run()) }
            RunLoop.main.run()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
        app.run()
    }
}


// MARK: - Long turns: keep the user aware

extension AppDelegate {
    /// Once a turn runs past 20s, say so — then once a minute. Hands-free
    /// speaks it (HandsFree.tick); otherwise the desktop avatar's bubble shows
    /// it with Stop, or, without him, the notch drops a short notice.
    func startSlowTurnWatch() {
        var level = 0
        var turn: Date?
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.backend.busy, let started = self.backend.turnStarted else { level = 0; turn = nil; return }
                if turn != started { turn = started; level = 0 }
                guard !self.handsFree.isOn, self.backend.approvals.isEmpty,
                      let n = VoiceTurn.slowNotice(elapsed: Date().timeIntervalSince(started), tool: self.backend.lastTool),
                      n.level > level else { return }
                level = n.level
                if !self.desktop.showSlowNotice(n.text), self.notch.mode != .expanded {
                    self.notch.showAlert(.info(icon: "hourglass", text: n.text), for: 6)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }
}
