import AVFoundation
import Foundation
import OpenNotchObjC
import Speech

/// Run an AVFoundation call that may raise an Objective-C exception. Logs and
/// returns false instead of taking the app down.
@discardableResult
func avSafe(_ what: String, _ block: () -> Void) -> Bool {
    if let reason = NBTry(block) {
        AppLog.write("AVFoundation exception in \(what): \(reason)")
        return false
    }
    return true
}

/// Hands-free conversation: listen → (silence) → send → speak the answer
/// sentence-by-sentence as it streams → listen again.
///
/// Threading — the part that has to be right:
///   * `VoiceIO` owns every audio object (engine, player, synthesizer,
///     recogniser) and touches them only on its own serial queue. Nothing
///     audio-related runs on the main thread.
///   * `HandsFree` is the main-actor state machine. It sends VoiceIO commands
///     and receives results via plain `DispatchQueue.main.async` hops — never
///     a Swift `Task` that does audio work.
/// The first version set up voice processing inside a main-actor Task; Core
/// Audio can spin the run loop re-entrantly during that setup, and a click
/// handled in that window crashed SwiftUI's main-actor check
/// (`MainActor.assumeIsolated` → SIGSEGV). Keeping audio off the main thread
/// removes the re-entrancy entirely.
///
/// One AVAudioEngine does both directions with voice processing (Apple's echo
/// cancellation) on, and Ledge's speech plays *through that engine*, so the
/// canceller knows what to cancel and you can talk over it. Without voice
/// processing it falls back to half-duplex. Standby + "Ledge" wake word only
/// with on-device recognition.
@MainActor
final class HandsFree: ObservableObject {
    enum Phase: Equatable { case off, starting, listening, hearing, thinking, speaking, standby }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var transcript = ""
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var speechLevel: CGFloat = 0     // drives the avatar's mouth
    @Published private(set) var echoCancelling = false
    @Published var lastError: String?

    weak var backend: Backend?
    /// A tool approval we've asked about out loud.
    private var pendingApproval: Approval?
    /// Asked before starting, so push-to-talk dictation can release the mic.
    var willStart: (() -> Void)?
    /// macOS is about to show a permission prompt — get out of its way.
    var willPrompt: (() -> Void)?
    /// "Show me" — open the notch on the conversation.
    var onShow: (() -> Void)?
    /// "New chat" / "start over".
    var onNewChat: (() -> Void)?

    var isOn: Bool { phase != .off }

    private let io = VoiceIO()
    private var ticker: Timer?
    private var lastHeard = Date()
    private var lastActivity = Date()
    private var pendingText = ""          // streamed text not yet spoken
    private var spokenChars = 0           // this turn — long answers are cut short
    private var turnDone = true
    private var spokenRecently = ""       // for telling echo from barge-in
    private var generation = 0            // ignores callbacks from a previous session
    private var lastAnswer = ""           // what was spoken for the last turn ("repeat that")
    private var turnStartedAt = Date()
    private var saidFiller = false        // a "working on it" filler at most once per turn
    private var lastFillerAt = Date.distantPast
    private var lastFiller = -1
    private var toolPhrases: [String] = []  // spoken this turn (≤ 2, no repeats)
    private var slowLevel = 0             // last "taking longer" notice spoken this turn

    /// Speaking rate, adjustable by voice ("slower" / "faster"), remembered.
    private var rate: Float {
        get { (UserDefaults.standard.object(forKey: "handsfree.rate") as? Float) ?? 0.52 }
        set { UserDefaults.standard.set(min(0.62, max(0.4, newValue)), forKey: "handsfree.rate") }
    }
    private let quietToStandby: TimeInterval = 30
    private let maxSpokenChars = 700

    init() {
        io.events = { [weak self] event in
            // Always delivered on the main queue by VoiceIO.
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    // MARK: control

    func toggle() { isOn ? stop(say: "Going quiet.") : start() }

    func start() {
        guard phase == .off else { return }
        willStart?()
        phase = .starting
        generation += 1
        let gen = generation
        if Permissions.needsPrompt { willPrompt?() }
        Permissions.speechAndMic { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen, self.phase == .starting else { return }
                if let error {
                    self.fail(error)
                    return
                }
                self.io.start(voiceID: VoiceChoice.identifier) { [weak self] result in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == gen, self.phase == .starting else { return }
                        switch result {
                        case .failure(let msg):
                            self.fail(msg)
                        case .success(let echo):
                            self.echoCancelling = echo
                            self.backend?.handsFree = true
                            self.lastActivity = Date()
                            self.io.setRate(self.rate)
                            self.listen()
                            self.io.speak("I'm listening.")
                            self.startTicker()
                        }
                    }
                }
            }
        }
    }

    func stop(say goodbye: String? = nil) {
        guard phase != .off else { return }
        generation += 1
        ticker?.invalidate()
        ticker = nil
        let wasRunning = phase != .starting
        phase = .off
        transcript = ""
        level = 0
        speechLevel = 0
        backend?.handsFree = false
        io.stopListening()
        if let goodbye, wasRunning {
            io.speak(goodbye)
            io.shutdown(afterSpeech: true)
        } else {
            io.shutdown(afterSpeech: false)
        }
    }

    /// Stop talking now (Esc / stop button / barge-in). Keeps listening.
    func interrupt() {
        io.stopSpeaking()
        speechLevel = 0
        if phase == .speaking { listen() }
    }

    private func fail(_ message: String) {
        lastError = message
        phase = .off
        backend?.handsFree = false
        backend?.notice(message)
        io.shutdown(afterSpeech: false)
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    // MARK: events from VoiceIO

    private func handle(_ e: VoiceIO.Event) {
        guard phase != .off else { return }
        switch e {
        case .micLevel(let l): level = l
        case .speechLevel(let l): speechLevel = l
        case .heard(let text, let final): heard(text, final: final)
        case .recognizerStopped:
            // Timeout / no speech / network hiccup: quietly start a fresh one.
            if phase == .listening || phase == .standby || phase == .hearing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.phase == .listening || self.phase == .standby else { return }
                        self.listen()
                    }
                }
            }
        case .speechIdle:
            speechLevel = 0
            if phase == .speaking && (turnDone || pendingApproval != nil) {
                lastActivity = Date()
                listen()                                   // turn over, or waiting for a spoken yes/no
            } else if phase == .speaking && backend?.busy == true {
                phase = .thinking                           // said "okay", the agent carries on
            }
        case .engineRestarted(let echo):
            // Audio route changed (AirPods, headphones): keep going.
            echoCancelling = echo
            if phase == .listening || phase == .standby || phase == .hearing { listen() }
        case .fatal(let msg):
            fail(msg)
        }
    }

    // MARK: listening

    private func listen() {
        transcript = ""
        lastHeard = Date()
        if phase != .standby { phase = .listening }
        io.listen()
    }

    private func heard(_ text: String, final: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != transcript else { return }

        switch phase {
        case .speaking:
            // Barge-in — but only if it isn't our own voice leaking back.
            guard echoCancelling, t.split(separator: " ").count >= 2, !looksLikeEcho(t) else { return }
            io.stopSpeaking()
            speechLevel = 0
            phase = .hearing
        case .standby:
            guard let r = t.range(of: VoiceTurn.wakeName, options: .caseInsensitive) else {
                if t.count > 120 { listen() }          // don't let standby text grow forever
                return
            }
            let rest = t[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
            Chime.done()
            lastActivity = Date()
            if rest.isEmpty { phase = .listening; listen(); return }
            phase = .hearing
            transcript = rest
            lastHeard = Date()
            return
        case .starting, .off:
            return
        default:
            phase = .hearing
        }
        transcript = t
        lastHeard = Date()
        lastActivity = Date()
        if final { commit() }
    }

    private func looksLikeEcho(_ t: String) -> Bool {
        let heard = Set(t.lowercased().split(separator: " ").map(String.init))
        let spoken = Set(spokenRecently.lowercased().split(separator: " ").map(String.init))
        guard !heard.isEmpty, !spoken.isEmpty else { return false }
        return Double(heard.intersection(spoken).count) / Double(heard.count) > 0.6
    }

    private func tick() {
        let now = Date()
        if phase == .hearing, now.timeIntervalSince(lastHeard) > VoiceTurn.silenceNeeded(transcript) {
            commit()
        } else if phase == .thinking,
                  let n = VoiceTurn.slowNotice(elapsed: now.timeIntervalSince(turnStartedAt), tool: backend?.lastTool ?? ""),
                  n.level > slowLevel {
            // Long turn: say so (between answer sentences only — phase is thinking).
            slowLevel = n.level
            saidFiller = true
            say(n.text, partOfAnswer: false)
        } else if phase == .thinking, !saidFiller, now.timeIntervalSince(turnStartedAt) > 4 {
            // A slow turn with nothing said yet: let them know it's working —
            // a different phrase each time, and not on every turn (hearing the
            // same "One moment." again and again grates).
            saidFiller = true
            if now.timeIntervalSince(lastFillerAt) > 45 {
                lastFillerAt = now
                say(VoiceTurn.filler(avoiding: &lastFiller), partOfAnswer: false)
            }
        } else if phase == .listening, now.timeIntervalSince(lastActivity) > quietToStandby {
            if io.supportsOnDevice {
                phase = .standby
                listen()
            } else {
                stop(say: "Going quiet.")               // never an always-open server mic
            }
        } else if phase == .thinking, backend?.connected == false {
            say("I've lost the connection to Ledge. I'll keep listening.")
            turnDone = true
        }
    }

    private func commit() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        guard !text.isEmpty else { listen(); return }
        // Waiting on a yes/no for a tool: answer it, and never send this to the model.
        if let a = pendingApproval {
            guard backend?.approvals.contains(where: { $0.id == a.id }) == true else {
                pendingApproval = nil                      // answered by click meanwhile
                commit(text: text)
                return
            }
            switch VoiceTurn.approvalAnswer(text) {
            case true?:
                pendingApproval = nil
                backend?.answer(a, allow: true)
                say("Okay, going ahead.", partOfAnswer: false)
            case false?:
                pendingApproval = nil
                backend?.answer(a, allow: false)
                say("Okay, I won't.", partOfAnswer: false)
            case nil:
                say("Sorry — yes or no?", partOfAnswer: false)
            }
            return
        }
        commit(text: text)
    }

    /// A tool needs permission: ask out loud and listen for yes / no.
    func approvalRequested(_ a: Approval) {
        guard isOn else { return }
        pendingApproval = a
        say(a.spoken.isEmpty ? VoiceTurn.approvalPhrase(tool: a.tool, args: [:]) : a.spoken, partOfAnswer: false)
    }

    private func commit(text: String) {
        // Local commands: instant, no model call.
        switch VoiceTurn.command(text) {
        case .exit:
            stop(say: "Okay. Say the word when you need me.")
            return
        case .cancel:
            if backend?.busy == true { backend?.stop() }
            io.stopSpeaking()
            say("Okay.", partOfAnswer: false)
            return
        case .stopTalking:
            io.stopSpeaking()
            listen()
            return
        case .repeatLast:
            if lastAnswer.isEmpty { say("I haven't said anything yet.", partOfAnswer: false) }
            else { io.speak(lastAnswer); phase = .speaking; turnDone = true }
            return
        case .slower, .faster:
            rate += VoiceTurn.command(text) == .slower ? -0.05 : 0.05
            io.setRate(rate)
            say(VoiceTurn.command(text) == .slower ? "Okay, slower." : "Okay, a bit faster.", partOfAnswer: false)
            turnDone = true
            return
        case .newChat:
            onNewChat?()
            say("Fresh start.", partOfAnswer: false)
            turnDone = true
            return
        case .show:
            onShow?()
            say("It's in the notch.", partOfAnswer: false)
            turnDone = true
            return
        case nil:
            break
        }
        guard backend?.connected == true else {
            say("Ledge's backend is offline right now. Give it a moment.")
            return
        }
        io.stopListening()
        phase = .thinking
        turnDone = false
        pendingText = ""
        spokenChars = 0
        lastAnswer = ""
        turnStartedAt = Date()
        saidFiller = false
        toolPhrases = []
        slowLevel = 0
        backend?.send(text, voice: true)
    }

    // MARK: speaking

    /// Streamed answer text arrives here; complete sentences are spoken as
    /// soon as they exist, so the reply starts before the model finishes.
    func feed(_ delta: String) {
        guard phase == .thinking || phase == .speaking else { return }
        pendingText += delta
        while let cut = SpeechText.sentenceCut(pendingText) {
            say(String(pendingText[..<cut]))
            pendingText.removeSubrange(..<cut)
        }
    }

    /// A tool started during the turn: say a few words so it isn't dead air
    /// (at most two per turn, never the same twice, only while nothing else is
    /// being said).
    /// Settings › Voice speed slider.
    func setSpeakingRate(_ r: Float) { rate = r; io.setRate(rate) }

    func toolStarted(_ verb: String) {
        guard phase == .thinking, toolPhrases.count < 2,
              let phrase = VoiceTurn.toolPhrase(verb), !toolPhrases.contains(phrase) else { return }
        toolPhrases.append(phrase)
        saidFiller = true
        say(phrase, partOfAnswer: false)
    }

    func turnFinished(_ finalText: String, streamed: Bool) {
        guard phase == .thinking || phase == .speaking else { return }
        if !streamed { pendingText += finalText }         // fast-path answers arrive whole
        if !pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { say(pendingText) }
        pendingText = ""
        turnDone = true
        if phase == .thinking { listen() }                  // nothing was spoken at all
    }

    /// partOfAnswer false = a status line ("Checking your email."): not counted
    /// toward the length cap and not replayed by "repeat that".
    private func say(_ raw: String, partOfAnswer: Bool = true) {
        guard !partOfAnswer || spokenChars < maxSpokenChars else { return }
        var text = SpeechText.clean(raw)
        guard !text.isEmpty else { return }
        if partOfAnswer { spokenChars += text.count }
        if spokenChars >= maxSpokenChars {
            text += " That's the gist — the rest is in the notch."
        }
        spokenRecently = String((spokenRecently + " " + text).suffix(400))
        if partOfAnswer { lastAnswer = String((lastAnswer + " " + text).suffix(1500)) }
        if phase != .standby { phase = .speaking }
        io.speak(text)
    }
}

// MARK: - Voice selection

enum VoiceChoice {
    /// Zoe (Premium) — the voice Ledge speaks with. Falls back to the best
    /// installed English voice if Zoe is ever removed.
    static let preferred = "com.apple.voice.premium.en-US.Zoe"

    static var identifier: String? {
        if AVSpeechSynthesisVoice(identifier: preferred) != nil { return preferred }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        return voices.max { rank($0) < rank($1) }?.identifier
    }

    private static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        switch v.quality {
        case .premium: return 2
        case .enhanced: return 1
        default: return 0
        }
    }
}

// MARK: - Permissions

enum Permissions {
    /// True when asking will pop a system dialog (first use).
    static var needsPrompt: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
            || AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    /// Speech recognition + microphone. `done(nil)` when both are granted,
    /// else a message saying exactly where to fix it. Calls back on main.
    static func speechAndMic(_ done: @escaping @Sendable (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    done(status == .restricted
                         ? "Speech recognition is restricted on this Mac."
                         : "Hands-free needs Speech Recognition — System Settings › Privacy & Security › Speech Recognition › OpenNotch.")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable ok in
                DispatchQueue.main.async {
                    done(ok ? nil : "Hands-free needs the microphone — System Settings › Privacy & Security › Microphone › OpenNotch.")
                }
            }
        }
    }
}

// MARK: - Audio plumbing (serial queue only)

/// Every AVFoundation / Speech object lives here and is touched only on `q`.
/// Results go back to the main queue through `events`.
final class VoiceIO: @unchecked Sendable {
    enum Event {
        case micLevel(CGFloat)
        case speechLevel(CGFloat)
        case heard(String, final: Bool)
        case recognizerStopped
        case speechIdle
        case engineRestarted(echo: Bool)
        case fatal(String)
    }
    enum StartResult { case success(echo: Bool), failure(String) }

    /// Set once from the main actor before use; called on the main queue.
    var events: ((Event) -> Void)?

    private let q = DispatchQueue(label: "opennotch.voice", qos: .userInteractive)
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let synth = AVSpeechSynthesizer()
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
    private let recogFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var voice: AVSpeechSynthesisVoice?

    // Touched from the audio tap thread → guarded by `lock`.
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var built = false            // engine + nodes + taps exist (teardown only if so)
    private var echo = false
    private var pendingUtterances = 0
    private var outstandingBuffers = 0
    private var shutdownAfterSpeech = false
    private var configObserver: NSObjectProtocol?

    let supportsOnDevice: Bool

    init() {
        supportsOnDevice = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition ?? false
    }

    private func emit(_ e: Event) {
        DispatchQueue.main.async { [weak self] in self?.events?(e) }
    }

    // MARK: lifecycle

    func start(voiceID: String?, _ done: @escaping @Sendable (StartResult) -> Void) {
        q.async { [self] in
            let result = self.bringUp(voiceID: voiceID)
            DispatchQueue.main.async { done(result) }
        }
    }

    private func bringUp(voiceID: String?) -> StartResult {
        guard let recognizer, recognizer.isAvailable else {
            return .failure("Speech recognition isn't available right now (offline and no on-device model?).")
        }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            return .failure("No microphone found.")
        }
        voice = voiceID.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        shutdownAfterSpeech = false
        // Echo-cancelled first; if the audio hardware refuses that combination,
        // fall back to half-duplex rather than failing outright.
        do {
            try buildEngine(voiceProcessing: true)
        } catch {
            AppLog.write("hands-free: echo-cancelled start failed (\(error)) — retrying without")
            teardownEngine()
            do {
                try buildEngine(voiceProcessing: false)
            } catch {
                teardownEngine()
                AppLog.write("hands-free: plain start failed too (\(error))")
                return .failure(VoiceIO.explain(error))
            }
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] n in
            guard let self, (n.object as? AVAudioEngine) === self.engine else { return }
            self.q.async { self.restartAfterRouteChange() }
        }
        return .success(echo: echo)
    }

    private func buildEngine(voiceProcessing: Bool) throws {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        // Order matters: with voice processing, the output unit must exist
        // *before* it's enabled, or engine.start() fails with -10875
        // (kAUInitialize on the output node). Verified on this Mac.
        _ = engine.outputNode
        _ = engine.mainMixerNode
        let input = engine.inputNode
        echo = false
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                if #available(macOS 14.0, *) {
                    input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)
                }
                echo = true
            } catch {
                echo = false
            }
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "the microphone isn't delivering audio"])
        }
        let conv = AVAudioConverter(from: inFormat, to: recogFormat)
        if inFormat.channelCount > 1 { conv?.channelMap = [0] }   // voice-processed input can be multi-channel

        let (eng, pl, pf) = (engine, player, playFormat)
        let wired = avSafe("wire engine") {
            eng.attach(pl)
            eng.connect(pl, to: eng.mainMixerNode, format: pf)
        }
        guard wired else {
            throw NSError(domain: "voice", code: 2, userInfo: [NSLocalizedDescriptionKey: "couldn't connect the audio output"])
        }
        built = true
        guard installInputTap(format: inFormat, converter: conv) else {
            throw NSError(domain: "voice", code: 3, userInfo: [NSLocalizedDescriptionKey: "couldn't open the microphone stream"])
        }
        avSafe("player tap") {
            pl.installTap(onBus: 0, bufferSize: 512, format: pf) { [weak self] buf, _ in
                self?.emit(.speechLevel(VoiceIO.rms(buf)))
            }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    /// Runs on the real-time tap thread: convert, hand to the recogniser, report level.
    @discardableResult
    private func installInputTap(format inFormat: AVAudioFormat, converter conv: AVAudioConverter?) -> Bool {
        let target = recogFormat
        let input = engine.inputNode
        return avSafe("input tap") {
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            guard let self else { return }
            var out: AVAudioPCMBuffer? = buf
            if let conv {
                let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / inFormat.sampleRate) + 32
                out = nil
                if let dst = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) {
                    var fed = false
                    var err: NSError?
                    conv.convert(to: dst, error: &err) { _, status in
                        if fed { status.pointee = .noDataNow; return nil }
                        fed = true
                        status.pointee = .haveData
                        return buf
                    }
                    if err == nil { out = dst }
                }
            }
            self.lock.lock()
            if let out { self.request?.append(out) }
            self.lock.unlock()
            self.emit(.micLevel(VoiceIO.rms(buf)))
        }
        }
    }

    private func restartAfterRouteChange() {
        guard running else { return }
        teardownEngine()
        do {
            try buildEngine(voiceProcessing: true)
        } catch {
            teardownEngine()
            do { try buildEngine(voiceProcessing: false) } catch {
                emit(.fatal("Audio device changed and the mic couldn't restart. " + VoiceIO.explain(error)))
                return
            }
        }
        emit(.engineRestarted(echo: echo))
    }

    /// Core Audio errors in words a person can act on.
    static func explain(_ error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case -10875, -10868:
            return "The Mac's audio hardware wouldn't start for voice. Check Sound settings (input and output device), then try again."
        case -10851:
            return "The microphone format isn't supported. Try a different input device in Sound settings."
        case 561_017_449:  // '!pri' — insufficient priority: another app owns the device
            return "Another app is using the microphone exclusively. Close it and try again."
        default:
            return "Couldn't start audio (\((error as NSError).domain) \(code))."
        }
    }

    /// Undo only what was built — removing a tap from a node that was never
    /// attached raises (that was the crash when hands-free failed at the
    /// permission step and shut down).
    private func teardownEngine() {
        running = false
        guard built else { return }
        built = false
        let (eng, pl, vp) = (engine, player, echo)
        avSafe("teardown") {
            if pl.engine != nil {
                pl.removeTap(onBus: 0)
                pl.stop()
            }
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
            eng.reset()
        }
        // Voice processing ducks every other app's audio (YouTube, Music) while
        // its unit exists — and stopping the engine doesn't remove it. Turn it
        // off and drop the engine so the ducking ends with hands-free.
        if vp {
            _ = avSafe("voice processing off") { try? eng.inputNode.setVoiceProcessingEnabled(false) }
        }
        echo = false
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
    }

    func shutdown(afterSpeech: Bool) {
        q.async { [self] in
            self.endRecognition()
            if afterSpeech && (self.pendingUtterances > 0 || self.outstandingBuffers > 0) {
                self.shutdownAfterSpeech = true              // finish the goodbye first
                return
            }
            self.finalShutdown()
        }
    }

    private func finalShutdown() {
        shutdownAfterSpeech = false
        synth.stopSpeaking(at: .immediate)
        pendingUtterances = 0
        outstandingBuffers = 0
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        teardownEngine()
    }

    // MARK: recognition

    func listen() {
        q.async { [self] in
            guard self.running, let recognizer = self.recognizer else { return }
            self.endRecognition()
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.taskHint = .dictation
            if self.supportsOnDevice { req.requiresOnDeviceRecognition = true }
            self.lock.lock(); self.request = req; self.lock.unlock()
            self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    self.emit(.heard(result.bestTranscription.formattedString, final: result.isFinal))
                } else if error != nil {
                    self.emit(.recognizerStopped)
                }
            }
        }
    }

    func stopListening() { q.async { [self] in self.endRecognition() } }

    private func endRecognition() {
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
        task?.cancel()
        task = nil
    }

    // MARK: speech

    private var rate: Float = 0.52          // queue-confined like everything here
    func setRate(_ r: Float) { q.async { [self] in self.rate = r } }

    func speak(_ text: String) {
        q.async { [self] in
            guard self.running else { return }
            let u = AVSpeechUtterance(string: text)
            u.voice = self.voice
            u.rate = self.rate
            u.postUtteranceDelay = 0.05
            self.pendingUtterances += 1
            self.synth.write(u) { [weak self] buffer in
                guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
                self.q.async { self.play(pcm) }
            }
        }
    }

    private func play(_ pcm: AVAudioPCMBuffer) {
        if pcm.frameLength == 0 {                          // end of one utterance
            pendingUtterances = max(0, pendingUtterances - 1)
            idleCheck()
            return
        }
        guard running, engine.isRunning, let buf = convertForPlayback(pcm) else { return }
        outstandingBuffers += 1
        let pl = player
        let ok = avSafe("schedule speech") {
            pl.scheduleBuffer(buf) { [weak self] in
                guard let self else { return }
                self.q.async {
                    self.outstandingBuffers = max(0, self.outstandingBuffers - 1)
                    self.idleCheck()
                }
            }
            if !pl.isPlaying { pl.play() }
        }
        if !ok { outstandingBuffers = max(0, outstandingBuffers - 1); idleCheck() }
        if !echo { endRecognition() }                     // half-duplex: don't hear ourselves
    }

    private func idleCheck() {
        guard pendingUtterances == 0, outstandingBuffers == 0 else { return }
        if shutdownAfterSpeech { finalShutdown(); return }
        emit(.speechIdle)
    }

    func stopSpeaking() {
        q.async { [self] in
            self.synth.stopSpeaking(at: .immediate)
            let pl = self.player, ready = self.running && self.built && self.engine.isRunning
            avSafe("stop speaking") {
                if pl.engine != nil { pl.stop() }
                if ready { pl.play() }                         // ready for the next utterance
            }
            self.pendingUtterances = 0
            self.outstandingBuffers = 0
            self.emit(.speechLevel(0))
        }
    }

    private func convertForPlayback(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if pcm.format == playFormat { return pcm }
        guard let conv = AVAudioConverter(from: pcm.format, to: playFormat) else { return nil }
        let cap = AVAudioFrameCount(Double(pcm.frameLength) * playFormat.sampleRate / pcm.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return pcm
        }
        return err == nil ? out : nil
    }

    static func rms(_ buf: AVAudioPCMBuffer) -> CGFloat {
        guard let ch = buf.floatChannelData?[0] else { return 0 }
        let n = Int(buf.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return CGFloat(min(1, sqrt(sum / Float(n)) * 10))
    }
}

/// Turns Markdown answers into something worth hearing.
enum SpeechText {
    /// End index of the first sentence boundary at least `minChars` in, or nil.
    static func sentenceCut(_ text: String, minChars: Int = 24) -> String.Index? {
        guard let rx = try? NSRegularExpression(pattern: #"[.!?](\s|$)|\n\n"#) else { return nil }
        let ns = text as NSString
        for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let end = m.range.location + m.range.length
            // Needs a following char (or newline) to be sure the sentence ended —
            // "3." might become "3.5" in the next chunk.
            guard end >= minChars, end < ns.length || text.hasSuffix("\n") else { continue }
            return Range(NSRange(location: 0, length: end), in: text)?.upperBound
        }
        return nil
    }

    static func clean(_ s: String) -> String {
        var t = s
        // Code is for the screen.
        t = t.replacingOccurrences(of: #"```[\s\S]*?(```|$)"#, with: " I've put the code in the notch. ",
                                   options: .regularExpression)
        t = t.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(/Users/[^/\s]+|~)(/[^\s/]+)*/([^\s/]+)"#, with: "$3",
                                   options: .regularExpression)
        // Headings and list items become their own spoken phrases.
        t = t.replacingOccurrences(of: #"(?m)^\s*#{1,6}\s*(.+)$"#, with: "$1.", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?m)^\s*(?:[-*•]|\d+\.)\s+(.+?)[.;:]?$"#, with: "$1.", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\*\*|__|\*|~~)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "_", with: " ")                     // offer_letter → offer letter
        t = t.replacingOccurrences(of: #"[|>#]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\.{2,}"#, with: ".", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Turn-taking and local voice commands — pure, so `checks/run.sh` tests them.
enum VoiceTurn {
    /// The assistant's name — the standby wake word and a prefix commands may start with.
    nonisolated(unsafe) static var wakeName: String = UserDefaults.standard.string(forKey: "assistantName") ?? "Ledge"

    /// Short "still working" fillers, rotated so none repeats back to back.
    static let fillers = ["One moment.", "Let me check.", "On it.", "Just a sec.", "Looking into it.",
                          "Give me a second.", "Working on it.", "Hmm, let me see.", "Checking now.", "Bear with me."]

    static func filler(avoiding last: inout Int) -> String {
        var i = Int.random(in: 0..<fillers.count)
        if i == last { i = (i + 1 + Int.random(in: 0..<(fillers.count - 1))) % fillers.count }
        last = i
        return fillers[i]
    }

    /// Words people trail off on mid-thought: wait longer before sending.
    static let trailing: Set<String> = [
        "and", "or", "but", "so", "because", "cause", "um", "uh", "er", "hmm", "like",
        "the", "a", "an", "to", "for", "with", "of", "in", "on", "at", "from", "about",
        "my", "your", "this", "that", "then", "also", "if", "when", "which", "is", "are",
    ]

    /// How long a pause means "I'm done" for what has been heard so far.
    /// A fixed 1.2s cut people off mid-thought and felt slow after a clear
    /// question; this waits for trailing words and answers finished ones sooner.
    static func silenceNeeded(_ transcript: String) -> TimeInterval {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
        guard let last = words.last.map(String.init) else { return 1.2 }
        if t.hasSuffix(",") || trailing.contains(last) { return 2.3 }
        if words.count <= 2 { return 1.5 }            // "what's the…" — give room to go on
        if t.hasSuffix("?") || t.hasSuffix(".") { return 0.8 }
        return 1.1
    }

    enum Command: Equatable {
        case exit, cancel, stopTalking, repeatLast, slower, faster, newChat, show
    }

    /// Only whole-utterance matches (after trimming filler/punctuation), so
    /// "stop the dev server" or "repeat that test" still go to Ledge.
    static func command(_ text: String) -> Command? {
        var t = text.lowercased().replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        let n = wakeName.lowercased()
        for p in ["\(n) ", "hey \(n) ", "okay ", "ok ", "please "] where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count))
        }
        for s in [" please", " \(n)"] where t.hasSuffix(s) { t = String(t.dropLast(s.count)) }
        let exits = ["stop listening", "goodbye", "good bye", "that's all", "that is all",
                     "exit hands free", "go to sleep", "bye \(n)", "bye", "turn off hands free"]
        if exits.contains(t) || t.hasSuffix(" goodbye") { return .exit }
        switch t {
        case "never mind", "nevermind", "cancel", "forget it", "cancel that": return .cancel
        case "stop", "stop talking", "shut up", "quiet", "be quiet", "enough": return .stopTalking
        case "repeat", "repeat that", "say that again", "come again", "what did you say", "pardon": return .repeatLast
        case "slower", "speak slower", "talk slower", "slow down": return .slower
        case "faster", "speak faster", "talk faster", "speed up": return .faster
        case "new chat", "start over", "new conversation", "clear the chat": return .newChat
        case "show me", "show it", "open the notch", "show me on screen": return .show
        default: return nil
        }
    }

    // MARK: Approvals by voice

    /// "yes" / "go ahead" → true, "no" / "cancel" → false, anything else → nil (ask again).
    static func approvalAnswer(_ text: String) -> Bool? {
        var t = text.lowercased().replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        let n = wakeName.lowercased()
        for p in ["\(n) ", "hey \(n) ", "um ", "uh ", "well "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        let no = ["no", "nope", "nah", "don't", "dont", "do not", "deny", "cancel", "stop", "never mind", "nevermind",
                  "no thanks", "don't do it", "not now", "skip", "no way", "don't run it", "not allowed"]
        let yes = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "go ahead", "do it", "allow", "approve", "approved",
                   "yes please", "go for it", "sounds good", "fine", "proceed", "continue", "run it", "yes go ahead", "please do"]
        // "No" wins ties ("yes— no, don't"): saying no should always be safe.
        if no.contains(where: { t == $0 || t.hasPrefix($0 + " ") || t.hasSuffix(" " + $0) }) { return false }
        if yes.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) { return true }
        return nil
    }

    /// What Zoe says when a tool needs permission: plain words from the tool's arguments.
    static func approvalPhrase(tool: String, args: [String: String]) -> String {
        func short(_ s: String?, _ n: Int = 50) -> String {
            let v = (s ?? "").replacingOccurrences(of: "\n", with: " ")
            return v.count > n ? String(v.prefix(n)) + "…" : v
        }
        func file(_ p: String?) -> String { ((p ?? "") as NSString).lastPathComponent }
        let what: String
        switch tool {
        case "run_command":
            let cmd = short(args["command"], 40)
            what = cmd.isEmpty ? "run a terminal command" : "run a command: \(cmd)"
        case "write_file": what = "write the file \(file(args["path"]))"
        case "edit_file": what = "edit \(file(args["path"]))"
        case "create_event": what = "add “\(short(args["title"]))” to your calendar"
        case "create_reminder": what = "add a reminder: \(short(args["title"]))"
        case "mail_draft": what = "open an email draft to \(short(args["to"], 40))"
        case "notes_create": what = "create a note called “\(short(args["title"]))”"
        case "schedule_task": what = "schedule this: \(short(args["prompt"]))"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.components(separatedBy: "__")
                what = "use \(parts.count > 1 ? parts[1] : "a connector") to \(parts.last?.replacingOccurrences(of: "_", with: " ") ?? "do something")"
            } else {
                what = "use \(tool.replacingOccurrences(of: "_", with: " "))"
            }
        }
        return "I need your OK to \(what). Say yes to go ahead, or no."
    }

    /// Two-word label for the closed notch: "Run command", "Edit file" …
    static func approvalShort(_ tool: String) -> String {
        switch tool {
        case "run_command": return "Run command"
        case "write_file": return "Write file"
        case "edit_file": return "Edit file"
        case "create_event": return "Add event"
        case "create_reminder": return "Add reminder"
        case "mail_draft": return "Email draft"
        case "notes_create": return "New note"
        case "schedule_task": return "Schedule"
        default: return tool.hasPrefix("mcp__") ? (tool.components(separatedBy: "__").dropFirst().first ?? "Connector") : "Allow tool"
        }
    }

    /// Progress notices for a long turn, so the user knows it's still going.
    /// Level 1 at 20s, 2 at 60s, then one more each further minute. Returns
    /// nil before 20s. `tool` is what's running now ("" if between tools).
    static func slowNotice(elapsed: TimeInterval, tool: String) -> (level: Int, text: String)? {
        guard elapsed >= 20 else { return nil }
        let minutes = Int(elapsed / 60)
        let level = elapsed < 60 ? 1 : 1 + minutes
        let base: String
        switch level {
        case 1: base = "This is taking longer than expected — I'm still working on it."
        case 2: base = "Still working on it — about a minute so far."
        default: base = "Still going — \(minutes) minutes so far. Say cancel or press stop if you'd like me to stop."
        }
        let t = tool.trimmingCharacters(in: .whitespaces)
        let now = t.isEmpty ? "" : " Right now: \(t.replacingOccurrences(of: "_", with: " ").lowercased())."
        return (level, base + now)
    }

    /// A few words to say while a tool runs, so a long turn isn't dead air.
    /// nil = say nothing (fast or self-explanatory tools).
    static func toolPhrase(_ verb: String) -> String? {
        let v = verb.lowercased()
        let map: [([String], String)] = [
            (["media", "music", "spotify"], ""),
            (["gmail", "mail", "inbox"], "Checking your email."),
            (["calendar", "event", "reminder"], "Checking your calendar."),
            (["computer_use"], "Taking the screen for a moment."),
            (["open_on_mac"], ""),
            (["web", "browser", "fetch", "http"], "Looking that up."),
            (["search_documents", "find_files", "search_files", "read_file", "read_pdf", "list_directory", "file"], "Looking through your files."),
            (["run_command", "run_python", "run_tests", "process"], "Running that now."),
            (["remember", "memory"], ""),
        ]
        for (keys, phrase) in map where keys.contains(where: { v.contains($0) }) {
            return phrase.isEmpty ? nil : phrase
        }
        return nil
    }
}
