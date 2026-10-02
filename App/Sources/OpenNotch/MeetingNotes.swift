import AppKit
import AVFoundation
import ScreenCaptureKit
import Speech

// Meeting notes without a bot joining the call. When a call starts in Zoom,
// Teams, Meet (a browser), Webex, FaceTime, Slack or Discord, Ledge offers to
// take notes — it never starts on its own. Audio is the Mac's own output
// (ScreenCaptureKit, the other people) plus, on macOS 15+, your microphone;
// both are transcribed **on the Mac**. When the call ends the transcript is
// saved locally and, if an AI is connected, summarised: decisions, action
// items, open questions. Only that summary request leaves the Mac.

enum MeetingLogic {
    /// Apps whose mic use means "a call" (PrivacyMonitor reports display names).
    static let callApps = ["zoom.us", "zoom", "microsoft teams", "teams", "webex", "facetime", "slack", "discord",
                           "google chrome", "arc", "safari", "brave browser", "microsoft edge", "firefox", "whatsapp", "skype"]

    /// The call app among the ones using the mic, if any.
    static func callApp(_ micApps: [String]) -> String? {
        micApps.first { app in callApps.contains { app.lowercased() == $0 || app.lowercased().hasPrefix($0 + " ") } }
    }

    static func summaryPrompt(transcript: String, app: String, minutes: Int) -> String {
        """
        Below is the transcript of a \(minutes)-minute call on \(app). "You" is me; "Them" is everyone else \
        (the transcript can't tell them apart). Write my meeting notes:

        **Summary** — 2–4 sentences.
        **Decisions** — bullets (or "None").
        **Action items** — bullets as "Who — what — when" (use "Me" for mine; "?" when unclear).
        **Open questions** — bullets (or "None").

        Use only what's in the transcript; transcription has errors, so don't invent names or numbers.

        Transcript:
        \(transcript)
        """
    }

    /// The transcript sent for summarising: the whole thing if it fits, else the start and the end.
    static func clip(_ transcript: String, max: Int = 60_000) -> String {
        guard transcript.count > max else { return transcript }
        return String(transcript.prefix(max / 3)) + "\n\n[… middle of the call omitted …]\n\n" + String(transcript.suffix(max * 2 / 3))
    }

    static func fileName(_ d: Date, app: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let safe = app.replacingOccurrences(of: "[^A-Za-z0-9 ]", with: "", options: .regularExpression)
        return "\(f.string(from: d)) \(safe).md"
    }
}

/// The audio side: one SCStream and up to two on-device recognisers, all on `q`.
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let q = DispatchQueue(label: "opennotch.meeting", qos: .userInitiated)
    private var stream: SCStream?
    private var them: Transcriber?
    private var me: Transcriber?

    /// `onLine(speaker, text)` arrives on the main queue.
    func start(withMic: Bool, onLine: @escaping @Sendable (String, String) -> Void, done: @escaping @Sendable (String?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            guard let display = content?.displays.first else {
                done(error?.localizedDescription ?? "Couldn't see the screen to capture its sound.")
                return
            }
            self.q.async {
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 16_000
                config.channelCount = 1
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                var mic = false
                if #available(macOS 15.0, *), withMic { config.captureMicrophone = true; mic = true }
                let s = SCStream(filter: filter, configuration: config, delegate: self)
                do {
                    try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.q)
                    if #available(macOS 15.0, *), mic { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: self.q) }
                } catch {
                    done(error.localizedDescription)
                    return
                }
                self.them = Transcriber(label: "Them", onLine: onLine)
                if mic { self.me = Transcriber(label: "You", onLine: onLine) }
                self.stream = s
                s.startCapture { err in done(err?.localizedDescription) }
            }
        }
    }

    func stop(_ finished: @escaping @Sendable () -> Void) {
        q.async {
            self.stream?.stopCapture { _ in }
            self.stream = nil
            self.them?.finish()
            self.me?.finish()
            // Let the last segments come back.
            self.q.asyncAfter(deadline: .now() + 2.5) {
                self.them = nil
                self.me = nil
                finished()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch type {
        case .audio: them?.append(buffer)
        default:
            if #available(macOS 15.0, *), type == .microphone { me?.append(buffer) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppLog.write("meeting capture stopped: \(error.localizedDescription)")
    }
}

/// One speaker's audio → text, on-device, in ~55 s segments (long requests get cut off).
final class Transcriber: @unchecked Sendable {
    private let label: String
    private let onLine: @Sendable (String, String) -> Void
    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var started = Date()

    init(label: String, onLine: @escaping @Sendable (String, String) -> Void) {
        self.label = label
        self.onLine = onLine
        begin()
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }
        r.addsPunctuation = true
        let label = self.label, onLine = self.onLine
        task = recognizer.recognitionTask(with: r) { result, error in
            if let error, ProcessInfo.processInfo.environment["OPENNOTCH_DEBUG_NOTES"] != nil { print("recognizer:", error.localizedDescription) }
            guard let result, result.isFinal else { return }
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { DispatchQueue.main.async { onLine(label, text) } }
        }
        request = r
        started = Date()
    }

    /// Called on the recorder's queue.
    private(set) var buffers = 0
    func append(_ buffer: CMSampleBuffer) {
        buffers += 1
        if Date().timeIntervalSince(started) > 55 {          // roll over to a fresh segment
            request?.endAudio()
            begin()
        }
        request?.appendAudioSampleBuffer(buffer)
    }

    func finish() {
        request?.endAudio()
        request = nil
    }
}

/// The feature: offer, record, stop when the call ends, summarise, propose.
@MainActor
final class MeetingNotes: ObservableObject {
    static let shared = MeetingNotes()
    static let pref = "meeting.offer"
    static var offerEnabled: Bool { UserDefaults.standard.object(forKey: pref) as? Bool ?? true }

    @Published private(set) var recordingApp: String?
    weak var notch: NotchController?
    weak var backend: Backend?
    weak var proactive: ProactiveEngine?

    private let recorder = MeetingRecorder()
    private var lines: [String] = []
    private var started = Date()
    private var watch: Timer?
    private var quietPolls = 0
    private var offeredFor: Date?

    /// A call just started (Attention saw the mic/camera go on).
    func callStarted(micApps: [String]) {
        guard Self.offerEnabled, recordingApp == nil, let app = MeetingLogic.callApp(micApps) else { return }
        if let t = offeredFor, Date().timeIntervalSince(t) < 10 * 60 { return }
        offeredFor = Date()
        Presence.shared.offer(Nudge(kind: .callNotes, icon: "waveform.badge.mic", title: "Take notes for this \(app) call?",
                                    detail: "Transcribed on your Mac. Let the others know you're taking notes.",
                                    actionLabel: "Take notes", action: .startNotes(app)))
    }

    func start(app: String) {
        guard recordingApp == nil else { return }
        if !CGPreflightScreenCaptureAccess() {
            notch?.yieldForSystemPrompt("Screen & System Audio Recording")
            if !CGRequestScreenCaptureAccess() {
                backend?.notice("To take call notes, allow OpenNotch in System Settings › Privacy & Security › Screen & System Audio Recording, then try again.")
                return
            }
        }
        if Permissions.needsPrompt { notch?.yieldForSystemPrompt("Speech Recognition") }
        Permissions.speechAndMic { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error { self.backend?.notice(error); return }
                self.lines = []
                self.started = Date()
                self.recordingApp = app
                self.recorder.start(withMic: true, onLine: { [weak self] who, text in
                    MainActor.assumeIsolated { self?.lines.append("**\(who):** \(text)") }
                }, done: { [weak self] err in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            if let err {
                                self.recordingApp = nil
                                self.backend?.notice("Couldn't start call notes: \(err)")
                            } else {
                                self.notch?.showAlert(.info(icon: "record.circle", text: "Taking notes · \(app) — stops when the call ends"), for: 5)
                                self.watchForEnd()
                            }
                        }
                    }
                })
            }
        }
    }

    /// The call ended when the mic and camera have been free for ~30 s.
    private func watchForEnd() {
        quietPolls = 0
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.recordingApp != nil else { return }
                let busy = self.notch?.privacy.micApps.contains { $0 != "OpenNotch" } ?? false
                self.quietPolls = busy ? 0 : self.quietPolls + 1
                if self.quietPolls >= 3 { self.stop() }
            }
        }
    }

    func stop() {
        guard let app = recordingApp else { return }
        watch?.invalidate(); watch = nil
        recordingApp = nil
        let started = self.started
        recorder.stop { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.wrapUp(app: app, started: started) } }
        }
    }

    private func wrapUp(app: String, started: Date) {
        let minutes = max(1, Int(Date().timeIntervalSince(started) / 60))
        let transcript = lines.joined(separator: "\n\n")
        guard !transcript.isEmpty else {
            backend?.notice("The call ended, but I didn't catch any speech to take notes from.")
            return
        }
        let path = opennotchDir("meetings") + "/" + MeetingLogic.fileName(started, app: app)
        let header = "# \(app) call — \(DateFormatter.localizedString(from: started, dateStyle: .medium, timeStyle: .short)) (\(minutes) min)\n\n"
        try? (header + "## Transcript\n\n" + transcript + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        ValueLedger.shared.add(.meetingNotes)
        guard let backend, backend.aiConnected else {
            proactive?.proposeNotes(app: app, body: "Transcript saved to \(path). Connect an AI in Settings › AI to get summaries.")
            return
        }
        let prompt = MeetingLogic.summaryPrompt(transcript: MeetingLogic.clip(transcript), app: app, minutes: minutes)
        Task { @MainActor in
            let notes = (try? await backend.core.complete(prompt, system: "You write accurate, concise meeting notes.")) ?? ""
            if !notes.isEmpty {
                try? (header + notes + "\n\n## Transcript\n\n" + transcript + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
            self.proactive?.proposeNotes(app: app, body: (notes.isEmpty ? "I couldn't summarise this one." : notes)
                                         + "\n\n_Full transcript: \(path)_")
        }
    }
}
