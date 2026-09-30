import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import Translation

// MARK: - Settings

@MainActor
final class Settings: ObservableObject {
    /// Falls back to STT Trans' LLM settings so the endpoint only has to be entered once.
    private static let sttTrans = UserDefaults(suiteName: "net.jioh.stttrans")

    @AppStorage("sourceLang") var sourceCode = "auto"
    @AppStorage("autoCandidates") var autoCandidatesRaw = "en,ko,ja"
    @AppStorage("translator") var translatorRaw = SubtitleTranslator.apple.rawValue
    @AppStorage("targetLang") var targetCode = "ko"
    @AppStorage("layout") var layoutRaw = SubtitleLayout.both.rawValue
    @AppStorage("llmBaseURL") var llmBaseURL = sttTrans?.string(forKey: "llmBaseURL") ?? ""
    @AppStorage("llmAPIKey") var llmAPIKey = sttTrans?.string(forKey: "llmAPIKey") ?? ""
    @AppStorage("llmModel") var llmModel = sttTrans?.string(forKey: "llmModel") ?? "gemma-4-31b-it"
    @AppStorage("llmSystemAsUser") var llmSystemAsUser = sttTrans?.bool(forKey: "llmSystemAsUser") ?? false
    @AppStorage("googleAPIKey") var googleAPIKey = sttTrans?.string(forKey: "googleAPIKey") ?? ""
    @AppStorage("userContext") var userContext = ""
    @AppStorage("vadMode") var vadModeRaw = VADMode.silero.rawValue
    /// Files processed at the same time. Recognition scales ~2x up to 3 jobs on an M1 (measured).
    @AppStorage("concurrency") var concurrency = Settings.defaultConcurrency
    @AppStorage("skipExisting") var skipExisting = true

    static var defaultConcurrency: Int {
        var n: Int32 = 0; var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0)   // performance cores
        return min(4, max(2, Int(n) - 1))
    }

    var translator: SubtitleTranslator { SubtitleTranslator(rawValue: translatorRaw) ?? .apple }

    var options: GeneratorOptions {
        var o = GeneratorOptions()
        o.sourceCode = sourceCode
        o.autoCandidates = autoCandidatesRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        o.translator = translator
        o.targetCode = targetCode
        o.layout = SubtitleLayout(rawValue: layoutRaw) ?? .both
        o.llm = LLMConfig(baseURL: llmBaseURL, apiKey: llmAPIKey, model: llmModel, temperature: 0.2,
                          historyTurns: 6, systemAsUser: llmSystemAsUser)
        o.googleAPIKey = googleAPIKey
        o.userContext = userContext
        o.vadMode = VADMode(rawValue: vadModeRaw) ?? .silero
        return o
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var queue: JobQueue?
    var pendingURLs: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Checkpoint running jobs and save the queue so the next launch continues where this one stopped.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let queue else { return .terminateNow }
        let busy = MainActor.assumeIsolated { () -> Bool in
            if queue.running.isEmpty { queue.saveNow(); return false }
            return true
        }
        guard busy else { return .terminateNow }
        Task { @MainActor in
            await queue.suspendAllForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Files dropped on the Dock icon / "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            if let queue { queue.add(urls) } else { pendingURLs += urls }
        }
    }
}

struct SamiGenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: Settings
    @StateObject private var queue: JobQueue

    init() {
        let s = Settings()
        _settings = StateObject(wrappedValue: s)
        _queue = StateObject(wrappedValue: JobQueue(settings: s))
    }

    var body: some Scene {
        WindowGroup("Badasseugi") {
            MainView()
                .environmentObject(settings).environmentObject(queue)
                .frame(minWidth: 720, minHeight: 420)
                .updatePrompt()
                .onAppear {
                    appDelegate.queue = queue
                    Updater.shared.startAutomaticChecks()
                    if let files = ProcessInfo.processInfo.environment["SAMIGEN_SELFTEST"] {
                        SelfTest.run(queue: queue, files: files.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
                    }
                    queue.add(appDelegate.pendingURLs); appDelegate.pendingURLs = []
                    NSApp.activate()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        }
        SwiftUI.Settings { SettingsView().environmentObject(settings) }
    }
}

@main
enum Main {
    static func main() {
        Updater.handleCommandLineIfRequested()   // `--update [--check]`
        if CommandLine.arguments.contains("--cli") {
            CLI.run()
        } else {
            SamiGenApp.main()
        }
    }
}

// MARK: - Views

struct MainView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var queue: JobQueue
    @State private var dropHover = false
    @State private var appleConfig: TranslationSession.Configuration?

    var body: some View {
        VStack(spacing: 0) {
            optionsBar
            Divider()
            ZStack {
                if queue.jobs.isEmpty {
                    DropHint(active: dropHover)
                } else {
                    List {
                        ForEach(Array(queue.jobs.enumerated()), id: \.element.id) { i, job in
                            JobRow(job: job, index: i + 1, total: queue.jobs.count)
                        }
                        .onMove { queue.move(fromOffsets: $0, toOffset: $1) }   // drag = priority
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    if dropHover {
                        RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: .init(lineWidth: 3, dash: [8]))
                            .padding(8).allowsHitTesting(false)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in queue.add([url]) } }
                    }
                }
                return true
            }
            Divider()
            HStack {
                Button { openPanel() } label: { Label("파일 추가…", systemImage: "plus") }
                Spacer()
                Text(footer).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("완료 항목 지우기") { queue.clearFinished() }
                    .disabled(!queue.hasFinished)
                    .help("완료·실패·취소된 항목을 목록에서 지웁니다")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .translationTask(appleConfig) { session in try? await session.prepareTranslation() }
    }

    private var footer: String {
        let total = queue.jobs.count
        guard total > 0 else { return "동영상/오디오 파일을 끌어다 놓으면 같은 이름의 .smi 가 만들어집니다" }
        func count(_ f: (Job.State) -> Bool) -> Int { queue.jobs.filter { f($0.state) }.count }
        let done = count { if case .done = $0 { true } else if case .skipped = $0 { true } else { false } }
        let waiting = count { $0 == .waiting }, paused = count { $0 == .paused }
        var parts = ["실행 \(queue.running.count)/\(queue.maxConcurrent)", "대기 \(waiting)"]
        if paused > 0 { parts.append("일시정지 \(paused)") }
        parts.append("완료 \(done)/\(total)")
        return parts.joined(separator: " · ") + "  —  드래그로 순서(우선순위) 변경"
    }

    private var optionsBar: some View {
        HStack(spacing: 12) {
            Picker("음성", selection: $settings.sourceCode) {
                Text("자동 감지").tag("auto")
                Divider()
                ForEach(Language.all) { Text($0.label).tag($0.code) }
            }
            .fixedSize()
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("번역", selection: $settings.translatorRaw) {
                ForEach(SubtitleTranslator.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .fixedSize()
            if settings.translator != .none {
                Picker("", selection: $settings.targetCode) {
                    ForEach(Language.all) { Text($0.label).tag($0.code) }
                }
                .labelsHidden().fixedSize()
                Picker("자막", selection: $settings.layoutRaw) {
                    ForEach(SubtitleLayout.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .fixedSize()
            }
            if settings.translator == .apple {
                Button("언어 팩") {
                    let src = settings.sourceCode == "auto" ? "en" : settings.sourceCode
                    let cfg = TranslationSession.Configuration(source: Locale.Language(identifier: src),
                                                               target: Locale.Language(identifier: settings.targetCode))
                    if appleConfig == cfg { appleConfig?.invalidate() } else { appleConfig = cfg }
                }
                .help("Apple 온디바이스 번역 언어 팩 다운로드")
            }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }.help("설정 (⌘,)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func openPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = JobQueue.mediaTypes + JobQueue.extraExtensions.compactMap { UTType(filenameExtension: $0) }
        if p.runModal() == .OK { queue.add(p.urls) }
    }
}

struct DropHint: View {
    let active: Bool
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 54, weight: .light))
            Text("동영상을 여기에 끌어다 놓으세요").font(.title3.weight(.medium))
            Text("mp4 · mov · mkv · webm · avi · mp3 · m4a …  (폴더도 가능)").font(.caption).foregroundStyle(.secondary)
        }
        .foregroundStyle(active ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(active ? Color.accentColor : Color.secondary.opacity(0.4), style: .init(lineWidth: 2, dash: [8]))
            .padding(16))
    }
}

struct JobRow: View {
    @ObservedObject var job: Job
    let index: Int
    let total: Int
    @EnvironmentObject var queue: JobQueue

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.url.path))
                .resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(index)/\(total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(job.url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(statusText).font(.caption.monospacedDigit()).foregroundStyle(statusColor)
                }
                ProgressView(value: job.progress)
                    .tint(statusColor)
                    .opacity(job.state == .waiting ? 0.4 : 1)
                HStack {
                    Text(job.phase).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    if !job.detail.isEmpty { Text("· \(job.detail)").font(.caption).foregroundStyle(.secondary) }
                    if case .failed(let msg) = job.state {
                        Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
            actions
        }
        .padding(.vertical, 4)
        .contextMenu { menu }
    }

    private var statusText: String {
        switch job.state {
        case .running: "\(Int(job.progress * 100))%"
        case .waiting: job.progress > 0 ? "대기 \(Int(job.progress * 100))%" : "대기"
        case .paused: "일시정지 \(Int(job.progress * 100))%"
        case .done: "완료"
        case .skipped: "건너뜀"
        case .failed: "실패"
        case .cancelled: "취소됨"
        }
    }

    private var statusColor: Color {
        switch job.state {
        case .done: .green
        case .skipped: .teal
        case .failed: .red
        case .paused: .orange
        case .cancelled: .secondary
        default: .accentColor
        }
    }

    private var output: URL? {
        switch job.state { case .done(let u), .skipped(let u): u; default: nil }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            switch job.state {
            case .running:
                Button { queue.pause(job) } label: { Image(systemName: "pause.circle") }
                    .help("일시정지 (지금까지 한 것은 저장됩니다)")
                Button { queue.cancel(job) } label: { Image(systemName: "xmark.circle") }.help("취소")
            case .waiting:
                Button { queue.startNow(job) } label: { Image(systemName: "bolt.circle") }
                    .help("지금 시작: 맨 위로 올리고 바로 실행 (자리가 없으면 가장 낮은 순위 작업이 저장 후 양보)")
                Button { queue.pause(job) } label: { Image(systemName: "pause.circle") }.help("일시정지")
                Button { queue.cancel(job) } label: { Image(systemName: "xmark.circle") }.help("취소")
            case .paused:
                Button { queue.resume(job) } label: { Image(systemName: "play.circle") }.help("재개 (대기열로)")
                Button { queue.startNow(job) } label: { Image(systemName: "bolt.circle") }.help("지금 시작")
                Button { queue.cancel(job) } label: { Image(systemName: "xmark.circle") }.help("취소")
            case .done, .skipped:
                if let out = output {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([out]) } label: { Image(systemName: "folder") }
                        .help("Finder에서 보기")
                }
                Button { NSWorkspace.shared.open(job.url) } label: { Image(systemName: "play.rectangle") }
                    .help("동영상 열기 (같은 폴더의 .smi 를 플레이어가 자동으로 불러옵니다)")
            case .failed, .cancelled:
                Button { queue.retry(job) } label: { Image(systemName: "arrow.clockwise") }
                    .help("다시 시도 (저장된 곳부터 이어서)")
            }
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }

    @ViewBuilder var menu: some View {
        if job.state != .running {
            Button("지금 시작") { queue.startNow(job) }
        }
        if job.state == .running || job.state == .waiting { Button("일시정지") { queue.pause(job) } }
        if job.state == .paused { Button("재개") { queue.resume(job) } }
        Divider()
        Button("맨 위로") { queue.move(job, to: 0) }
        Button("맨 아래로") { queue.moveToBottom(job) }
        Divider()
        if job.state != .running { Button("다시 만들기 (덮어쓰기)") { queue.redo(job) } }
        if let out = output { Button("Finder에서 .smi 보기") { NSWorkspace.shared.activateFileViewerSelecting([out]) } }
        Button("Finder에서 동영상 보기") { NSWorkspace.shared.activateFileViewerSelecting([job.url]) }
        Divider()
        if job.isActive { Button("취소") { queue.cancel(job) } }
        Button("목록에서 제거") { queue.remove(job) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    var body: some View {
        Form {
            Section("음성 언어 자동 감지 후보") {
                TextField("언어 코드 (쉼표 구분)", text: $settings.autoCandidatesRaw, prompt: Text("en,ko,ja"))
                Text("후보가 많을수록 감지가 느려집니다. 코드: " + Language.all.map(\.code).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("처리") {
                Stepper("동시 처리 파일 수: \(settings.concurrency)", value: $settings.concurrency, in: 1...6)
                Text("M1 측정: 3개 동시 처리 시 약 2배 빠름 (그 이상은 효과가 거의 없음). 기본값 \(Settings.defaultConcurrency)")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("같은 이름의 .smi 가 이미 있으면 건너뛰기", isOn: $settings.skipExisting)
                Text("진행 중인 작업은 동영상 옆 '이름.smi.tmp' 에 수시로 저장되어, 종료·충돌 후에도 이어서 진행됩니다. 완료되면 삭제됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("음성 구간 검출 (VAD)") {
                Picker("방식", selection: $settings.vadModeRaw) {
                    ForEach(VADMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Text("Silero: 음악·효과음·잡음을 걸러내고 말소리만 인식기에 보냅니다 (권장). 음량 기반: 조용한 녹음용.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("LLM (OpenAI 호환)") {
                TextField("Base URL", text: $settings.llmBaseURL, prompt: Text("https://host/v1"))
                SecureField("API Key", text: $settings.llmAPIKey)
                TextField("Model", text: $settings.llmModel)
                Toggle("system 역할을 user 메시지에 합치기", isOn: $settings.llmSystemAsUser)
            }
            Section("Google") {
                SecureField("Cloud Translation API Key (비우면 무료 엔드포인트)", text: $settings.googleAPIKey)
            }
            Section("맥락 / 용어집") {
                TextEditor(text: $settings.userContext).font(.system(size: 12, design: .monospaced)).frame(minHeight: 100)
                Text("번역 프롬프트에 포함되고, 짧은 줄은 음성 인식 힌트로도 쓰입니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
    }
}

// MARK: - Self test (drives the same queue actions as the UI buttons)

@MainActor
enum SelfTest {
    static func log(_ q: JobQueue, _ step: String) {
        let states = q.jobs.map { j -> String in
            let s: String = switch j.state {
            case .waiting: "waiting"; case .running: "RUNNING"; case .paused: "paused"
            case .done: "done"; case .skipped: "skipped"; case .failed(let m): "failed(\(m.prefix(30)))"; case .cancelled: "cancelled"
            }
            return "\(j.url.deletingPathExtension().lastPathComponent)=\(s)\(Int(j.progress * 100))%"
        }
        FileHandle.standardError.write("[selftest] \(step): \(states.joined(separator: " "))\n".data(using: .utf8)!)
    }

    static func run(queue q: JobQueue, files: [URL]) {
        Task {
            q.add(files)
            log(q, "added (slots \(q.maxConcurrent))")
            try? await Task.sleep(for: .seconds(3))
            log(q, "t=3s")
            if let last = q.jobs.last { q.startNow(last); log(q, "startNow(\(last.url.lastPathComponent)) requested") }
            try? await Task.sleep(for: .seconds(2))
            log(q, "t=5s after preemption")
            if let r = q.running.first { q.pause(r); log(q, "pause(\(r.url.lastPathComponent)) requested") }
            try? await Task.sleep(for: .seconds(2))
            log(q, "t=7s")
            if let p = q.jobs.first(where: { $0.state == .paused }) { q.resume(p); log(q, "resume(\(p.url.lastPathComponent))") }
            if q.jobs.count > 2 { q.move(fromOffsets: IndexSet(integer: q.jobs.count - 1), toOffset: 0); log(q, "dragged last to top") }
            while q.jobs.contains(where: { $0.isActive }) {
                try? await Task.sleep(for: .seconds(5)); log(q, "…")
            }
            log(q, "ALL FINISHED")
            q.add(files)   // re-adding finished files must skip (existing .smi)
            try? await Task.sleep(for: .seconds(1))
            log(q, "re-added same files")
            DispatchQueue.main.async { NSApp.terminate(nil) }   // outside this main-actor job
        }
    }
}

// MARK: - CLI

/// SamiGen --cli <files…> [--lang auto|en|ko…] [--translate none|apple|google|llm] [--to ko] [--layout both|translation|original]
enum CLI {
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var args = Array(CommandLine.arguments.dropFirst()).filter { $0 != "--cli" }
        var o = GeneratorOptions()
        o.translator = .none
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
        }
        if let v = value("--lang") { o.sourceCode = v }
        if let v = value("--to") { o.targetCode = v }
        if let v = value("--translate") {
            o.translator = ["apple": .apple, "google": .google, "llm": .llm][v] ?? .none
        }
        let cpPath = value("--checkpoint")
        let stopAfter = value("--stop-after").flatMap(Double.init)
        if let v = value("--vad") { o.vadMode = v == "energy" ? .energy : .silero }
        if let v = value("--layout") {
            o.layout = ["both": .both, "translation": .translation, "original": .original][v] ?? .both
        }
        let env = ProcessInfo.processInfo.environment
        o.llm = LLMConfig(baseURL: env["STTTRANS_API_BASE"] ?? "", apiKey: env["STTTRANS_API_KEY"] ?? "",
                          model: env["STTTRANS_MODEL"] ?? "gemma-4-31b-it", temperature: 0.2, historyTurns: 6, systemAsUser: false)
        let files = args.map { URL(fileURLWithPath: $0) }
        Task.detached {
            var failed = false
            for f in files {
                let t0 = Date()
                final class Last: @unchecked Sendable { var v = -1; var phase = "" }
                let last = Last()
                let cpURL = cpPath.map { URL(fileURLWithPath: $0) }
                let resume = cpURL.flatMap { try? JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: $0)) }
                if let resume { print(String(format: "  resuming: recognized until %.1fs, %d words, cues=%@, translated=%d",
                                              resume.recognizedUntil, resume.words.count,
                                              resume.cues.map { String($0.count) } ?? "-", resume.translated)) }
                let gen = SubtitleGenerator(url: f, options: o, resume: resume, progress: { p, phase in
                    let pct = Int(p * 100)
                    let kind = String(phase.prefix { $0 != "·" })
                    if pct / 10 != last.v / 10 || kind != last.phase { last.v = pct; last.phase = kind; print("  \(pct)% \(phase)") }
                }, save: { cp in
                    if let cpURL { try? JSONEncoder().encode(cp).write(to: cpURL, options: .atomic) }
                })
                print("▶ \(f.lastPathComponent)")
                do {
                    let work = Task { try await gen.run() }
                    if let stopAfter {
                        Task { try? await Task.sleep(for: .seconds(stopAfter)); work.cancel() }
                    }
                    let r = try await work.value
                    print(String(format: "✓ %@ (%d cues, lang=%@, %.1fs)", r.url.path, r.cues,
                                 gen.detectedLanguage ?? "?", Date().timeIntervalSince(t0)))
                } catch is CancellationError {
                    let c = gen.checkpoint
                    print(String(format: "⏸ stopped: recognized until %.1fs (%d words), cues=%@, translated=%d",
                                 c.recognizedUntil, c.words.count, c.cues.map { String($0.count) } ?? "-", c.translated))
                    failed = true
                } catch { failed = true; print("✗ \(error.localizedDescription)") }
            }
            exit(failed ? 1 : 0)
        }
        dispatchMain()   // keep the main queue/run loop free: the Translation framework needs it
    }
}
