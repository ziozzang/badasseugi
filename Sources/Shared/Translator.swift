import Foundation
import Translation

enum TranslatorKind: String, CaseIterable, Identifiable {
    case llm = "LLM"
    case apple = "Apple"
    case google = "Google"
    var id: String { rawValue }
}

struct Language: Hashable, Identifiable {
    let code: String      // BCP-47, used for Apple/Google and speech locale mapping
    let name: String      // English name, used in LLM prompts
    let label: String     // UI label
    var id: String { code }

    static let all: [Language] = [
        .init(code: "ko", name: "Korean", label: "한국어"),
        .init(code: "en", name: "English", label: "English"),
        .init(code: "ja", name: "Japanese", label: "日本語"),
        .init(code: "zh-Hans", name: "Simplified Chinese", label: "中文(简体)"),
        .init(code: "zh-Hant", name: "Traditional Chinese", label: "中文(繁體)"),
        .init(code: "es", name: "Spanish", label: "Español"),
        .init(code: "fr", name: "French", label: "Français"),
        .init(code: "de", name: "German", label: "Deutsch"),
        .init(code: "it", name: "Italian", label: "Italiano"),
        .init(code: "pt", name: "Portuguese", label: "Português"),
        .init(code: "ru", name: "Russian", label: "Русский"),
        .init(code: "vi", name: "Vietnamese", label: "Tiếng Việt"),
        .init(code: "th", name: "Thai", label: "ไทย"),
        .init(code: "id", name: "Indonesian", label: "Bahasa Indonesia"),
        .init(code: "ar", name: "Arabic", label: "العربية"),
        .init(code: "hi", name: "Hindi", label: "हिन्दी"),
    ]
    static func byCode(_ c: String) -> Language { all.first { $0.code == c } ?? all[1] }

    var googleCode: String {
        switch code { case "zh-Hans": "zh-CN"; case "zh-Hant": "zh-TW"; default: code }
    }
}

struct TranslationRequest {
    let text: String
    let source: Language
    let target: Language
    let history: [(source: String, translation: String)]  // most recent last
    let userContext: String
}

protocol Translator {
    func translate(_ req: TranslationRequest, onPartial: @escaping (String) -> Void) async throws -> String
}

// MARK: - LLM (OpenAI-compatible chat completions, streaming)

struct LLMConfig {
    var baseURL: String
    var apiKey: String
    var model: String
    var temperature: Double
    var historyTurns: Int
    var systemAsUser: Bool   // some Gemma templates reject the system role
}

final class LLMTranslator: Translator {
    let config: LLMConfig
    init(config: LLMConfig) { self.config = config }

    static func systemPrompt(_ r: TranslationRequest) -> String {
        var s = """
        You are a professional simultaneous interpreter. You receive a live speech-recognition transcript \
        in \(r.source.name), delivered chunk by chunk, and translate each chunk into natural, fluent \(r.target.name).

        Rules:
        - Output ONLY the \(r.target.name) translation of the latest chunk. No explanations, notes, quotes, labels, or the original text.
        - Earlier chunks and their translations are given only as context. Never repeat or re-translate them.
        - Keep terminology, names, tone and register consistent with earlier translations.
        - The transcript comes from automatic speech recognition and may contain misrecognized words or missing punctuation. \
        Use context to infer the intended meaning and translate that.
        - A chunk may be an incomplete sentence. Translate just what is there, naturally, without inventing the rest.
        - If the chunk is only filler or noise (e.g. "um", "uh"), output nothing.
        """
        let ctx = r.userContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty {
            s += "\n\nBackground context about this conversation (use it for terminology and disambiguation):\n\(ctx)"
        }
        return s
    }

    func buildMessages(_ r: TranslationRequest) -> [[String: String]] {
        var msgs: [[String: String]] = []
        let sys = Self.systemPrompt(r)
        let recent = r.history.suffix(config.historyTurns)
        if config.systemAsUser {
            // Fold instructions into the first user turn.
            var first = true
            for h in recent {
                msgs.append(["role": "user", "content": (first ? sys + "\n\n" : "") + h.source])
                msgs.append(["role": "assistant", "content": h.translation])
                first = false
            }
            msgs.append(["role": "user", "content": (first ? sys + "\n\n" : "") + r.text])
        } else {
            msgs.append(["role": "system", "content": sys])
            for h in recent {
                msgs.append(["role": "user", "content": h.source])
                msgs.append(["role": "assistant", "content": h.translation])
            }
            msgs.append(["role": "user", "content": r.text])
        }
        return msgs
    }

    func translate(_ r: TranslationRequest, onPartial: @escaping (String) -> Void) async throws -> String {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { throw AppError.translate("LLM API 엔드포인트가 설정되지 않았습니다 (설정 ⌘,).") }
        let urlString = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: urlString) else { throw AppError.translate("잘못된 URL: \(urlString)") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "model": config.model,
            "messages": buildMessages(r),
            "temperature": config.temperature,
            "max_tokens": 1024,
            "stream": true,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errText = ""
            for try await line in bytes.lines { errText += line; if errText.count > 800 { break } }
            throw AppError.translate("LLM HTTP \(http.statusCode): \(errText)")
        }

        var output = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]], let first = choices.first else { continue }
            let delta = (first["delta"] as? [String: Any])?["content"] as? String
                ?? (first["message"] as? [String: Any])?["content"] as? String
            if let delta {
                output += delta
                onPartial(Self.clean(output, final: false))
            }
        }
        return Self.clean(output, final: true)
    }

    /// Strips reasoning blocks and stray wrappers the model may emit.
    static func clean(_ s: String, final: Bool) -> String {
        var t = s
        for (open, close) in [("<think>", "</think>"), ("<thinking>", "</thinking>")] {
            while let a = t.range(of: open) {
                if let b = t.range(of: close, range: a.upperBound..<t.endIndex) {
                    t.removeSubrange(a.lowerBound..<b.upperBound)
                } else {
                    t.removeSubrange(a.lowerBound..<t.endIndex)  // still thinking
                }
            }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if final, t.count >= 2, t.first == "\"", t.last == "\"" { t = String(t.dropFirst().dropLast()) }
        return t
    }
}

// MARK: - Apple Translation (on-device)

/// Apple translation model for this pair isn't installed (downloadable). Not a real failure: wait + download.
struct LanguagePackMissing: LocalizedError, Equatable {
    let source: Language
    let target: Language
    var errorDescription: String? { "Apple 번역 언어 팩이 필요합니다: \(source.label) → \(target.label)" }
    var key: String { "\(source.code)>\(target.code)" }

    static func status(_ source: Language, _ target: Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: Locale.Language(identifier: source.code), to: Locale.Language(identifier: target.code))
    }
}

final class AppleTranslator: Translator {
    private var session: TranslationSession?
    private var pair: (String, String)?

    func translate(_ r: TranslationRequest, onPartial: @escaping (String) -> Void) async throws -> String {
        if session == nil || pair?.0 != r.source.code || pair?.1 != r.target.code {
            let src = Locale.Language(identifier: r.source.code)
            let tgt = Locale.Language(identifier: r.target.code)
            let status = await LanguageAvailability().status(from: src, to: tgt)
            switch status {
            case .unsupported: throw AppError.translate("Apple 번역이 \(r.source.label)→\(r.target.label)를 지원하지 않습니다.")
            case .supported: throw LanguagePackMissing(source: r.source, target: r.target)
            case .installed: break
            @unknown default: break
            }
            session = TranslationSession(installedSource: src, target: tgt)
            pair = (r.source.code, r.target.code)
        }
        let res = try await session!.translate(r.text)
        return res.targetText
    }

    /// Many strings in one call (much faster than one XPC round trip per string). Order is preserved.
    func translateBatch(_ texts: [String], source: Language, target: Language) async throws -> [String] {
        guard let first = texts.first else { return [] }
        _ = try await translate(TranslationRequest(text: first, source: source, target: target, history: [], userContext: "")) { _ in }
        let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        let responses = try await session!.translations(from: reqs)
        var out = texts   // fall back to the source text if a response is missing
        for r in responses { if let id = r.clientIdentifier, let i = Int(id), i < out.count { out[i] = r.targetText } }
        return out
    }
}

// MARK: - Google Translate

final class GoogleTranslator: Translator {
    let apiKey: String
    init(apiKey: String) { self.apiKey = apiKey }

    func translate(_ r: TranslationRequest, onPartial: @escaping (String) -> Void) async throws -> String {
        if !apiKey.isEmpty { return try await official(r) }
        return try await free(r)
    }

    /// Cloud Translation API v2 (requires API key).
    private func official(_ r: TranslationRequest) async throws -> String {
        var c = URLComponents(string: "https://translation.googleapis.com/language/translate/v2")!
        c.queryItems = [.init(name: "key", value: apiKey)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "q": r.text, "source": r.source.googleCode, "target": r.target.googleCode, "format": "text"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw AppError.translate("Google HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = json["data"] as? [String: Any], let ts = d["translations"] as? [[String: Any]],
              let t = ts.first?["translatedText"] as? String else { throw AppError.translate("Google 응답 파싱 실패") }
        return t
    }

    /// Unofficial public endpoint (no key; rate-limited, best effort).
    private func free(_ r: TranslationRequest) async throws -> String {
        var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        c.queryItems = [.init(name: "client", value: "gtx"), .init(name: "sl", value: r.source.googleCode),
                        .init(name: "tl", value: r.target.googleCode), .init(name: "dt", value: "t"),
                        .init(name: "q", value: r.text)]
        let (data, resp) = try await URLSession.shared.data(from: c.url!)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw AppError.translate("Google HTTP \(http.statusCode)")
        }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any],
              let parts = arr.first as? [Any] else { throw AppError.translate("Google 응답 파싱 실패") }
        return parts.compactMap { ($0 as? [Any])?.first as? String }.joined()
    }
}
