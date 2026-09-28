import AppKit
import Combine
import ServiceManagement

/// 노치 위치·크기. 노치 없는 화면이면 hasNotch=false 로 상단 중앙 가상 노치.
struct NotchGeometry: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool
    var screenFrame: CGRect

    static func detect() -> NotchGeometry {
        let screens = NSScreen.screens
        if let s = screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            let w = s.frame.width - l.width - r.width
            return NotchGeometry(
                notchWidth: w, notchHeight: s.safeAreaInsets.top,
                hasNotch: true, screenFrame: s.frame
            )
        }
        let s = NSScreen.main ?? screens.first
        let frame = s?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let menuBar = s.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24
        return NotchGeometry(
            notchWidth: 0, notchHeight: max(24, menuBar),
            hasNotch: false, screenFrame: frame
        )
    }
}

enum UpdateState: Equatable {
    case idle
    case running
    case failed(String)
}

@MainActor
final class NotchViewModel: ObservableObject {
    // 레이아웃 상수
    static let pillWidth: CGFloat = 64
    static let pillSpacing: CGFloat = 4
    static let wingPadding: CGFloat = 10
    static let virtualNotchWidth: CGFloat = 16
    static let expandedMinWidth: CGFloat = 640
    static let expandedMaxBody: CGFloat = 560

    @Published var geometry = NotchGeometry.detect()
    @Published var snapshot: UsageSnapshot?
    @Published var isExpanded = false
    @Published var isFetching = false
    @Published var fetchError: String?
    @Published var lastFetchAt: Date?
    @Published var latest: Updater.Latest?
    @Published var updateState: UpdateState = .idle
    @Published var launchAtLogin = false
    @Published var bodyHeight: CGFloat = 0

    let core = UsageCore()
    let updater = Updater()
    let version = Updater.currentVersion

    private var refreshTimer: Timer?
    private var updateTimer: Timer?
    private var clockTimer: Timer?
    @Published var tick = 0 // 리셋 카운트다운 갱신용

    var hasUpdate: Bool {
        guard let l = latest else { return false }
        return Updater.cmpVer(l.version, version) > 0
    }

    var leftItems: [BatteryItem] { snapshot?.leftItems ?? [] }
    var rightItems: [BatteryItem] { snapshot?.rightItems ?? [] }

    /// 양쪽 날개 폭 (대칭). 배터리 없으면 최소 폭.
    var wingWidth: CGFloat {
        let n = max(leftItems.count, rightItems.count, 1)
        return CGFloat(n) * Self.pillWidth + CGFloat(n - 1) * Self.pillSpacing + Self.wingPadding * 2
    }

    var notchSpan: CGFloat {
        geometry.hasNotch ? geometry.notchWidth : Self.virtualNotchWidth
    }

    var collapsedWidth: CGFloat { notchSpan + wingWidth * 2 }
    var expandedWidth: CGFloat { max(collapsedWidth, Self.expandedMinWidth) }
    var currentWidth: CGFloat { isExpanded ? expandedWidth : collapsedWidth }

    func dbg(_ m: String) {
        if ProcessInfo.processInfo.environment["AIU_DEBUG"] != nil {
            FileHandle.standardError.write("[\(Int(Date().timeIntervalSince1970) % 1000)] \(m)\n".data(using: .utf8)!)
        }
    }

    func start() {
        dbg("start")
        if ProcessInfo.processInfo.environment["AIU_DEBUG_EXPAND"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.dbg("auto-expand fire"); self.isExpanded = true; self.dbg("auto-expand set") }
        }
        refreshLoginState()
        dbg("login state ok")
        refresh()
        checkUpdate()
        dbg("timers")
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkUpdate() }
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick += 1 }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.geometry = NotchGeometry.detect() }
        }
    }

    func toggle() { isExpanded.toggle() }
    func collapse() { if isExpanded { isExpanded = false } }

    func refresh() {
        guard !isFetching else { return }
        isFetching = true
        let core = self.core
        dbg("fetch begin")
        Task.detached(priority: .utility) {
            let t0 = Date()
            let result = Result { try core.fetch() }
            await MainActor.run {
                self.dbg("fetch done \(Int(Date().timeIntervalSince(t0)))s main=\(Thread.isMainThread)")
                switch result {
                case .success(let snap):
                    self.snapshot = snap
                    self.fetchError = snap.errors.isEmpty ? nil : snap.errors.joined(separator: " · ")
                case .failure(let e):
                    self.fetchError = e.localizedDescription
                }
                self.lastFetchAt = Date()
                self.isFetching = false
            }
        }
    }

    func checkUpdate() {
        let updater = self.updater
        dbg("update check begin")
        Task.detached(priority: .background) {
            let t0 = Date()
            let l = updater.fetchLatest()
            await MainActor.run {
                self.dbg("update check done \(Int(Date().timeIntervalSince(t0)))s → \(String(describing: l))")
                if let l { self.latest = l }
            }
        }
    }

    func runUpdate() {
        guard updateState != .running else { return }
        updateState = .running
        updater.runUpdate { [weak self] tail in
            self?.updateState = .failed(tail.isEmpty ? "update.sh 실패 (로그 없음)" : tail)
        }
    }

    func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Updater.logPath))
    }

    func openRepo() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)")!)
    }

    func quit() { NSApp.terminate(nil) }

    // MARK: 로그인 시 실행 (SMAppService, macOS 13+)

    func refreshLoginState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            fetchError = "로그인 항목 변경 실패: \(error.localizedDescription)"
        }
        refreshLoginState()
    }
}
