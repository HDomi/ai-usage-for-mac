import Foundation

/// GitHub main 의 VERSION 을 확인하고, 소스 체크아웃에서 update.sh 로 재빌드·재설치한다.
final class Updater {
    static let repo = "HDomi/ai-usage-for-mac"
    static let bundleID = "com.hdomi.ai-usage-for-mac"
    static let defaultAppPath = "/Applications/AI Usage.app"
    static let logPath = "\(UsageCore.home)/Library/Logs/ai-usage-for-mac/update.log"

    struct Latest: Equatable {
        let version: String
        let sha: String?
    }

    /// 레포 루트 (개발 실행 시). #filePath = Sources/AIUsageNotch/Updater.swift
    static var devRepoRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }

    static var currentVersion: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        if let v = try? String(contentsOfFile: devRepoRoot + "/VERSION", encoding: .utf8) {
            return v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "0.0.0"
    }

    static var isBundled: Bool { Bundle.main.bundlePath.hasSuffix(".app") }

    /// install.sh 가 기록한 소스 경로. 없으면 ~/.ai-usage-for-mac/src 로 clone 한다.
    static var sourceDir: String {
        if let d = UserDefaults.standard.string(forKey: "SourceDir"),
           FileManager.default.fileExists(atPath: d + "/update.sh") {
            return d
        }
        if !isBundled, FileManager.default.fileExists(atPath: devRepoRoot + "/update.sh") {
            return devRepoRoot
        }
        return "\(UsageCore.home)/.ai-usage-for-mac/src"
    }

    static func cmpVer(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<3 {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x > y { return 1 }
            if x < y { return -1 }
        }
        return 0
    }

    /// 동기. raw CDN(max-age=300) 회피를 위해 commits SHA 로 VERSION 을 핀한다.
    func fetchLatest() -> Latest? {
        let ts = Int(Date().timeIntervalSince1970)
        let script = """
        sha=$(curl -fsSL --max-time 8 -A "ai-usage-for-mac-updater" \
          -H "Accept: application/vnd.github.VERSION.sha" -H "Cache-Control: no-cache" \
          "https://api.github.com/repos/\(Self.repo)/commits/main" 2>/dev/null | tr -d "[:space:]")
        latest=""
        if printf "%s" "$sha" | grep -Eq "^[a-f0-9]{40}$"; then
          latest=$(curl -fsSL --max-time 8 -A "ai-usage-for-mac-updater" -H "Cache-Control: no-cache" \
            "https://raw.githubusercontent.com/\(Self.repo)/$sha/VERSION" 2>/dev/null | tr -d "[:space:]")
        fi
        if [ -z "$latest" ]; then
          latest=$(curl -fsSL --max-time 8 -A "ai-usage-for-mac-updater" -H "Cache-Control: no-cache" \
            "https://raw.githubusercontent.com/\(Self.repo)/main/VERSION?t=\(ts)" 2>/dev/null | tr -d "[:space:]")
        fi
        printf "%s %s" "$latest" "$sha"
        """
        guard let r = Shell.run("/bin/sh", ["-c", script]), r.status == 0 else { return nil }
        let parts = r.out.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let v = parts.first, !v.isEmpty else { return nil }
        let sha = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        return Latest(version: v, sha: sha)
    }

    /// update.sh 를 login shell 로 띄운다. 스크립트가 새 앱을 열고 이 프로세스를 종료한다.
    /// 실패(비정상 종료)하면 onFailure 에 로그 꼬리를 넘긴다.
    func runUpdate(onFailure: @escaping (String) -> Void) {
        let src = Self.sourceDir
        let appPath = Self.isBundled ? Bundle.main.bundlePath : Self.defaultAppPath
        let logDir = (Self.logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.logPath) {
            FileManager.default.createFile(atPath: Self.logPath, contents: nil)
        }

        let cmd = """
        set -e
        SRC="\(src)"
        if [ ! -f "$SRC/update.sh" ]; then
          echo "== 소스 없음 → clone: $SRC"
          mkdir -p "$(dirname "$SRC")"
          git clone --depth 1 "https://github.com/\(Self.repo).git" "$SRC"
        fi
        exec /bin/bash "$SRC/update.sh"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        var env = ProcessInfo.processInfo.environment
        env["AIU_OLD_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        env["AIU_APP_PATH"] = appPath
        env["AIU_LOG"] = Self.logPath
        p.environment = env
        if let fh = FileHandle(forWritingAtPath: Self.logPath) {
            fh.seekToEndOfFile()
            p.standardOutput = fh
            p.standardError = fh
        }
        p.terminationHandler = { proc in
            guard proc.terminationStatus != 0 else { return }
            let tail = Self.logTail(lines: 12)
            DispatchQueue.main.async { onFailure(tail) }
        }
        do {
            try p.run()
        } catch {
            onFailure("update.sh 실행 실패: \(error.localizedDescription)")
        }
    }

    static func logTail(lines: Int) -> String {
        guard let s = try? String(contentsOfFile: logPath, encoding: .utf8) else { return "" }
        return s.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
