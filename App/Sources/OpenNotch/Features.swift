import AppKit
import AVFoundation
import OpenNotchObjC
import Speech

/// Push-to-talk dictation, on-device when the Mac supports it.
///
/// Same threading rule as hands-free: all audio on `q`, results hop back with
/// `DispatchQueue.main.async`, never audio work inside a main-actor Task.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var level: CGFloat = 0          // 0…1, drives the waveform
    @Published private(set) var transcript = ""

    var onFinish: ((String) -> Void)?
    /// Ended with nothing heard.
    var onEmpty: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Return false to refuse (e.g. hands-free already owns the mic).
    var canStart: (() -> Bool)?
    /// macOS is about to show a permission prompt — get out of its way.
    var willPrompt: (() -> Void)?

    private let q = DispatchQueue(label: "opennotch.dictation", qos: .userInitiated)
    private let io = DictationIO()
    private var stopping = false
    private var starting = false

    func toggle() { listening ? stop() : start() }

    func start() {
        guard !listening, !starting else { return }
        if let canStart, !canStart() { return }
        starting = true
        if Permissions.needsPrompt { willPrompt?() }
        Permissions.speechAndMic { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error { self.starting = false; self.onError?(error); return }
                self.transcript = ""
                self.stopping = false
                self.io.start(
                    onText: { [weak self] text, final in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.transcript = text
                            if final { self.finish() }
                        }
                    },
                    onLevel: { [weak self] l in MainActor.assumeIsolated { self?.level = l } },
                    onEnded: { [weak self] in MainActor.assumeIsolated { self?.finish() } },
                    done: { [weak self] error in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.starting = false
                            if let error { self.onError?(error) } else { self.listening = true }
                        }
                    })
            }
        }
    }

    func stop() {
        guard listening else { return }
        stopping = true
        listening = false
        level = 0
        io.endAudio()
        // If the recogniser never sends a final result, don't hang.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    private func finish() {
        guard stopping || listening else { return }
        stopping = false
        listening = false
        level = 0
        io.cancel()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onFinish?(text) } else { onEmpty?() }
        transcript = ""
    }
}

/// Dictation's audio, confined to one queue.
final class DictationIO: @unchecked Sendable {
    private let q = DispatchQueue(label: "opennotch.dictation.io", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start(onText: @escaping @Sendable (String, Bool) -> Void,
               onLevel: @escaping @Sendable (CGFloat) -> Void,
               onEnded: @escaping @Sendable () -> Void,
               done: @escaping @Sendable (String?) -> Void) {
        q.async { [self] in
            guard let recognizer = self.recognizer, recognizer.isAvailable else {
                DispatchQueue.main.async { done("Speech recognition isn't available right now.") }
                return
            }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            self.lock.lock(); self.request = req; self.lock.unlock()

            let input = self.engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                DispatchQueue.main.async { done("The microphone isn't delivering audio.") }
                return
            }
            let tapped = avSafe("dictation tap") {
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                    guard let self else { return }
                    self.lock.lock(); self.request?.append(buf); self.lock.unlock()
                    let lvl = VoiceIO.rms(buf)
                    DispatchQueue.main.async { onLevel(min(1, lvl * 1.2)) }
                }
            }
            guard tapped else {
                DispatchQueue.main.async { done("Couldn't open the microphone stream.") }
                return
            }
            do {
                self.engine.prepare()
                try self.engine.start()
            } catch {
                avSafe("dictation cleanup") { input.removeTap(onBus: 0) }
                DispatchQueue.main.async { done("Couldn't start the microphone: \(error.localizedDescription)") }
                return
            }
            self.task = recognizer.recognitionTask(with: req) { result, error in
                if let result {
                    let text = result.bestTranscription.formattedString
                    let final = result.isFinal
                    DispatchQueue.main.async { onText(text, final) }
                } else if error != nil {
                    DispatchQueue.main.async { onEnded() }
                }
            }
            DispatchQueue.main.async { done(nil) }
        }
    }

    /// Stop capturing; the recogniser delivers its final result after this.
    func endAudio() {
        q.async { [self] in
            let eng = self.engine
            avSafe("dictation stop") { eng.stop(); eng.inputNode.removeTap(onBus: 0) }
            self.lock.lock(); self.request?.endAudio(); self.request = nil; self.lock.unlock()
        }
    }

    func cancel() {
        q.async { [self] in
            let eng = self.engine
            if eng.isRunning { avSafe("dictation cancel") { eng.stop(); eng.inputNode.removeTap(onBus: 0) } }
            self.task?.cancel()
            self.task = nil
        }
    }
}

enum ScreenGrab {
    /// Full-screen PNG of the main display with the notch panel hidden, or nil.
    @MainActor
    static func capture(hiding panel: NSWindow) async -> String? {
        let dir = "\(AppPaths.root)/shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let path = "\(dir)/screen-\(fmt.string(from: Date())).png"

        let alpha = panel.alphaValue
        panel.alphaValue = 0
        defer { panel.alphaValue = alpha }
        try? await Task.sleep(nanoseconds: 120_000_000)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-m", path]
        do { try p.run() } catch { return nil }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { p.waitUntilExit(); c.resume() }
        }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
}

enum Chime {
    static func done() { play("Tink", 0.35) }
    static func attention() { play("Glass", 0.4) }
    private static func play(_ name: String, _ volume: Float) {
        guard let s = NSSound(named: NSSound.Name(name)) else { return }
        s.volume = volume
        s.play()
    }
}
