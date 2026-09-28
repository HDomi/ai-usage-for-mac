import Foundation

enum UsageCoreError: LocalizedError {
    case nodeNotFound
    case scriptNotFound
    case exit(Int32, String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .nodeNotFound: return "node 또는 bun 을 찾을 수 없음 (Node.js 설치 필요)"
        case .scriptNotFound: return "usage-core.js 를 찾을 수 없음"
        case .exit(let code, let err): return "코어 종료 코드 \(code): \(err)"
        case .timeout: return "코어 응답 시간 초과 (90s)"
        }
    }
}

/// usage-core.js 를 node 로 실행해 UsageSnapshot 을 얻는다.
final class UsageCore {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// 실행기 후보를 PATH 무관하게 찾는다. Homebrew → nvm 최신 → bun → login shell
    static func locateRuntime() -> String? {
        var cands = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(home)/.nvm/versions/node/current/bin/node",
        ]
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let vers = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            let sorted = vers.filter { $0.hasPrefix("v") }.sorted { a, b in
                let pa = a.dropFirst().split(separator: ".").compactMap { Int($0) }
                let pb = b.dropFirst().split(separator: ".").compactMap { Int($0) }
                for i in 0..<3 {
                    let x = i < pa.count ? pa[i] : 0
                    let y = i < pb.count ? pb[i] : 0
                    if x != y { return x > y }
                }
                return false
            }
            cands += sorted.map { "\(nvmRoot)/\($0)/bin/node" }
        }
        cands.append("\(home)/.bun/bin/bun")
        for c in cands where FileManager.default.isExecutableFile(atPath: c) { return c }
        if let p = Shell.run("/bin/zsh", ["-lc", "command -v node || command -v bun"])?.out
            .trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty,
           FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    /// 번들 Resources → 개발 시 레포의 core/ 순으로 찾는다.
    static func locateScript() -> URL? {
        if let u = Bundle.main.url(forResource: "usage-core", withExtension: "js") { return u }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dev = repo.appendingPathComponent("core/usage-core.js")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private(set) var runtimePath: String?
    private(set) var scriptURL: URL?

    init() {
        runtimePath = Self.locateRuntime()
        scriptURL = Self.locateScript()
    }

    /// 동기 실행. 백그라운드 스레드에서 호출할 것.
    func fetch() throws -> UsageSnapshot {
        if runtimePath == nil { runtimePath = Self.locateRuntime() }
        guard let runtime = runtimePath else { throw UsageCoreError.nodeNotFound }
        guard let script = scriptURL else { throw UsageCoreError.scriptNotFound }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: runtime)
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [
            (runtime as NSString).deletingLastPathComponent,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        env["HOME"] = Self.home
        p.environment = env
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()

        var timedOut = false
        let timer = DispatchWorkItem { [weak p] in
            if let p, p.isRunning { timedOut = true; p.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        if timedOut { throw UsageCoreError.timeout }
        guard p.terminationStatus == 0 else {
            let e = String(data: errData, encoding: .utf8)?
                .split(separator: "\n").last.map(String.init) ?? ""
            throw UsageCoreError.exit(p.terminationStatus, e)
        }
        return try JSONDecoder().decode(UsageSnapshot.self, from: data)
    }
}

/// 짧은 셸 실행 헬퍼
enum Shell {
    struct Result { let status: Int32; let out: String; let err: String }

    @discardableResult
    static func run(_ launch: String, _ args: [String], env: [String: String]? = nil) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        if let env { p.environment = env }
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return nil }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(
            status: p.terminationStatus,
            out: String(data: od, encoding: .utf8) ?? "",
            err: String(data: ed, encoding: .utf8) ?? ""
        )
    }
}
