import Foundation
import Network

struct Repo: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let nameWithOwner: String
    let sizeMB: Int
    var onDisk: Bool
}

// Non-isolated shell layer: runs `gh` / `repo`, feeding GH_TOKEN from the same
// file the SwiftBar plugin uses (a GUI process can't read the keychain).
enum Shell {
    static let gh: String = {
        for p in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "/opt/homebrew/bin/gh"
    }()

    // The `repo` CLI sits two levels up from the app bundle (<repo>/menubar/Repos.app).
    static let repoBin: String = {
        let up = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("repo").path
        for p in [up, NSHomeDirectory() + "/.local/bin/repo", NSHomeDirectory() + "/dev/repos/repo"]
            where FileManager.default.isExecutableFile(atPath: p) { return p }
        return up
    }()

    static let repoNotify: String = {
        let up = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("repo-notify").path
        for p in [up, NSHomeDirectory() + "/dev/repos/repo-notify"]
            where FileManager.default.isExecutableFile(atPath: p) { return p }
        return up
    }()

    static func token() -> String? {
        let path = NSHomeDirectory() + "/.config/gh/swiftbar-token"
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func lastLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).last.map(String.init) ?? s
    }

    private static func env(_ extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        env["PATH"] = "/opt/homebrew/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for (k, v) in extra { env[k] = v }
        return env
    }

    static func run(_ exe: String, _ args: [String], env extra: [String: String]) async -> (Int32, String, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.environment = env(extra)
                let o = Pipe(); let e = Pipe()
                p.standardOutput = o; p.standardError = e
                do { try p.run() } catch {
                    cont.resume(returning: (-1, "", "launch failed: \(error.localizedDescription)")); return
                }
                let od = o.fileHandleForReading.readDataToEndOfFile()
                let ed = e.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus,
                                        String(data: od, encoding: .utf8) ?? "",
                                        String(data: ed, encoding: .utf8) ?? ""))
            }
        }
    }

    // Like run(), but streams stderr chunks to onChunk as they arrive (for live
    // git clone progress). stdout is discarded.
    static func runStreaming(_ exe: String, _ args: [String], env extra: [String: String],
                             onChunk: @escaping (String) -> Void) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.environment = env(extra)
                p.standardOutput = FileHandle.nullDevice
                let e = Pipe()
                p.standardError = e
                let h = e.fileHandleForReading
                var collected = ""
                h.readabilityHandler = { fh in
                    let d = fh.availableData
                    guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                    collected += s
                    onChunk(s)
                }
                do { try p.run() } catch {
                    h.readabilityHandler = nil
                    cont.resume(returning: (-1, "launch failed: \(error.localizedDescription)")); return
                }
                p.waitUntilExit()
                h.readabilityHandler = nil
                let rest = h.readDataToEndOfFile()
                if let s = String(data: rest, encoding: .utf8) { collected += s }
                cont.resume(returning: (p.terminationStatus, collected))
            }
        }
    }

    private static let pctRegex = try! NSRegularExpression(pattern: "(\\d+)%")
    private static func firstPercent(_ s: String) -> Double? {
        let ns = s as NSString
        guard let m = pctRegex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2, let v = Double(ns.substring(with: m.range(at: 1))) else { return nil }
        return min(max(v / 100, 0), 1)
    }

    // Map git clone progress to one monotonic bar: Receiving objects 0–90%,
    // Resolving deltas 90–100%. The server-side "Enumerating" phase is ignored so
    // the bar doesn't jump to 100 and reset.
    static func clonePercent(_ chunk: String) -> Double? {
        var result: Double?
        for raw in chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let line = String(raw)
            if line.contains("Receiving objects"), let p = firstPercent(line) { result = p * 0.9 }
            else if line.contains("Resolving deltas"), let p = firstPercent(line) { result = 0.9 + p * 0.1 }
        }
        return result
    }
}

@MainActor
final class ReposModel: ObservableObject {
    @Published var repos: [Repo] = []
    @Published var search = ""
    @Published var loading = false
    @Published var busy: Set<String> = []
    @Published var progress: [String: Double] = [:]   // name -> 0...1 while cloning
    @Published var error: String?

    // In-app file browser navigation (nil browseRepo == repo list view).
    @Published var browseRepo: Repo?
    @Published var browsePath: URL?

    // Auto-reload when the network recovers, so a reconnect needs no manual refresh.
    private let monitor = NWPathMonitor()
    private var wasOnline = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if online && !self.wasOnline { await self.reload() }
                self.wasOnline = online
            }
        }
        monitor.start(queue: .global())
    }

    var reposDir: String {
        ProcessInfo.processInfo.environment["REPO_DIR"] ?? (NSHomeDirectory() + "/dev")
    }

    var filtered: [Repo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? repos : repos.filter { $0.name.lowercased().contains(q) }
    }
    var onDiskFiltered: [Repo] { filtered.filter(\.onDisk) }
    var cloudFiltered: [Repo] { filtered.filter { !$0.onDisk } }
    var onDiskCount: Int { repos.lazy.filter(\.onDisk).count }
    var onDiskMB: Int { repos.lazy.filter(\.onDisk).reduce(0) { $0 + $1.sizeMB } }

    func reload() async {
        loading = true
        defer { loading = false }
        guard let token = Shell.token() else {
            error = "No gh token at ~/.config/gh/swiftbar-token — run install.sh"; return
        }
        let (status, out, err) = await Shell.run(
            Shell.gh, ["repo", "list", "--limit", "200", "--json", "name,nameWithOwner,diskUsage"],
            env: ["GH_TOKEN": token])
        guard status == 0 else { error = "gh repo list failed: " + Shell.lastLine(err); return }

        struct GHRepo: Decodable { let name: String; let nameWithOwner: String; let diskUsage: Int }
        guard let data = out.data(using: .utf8),
              let list = try? JSONDecoder().decode([GHRepo].self, from: data) else {
            error = "couldn't parse gh output"; return
        }
        let fm = FileManager.default
        let dir = reposDir
        repos = list.map {
            Repo(name: $0.name, nameWithOwner: $0.nameWithOwner, sizeMB: $0.diskUsage / 1024,
                 onDisk: fm.fileExists(atPath: dir + "/" + $0.name + "/.git"))
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        error = nil
    }

    func toggle(_ repo: Repo) async {
        let name = repo.name
        guard !busy.contains(name) else { return }
        busy.insert(name)
        defer { busy.remove(name); progress[name] = nil }
        guard let token = Shell.token() else { return }

        if repo.onDisk {
            // Offload — fast filesystem removal, no meaningful progress.
            let (status, _, err) = await Shell.run(Shell.repoBin, ["off", name], env: ["GH_TOKEN": token])
            if status != 0 { error = "\(name): " + Shell.lastLine(err) }
            else { setOnDisk(name, false) }   // reflect immediately, don't wait for reload's network call
        } else {
            // Clone — stream git progress into progress[name]. Guard on busy so a
            // late chunk can't resurrect progress after we've cleaned up.
            let (status, err) = await Shell.runStreaming(
                Shell.repoBin, ["on", name], env: ["GH_TOKEN": token]
            ) { chunk in
                if let pct = Shell.clonePercent(chunk) {
                    Task { @MainActor in if self.busy.contains(name) { self.progress[name] = pct } }
                }
            }
            if status != 0 { error = "\(name): " + Shell.lastLine(err) }
            else { setOnDisk(name, true) }
        }
        await reload()
    }

    private func setOnDisk(_ name: String, _ value: Bool) {
        if let i = repos.firstIndex(where: { $0.id == name }) { repos[i].onDisk = value }
    }

    // MARK: - file browser navigation
    func open(_ repo: Repo) {
        guard repo.onDisk else { return }
        browseRepo = repo
        browsePath = URL(fileURLWithPath: reposDir + "/" + repo.name)
    }
    func descend(into url: URL) { browsePath = url }
    func ascend() {
        guard let repo = browseRepo, let path = browsePath else { return }
        let root = URL(fileURLWithPath: reposDir + "/" + repo.name).standardizedFileURL
        if path.standardizedFileURL == root { closeBrowser() }
        else { browsePath = path.deletingLastPathComponent() }
    }
    func closeBrowser() { browseRepo = nil; browsePath = nil }

    // Debug: fire a test notification (carries over the old SwiftBar Debug menu).
    func notifyTest(_ mode: String) {
        Task { _ = await Shell.run(Shell.repoNotify, [mode, "Debug", "Notifications are working ✓"], env: [:]) }
    }
}
