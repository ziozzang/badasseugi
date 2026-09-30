import CoreML
import Foundation

/// Silero VAD v6.2.1 (CoreML conversion by FluidInference, MIT; huggingface.co/FluidInference/silero-vad-coreml).
/// Neural speech detector: tells speech apart from music/noise, unlike the energy VAD.
/// Input: 16 kHz mono float. One speech probability per 256 ms block (4096 samples + 64 context).
final class SileroVAD {
    static let modelName = "silero-vad-unified-256ms-v6.2.1"
    static let blockSamples = 4096
    static let contextSamples = 64

    private let model: MLModel
    private let input: MLMultiArray
    private var hidden: MLMultiArray
    private var cell: MLMultiArray
    private var context = [Float](repeating: 0, count: contextSamples)
    private var pending: [Float] = []

    /// Finished blocks: (start sample, probability).
    private(set) var blocks: [(start: Int64, prob: Float)] = []
    private var consumed: Int64 = 0

    static var modelURL: URL? {
        Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
            ?? ProcessInfo.processInfo.environment["SILERO_MODEL"].map { URL(fileURLWithPath: $0) }
    }

    init() throws {
        guard let url = Self.modelURL else { throw AppError.audio("Silero VAD 모델을 찾을 수 없습니다.") }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly   // tiny LSTM: dispatch overhead makes ANE/GPU slower here
        model = try MLModel(contentsOf: url, configuration: cfg)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.contextSamples + Self.blockSamples)], dataType: .float32)
        hidden = try MLMultiArray(shape: [1, 128], dataType: .float32)
        cell = try MLMultiArray(shape: [1, 128], dataType: .float32)
        for i in 0..<128 { hidden[i] = 0; cell[i] = 0 }
    }

    /// Samples covered by finished blocks.
    var processedSamples: Int64 { consumed }

    func append(_ samples: UnsafeBufferPointer<Float>) throws {
        pending.append(contentsOf: samples)
        while pending.count >= Self.blockSamples {
            try run(Array(pending[0..<Self.blockSamples]))
            pending.removeFirst(Self.blockSamples)
        }
    }

    /// Process the remaining partial block (zero-padded).
    func flush() throws {
        guard !pending.isEmpty else { return }
        let n = pending.count
        try run(pending + [Float](repeating: 0, count: Self.blockSamples - n))
        consumed -= Int64(Self.blockSamples - n)
        pending.removeAll()
    }

    private func run(_ block: [Float]) throws {
        let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: Self.contextSamples + Self.blockSamples)
        context.withUnsafeBufferPointer { ptr.update(from: $0.baseAddress!, count: Self.contextSamples) }
        block.withUnsafeBufferPointer { (ptr + Self.contextSamples).update(from: $0.baseAddress!, count: Self.blockSamples) }
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "audio_input": input, "hidden_state": hidden, "cell_state": cell,
        ])
        let out = try model.prediction(from: features)
        let prob = out.featureValue(for: "vad_output")?.multiArrayValue?[0].floatValue ?? 0
        if let h = out.featureValue(for: "new_hidden_state")?.multiArrayValue { hidden = h }
        if let c = out.featureValue(for: "new_cell_state")?.multiArrayValue { cell = c }
        context = Array(block.suffix(Self.contextSamples))
        blocks.append((consumed, prob))
        consumed += Int64(Self.blockSamples)
        if blocks.count > 4096 { blocks.removeFirst(2048) }
    }

    /// Max speech probability over blocks overlapping [start, end) samples, or nil if not processed yet.
    func probability(from start: Int64, to end: Int64) -> Float? {
        guard end <= consumed else { return nil }
        let bs = Int64(Self.blockSamples)
        return blocks.lazy.filter { $0.start < end && $0.start + bs > start }.map(\.prob).max() ?? 0
    }
}
