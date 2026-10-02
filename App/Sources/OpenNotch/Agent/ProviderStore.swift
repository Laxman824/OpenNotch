import Foundation
import Security

/// API keys live in the login Keychain — never in files or UserDefaults.
enum Keychain {
    private static let service = "dev.opennotch.OpenNotch.keys"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

/// Every way OpenNotch can reach a model.
enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case openrouter, openai, anthropic, gemini, groq, ollama, lmstudio, apple
    var id: String { rawValue }

    var label: String {
        switch self {
        case .openrouter: return "OpenRouter"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic (Claude)"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .ollama: return "Ollama (local)"
        case .lmstudio: return "LM Studio (local)"
        case .apple: return "Apple on-device"
        }
    }

    var needsKey: Bool { ![.ollama, .lmstudio, .apple].contains(self) }
    var isLocal: Bool { [.ollama, .lmstudio, .apple].contains(self) }

    var baseURL: URL? {
        switch self {
        case .openrouter: return URL(string: "https://openrouter.ai/api/v1")
        case .openai: return URL(string: "https://api.openai.com/v1")
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")
        case .groq: return URL(string: "https://api.groq.com/openai/v1")
        case .ollama: return URL(string: "http://127.0.0.1:11434/v1")
        case .lmstudio: return URL(string: "http://127.0.0.1:1234/v1")
        case .anthropic, .apple: return nil
        }
    }

    /// Where to get a key (Settings links here).
    var keyPage: URL? {
        switch self {
        case .openrouter: return URL(string: "https://openrouter.ai/keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .ollama: return URL(string: "https://ollama.com/download")
        case .lmstudio: return URL(string: "https://lmstudio.ai")
        case .apple: return nil
        }
    }

    /// Preferred models, best first; the first one the account actually lists wins.
    var preferredModels: [String] {
        switch self {
        case .openrouter: return ["openrouter/auto"]
        case .anthropic: return AnthropicProvider.knownModels
        case .openai: return ["gpt-5.5", "gpt-5.1", "gpt-5", "gpt-4.1", "gpt-4o"]
        case .gemini: return ["gemini-flash-latest", "gemini-2.5-flash", "gemini-pro-latest"]
        case .groq: return ["openai/gpt-oss-120b", "llama-3.3-70b-versatile"]
        case .ollama, .lmstudio, .apple: return []
        }
    }

    static func pickDefault(_ kind: ProviderKind, from available: [String]) -> String? {
        if kind == .openrouter { return "openrouter/auto" }
        for want in kind.preferredModels {
            if let hit = available.first(where: { $0 == want }) ?? available.first(where: { $0.hasPrefix(want) }) { return hit }
        }
        if kind == .anthropic { return AnthropicProvider.defaultModel }
        return available.first
    }
}

/// Which provider/model is active, and building the provider for it.
enum ProviderStore {
    private static let kindKey = "ai.provider"
    private static func modelKey(_ k: ProviderKind) -> String { "ai.model.\(k.rawValue)" }

    static var activeKind: ProviderKind? {
        get { UserDefaults.standard.string(forKey: kindKey).flatMap(ProviderKind.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: kindKey) }
    }

    static func model(for k: ProviderKind) -> String? { UserDefaults.standard.string(forKey: modelKey(k)) }
    static func setModel(_ m: String, for k: ProviderKind) { UserDefaults.standard.set(m, forKey: modelKey(k)) }

    static func key(for k: ProviderKind) -> String? { Keychain.get(k.rawValue) }

    /// The provider for the active selection, or the "connect an AI" stand-in.
    static func make() -> ChatProvider {
        guard let k = activeKind else { return NotConnectedProvider() }
        return make(k, model: model(for: k), key: key(for: k)) ?? NotConnectedProvider()
    }

    static func make(_ k: ProviderKind, model: String?, key: String?) -> ChatProvider? {
        switch k {
        case .apple:
            return AppleOnDeviceProvider()
        case .anthropic:
            guard let key, !key.isEmpty else { return nil }
            return AnthropicProvider(model: model ?? AnthropicProvider.defaultModel, apiKey: key)
        default:
            guard let base = k.baseURL, let model, !model.isEmpty else { return nil }
            if k.needsKey && (key ?? "").isEmpty { return nil }
            var headers: [String: String] = [:]
            if k == .openrouter {
                headers = ["HTTP-Referer": "https://github.com/Laxman824/OpenNotch", "X-Title": "OpenNotch"]
            }
            return OpenAICompatibleProvider(name: k.label, model: model, baseURL: base, apiKey: key,
                                            extraHeaders: headers,
                                            usageInStream: [.openai, .openrouter, .groq].contains(k),
                                            supportsImages: ![.groq].contains(k),
                                            requestReasoning: k == .openrouter,
                                            maxTokens: k == .openrouter ? 16_000 : nil,
                                            contextChars: k.isLocal ? 24_000 : 300_000)
        }
    }

    /// OpenRouter's router across whatever free models are up (price 0, supports tools).
    static let openRouterFree = "openrouter/free"

    /// Does this OpenRouter key have no paid credit? (Then paid models fail with
    /// "requires more credits" — use the free router instead.) nil = couldn't tell.
    static func openRouterFreeTier(key: String) async -> Bool? {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        req.timeoutInterval = 10
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await HTTP.session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let d = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any] else { return nil }
        if let free = d["is_free_tier"] as? Bool, free { return true }
        if let left = d["limit_remaining"] as? Double, left <= 0 { return true }
        return false
    }

    /// Free and private by default: Apple's on-device model when nothing is set up yet.
    /// Returns true if it picked one.
    @discardableResult
    static func adoptFreeDefault() -> Bool {
        guard activeKind == nil, AppleOnDeviceProvider.availability == nil else { return false }
        activeKind = .apple
        return true
    }

    /// Checks a key/endpoint by listing models. Returns the models on success.
    static func test(_ k: ProviderKind, key: String?) async throws -> [String] {
        switch k {
        case .apple:
            if let why = AppleOnDeviceProvider.availability { throw ProviderError(message: why) }
            return ["Apple Intelligence"]
        case .anthropic:
            return try await AnthropicProvider.listModels(apiKey: key ?? "")
        default:
            guard let base = k.baseURL else { return [] }
            let models = try await OpenAICompatibleProvider.listModels(baseURL: base, apiKey: key)
            if k.isLocal && models.isEmpty {
                throw ProviderError(message: "\(k.label) is running but has no models yet — download one first.")
            }
            return models.sorted()
        }
    }
}
