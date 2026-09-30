import AVFoundation
import Accelerate

/// Lightweight energy VAD with an adaptive noise floor (vDSP RMS, ~no CPU cost).
/// Only speech (plus pre-roll / hangover padding) is forwarded to the recognizer,
/// so the neural ASR model is idle during silence.
final class EnergyVAD {
    struct Config {
        var marginDB: Float = 9          // how far above the noise floor counts as speech
        var absoluteFloorDB: Float = -58 // never treat anything quieter than this as speech
        var onsetMs: Double = 120        // voiced time needed to open a segment
        var hangoverMs: Double = 700     // silence needed to close a segment
        var preRollMs: Double = 500      // audio kept from before onset (overlap so first words aren't clipped)
        var maxSegmentSec: Double = 14   // after this, split at the next micro-pause
        var microPauseMs: Double = 150   // a breath/gap long enough to split a monologue on
        var hardMaxFactor: Double = 1.5  // never exceed maxSegmentSec * this
    }

    enum Event {
        case speech(AVAudioPCMBuffer)   // forward to recognizer
        case segmentEnd                 // speech ended: finalize now
    }

    var config = Config()
    private(set) var isSpeech = false
    private(set) var levelDB: Float = -100
    private(set) var noiseFloorDB: Float = -50

    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollMs: Double = 0
    private var voicedMs: Double = 0
    private var silentMs: Double = 0
    private var segmentMs: Double = 0

    func reset() {
        isSpeech = false; preRoll.removeAll(); preRollMs = 0
        voicedMs = 0; silentMs = 0; segmentMs = 0; noiseFloorDB = -50
    }

    /// `analysisBuffer` is the float buffer used for energy; `forwardBuffer` is what gets emitted
    /// (already converted to the recognizer format).
    /// `voiced`: external speech decision (e.g. neural VAD); nil = decide from energy.
    func process(analysisBuffer: AVAudioPCMBuffer, forwardBuffer: AVAudioPCMBuffer, voiced external: Bool? = nil) -> [Event] {
        let ms = Double(analysisBuffer.frameLength) / analysisBuffer.format.sampleRate * 1000
        let db = Self.rmsDB(analysisBuffer)
        levelDB = db

        // Adapt the noise floor quickly downward, slowly upward (and not while talking).
        if db < noiseFloorDB { noiseFloorDB = noiseFloorDB * 0.7 + db * 0.3 }
        else if !isSpeech { noiseFloorDB = noiseFloorDB * 0.985 + db * 0.015 }
        noiseFloorDB = max(noiseFloorDB, -90)

        let threshold = max(noiseFloorDB + config.marginDB, config.absoluteFloorDB)
        let voiced = external ?? (db > threshold)
        var events: [Event] = []

        if !isSpeech {
            preRoll.append(forwardBuffer); preRollMs += ms
            while preRollMs > config.preRollMs, preRoll.count > 1 {
                let first = preRoll.removeFirst()
                preRollMs -= Double(first.frameLength) / first.format.sampleRate * 1000
            }
            voicedMs = voiced ? voicedMs + ms : 0
            if voicedMs >= config.onsetMs {
                isSpeech = true; silentMs = 0; segmentMs = preRollMs
                events += preRoll.map { .speech($0) }
                preRoll.removeAll(); preRollMs = 0
            }
        } else {
            events.append(.speech(forwardBuffer))
            segmentMs += ms
            silentMs = voiced ? 0 : silentMs + ms
            if silentMs >= config.hangoverMs {
                isSpeech = false; voicedMs = 0; silentMs = 0; segmentMs = 0
                events.append(.segmentEnd)
            } else if segmentMs >= config.maxSegmentSec * 1000 {
                // Long monologue: split at a micro-pause so we don't cut mid-word; hard cap as last resort.
                let atPause = silentMs >= config.microPauseMs
                let hardCap = segmentMs >= config.maxSegmentSec * config.hardMaxFactor * 1000
                if atPause || hardCap {
                    segmentMs = 0
                    events.append(.segmentEnd)
                }
            }
        }
        return events
    }

    static func rmsDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -100 }
        var rms: Float = 0
        vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(buffer.frameLength))
        return 20 * log10(max(rms, 1e-7))
    }
}
