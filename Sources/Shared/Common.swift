import Foundation
import AVFoundation
import CoreMedia
import NaturalLanguage

// Shared by STT Trans and SAMI Gen.

/// Runs `op` in an unstructured task and stops waiting after `seconds` (the op may keep running).
@discardableResult
func withTimeout(seconds: Double, _ op: @escaping @Sendable () async -> Void) async -> Bool {
    final class Once: @unchecked Sendable {
        let lock = NSLock(); var done = false
        func fire(_ c: CheckedContinuation<Bool, Never>, _ v: Bool) {
            lock.lock(); defer { lock.unlock() }
            if !done { done = true; c.resume(returning: v) }
        }
    }
    let once = Once()
    return await withCheckedContinuation { c in
        Task { await op(); once.fire(c, true) }
        Task { try? await Task.sleep(for: .seconds(seconds)); once.fire(c, false) }
    }
}

private let debugLogging = ProcessInfo.processInfo.environment["STTTRANS_DEBUG"] != nil
    || ProcessInfo.processInfo.environment["SAMIGEN_DEBUG"] != nil

func dlog(_ s: String) {
    guard debugLogging else { return }
    FileHandle.standardError.write(("[\(String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))] " + s + "\n").data(using: .utf8)!)
}


enum LanguageID {
    /// Probability (0...1) that `text` is written in `code`, per Apple NaturalLanguage.
    static func match(_ text: String, _ code: String) -> Double {
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return 0 }
        let r = NLLanguageRecognizer()
        r.processString(text)
        let hyps = r.languageHypotheses(withMaximum: 6)
        if let p = hyps[NLLanguage(rawValue: code)] { return p }
        // NL uses zh-Hans / zh-Hant; match on the base language as a fallback.
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return hyps.first { $0.key.rawValue.hasPrefix(base) }?.value ?? 0
    }
}

extension Language {
    /// Locale used for SpeechTranscriber.
    var speechLocaleID: String {
        [
            "ko": "ko-KR", "en": "en-US", "ja": "ja-JP", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW",
            "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "pt": "pt-BR", "ru": "ru-RU",
            "vi": "vi-VN", "th": "th-TH", "id": "id-ID", "ar": "ar-SA", "hi": "hi-IN",
        ][code] ?? code
    }
}

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let desc = formatDescription,
              let asbd = desc.audioStreamBasicDescription else { return nil }
        var asbdCopy = asbd
        guard let format = AVAudioFormat(streamDescription: &asbdCopy) else { return nil }
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

enum AppError: LocalizedError {
    case permission(String), audio(String), speech(String), translate(String)
    var errorDescription: String? {
        switch self {
        case .permission(let s), .audio(let s), .speech(let s), .translate(let s): return s
        }
    }
}
