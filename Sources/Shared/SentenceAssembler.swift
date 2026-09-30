import Foundation
import NaturalLanguage

/// Sentence-boundary awareness between ASR and translation.
/// VAD cuts on pauses, not on sentences; this joins fragments so the translator sees whole sentences.
enum SentenceSplitter {
    private static let terminal: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "」", "』"]

    /// English words that can't end a sentence (ASR often appends "." on forced finalization).
    private static let enContinuers: Set<String> = [
        "and", "or", "but", "so", "because", "cause", "the", "a", "an", "to", "of", "in", "on", "at", "for",
        "with", "from", "by", "about", "that", "which", "who", "whose", "if", "when", "while", "as", "than",
        "is", "are", "was", "were", "be", "been", "my", "your", "our", "their", "his", "her", "its", "this",
        "these", "those", "very", "really", "just", "into", "onto", "like", "um", "uh", "we", "i", "you",
    ]
    /// Korean endings/particles that continue a sentence (connective endings, case particles).
    private static let koContinuers: [String] = [
        "는데", "은데", "인데", "지만", "니까", "으니까", "면서", "으면", "려고", "으려고", "도록", "거나", "든지",
        "하고", "했고", "하며", "해서", "라서", "어서", "아서", "이고", "이며", "면", "고", "며", "서",
        "은", "는", "이", "가", "을", "를", "의", "에", "에서", "에게", "한테", "께서", "와", "과", "로", "으로",
        "도", "만", "까지", "부터", "처럼", "보다", "그리고", "그래서", "그런데", "하지만", "근데",
    ]
    /// Korean sentence-final endings.
    private static let koFinals: [String] = [
        "다", "요", "죠", "까", "니다", "세요", "네", "군", "구나", "지", "자", "라", "냐", "니", "래", "게",
    ]

    static func isComplete(_ sentence: String, lang: String) -> Bool {
        var s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last, closers.contains(last) { s.removeLast() }
        guard let last = s.last, terminal.contains(last) else { return false }
        if last == "?" || last == "!" || last == "？" || last == "！" { return true }
        // Period: check the word before it — forced finalization appends "." mid-sentence.
        let body = s.trimmingCharacters(in: CharacterSet(charactersIn: ".。… "))
        guard let word = body.split(whereSeparator: { $0 == " " || $0 == "," }).last.map(String.init) else { return false }
        switch lang.prefix(2) {
        case "en":
            return !enContinuers.contains(word.lowercased())
        case "ko":
            // Longest matching suffix wins ("니까" connective beats "까" final).
            let fin = koFinals.filter { word.hasSuffix($0) }.map(\.count).max() ?? 0
            let cont = koContinuers.filter { word.hasSuffix($0) }.map(\.count).max() ?? 0
            if fin == 0 && cont == 0 { return false }   // ends in a bare noun: "결과." -> sentence continues
            return fin >= cont
        default:
            return true
        }
    }

    /// Tail clearly mid-sentence ("... and", "...는데")? Such tails deserve a longer wait.
    static func clearlyContinues(_ text: String, lang: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,。、…")))
        guard let word = t.split(separator: " ").last.map(String.init) else { return false }
        switch lang.prefix(2) {
        case "en": return enContinuers.contains(word.lowercased())
        case "ko":
            let fin = koFinals.filter { word.hasSuffix($0) }.map(\.count).max() ?? 0
            let cont = koContinuers.filter { word.hasSuffix($0) }.map(\.count).max() ?? 0
            return cont > fin
        default: return false
        }
    }

    /// Splits into (complete sentences, incomplete tail).
    static func split(_ text: String, lang: String) -> (complete: String, rest: String) {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        tok.setLanguage(NLLanguage(rawValue: lang))
        let ranges = tok.tokens(for: text.startIndex..<text.endIndex)
        guard let lastRange = ranges.last else { return ("", text) }
        if isComplete(String(text[lastRange]), lang: lang) {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        let complete = String(text[..<lastRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(text[lastRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (complete, rest)
    }

    /// Words that, starting a chunk, mean it continues the previous sentence.
    private static let enStartContinuers: Set<String> = [
        "and", "or", "but", "because", "cause", "which", "that", "who", "whom", "whose", "where", "when",
        "while", "for", "to", "with", "of", "in", "on", "at", "from", "by", "than", "as", "including",
        "plus", "into", "about", "after", "before", "until", "unless", "whereas", "though", "although",
    ]

    /// Does `next` look like the continuation of the previous (period-ended) chunk?
    static func isContinuation(_ next: String, lang: String) -> Bool {
        let t = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return false }
        if lang.hasPrefix("ko") || lang.hasPrefix("ja") || lang.hasPrefix("zh") { return false }
        if first.isLowercase { return true }
        let word = t.prefix { $0.isLetter }.lowercased()
        return lang.hasPrefix("en") && enStartContinuers.contains(word)
    }

    /// Ends with a plain period (as opposed to ? or !) — may be a forced, fake sentence end.
    static func endsWithSoftPeriod(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return last == "." || last == "。"
    }

    /// Joins `prev` + `next` into one sentence: drops prev's fake period, lowercases next's first word.
    static func mergeContinuation(_ prev: String, _ next: String, lang: String) -> String {
        var p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        while let l = p.last, l == "." || l == "。" { p.removeLast() }
        var n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if lang.hasPrefix("en"), let f = n.first, f.isUppercase {
            let word = n.prefix { $0.isLetter }
            if word != "I" && !word.dropFirst().contains(where: \.isUppercase) {   // keep "I", "NASA"
                n = f.lowercased() + n.dropFirst()
            }
        }
        return p + joiner(for: lang) + n
    }

    static func joiner(for lang: String) -> String {
        lang.hasPrefix("ja") || lang.hasPrefix("zh") ? "" : " "
    }
}

/// Noise / filler detection for recognized segments.
enum NoiseFilter {
    private static let fillers: Set<String> = [
        "um", "uh", "umm", "uhm", "hmm", "mm", "ah", "oh", "er", "erm", "eh", "huh", "mhm", "uh-huh",
        "음", "어", "아", "으", "흠", "에", "그", "저", "엄", "음음", "어어",
        "えー", "あの", "えっと", "嗯", "啊",
    ]

    static func isNoise(_ text: String, confidence: Double) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        if letters == 0 { return true }                      // ".", ", ..", "…"
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty }
        if !words.isEmpty && words.allSatisfy({ fillers.contains($0) }) { return true }
        if letters <= 4 && confidence < 0.6 { return true }  // tiny + unsure
        if confidence < 0.3 { return true }                  // garbage
        return false
    }
}
