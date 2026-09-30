import AVFoundation
import Speech

struct Cue: Codable {
    var start: Double
    var end: Double
    var text: String
    var translation = ""
}

/// A recognized word in file time.
struct FileWord: Codable {
    var text: String
    var start: Double
    var end: Double
    var conf: Double
}

enum SubtitleLayout: String, CaseIterable, Identifiable, Codable {
    case translation = "번역만"
    case both = "번역 + 원문"
    case original = "원문만"
    var id: String { rawValue }
}

enum VADMode: String, CaseIterable, Identifiable, Codable {
    case silero = "Silero (신경망)"
    case energy = "음량 기반"
    var id: String { rawValue }
}

enum SubtitleTranslator: String, CaseIterable, Identifiable, Codable {
    case none = "번역 안 함"
    case apple = "Apple"
    case google = "Google"
    case llm = "LLM"
    var id: String { rawValue }
}

struct GeneratorOptions {
    var sourceCode = "auto"                 // "auto" or Language.code
    var autoCandidates = ["en", "ko", "ja"]
    var translator: SubtitleTranslator = .apple
    var targetCode = "ko"
    var layout: SubtitleLayout = .both
    var vadMode: VADMode = .silero
    var llm = LLMConfig(baseURL: "", apiKey: "", model: "", temperature: 0.2, historyTurns: 6, systemAsUser: false)
    var googleAPIKey = ""
    var userContext = ""
}

/// Options a job was started with (no secrets), so a resumed job keeps behaving the same.
struct StoredOptions: Codable {
    var sourceCode: String
    var autoCandidates: [String]
    var translator: SubtitleTranslator
    var targetCode: String
    var layout: SubtitleLayout
    var vadMode: VADMode
    var userContext: String

    init(_ o: GeneratorOptions) {
        sourceCode = o.sourceCode; autoCandidates = o.autoCandidates; translator = o.translator
        targetCode = o.targetCode; layout = o.layout; vadMode = o.vadMode; userContext = o.userContext
    }

    /// Re-applies stored choices over current settings (which supply API keys / endpoints).
    func apply(to current: GeneratorOptions) -> GeneratorOptions {
        var o = current
        o.sourceCode = sourceCode; o.autoCandidates = autoCandidates; o.translator = translator
        o.targetCode = targetCode; o.layout = layout; o.vadMode = vadMode; o.userContext = userContext
        return o
    }
}

/// Resumable job state, written periodically and on pause/cancel/quit.
struct Checkpoint: Codable {
    var fileSize: Int64
    var fileModified: Double
    var options: StoredOptions
    var duration: Double?
    var language: String?
    /// Recognition is final for file time < recognizedUntil (a VAD segment boundary = silence).
    var recognizedUntil = 0.0
    var words: [FileWord] = []
    /// Set once recognition is complete.
    var cues: [Cue]?
    var translated = 0
    var progress = 0.0
    var phase = ""

    static func identity(of url: URL) -> (size: Int64, modified: Double)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return ((a[.size] as? NSNumber)?.int64Value ?? 0, (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }

    /// Checkpoint still matches the file on disk?
    func matches(_ url: URL) -> Bool {
        guard let id = Self.identity(of: url) else { return false }
        return id.size == fileSize && abs(id.modified - fileModified) < 1
    }
}

/// media file -> VAD -> SpeechAnalyzer (word timings) -> cues -> (translation) -> .smi
/// Resumable: progress is saved through `save` and continued from a `Checkpoint`.
final class SubtitleGenerator: @unchecked Sendable {
    typealias Progress = @Sendable (_ fraction: Double, _ phase: String) -> Void
    typealias Save = @Sendable (Checkpoint) -> Void

    let url: URL
    let options: GeneratorOptions
    let progress: Progress
    let save: Save
    private var cp: Checkpoint
    private(set) var detectedLanguage: String?
    private var lastSave = Date()

    init(url: URL, options: GeneratorOptions, resume: Checkpoint? = nil,
         progress: @escaping Progress, save: @escaping Save = { _ in }) {
        self.url = url; self.progress = progress; self.save = save
        if let resume, resume.matches(url) {
            cp = resume
            self.options = resume.options.apply(to: options)
        } else {
            let id = Checkpoint.identity(of: url) ?? (0, 0)
            cp = Checkpoint(fileSize: id.size, fileModified: id.modified, options: StoredOptions(options))
            self.options = options
        }
    }

    var outputURL: URL { url.deletingPathExtension().appendingPathExtension("smi") }
    var checkpoint: Checkpoint { cp }

    private func persist(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSave) >= 10 else { return }
        lastSave = Date()
        save(cp)
    }

    private func report(_ f: Double, _ phase: String) {
        cp.progress = f; cp.phase = phase
        progress(f, phase)
    }

    func run() async throws -> (url: URL, cues: Int) {
        let translating = options.translator != .none && options.layout != .original
        let asrWeight = translating ? 0.8 : 1.0
        report(cp.progress, cp.recognizedUntil > 0 || cp.cues != nil ? "이어서 진행 준비 중" : "준비 중")

        let duration: Double
        if let d = cp.duration { duration = d } else {
            guard let d = await Decoder.duration(of: url), d > 0 else { throw AppError.audio("오디오 트랙을 찾을 수 없습니다.") }
            duration = d; cp.duration = d
        }

        let lang: String
        if let l = cp.language { lang = l } else {
            lang = options.sourceCode == "auto" ? try await detectLanguage(duration: duration) : options.sourceCode
            cp.language = lang
            persist(force: true)
        }
        detectedLanguage = lang
        try Task.checkCancellation()

        if cp.cues == nil {
            let words = try await recognize(language: lang, duration: duration) { f, detail in
                self.report(f * asrWeight, "음성 인식 중 (\(Language.byCode(lang).label)) · \(detail)")
            }
            cp.cues = CueBuilder.build(words, lang: lang)
            cp.words = []
            cp.progress = asrWeight
            persist(force: true)
        }
        var cues = cp.cues ?? []
        try Task.checkCancellation()

        let needsTranslation = translating && lang != options.targetCode
        if needsTranslation && cp.translated < cues.count {
            cues = try await translate(cues, from: lang, startAt: cp.translated) { done, total in
                self.report(asrWeight + Double(done) / Double(max(total, 1)) * (1 - asrWeight),
                            "번역 중 (\(self.options.translator.rawValue)) · \(done) / \(total)")
            }
        }
        let layout: SubtitleLayout = needsTranslation ? options.layout : .original
        let smi = SMIWriter.make(cues: cues, title: url.deletingPathExtension().lastPathComponent,
                                 sourceLang: lang, targetLang: options.targetCode, layout: layout)
        var data = Data([0xEF, 0xBB, 0xBF])   // UTF-8 BOM: most players need it to detect UTF-8 SAMI
        data.append(smi.data(using: .utf8)!)
        try data.write(to: outputURL, options: .atomic)
        report(1, "완료")
        return (outputURL, cues.count)
    }

    // MARK: - Speech recognition

    /// Word in recognizer (gapless) time.
    private struct Word { var text: String; var start: Double; var end: Double; var conf: Double }

    /// VAD segment ends in file time (silence -> safe resume points).
    private final class Boundaries: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Double] = []
        func add(_ t: Double) { lock.withLock { list.append(t) } }
        func last(atOrBefore t: Double) -> Double? { lock.withLock { list.last { $0 <= t } } }
    }

    /// Thread-safe sink for recognizer output.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var words: [Word] = []
        private var lastEnd = 0.0
        func add(_ r: SpeechTranscriber.Result) {
            var ws: [Word] = []
            for run in r.text.runs {
                let text = String(r.text[run.range].characters)
                if let tr = run.audioTimeRange {
                    ws.append(Word(text: text, start: tr.start.seconds, end: tr.end.seconds,
                                   conf: run.transcriptionConfidence ?? 0.8))
                } else if !ws.isEmpty {
                    ws[ws.count - 1].text += text     // punctuation / spacing without timing
                } else if !words.isEmpty {
                    lock.withLock { words[words.count - 1].text += text }
                }
            }
            lock.withLock {
                if !ws.isEmpty { results += 1 }
                words += ws
                lastEnd = max(lastEnd, r.range.end.seconds)
            }
        }
        var snapshot: [Word] { lock.withLock { words.sorted { $0.start < $1.start } } }
        var latest: Double { lock.withLock { lastEnd } }
        private var results = 0
        var count: Int { lock.withLock { results } }
    }

    /// Maps the recognizer's gapless timeline back to file time.
    /// (Feeding with timestamp jumps makes the model garble the start of the next utterance.)
    final class Timeline: @unchecked Sendable {
        private let lock = NSLock()
        private var anchors: [(a: Double, f: Double)] = []
        func add(analyzer a: Double, file f: Double) { lock.withLock { anchors.append((a, f)) } }

        /// Word range -> file time. The model stretches the first word of a segment back into the preceding
        /// silence, so words are placed by the segment their *end* falls in, and starts are clamped to it.
        func toFile(start: Double, end: Double, preRoll: Double) -> (Double, Double) {
            lock.withLock {
                guard let seg = anchors.last(where: { $0.a <= end - 0.01 }) ?? anchors.first else { return (start, end) }
                let e = seg.f + (end - seg.a)
                let s = start >= seg.a ? seg.f + (start - seg.a) : min(seg.f + preRoll, e - 0.1)
                return (s, e)
            }
        }
        func toFile(_ t: Double) -> Double {
            lock.withLock {
                guard let x = anchors.last(where: { $0.a <= t + 1e-6 }) ?? anchors.first else { return t }
                return x.f + (t - x.a)
            }
        }
    }

    private func makeTranscriber(_ code: String) async throws -> SpeechTranscriber {
        let id = Language.byCode(code).speechLocaleID
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else {
            throw AppError.speech("\(Language.byCode(code).label) 음성 인식을 지원하지 않습니다.")
        }
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                  attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        progress(0, "음성 모델 확인 중 (\(locale.identifier))")
        let status = await AssetInventory.status(forModules: [t])
        if status == .unsupported { throw AppError.speech("\(locale.identifier) 음성 인식을 지원하지 않습니다.") }
        if status != .installed, let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            progress(0, "음성 모델 다운로드 중 (\(locale.identifier))")
            try await req.downloadAndInstall()
        }
        return t
    }

    /// Feeds VAD-gated speech (stamped with its real file time) into `analyzer`.
    /// Returns when the file is exhausted or `stopAfterSpeechSec` of speech was fed.
    struct FeedStats {
        var fraction: Double      // decoded position / duration
        var position: Double      // seconds of the file decoded
        var segments: Int         // speech segments found by VAD
        var speech: Double        // seconds of speech sent to the recognizer
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private let sileroOnThreshold: Float = Float(ProcessInfo.processInfo.environment["SILERO_ON"] ?? "") ?? 0.5
    private let sileroOffThreshold: Float = Float(ProcessInfo.processInfo.environment["SILERO_OFF"] ?? "") ?? 0.35

    private func feed(analyzer: SpeechAnalyzer, format: AVAudioFormat, cont: AsyncStream<AnalyzerInput>.Continuation,
                      duration: Double, collector: Collector?, timeline: Timeline = Timeline(), from: Double = 0,
                      boundaries: Boundaries? = nil, stopAfterSpeechSec: Double? = nil,
                      onProgress: ((FeedStats) -> Void)? = nil) async throws {
        let vad = EnergyVAD()
        vad.config.maxSegmentSec = 20
        guard let converter = AVAudioConverter(from: Decoder.format, to: format) else {
            throw AppError.audio("오디오 변환기를 만들 수 없습니다.")
        }
        var recent: [(buf: AVAudioPCMBuffer, frame: Int64)] = []   // maps VAD-forwarded buffers to file time
        var fedSpeech = 0.0
        var segments = 0
        var lastFedEnd = 0.0            // recognizer (gapless) time, seconds
        var analyzerFrames: Int64 = 0   // recognizer timeline position
        var lastFileEnd: Int64 = -1     // file position right after the last fed buffer
        let rate = Decoder.sampleRate
        let padSec = Double(ProcessInfo.processInfo.environment["SAMIGEN_PAD"] ?? "") ?? 0.5
        func yieldGapless(_ b: AVAudioPCMBuffer, fileFrame: Int64) {
            if fileFrame != lastFileEnd {
                timeline.add(analyzer: Double(analyzerFrames) / rate, file: Double(fileFrame) / rate)
            }
            cont.yield(AnalyzerInput(buffer: b, bufferStartTime: CMTime(value: analyzerFrames, timescale: CMTimeScale(rate))))
            analyzerFrames += Int64(b.frameLength)
            lastFileEnd = fileFrame + Int64(b.frameLength)
            lastFedEnd = Double(analyzerFrames) / rate
        }

        // Neural VAD (Silero): tells speech from music/noise. Chunks wait in a short look-ahead queue
        // (≤ 256 ms) until their block has been scored.
        var silero: SileroVAD?
        if options.vadMode == .silero {
            do { silero = try SileroVAD() } catch { dlog("Silero unavailable, energy VAD: \(error)") }
        }
        var lookahead: [(chunk: AudioChunk, out: AVAudioPCMBuffer)] = []
        let baseFrame = Int64(from * rate)

        func handle(_ chunk: AudioChunk, _ out: AVAudioPCMBuffer, voiced: Bool?) {
            for event in vad.process(analysisBuffer: chunk.buffer, forwardBuffer: out, voiced: voiced) {
                switch event {
                case .speech(let b):
                    guard let frame = recent.last(where: { $0.buf === b })?.frame else { continue }
                    yieldGapless(b, fileFrame: frame)
                    fedSpeech += Double(b.frameLength) / rate
                case .segmentEnd:
                    segments += 1
                    boundaries?.add(Double(lastFileEnd) / rate)
                    // A little real silence after each utterance gives the model a clean ending
                    // (without it the last sentence of a file can be lost).
                    if padSec > 0, let pad = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * padSec)) {
                        pad.frameLength = pad.frameCapacity
                        if let i = pad.int16ChannelData { memset(i[0], 0, Int(pad.frameLength) * 2) }
                        if let f = pad.floatChannelData { memset(f[0], 0, Int(pad.frameLength) * 4) }
                        yieldGapless(pad, fileFrame: lastFileEnd)   // continues right after the speech in file time
                    }
                }
            }
        }

        func drain(final: Bool) {
            guard let silero else { return }
            while let first = lookahead.first {
                // Silero counts samples from where decoding started (non-zero when resuming).
                let start = first.chunk.startFrame - baseFrame, end = start + Int64(first.chunk.buffer.frameLength)
                let p: Float
                if let v = silero.probability(from: start, to: end) { p = v }
                else if final { p = 0 }
                else { break }
                // Hysteresis (Silero defaults): 0.5 to start speech, stay in speech down to 0.35.
                let voiced = p >= (vad.isSpeech ? sileroOffThreshold : sileroOnThreshold)
                lookahead.removeFirst()
                handle(first.chunk, first.out, voiced: voiced)
            }
        }

        for try await chunk in try await Decoder.chunks(of: url, from: from) {
            try Task.checkCancellation()
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk.buffer.frameLength) else { continue }
            try converter.convert(to: out, from: chunk.buffer)
            recent.append((out, chunk.startFrame))
            if recent.count > 64 { recent.removeFirst(recent.count - 64) }

            if let silero {
                try silero.append(UnsafeBufferPointer(start: chunk.buffer.floatChannelData![0], count: Int(chunk.buffer.frameLength)))
                lookahead.append((chunk, out))
                drain(final: false)
            } else {
                handle(chunk, out, voiced: nil)
            }
            let pos = Double(chunk.startFrame) / rate
            onProgress?(FeedStats(fraction: min(1, pos / duration), position: pos, segments: segments, speech: fedSpeech))
            if let limit = stopAfterSpeechSec, fedSpeech >= limit { break }
            // Back-pressure: don't run far ahead of the recognizer (keeps memory flat on long files).
            if let collector {
                var waited = 0.0
                while lastFedEnd - collector.latest > 120, waited < 10 {
                    try await Task.sleep(for: .milliseconds(50)); waited += 0.05
                }
            }
        }
        // A cancelled decode stream just ends; make sure that is never mistaken for end-of-file.
        try Task.checkCancellation()
        if let silero { try silero.flush(); drain(final: true) }
        dlog(String(format: "VAD(\(silero == nil ? "energy" : "silero")): fed %.1fs of speech (+%.1fs pad) out of %.1fs decoded (%.0f%% skipped)",
                    fedSpeech, lastFedEnd - fedSpeech, Double(max(lastFileEnd, 0)) / rate,
                    100 * (1 - lastFedEnd / max(duration, 0.001))))
    }

    /// Recognizes from `cp.recognizedUntil` on, merging with `cp.words`. Checkpoints every ~10 s and on cancel.
    private func recognize(language: String, duration: Double,
                           onProgress: @escaping (_ fraction: Double, _ detail: String) -> Void) async throws -> [FileWord] {
        let t = try await makeTranscriber(language)
        let analyzer = SpeechAnalyzer(modules: [t], options: .init(priority: .userInitiated, modelRetention: .lingering))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else {
            throw AppError.speech("호환 오디오 포맷을 찾을 수 없습니다.")
        }
        if !options.userContext.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = options.userContext.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0.count < 40 }
            try? await analyzer.setContext(ctx)
        }
        try await analyzer.prepareToAnalyze(in: format)
        let (seq, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: seq)

        let start = cp.recognizedUntil
        let prior = cp.words
        let collector = Collector()
        let timeline = Timeline()
        let boundaries = Boundaries()
        let cjk = language.hasPrefix("ko") || language.hasPrefix("ja") || language.hasPrefix("zh")
        // Speech starts ~onset-time after a segment's first (pre-roll) buffer.
        let lead = max(0, (EnergyVAD.Config().preRollMs - EnergyVAD.Config().onsetMs * 2) / 1000)

        func fileWords() -> [FileWord] {
            collector.snapshot.map {
                var (s, e) = timeline.toFile(start: $0.start, end: $0.end, preRoll: lead)
                // A word after a pause also gets stretched back into it: cap duration by word length.
                let chars = Double($0.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).count)
                s = max(s, e - (cjk ? 0.22 * chars + 0.3 : 0.09 * chars + 0.35))
                return FileWord(text: $0.text, start: s, end: e, conf: $0.conf)
            }
        }
        /// Everything recognized before the last VAD boundary the recognizer has fully passed.
        func checkpointNow(force: Bool) {
            let done = timeline.toFile(collector.latest)
            if let safe = boundaries.last(atOrBefore: done), safe > cp.recognizedUntil {
                cp.words = prior + fileWords().filter { $0.end <= safe + 0.05 }
                cp.recognizedUntil = safe
            }
            persist(force: force)   // always write when forced (throttled writes may have skipped the latest state)
        }

        let results = Task {
            for try await r in t.results where r.isFinal { collector.add(r) }
        }
        do {
            try await feed(analyzer: analyzer, format: format, cont: cont, duration: duration, collector: collector,
                           timeline: timeline, from: start, boundaries: boundaries) { st in
                // Recognition trails decoding a little; blend both so the bar moves smoothly.
                let f = min(0.97, 0.5 * st.fraction + 0.5 * min(1, timeline.toFile(collector.latest) / duration))
                onProgress(f, "\(Self.clock(st.position)) / \(Self.clock(duration)) · 음성 구간 \(st.segments)개 · 문장 \(collector.count)개")
                checkpointNow(force: false)
            }
            try Task.checkCancellation()
            cont.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await results.value
            try Task.checkCancellation()
        } catch {
            cont.finish()
            await analyzer.cancelAndFinishNow()
            results.cancel()
            checkpointNow(force: true)   // pause / cancel / quit: keep what is safely done
            throw error
        }
        onProgress(1, "문장 \(collector.count)개")
        return prior + fileWords()
    }

    // MARK: - Language detection

    /// Runs candidate-language transcribers on the first ~40 s of speech and picks the most plausible.
    private func detectLanguage(duration: Double) async throws -> String {
        var lanes: [(code: String, t: SpeechTranscriber)] = []
        for code in options.autoCandidates {
            if let t = try? await makeTranscriber(code) { lanes.append((code, t)) }
        }
        guard lanes.count > 1 else { return lanes.first?.code ?? "en" }
        let modules: [any SpeechModule] = lanes.map(\.t)
        let analyzer = SpeechAnalyzer(modules: modules)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else { return lanes[0].code }
        let (seq, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: seq)

        final class Acc: @unchecked Sendable { var text = ""; var conf = 0.0; var n = 0.0 }
        let accs = lanes.map { _ in Acc() }
        progress(0, "언어 감지 중 · 후보 \(lanes.map { Language.byCode($0.code).label }.joined(separator: "/"))")
        let tasks = lanes.enumerated().map { i, lane in
            Task {
                for try await r in lane.t.results where r.isFinal {
                    accs[i].text += String(r.text.characters)
                    for run in r.text.runs {
                        let w = Double(r.text[run.range].characters.count)
                        accs[i].conf += (run.transcriptionConfidence ?? 0.5) * w; accs[i].n += w
                    }
                }
            }
        }
        try await feed(analyzer: analyzer, format: format, cont: cont, duration: duration, collector: nil,
                       stopAfterSpeechSec: 40) { st in
            self.progress(0, String(format: "언어 감지 중 · 음성 %.0f초 / 40초 · %@ 지점", st.speech, Self.clock(st.position)))
        }
        cont.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        for t in tasks { _ = try? await t.value }

        let scored = lanes.indices.map { i -> (String, Double) in
            let a = accs[i]
            let conf = a.n > 0 ? a.conf / a.n : 0
            return (lanes[i].code, conf * LanguageID.match(a.text, lanes[i].code))
        }
        dlog("language scores: \(scored)")
        return scored.max { $0.1 < $1.1 }.map { $0.1 > 0.05 ? $0.0 : lanes[0].code } ?? lanes[0].code
    }

    // MARK: - Translation

    /// Translates cues[startAt...] with context; saves every ~10 s and when interrupted.
    private func translate(_ cues: [Cue], from lang: String, startAt: Int,
                           onProgress: (_ done: Int, _ total: Int) -> Void) async throws -> [Cue] {
        let translator: Translator = switch options.translator {
        case .apple: AppleTranslator()
        case .google: GoogleTranslator(apiKey: options.googleAPIKey)
        case .llm: LLMTranslator(config: options.llm)
        case .none: AppleTranslator()
        }
        let src = Language.byCode(lang), tgt = Language.byCode(options.targetCode)
        var out = cues
        var history: [(source: String, translation: String)] = out[..<startAt].map { ($0.text, $0.translation) }
        func checkpoint(_ done: Int, force: Bool) {
            cp.cues = out; cp.translated = done
            persist(force: force)
        }
        // Apple (on-device): batch translation, checkpoint after every batch.
        if let apple = translator as? AppleTranslator {
            var i = startAt
            while i < out.count {
                if Task.isCancelled { checkpoint(i, force: true); throw CancellationError() }
                let end = min(out.count, i + 20)
                let results: [String]
                do { results = try await apple.translateBatch(out[i..<end].map(\.text), source: src, target: tgt) }
                catch { checkpoint(i, force: true); throw Task.isCancelled ? CancellationError() : error }
                for (k, t) in results.enumerated() { out[i + k].translation = t }
                i = end
                onProgress(i, out.count)
                checkpoint(i, force: false)
            }
            checkpoint(out.count, force: true)
            return out
        }
        for i in startAt..<out.count {
            if Task.isCancelled { checkpoint(i, force: true); throw CancellationError() }
            let req = TranslationRequest(text: out[i].text, source: src, target: tgt,
                                         history: Array(history.suffix(8)), userContext: options.userContext)
            var result = ""
            var attempt = 0
            while true {
                do { result = try await translator.translate(req) { _ in }; break }
                catch is CancellationError { checkpoint(i, force: true); throw CancellationError() }
                catch let e as LanguagePackMissing { checkpoint(i, force: true); throw e }   // wait for download, don't retry
                catch {
                    if Task.isCancelled { checkpoint(i, force: true); throw CancellationError() }
                    attempt += 1
                    // Rate limits (429) / server errors / network blips: back off and retry.
                    let msg = error.localizedDescription
                    let transient = msg.contains("429") || msg.contains("HTTP 5") || error is URLError
                    if attempt >= (transient ? 6 : 3) { checkpoint(i, force: true); throw error }
                    let wait = transient ? min(30, pow(2, Double(attempt))) : Double(attempt)
                    progress(cp.progress, "번역 재시도 대기 \(Int(wait))초 (\(attempt)/6) · \(msg.prefix(40))")
                    do { try await Task.sleep(for: .seconds(wait)) }
                    catch { checkpoint(i, force: true); throw CancellationError() }
                }
            }
            out[i].translation = result
            history.append((out[i].text, result))
            onProgress(i + 1, out.count)
            checkpoint(i + 1, force: false)
        }
        checkpoint(out.count, force: true)
        return out
    }
}

// MARK: - Cue building

enum CueBuilder {
    /// Groups timed words into subtitle cues: sentence ends, pauses, and length/duration limits.
    static func build(_ fileWords: [FileWord], lang: String) -> [Cue] {
        let words = fileWords.sorted { $0.start < $1.start }.map { (text: $0.text, start: $0.start, end: $0.end, conf: $0.conf) }
        let cjk = lang.hasPrefix("ko") || lang.hasPrefix("ja") || lang.hasPrefix("zh")
        let maxChars = cjk ? 42 : 84
        let softChars = Int(Double(maxChars) * 0.6)
        let maxDur = 7.0, gapBreak = 1.0
        let terminal: Set<Character> = [".", "?", "!", "。", "？", "！"]
        let comma: Set<Character> = [",", "、", "，", ";"]

        var cues: [Cue] = []
        var cur: [(text: String, start: Double, end: Double, conf: Double)] = []
        func close() {
            guard let first = cur.first, let last = cur.last else { return }
            let text = cur.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let conf = cur.map(\.conf).reduce(0, +) / Double(cur.count)
            if !NoiseFilter.isNoise(text, confidence: conf) {
                cues.append(Cue(start: first.start, end: last.end, text: text))
            }
            cur.removeAll()
        }
        for w in words {
            if let last = cur.last, w.start - last.end >= gapBreak { close() }
            cur.append(w)
            let text = cur.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            let lastChar = w.text.trimmingCharacters(in: .whitespaces).last
            let dur = w.end - (cur.first?.start ?? w.start)
            if let c = lastChar, terminal.contains(c) { close() }
            else if text.count >= maxChars || dur >= maxDur { close() }
            else if text.count >= softChars, let c = lastChar, comma.contains(c) { close() }
        }
        close()

        // Timing polish: minimum on-screen time, a little linger, never overlap the next cue.
        for i in cues.indices {
            let nextStart = i + 1 < cues.count ? cues[i + 1].start : .infinity
            let readTime = max(0.9, Double(cues[i].text.count) / (cjk ? 12 : 17))   // chars/sec
            let target = max(cues[i].end + 0.4, cues[i].start + readTime)
            cues[i].end = min(target, nextStart - 0.05)
            if cues[i].end <= cues[i].start { cues[i].end = cues[i].start + 0.3 }
        }
        return cues
    }
}

// MARK: - SAMI writer

enum SMIWriter {
    static func samiClass(_ code: String) -> String {
        switch code {
        case "ko": "KRCC"; case "en": "ENCC"; case "ja": "JPCC"
        case "zh-Hans": "CNCC"; case "zh-Hant": "TWCC"
        default: code.uppercased().replacingOccurrences(of: "-", with: "") + "CC"
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
    }

    static func make(cues: [Cue], title: String, sourceLang: String, targetLang: String, layout: SubtitleLayout) -> String {
        let lang = layout == .original ? sourceLang : targetLang
        let cls = samiClass(lang)
        let l = Language.byCode(lang)
        var s = """
        <SAMI>
        <HEAD>
        <TITLE>\(escape(title))</TITLE>
        <STYLE TYPE="text/css">
        <!--
        P { margin-left:8pt; margin-right:8pt; margin-bottom:2pt; margin-top:2pt; text-align:center;
            font-size:20pt; font-family:"Apple SD Gothic Neo", Arial, sans-serif; font-weight:normal; color:white; }
        .\(cls) { Name:\(l.name); lang:\(l.speechLocaleID); SAMIType:CC; }
        -->
        </STYLE>
        </HEAD>
        <BODY>

        """
        for (i, c) in cues.enumerated() {
            let body: String = switch layout {
            case .original: escape(c.text)
            case .translation: escape(c.translation.isEmpty ? c.text : c.translation)
            case .both: c.translation.isEmpty ? escape(c.text)
                : "\(escape(c.translation))<br><font color=\"#c8c8c8\">\(escape(c.text))</font>"
            }
            s += "<SYNC Start=\(ms(c.start))><P Class=\(cls)>\(body)\n"
            // Clear the screen unless the next cue starts right away.
            let next = i + 1 < cues.count ? cues[i + 1].start : .infinity
            if next - c.end > 0.06 { s += "<SYNC Start=\(ms(c.end))><P Class=\(cls)>&nbsp;\n" }
        }
        s += "</BODY>\n</SAMI>\n"
        return s
    }

    private static func ms(_ t: Double) -> Int { Int((t * 1000).rounded()) }
}
