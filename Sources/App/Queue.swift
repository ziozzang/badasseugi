import Foundation
import Combine
import CryptoKit
import UniformTypeIdentifiers
import Translation

// MARK: - Checkpoint files

/// In-progress state lives next to the media file as `name.smi.tmp` (so dropping the same file again
/// resumes it), falling back to Application Support if that folder isn't writable. Deleted on completion.
enum CheckpointStore {
    static func tmpURL(for media: URL) -> URL { media.deletingPathExtension().appendingPathExtension("smi.tmp") }

    static var supportDir: URL {
        // SAMIGEN_SUPPORT_DIR: isolated data dir for tests. ("SAMI Gen" kept for continuity with earlier builds.)
        let d = ProcessInfo.processInfo.environment["SAMIGEN_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SAMI Gen", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func fallbackURL(for media: URL) -> URL {
        let hash = SHA256.hash(data: Data(media.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let dir = supportDir.appendingPathComponent("checkpoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(hash).json")
    }

    /// A checkpoint that still matches the media file (size + mtime), if any.
    static func load(_ media: URL) -> Checkpoint? {
        for url in [tmpURL(for: media), fallbackURL(for: media)] {
            if let data = try? Data(contentsOf: url), let cp = try? JSONDecoder().decode(Checkpoint.self, from: data),
               cp.matches(media) { return cp }
        }
        return nil
    }

    static func save(_ media: URL, _ cp: Checkpoint) {
        guard let data = try? JSONEncoder().encode(cp) else { return }
        do { try data.write(to: tmpURL(for: media), options: .atomic) }
        catch { try? data.write(to: fallbackURL(for: media), options: .atomic) }
    }

    static func remove(_ media: URL) {
        try? FileManager.default.removeItem(at: tmpURL(for: media))
        try? FileManager.default.removeItem(at: fallbackURL(for: media))
    }
}

// MARK: - Job

@MainActor
final class Job: ObservableObject, Identifiable {
    enum State: Equatable {
        case waiting, running, paused
        case needsPack(String)          // waiting for an Apple translation language pack (key "src>tgt")
        case done(URL), skipped(URL), failed(String), cancelled
    }
    /// Why a running job is being stopped (all save a checkpoint first).
    enum StopReason { case pause, preempt, quit, cancel }

    let id: UUID
    let url: URL
    @Published var state: State = .waiting
    @Published var progress = 0.0
    @Published var phase = "대기 중"
    @Published var detail = ""
    var overwrite = false          // "다시 만들기": ignore existing .smi / checkpoint
    var stopReason: StopReason?
    var cancelHandler: (() -> Void)?
    var started: Date?
    var retries = 0                // automatic retries after failures

    init(url: URL, id: UUID = UUID()) { self.url = url; self.id = id }

    /// Still owes work (not finished).
    var isActive: Bool {
        switch state { case .waiting, .running, .paused, .needsPack: true; default: false }
    }
    var isResumable: Bool {
        switch state { case .paused, .failed, .needsPack: true; default: false }
    }
    var outputURL: URL { url.deletingPathExtension().appendingPathExtension("smi") }
}

/// What survives a restart (order + state; the real progress is in the checkpoint file).
private struct PersistedJob: Codable {
    var id: UUID
    var path: String
    var state: String
    var output: String?
    var error: String?
    var progress: Double
    var phase: String
    var detail: String
    var overwrite: Bool
}

// MARK: - Queue

@MainActor
final class JobQueue: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    /// Queue switch (Start / Stop). Persisted: a stopped queue stays stopped after relaunch.
    @Published private(set) var active = UserDefaults.standard.object(forKey: "queueActive") as? Bool ?? true
    /// Language packs jobs are waiting for.
    @Published private(set) var packs: [PackRequest] = []
    /// Drives `.translationTask` in the main window (the only way to show the system download prompt).
    @Published var downloadConfig: TranslationSession.Configuration?
    private var downloadingKey: String?
    private var packPoller: Task<Void, Never>?
    let settings: Settings
    private var watchers: [UUID: AnyCancellable] = [:]
    private var saveScheduled = false

    static let mediaTypes: [UTType] = [.movie, .video, .audio, .audiovisualContent, .mpeg4Movie, .quickTimeMovie]
    static let extraExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "ts", "m2ts", "mts", "ogg", "opus", "flac"]

    static func isMedia(_ url: URL) -> Bool {
        if extraExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return mediaTypes.contains { t.conforms(to: $0) }
    }

    init(settings: Settings) {
        self.settings = settings
        restore()
        pump()
    }

    var maxConcurrent: Int { max(1, settings.concurrency) }
    var running: [Job] { jobs.filter { $0.state == .running } }
    var hasFinished: Bool { jobs.contains { !$0.isActive } }

    // MARK: Adding

    func add(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                // Folder: take the media files inside (non-recursive).
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                add(items.filter(Self.isMedia).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                continue
            }
            guard Self.isMedia(url), !jobs.contains(where: { $0.url == url && $0.isActive }) else { continue }
            let job = Job(url: url)
            prepare(job)
            append(job)
        }
        save()
        pump()
    }

    /// Initial state for a new job: skip if a finished .smi exists, show resumable progress if a checkpoint exists.
    private func prepare(_ job: Job) {
        if let cp = CheckpointStore.load(job.url) {
            job.progress = cp.progress
            job.phase = "이어서 진행 대기 (\(Int(cp.progress * 100))%)"
        } else if settings.skipExisting, !job.overwrite, FileManager.default.fileExists(atPath: job.outputURL.path) {
            job.state = .skipped(job.outputURL)
            job.progress = 1
            job.phase = "건너뜀"
            job.detail = "이미 \(job.outputURL.lastPathComponent) 있음"
        }
    }

    private func append(_ job: Job) {
        watch(job)
        jobs.append(job)
    }

    /// Jobs are separate ObservableObjects: forward state changes to queue-level UI and persist them.
    private func watch(_ job: Job) {
        watchers[job.id] = job.$state.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
                self?.save()
            }
        }
    }

    // MARK: Scheduling

    /// Fill free slots with the highest waiting jobs (list order = priority).
    func pump() {
        guard active else { return }
        while running.count < maxConcurrent, let next = jobs.first(where: { $0.state == .waiting }) {
            start(next)
        }
    }

    private func start(_ job: Job) {
        job.state = .running
        job.started = Date()
        job.stopReason = nil
        if job.overwrite { CheckpointStore.remove(job.url) }
        let url = job.url
        let resume = job.overwrite ? nil : CheckpointStore.load(url)
        job.overwrite = false
        if resume != nil { job.phase = "이어서 진행" }
        let gen = SubtitleGenerator(url: url, options: settings.options, resume: resume, progress: { f, phase in
            Task { @MainActor in job.progress = max(job.progress, f); job.phase = phase }
        }, save: { cp in
            CheckpointStore.save(url, cp)
        })
        let work = Task { try await gen.run() }
        job.cancelHandler = { work.cancel() }
        preflightLanguagePack()
        Task {
            await finish(job, gen: gen, work: work)
            pump()
        }
    }

    private func finish(_ job: Job, gen: SubtitleGenerator, work: Task<(url: URL, cues: Int), Error>) async {
        defer { job.cancelHandler = nil }
        do {
            let result = try await work.value
            CheckpointStore.remove(job.url)                 // done: the .tmp is no longer needed
            job.state = .done(result.url)
            job.progress = 1
            let secs = Int(Date().timeIntervalSince(job.started ?? Date()))
            let lang = gen.detectedLanguage.map { Language.byCode($0).label } ?? ""
            job.phase = "완료"
            job.detail = "\(result.cues)개 자막 · \(lang) · \(secs)초"
        } catch {
            let pct = "\(Int(job.progress * 100))%"
            if error is CancellationError {
                switch job.stopReason {
                case .pause?:
                    job.state = .paused; job.phase = "일시정지됨 · \(pct)에서 이어서 진행"
                case .preempt?:
                    job.state = .waiting; job.phase = "양보함 · \(pct)에서 이어서 진행 대기"
                case .quit?:
                    job.state = .waiting; job.phase = "이어서 진행 대기 (\(pct))"
                case .cancel?, nil:
                    CheckpointStore.remove(job.url)
                    job.state = .cancelled; job.phase = "취소됨"
                }
            } else if let missing = error as? LanguagePackMissing {
                // Not a failure: wait for the pack (recognition is checkpointed), resume when installed.
                job.state = .needsPack(missing.key)
                job.phase = "언어 팩 대기: \(missing.source.label) → \(missing.target.label) · \(pct)까지 저장됨"
                requestPack(missing.source, missing.target, auto: true)
            } else {
                // Real failure: keep the checkpoint so retries resume where it stopped.
                job.state = .failed(error.localizedDescription)
                if settings.autoRetry && job.retries < 3 {
                    job.retries += 1
                    let delay = 30 * job.retries
                    job.phase = "실패 · \(pct)까지 저장됨 · \(delay)초 후 자동 재시도 (\(job.retries)/3)"
                    let id = job.id
                    Task {
                        try? await Task.sleep(for: .seconds(Double(delay)))
                        guard let j = jobs.first(where: { $0.id == id }), case .failed = j.state else { return }
                        j.state = .waiting; j.phase = "자동 재시도 대기 (\(j.retries)/3)"
                        pump()
                    }
                } else {
                    job.phase = "실패 · \(pct)까지 저장됨"
                }
            }
        }
        job.stopReason = nil
    }

    private func stop(_ job: Job, _ reason: Job.StopReason) {
        guard job.state == .running else { return }
        // Model loading can't be interrupted, so the actual stop may take a few seconds.
        if job.stopReason == nil || reason == .cancel || (reason == .pause && job.stopReason != .cancel) { job.stopReason = reason }
        job.phase = reason == .cancel ? "취소하는 중…" : "저장하고 멈추는 중…"
        job.cancelHandler?()
    }

    // MARK: User actions

    func pause(_ job: Job) {
        switch job.state {
        case .running: stop(job, .pause)
        case .waiting: job.state = .paused; job.phase = "일시정지됨"
        default: break
        }
    }

    func resume(_ job: Job) {
        guard job.state == .paused else { return }
        job.state = .waiting
        job.phase = "대기 중"
        pump()
    }

    /// Top of the queue and run immediately; if all slots are busy, the lowest-priority running job
    /// yields (it checkpoints and goes back to waiting).
    func startNow(_ job: Job) {
        guard job.state != .running else { return }
        move(job, to: 0)
        if case .done = job.state { job.overwrite = true }
        if case .skipped = job.state { job.overwrite = true }
        job.state = .waiting
        job.phase = "곧 시작"
        if running.count >= maxConcurrent,
           let victim = jobs.last(where: { $0.state == .running && $0.id != job.id }) {
            stop(victim, .preempt)   // its slot goes to `job` once it has saved (pump runs after it stops)
        } else {
            pump()
        }
    }

    func cancel(_ job: Job) {
        switch job.state {
        case .running: stop(job, .cancel)
        case .waiting, .paused, .needsPack:
            CheckpointStore.remove(job.url)
            job.state = .cancelled; job.phase = "취소됨"
        default: break
        }
    }

    func retry(_ job: Job) {
        job.retries = 0
        job.state = .waiting
        job.phase = CheckpointStore.load(job.url) != nil ? "이어서 진행 대기" : "대기 중"
        job.detail = ""
        pump()
    }

    /// Regenerate even though a .smi exists (overwrites it when done).
    func redo(_ job: Job) {
        if job.state == .running { return }
        job.overwrite = true
        job.progress = 0
        job.detail = ""
        job.state = .waiting
        job.phase = "대기 중 (다시 만들기)"
        pump()
    }

    func remove(_ job: Job) {
        if job.state == .running { stop(job, .cancel) }
        else if job.isActive { CheckpointStore.remove(job.url) }
        watchers[job.id] = nil
        jobs.removeAll { $0.id == job.id }
        save()
    }

    func clearFinished() {
        for j in jobs where !j.isActive { watchers[j.id] = nil }
        jobs.removeAll { !$0.isActive }
        save()
    }

    // MARK: Queue-wide (Start / Stop / Resume All)

    private func setActive(_ on: Bool) {
        active = on
        UserDefaults.standard.set(on, forKey: "queueActive")
    }

    /// ▶ Start: let the queue run waiting jobs.
    func startQueue() {
        setActive(true)
        pump()
    }

    /// ⏹ Stop: running jobs save a checkpoint and go back to waiting; nothing new starts.
    func stopQueue() {
        setActive(false)
        for j in running { stop(j, .quit) }
    }

    var resumableCount: Int { jobs.filter(\.isResumable).count }

    /// ↻ Resume All: paused, failed and language-pack-waiting jobs go back to waiting (from their checkpoints).
    func resumeAll() {
        for j in jobs where j.isResumable {
            if case .needsPack(let key) = j.state, packs.contains(where: { $0.id == key }) {
                continue   // still not installed: stays waiting for the pack
            }
            j.retries = 0
            j.state = .waiting
            j.phase = CheckpointStore.load(j.url) != nil ? "이어서 진행 대기 (\(Int(j.progress * 100))%)" : "대기 중"
        }
        startQueue()
    }

    // MARK: Apple language packs

    struct PackRequest: Identifiable, Equatable {
        let source: Language
        let target: Language
        var id: String { "\(source.code)>\(target.code)" }
        var label: String { "\(source.label) → \(target.label)" }
        var attempts = 0
        var status = "다운로드 요청 중…"
        var failed = false
    }

    /// Asks for a download (system prompt) — automatically only once per pair, then via the banner button.
    func requestPack(_ source: Language, _ target: Language, auto: Bool) {
        let key = "\(source.code)>\(target.code)"
        if !packs.contains(where: { $0.id == key }) { packs.append(PackRequest(source: source, target: target)) }
        if let i = packs.firstIndex(where: { $0.id == key }), !auto || packs[i].attempts == 0 {
            download(key)
        }
        startPackPoller()
    }

    func download(_ key: String) {
        guard let i = packs.firstIndex(where: { $0.id == key }) else { return }
        packs[i].attempts += 1
        packs[i].failed = false
        packs[i].status = "다운로드 중… (시도 \(packs[i].attempts))"
        downloadingKey = key
        let cfg = TranslationSession.Configuration(source: Locale.Language(identifier: packs[i].source.code),
                                                   target: Locale.Language(identifier: packs[i].target.code))
        if downloadConfig == cfg { downloadConfig?.invalidate() } else { downloadConfig = cfg }
    }

    /// Called from the main window's `.translationTask` with the session for `downloadConfig`.
    func performDownload(_ session: TranslationSession) async {
        let key = downloadingKey
        do {
            try await session.prepareTranslation()
            if let key, let i = packs.firstIndex(where: { $0.id == key }) { packs[i].status = "설치 확인 중…" }
        } catch {
            if let key, let i = packs.firstIndex(where: { $0.id == key }) {
                packs[i].failed = true
                packs[i].status = "다운로드 실패: \(error.localizedDescription)"
            }
        }
        await checkPacks()
    }

    /// Poll installation (also catches installs done in System Settings) and release waiting jobs.
    private func startPackPoller() {
        guard packPoller == nil else { return }
        packPoller = Task {
            while !packs.isEmpty {
                await checkPacks()
                try? await Task.sleep(for: .seconds(5))
            }
            packPoller = nil
        }
    }

    private func checkPacks() async {
        for p in packs where await LanguagePackMissing.status(p.source, p.target) == .installed {
            packs.removeAll { $0.id == p.id }
            for j in jobs {
                if case .needsPack(let key) = j.state, key == p.id {
                    j.state = .waiting; j.phase = "언어 팩 설치됨 · 이어서 진행 대기"
                }
            }
            pump()
        }
    }

    /// Fixed language pair + Apple translator: request the pack while recognition is still running.
    private func preflightLanguagePack() {
        let o = settings.options
        guard o.translator == .apple, o.layout != .original, o.sourceCode != "auto", o.sourceCode != o.targetCode else { return }
        let src = Language.byCode(o.sourceCode), tgt = Language.byCode(o.targetCode)
        Task {
            if await LanguagePackMissing.status(src, tgt) == .supported { requestPack(src, tgt, auto: true) }
        }
    }

    /// Manual request from the options bar ("언어 팩" button).
    func requestPackManually(source: String, target: String) {
        requestPack(Language.byCode(source == "auto" ? "en" : source), Language.byCode(target), auto: false)
    }

    // MARK: Ordering (priority)

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        jobs.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func move(_ job: Job, to index: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        let j = jobs.remove(at: i)
        jobs.insert(j, at: min(max(0, index), jobs.count))
        save()
    }

    func moveToBottom(_ job: Job) { move(job, to: jobs.count) }

    // MARK: Quit / restore

    /// Checkpoint every running job and persist the queue (called on quit).
    func suspendAllForQuit() async {
        for j in running { stop(j, .quit) }
        let deadline = Date().addingTimeInterval(8)
        while !running.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        writeQueue()
    }

    private var storeURL: URL { CheckpointStore.supportDir.appendingPathComponent("queue.json") }

    /// Coalesced save of the queue file.
    func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.saveScheduled = false
            self?.writeQueue()
        }
    }

    func saveNow() { writeQueue() }

    private func writeQueue() {
        let list = jobs.map { j -> PersistedJob in
            var state = "waiting", output: String?, err: String?
            switch j.state {
            case .waiting, .running, .needsPack: state = "waiting"   // re-evaluated on next run
            case .paused: state = "paused"
            case .done(let u): state = "done"; output = u.path
            case .skipped(let u): state = "skipped"; output = u.path
            case .failed(let m): state = "failed"; err = m
            case .cancelled: state = "cancelled"
            }
            return PersistedJob(id: j.id, path: j.url.path, state: state, output: output, error: err,
                                progress: j.progress, phase: j.phase, detail: j.detail, overwrite: j.overwrite)
        }
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: storeURL, options: .atomic) }
    }

    private func restore() {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([PersistedJob].self, from: data) else { return }
        for p in list {
            let url = URL(fileURLWithPath: p.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }   // media moved/deleted
            let job = Job(url: url, id: p.id)
            job.progress = p.progress
            job.phase = p.phase
            job.detail = p.detail
            job.overwrite = p.overwrite
            switch p.state {
            case "paused": job.state = .paused
            case "done": job.state = .done(URL(fileURLWithPath: p.output ?? job.outputURL.path))
            case "skipped": job.state = .skipped(URL(fileURLWithPath: p.output ?? job.outputURL.path))
            case "failed": job.state = .failed(p.error ?? "")
            case "cancelled": job.state = .cancelled
            default:
                job.state = .waiting
                if let cp = CheckpointStore.load(url) {
                    job.progress = cp.progress
                    job.phase = "이어서 진행 대기 (\(Int(cp.progress * 100))%)"
                } else {
                    job.progress = 0
                    job.phase = "대기 중"
                }
            }
            append(job)
        }
    }
}
