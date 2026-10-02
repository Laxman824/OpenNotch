import AppKit
import ApplicationServices
import Carbon.HIToolbox

// Dictation anywhere: hold ⌥⇧D, talk, let go — the words are typed into
// whatever app you're in (Slack, Mail, a code comment…). A quick tap starts
// hands-off dictation instead; tap again to finish. Speech is recognised on the
// Mac (the existing `Dictation`); if an AI is connected the text gets a quick
// polish first (punctuation, fillers out), never more than ~4 s.

/// Pure rules (checked by `--checks`).
enum DictateLogic {
    /// Held at least this long = hold-to-talk; shorter = tap to toggle.
    static let holdThreshold: TimeInterval = 0.35

    static func polishPrompt(_ text: String) -> String {
        """
        Clean up this dictated text. Fix punctuation and capitalisation, remove filler words (um, uh, like, \
        you know) and false starts, keep the speaker's own words, language and meaning. Don't add, answer or \
        explain anything. Reply with only the cleaned text.

        \(text)
        """
    }

    /// Accept the model's polish only if it still looks like the same text (not an answer to it).
    static func acceptPolish(original: String, polished: String) -> Bool {
        let p = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        let ratio = Double(p.count) / Double(max(1, original.count))
        guard ratio > 0.5 && ratio < 1.4 else { return false }
        // Most of the spoken words should still be there.
        let words = Set(original.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 3 })
        guard !words.isEmpty else { return true }
        let kept = words.filter { p.lowercased().contains($0) }.count
        return Double(kept) / Double(words.count) >= 0.6
    }

    /// Rough words in a string (for the value ledger).
    static func wordCount(_ s: String) -> Int { s.split { $0.isWhitespace || $0.isNewline }.count }
}

@MainActor
final class DictateAnywhere {
    weak var dictation: Dictation?
    weak var backend: Backend?
    weak var notch: NotchController?
    weak var hub: Hub?

    /// Whether the current dictation is for another app (vs. the chat).
    private(set) var active = false
    private var pressedAt: Date?
    private var toggled = false
    private var target: NSRunningApplication?

    static let pref = "dictate.polish"
    static var polish: Bool { UserDefaults.standard.object(forKey: pref) as? Bool ?? true }

    /// ⌥⇧D went down.
    func keyDown() {
        guard let dictation else { return }
        if active && toggled {                         // second tap: finish hands-off dictation
            toggled = false
            dictation.stop()
            return
        }
        guard !dictation.listening else { return }
        if let can = dictation.canStart, !can() { return }          // hands-free owns the mic (it says so)
        target = NSWorkspace.shared.frontmostApplication
        if target?.bundleIdentifier == Bundle.main.bundleIdentifier { target = nil }
        active = true
        pressedAt = Date()
        dictation.start()
        notch?.showAlert(.info(icon: "mic.fill", text: "Listening… let go of ⌥⇧D to type it"), for: 30)
    }

    /// ⌥⇧D came up.
    func keyUp() {
        guard active, let pressedAt, let dictation else { return }
        self.pressedAt = nil
        if Date().timeIntervalSince(pressedAt) < DictateLogic.holdThreshold {
            toggled = true                              // a tap: keep listening until the next tap
            notch?.showAlert(.info(icon: "mic.fill", text: "Dictating — tap ⌥⇧D again when you're done"), for: 120)
        } else {
            dictation.stop()
        }
    }

    /// Dictation produced text (or failed): type it into the app you were in.
    func finished(_ text: String) {
        active = false
        toggled = false
        notch?.collapse()
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        ValueLedger.shared.add(.dictatedWords, DictateLogic.wordCount(raw))
        guard let backend, Self.polish, backend.aiConnected, DictateLogic.wordCount(raw) >= 4 else { insert(raw); return }
        Task { @MainActor in
            let polished = await withTaskGroup(of: String?.self) { g -> String? in
                g.addTask { try? await backend.core.complete(DictateLogic.polishPrompt(raw), system: "You clean up dictated text.") }
                g.addTask { try? await Task.sleep(nanoseconds: 4_000_000_000); return nil }   // never make you wait long
                let first = await g.next() ?? nil
                g.cancelAll()
                return first
            }
            let final = polished.flatMap { DictateLogic.acceptPolish(original: raw, polished: $0) ? $0 : nil } ?? raw
            self.insert(final.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func cancelled() {
        active = false
        toggled = false
    }

    /// Paste into the target app, then put the clipboard back.
    private func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        } ?? []
        hub?.clipboard.suppressNextChange(for: 3)
        pb.clearContents()
        pb.setString(text, forType: .string)
        guard AXIsProcessTrusted() else {
            backend?.notice("Copied what you said — press ⌘V. (Allow OpenNotch in Privacy › Accessibility to type it for you.)")
            return
        }
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let v = CGKeyCode(kVK_ANSI_V)
            let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            // Give the app a moment to read the clipboard, then restore what you had.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.hub?.clipboard.suppressNextChange(for: 2)
                pb.clearContents()
                if !saved.isEmpty {
                    pb.writeObjects(saved.map { d -> NSPasteboardItem in
                        let item = NSPasteboardItem()
                        for (t, data) in d { item.setData(data, forType: t) }
                        return item
                    })
                }
            }
        }
    }
}
