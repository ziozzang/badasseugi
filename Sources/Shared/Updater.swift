import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// GitHub-Releases self-updater (same scheme as ziozzang/sugyeol):
///   release tag `vX.Y.Z`, assets `<prefix>_<X.Y.Z>_macos_arm64.zip` (zipped .app) + `SHA256SUMS`.
/// Flow: check /releases/latest → compare versions → download → verify SHA-256 → unzip →
/// a detached helper waits for this process to exit, swaps the bundle and relaunches it.
/// Configured by Info.plist keys `UpdateRepo` (owner/name) and `UpdateAssetPrefix`.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let tag: String
        let notes: String
        let assetName: String
        let assetURL: URL
        let checksumsURL: URL
        let size: Int
    }

    static let shared = Updater()

    let repo: String
    let assetPrefix: String
    let currentVersion: String
    @Published private(set) var available: Release?
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    @Published var showPrompt = false

    private let checkInterval: TimeInterval = 24 * 3600
    private let lastCheckKey = "updater.lastCheck"
    private let skippedKey = "updater.skippedVersion"

    init(bundle: Bundle = .main) {
        repo = bundle.object(forInfoDictionaryKey: "UpdateRepo") as? String ?? ""
        assetPrefix = bundle.object(forInfoDictionaryKey: "UpdateAssetPrefix") as? String ?? ""
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var enabled: Bool { !repo.isEmpty }
    /// Automatic (background) checks can be turned off with NO_UPDATE_CHECK=1.
    var automaticEnabled: Bool { enabled && ProcessInfo.processInfo.environment["NO_UPDATE_CHECK"] == nil }

    /// Background check on launch / periodically; prompts only for versions the user hasn't skipped.
    func checkIfDue() {
        guard automaticEnabled else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= checkInterval else { return }
        Task { await check(userInitiated: false) }
    }

    /// Schedules `checkIfDue` on launch and then every few hours (cheap: it only hits the API once a day).
    func startAutomaticChecks() {
        guard automaticEnabled else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            checkIfDue()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3 * 3600))
                checkIfDue()
            }
        }
    }

    func check(userInitiated: Bool) async {
        guard enabled, !busy else { return }
        busy = true
        defer { busy = false }
        status = "Checking for updates…"
        do {
            let rel = try await fetchLatest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            if Self.compare(rel.version, currentVersion) > 0 {
                available = rel
                status = "Version \(rel.version) is available (current \(currentVersion))."
                let skipped = UserDefaults.standard.string(forKey: skippedKey)
                if userInitiated || skipped != rel.version { showPrompt = true }
            } else {
                available = nil
                status = "Up to date (\(currentVersion))."
                if userInitiated { showPrompt = true }
            }
        } catch {
            status = "Update check failed: \(error.localizedDescription)"
            if userInitiated { showPrompt = true }
        }
    }

    func skipThisVersion() {
        if let v = available?.version { UserDefaults.standard.set(v, forKey: skippedKey) }
        showPrompt = false
    }

    // MARK: GitHub

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 60)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("\(assetPrefix)-updater/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        return r
    }

    private func fetchLatest() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, resp) = try await URLSession.shared.data(for: request(url))
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("GitHub API HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let assets = json["assets"] as? [[String: Any]] else {
            throw UpdateError("Unexpected release format")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let name = "\(assetPrefix)_\(version)_macos_arm64.zip"
        func find(_ n: String) -> [String: Any]? { assets.first { $0["name"] as? String == n } }
        guard let asset = find(name), let aurl = (asset["browser_download_url"] as? String).flatMap(URL.init) else {
            throw UpdateError("Release \(tag) has no asset \(name)")
        }
        guard let sums = find("SHA256SUMS"), let surl = (sums["browser_download_url"] as? String).flatMap(URL.init) else {
            throw UpdateError("Release \(tag) has no SHA256SUMS")
        }
        return Release(version: version, tag: tag, notes: json["body"] as? String ?? "", assetName: name,
                       assetURL: aurl, checksumsURL: surl, size: asset["size"] as? Int ?? 0)
    }

    // MARK: Install

    /// Downloads, verifies and installs `available`, then quits (the helper relaunches the new version).
    func installAndRelaunch() async {
        guard available != nil, !busy else { return }
        do {
            try await install(relaunch: true)
            status = "Restarting…"
            NSApp.terminate(nil)
        } catch {
            status = "Update failed: \(error.localizedDescription)"
            showPrompt = true
        }
    }

    /// Download → verify SHA-256 → unzip → stage next to the app → detached helper swaps the bundle
    /// once this process has exited (and relaunches it if asked). The caller must then exit.
    func install(relaunch: Bool) async throws {
        guard let rel = available else { throw UpdateError("No update available") }
        busy = true
        defer { busy = false }
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else { throw UpdateError("Not running from an .app bundle") }
        let parent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("No write permission for \(parent.path). Move the app to a writable folder (e.g. /Applications or ~/Applications).")
        }
        status = "Downloading \(rel.version)…"
        let (sumData, _) = try await URLSession.shared.data(for: request(rel.checksumsURL))
        let sums = String(decoding: sumData, as: UTF8.self)
        guard let want = sums.split(separator: "\n").compactMap({ line -> String? in
            let f = line.split(whereSeparator: \.isWhitespace)
            return f.count == 2 && f[1] == Substring(rel.assetName) ? String(f[0]).lowercased() : nil
        }).first else { throw UpdateError("SHA256SUMS has no entry for \(rel.assetName)") }

        let (tmpZip, _) = try await URLSession.shared.download(for: request(rel.assetURL))
        let zipData = try Data(contentsOf: tmpZip, options: .mappedIfSafe)
        let got = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        guard got == want else { throw UpdateError("Checksum mismatch (got \(got.prefix(12))…, want \(want.prefix(12))…)") }

        status = "Installing \(rel.version)…"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Self.run("/usr/bin/ditto", ["-x", "-k", tmpZip.path, work.path])
        guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("No .app in the update archive") }
        let newVersion = Bundle(url: newApp)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard newVersion == rel.version else { throw UpdateError("Archive contains version \(newVersion ?? "?"), expected \(rel.version)") }
        // Stage next to the current app (same volume → atomic rename).
        let staged = parent.appendingPathComponent(".\(appURL.lastPathComponent).update")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: newApp, to: staged)
        try? FileManager.default.removeItem(at: work)
        try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        let script = """
        while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.3; done
        OLD="\(appURL.path)"; NEW="\(staged.path)"; BAK="$OLD.old"
        /bin/rm -rf "$BAK"
        /bin/mv "$OLD" "$BAK" && /bin/mv "$NEW" "$OLD" && /bin/rm -rf "$BAK" || { /bin/mv "$BAK" "$OLD" 2>/dev/null; }
        \(relaunch ? "/usr/bin/open \"$OLD\"" : "")
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()   // not waited on: it outlives this process
        status = "Update \(rel.version) staged; it is applied when the app exits."
    }

    /// `App --update [--check] [--force]`: non-interactive update (like `sugyeol update`). Exits the process.
    nonisolated static func handleCommandLineIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--update") else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            let u = Updater.shared
            print("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") ?? "app") \(u.currentVersion) · \(u.repo)")
            await u.check(userInitiated: true)
            print(u.status)
            guard !u.status.hasPrefix("Update check failed") else { exit(1) }
            guard let rel = u.available, !args.contains("--check") else { exit(0) }
            do {
                try await u.install(relaunch: false)
                print("Installing \(rel.version) — replaced as soon as this process exits.")
                exit(0)
            } catch {
                print("Update failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }

    // MARK: Helpers

    struct UpdateError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    static func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw UpdateError("\((path as NSString).lastPathComponent) failed (\(p.terminationStatus))") }
    }

    /// Numeric dotted-version compare ("1.10.0" > "1.9.2"); pre-release suffixes are ignored.
    static func compare(_ a: String, _ b: String) -> Int {
        func fields(_ v: String) -> [Int] {
            let core = v.trimmingCharacters(in: .whitespaces).drop { $0 == "v" }.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = fields(a), y = fields(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }
}

// MARK: - UI helpers

extension Updater {
    var promptTitle: String {
        if let a = available { return "Update available: \(a.version)" }
        return status.hasPrefix("Update") ? "Update" : "Software Update"
    }

    var promptMessage: String {
        guard let a = available else { return status }
        let notes = a.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Current version \(currentVersion) → \(a.version)"
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
            + (status.hasPrefix("Update failed") ? "\n\n⚠︎ " + status : "")
    }

    /// For menu-bar-only apps (no window to hang a SwiftUI alert on).
    func presentAlert() {
        showPrompt = false
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = promptTitle
        alert.informativeText = promptMessage
        if available != nil {
            alert.addButton(withTitle: "Install & Relaunch")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Skip This Version")
            switch alert.runModal() {
            case .alertFirstButtonReturn: Task { await installAndRelaunch() }
            case .alertThirdButtonReturn: skipThisVersion()
            default: break
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

/// "Check for Updates…" menu item.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater = Updater.shared
    var body: some View {
        Button(updater.busy ? "Checking for Updates…" : "Check for Updates…") {
            Task { await updater.check(userInitiated: true) }
        }
        .disabled(updater.busy || !updater.enabled)
    }
}

/// Alert shown when an update is found (or when a manual check finishes).
struct UpdatePrompt: ViewModifier {
    @ObservedObject var updater = Updater.shared
    func body(content: Content) -> some View {
        content.alert(updater.promptTitle, isPresented: $updater.showPrompt) {
            if updater.available != nil {
                Button("Install & Relaunch") { Task { await updater.installAndRelaunch() } }
                Button("Skip This Version") { updater.skipThisVersion() }
                Button("Later", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(updater.promptMessage)
        }
    }
}

extension View {
    func updatePrompt() -> some View { modifier(UpdatePrompt()) }
}
