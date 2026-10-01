import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (macOS 26+, Apple Intelligence Macs): free, private,
/// offline. Small context, so it gets a trimmed transcript and no tools yet.
struct AppleOnDeviceProvider: ChatProvider {
    let name = "Apple on-device"
    let model = "Apple Intelligence"
    var isConnected: Bool { Self.availability == nil }
    let supportsTools = false
    let supportsImages = false

    /// nil when usable, else why not.
    static var availability: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri, then try again."
            case .unavailable(.modelNotReady): return "Apple's on-device model is still downloading — try again in a while."
            case .unavailable(let reason): return "Apple Intelligence isn't available (\(reason))."
            @unknown default: return "Apple Intelligence isn't available."
            }
        }
        return "Needs macOS 26 or later."
        #else
        return "This build doesn't include Apple's on-device model."
        #endif
    }

    func turn(system: String, messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    do {
                        // Recent turns as plain text; the last user message is the prompt.
                        let recent = messages.filter { $0.role == .user || $0.role == .assistant }.suffix(8)
                        var history = ""
                        for m in recent.dropLast() {
                            history += (m.role == .user ? "User: " : "Assistant: ") + String(m.text.prefix(1500)) + "\n"
                        }
                        let prompt = (history.isEmpty ? "" : "Conversation so far:\n\(history)\n")
                            + (recent.last?.text ?? "")
                        let session = LanguageModelSession(instructions: system)
                        var sent = ""
                        for try await snapshot in session.streamResponse(to: prompt) {
                            let full = snapshot.content
                            if full.count > sent.count, full.hasPrefix(sent) {
                                c.yield(.text(String(full.dropFirst(sent.count))))
                            }
                            sent = full
                        }
                        c.yield(.stop(reason: "end_turn"))
                        c.finish()
                    } catch {
                        c.finish(throwing: ProviderError(message: "Apple on-device model: \(error.localizedDescription)"))
                    }
                    return
                }
                #endif
                c.finish(throwing: ProviderError(message: Self.availability ?? "Unavailable"))
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}
