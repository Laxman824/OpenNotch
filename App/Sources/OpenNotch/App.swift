import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let backend = Backend()
    let dictation = Dictation()
    let handsFree = HandsFree()
    let hub = Hub()
    let desktop = DesktopCompanion()
    var notch: NotchController!
    private var hotKeys: [HotKey] = []
    private var subs: Set<AnyCancellable> = []
    private var mediaPoll: Timer?
    private let systemMonitor = SystemMonitor()
    private let health = HealthMonitor()

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
            // Desktop Ledge says it in his bubble; one voice, not two.
            if self.desktop.isActive { return }
            Chime.done()
            self.notch.peek()
        }
        backend.onApproval = { [weak self] in
            Chime.attention()
            self?.notch.expand(pinned: true)
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
        dictation.onFinish = { [weak self] text in self?.backend.send(text) }
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
        dictation.onError = { [weak self] msg in self?.backend.notice(msg) }

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
            .environmentObject(handsFree))

        let keys = [
            HotKey(id: 1, name: "⌥Space") { [weak self] in Task { @MainActor in self?.notch.toggleFromHotkey() } },
            HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), id: 4, name: "⌥⇧Space") { [weak self] in
                Task { @MainActor in self?.handsFree.toggle() }
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
        KeepAwake.shared.onChange = { [weak self] on in
            self?.notch.objectWillChange.send()
            self?.notch.showHUD(.awake(on: on, label: HealthLogic.awakeLabel(until: KeepAwake.shared.until)
                .replacingOccurrences(of: "∞", with: "Until you stop it")), for: 1.8)
        }
        backend.start()
        ToolHost.hub = hub
        ToolHost.notch = notch
        Task { await MCPManager.shared.reload() }
        // First run: the permission checklist, once.
        if !UserDefaults.standard.bool(forKey: Prefs.onboardingDone) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                SettingsWindow.shared.show(.permissions, welcome: true)
            }
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
        notch.onOpen = { [weak ctx] in ctx?.refresh() }

        let pro = hub.proactive
        pro.backend = backend
        pro.calendar = hub.calendar
        pro.present = { [weak self] p in
            guard let self else { return }
            Chime.attention()
            self.notch.showAlert(.proposal(p))
        }
        pro.openChat = { [weak self] in
            self?.hub.module = .chat
            self?.notch.expand(pinned: true)
        }
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
        if CommandLine.arguments.contains("--checks") {
            Task { @MainActor in exit(await AgentChecks.run()) }
            RunLoop.main.run()
        }
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.start()
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
