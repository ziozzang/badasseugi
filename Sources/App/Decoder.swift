import AVFoundation
import CoreMedia

/// Decodes any media file to 16 kHz mono Float32 chunks with their file position.
/// AVFoundation handles mp4/mov/m4v/m4a/mp3/wav/aiff…; everything else (mkv, webm, avi, …) goes through ffmpeg.
struct AudioChunk {
    let buffer: AVAudioPCMBuffer   // 16 kHz mono Float32
    let startFrame: Int64          // position in the file, in 16 kHz frames
}

enum Decoder {
    static let sampleRate = 16_000.0
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    static let chunkFrames: AVAudioFrameCount = 1600   // 100 ms — VAD granularity

    static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Duration in seconds (AVFoundation, then ffprobe).
    static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration), d.isNumeric, d.seconds > 0,
           let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty {
            return d.seconds
        }
        guard let ffmpeg = ffmpegPath else { return nil }
        let probe = (ffmpeg as NSString).deletingLastPathComponent + "/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: probe) else { return nil }
        let out = try? run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path])
        return out.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// `from`: start position in seconds (resume after a checkpoint).
    static func chunks(of url: URL, from: Double = 0) async throws -> AsyncThrowingStream<AudioChunk, Error> {
        // Prefer ffmpeg: it follows presentation timestamps through gaps/edits consistently
        // (continuous and seeked reads agree), which subtitle sync and resume both depend on.
        let preferAVF = ProcessInfo.processInfo.environment["SAMIGEN_DECODER"] == "avf"
        if !preferAVF, let ffmpeg = ffmpegPath { return viaFFmpeg(ffmpeg, url: url, from: from) }
        let asset = AVURLAsset(url: url)
        if let tracks = try? await asset.loadTracks(withMediaType: .audio), let track = tracks.first,
           (try? AVAssetReader(asset: asset)) != nil {
            return avfoundation(asset: asset, track: track, from: from)
        }
        guard let ffmpeg = ffmpegPath else {
            throw AppError.audio("이 형식은 AVFoundation으로 읽을 수 없습니다. ffmpeg를 설치하세요 (brew install ffmpeg).")
        }
        return viaFFmpeg(ffmpeg, url: url, from: from)
    }

    // MARK: AVFoundation

    private static func avfoundation(asset: AVURLAsset, track: AVAssetTrack, from: Double) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { cont in
            let task = Task.detached {
                do {
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false,
                    ])
                    output.alwaysCopiesSampleData = false
                    reader.add(output)
                    if from > 0 {
                        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 16_000),
                                                       duration: .positiveInfinity)
                    }
                    guard reader.startReading() else { throw reader.error ?? AppError.audio("오디오를 읽을 수 없습니다.") }
                    var rechunker = Rechunker(startFrame: Int64(from * sampleRate))
                    while !Task.isCancelled, let sb = output.copyNextSampleBuffer() {
                        guard let pcm = sb.toPCMBuffer(), let data = pcm.floatChannelData else { continue }
                        // Follow presentation timestamps: players sync subtitles to PTS, and files with
                        // gaps/overlaps (edits, concatenations) would otherwise drift.
                        let pts = sb.presentationTimeStamp
                        let at = pts.isNumeric ? Int64((pts.seconds * sampleRate).rounded()) : nil
                        rechunker.append(UnsafeBufferPointer(start: data[0], count: Int(pcm.frameLength)), at: at) { cont.yield($0) }
                    }
                    if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
                    if reader.status == .failed { throw reader.error ?? AppError.audio("오디오 디코딩 실패") }
                    rechunker.flush { cont.yield($0) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: ffmpeg

    private static func viaFFmpeg(_ ffmpeg: String, url: URL, from: Double) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            // aresample=async=1 pads gaps / trims overlaps so sample count follows timestamps.
            proc.arguments = ["-nostdin", "-v", "error"] + (from > 0 ? ["-ss", String(format: "%.3f", from)] : []) + ["-i", url.path, "-vn", "-sn", "-dn",
                              "-af", "aresample=async=1",
                              "-ac", "1", "-ar", String(Int(sampleRate)), "-f", "f32le", "pipe:1"]
            let outPipe = Pipe(), errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            let task = Task.detached {
                do {
                    try proc.run()
                    let fh = outPipe.fileHandleForReading
                    var rechunker = Rechunker(startFrame: Int64(from * sampleRate))
                    var carry = Data()
                    while !Task.isCancelled {
                        let data = fh.readData(ofLength: 64_000)
                        if data.isEmpty { break }
                        carry.append(data)
                        let usable = carry.count / 4 * 4
                        carry.prefix(usable).withUnsafeBytes { raw in
                            rechunker.append(raw.bindMemory(to: Float.self)) { cont.yield($0) }
                        }
                        carry.removeFirst(usable)
                    }
                    if Task.isCancelled { proc.terminate(); throw CancellationError() }
                    proc.waitUntilExit()
                    if proc.terminationStatus != 0 {
                        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        throw AppError.audio("ffmpeg 오류: \(err.suffix(400))")
                    }
                    rechunker.flush { cont.yield($0) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel(); if proc.isRunning { proc.terminate() } }
        }
    }

    static func run(_ path: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

/// Re-slices arbitrary sample runs into fixed 100 ms chunks, tracking file position.
private struct Rechunker {
    private var pending: [Float] = []
    private var position: Int64

    init(startFrame: Int64 = 0) { position = startFrame }

    /// `at`: timestamp (in samples) of the first sample, if known. Gaps are filled with silence,
    /// overlaps are dropped, so chunk positions always match presentation time.
    mutating func append(_ samples: UnsafeBufferPointer<Float>, at: Int64? = nil, emit: (AudioChunk) -> Void) {
        var samples = samples
        if let at {
            let expected = position + Int64(pending.count)
            let tolerance: Int64 = 160   // 10 ms
            if at > expected + tolerance {
                pending.append(contentsOf: repeatElement(0, count: Int(at - expected)))
            } else if at < expected - tolerance {
                let drop = min(Int(expected - at), samples.count)
                samples = UnsafeBufferPointer(rebasing: samples[drop...])
            }
        }
        pending.append(contentsOf: samples)
        let n = Int(Decoder.chunkFrames)
        var offset = 0
        while pending.count - offset >= n {
            emit(make(pending[offset..<offset + n]))
            offset += n
        }
        pending.removeFirst(offset)
    }

    mutating func flush(emit: (AudioChunk) -> Void) {
        if !pending.isEmpty { emit(make(pending[...])); pending.removeAll() }
    }

    private mutating func make(_ s: ArraySlice<Float>) -> AudioChunk {
        let buf = AVAudioPCMBuffer(pcmFormat: Decoder.format, frameCapacity: AVAudioFrameCount(s.count))!
        buf.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: s.count) }
        defer { position += Int64(s.count) }
        return AudioChunk(buffer: buf, startFrame: position)
    }
}
