import AppKit
import Combine
import ServiceManagement

/// 노치 위치·크기. 노치 없는 화면이면 hasNotch=false 로 상단 중앙 가상 노치.
struct NotchGeometry: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool
    var screenFrame: CGRect
    /// 노치(또는 가상 노치) 왼쪽 끝. 화면 좌표
    var notchMinX: CGFloat

    var notchMaxX: CGFloat { notchMinX + notchWidth }
    var notchMidX: CGFloat { notchMinX + notchWidth / 2 }

    static func detect() -> NotchGeometry {
        let screens = NSScreen.screens
        if let s = screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            let w = s.frame.width - l.width - r.width
            return NotchGeometry(
                notchWidth: w, notchHeight: s.safeAreaInsets.top,
                hasNotch: true, screenFrame: s.frame,
                notchMinX: s.frame.minX + l.width
            )
        }
        let s = NSScreen.main ?? screens.first
        let frame = s?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let menuBar = s.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24
        let w = NotchViewModel.virtualNotchWidth
        return NotchGeometry(
            notchWidth: w, notchHeight: max(24, menuBar),
            hasNotch: false, screenFrame: frame,
            notchMinX: frame.midX - w / 2
        )
    }
}

/// 알약 스타일. compact = 배터리 아이콘 없이 라벨 + 숫자만
enum PillStyle: Equatable { case full, compact }

/// 한쪽 날개에 실제로 그릴 것
struct WingLayout: Equatable {
    var items: [BatteryItem]
    var style: PillStyle
    var width: CGFloat
}

enum UpdateState: Equatable {
    case idle
    case running
    case failed(String)
}

@MainActor
final class NotchViewModel: ObservableObject {
    // 레이아웃 상수
    static let pillWidth: CGFloat = 56
    static let compactPillWidth: CGFloat = 40
    static let pillSpacing: CGFloat = 4
    static let wingPadding: CGFloat = 10
    /// 배터리 숨김 모드의 세로 배터리 아이콘 폭
    static let miniIconWidth: CGFloat = 10
    /// 날개와 이웃(앱 메뉴·상태 아이콘) 사이 최소 간격
    static let edgeMargin: CGFloat = 8
    nonisolated static let virtualNotchWidth: CGFloat = 16
    static let expandedMinWidth: CGFloat = 720
    static let expandedMaxBody: CGFloat = 560
    /// AIU_ANIM=초 로 늘려서 애니메이션 프레임 확인 가능 (디버그용)
    static let animDuration: Double = ProcessInfo.processInfo.environment["AIU_ANIM"].flatMap(Double.init) ?? 0.15

    @Published var geometry = NotchGeometry.detect()
    @Published var snapshot: UsageSnapshot?
    /// 논리 상태. 펼침 애니메이션 목표
    @Published var isExpanded = false
    /// 본문이 렌더돼 있고 창이 펼침 크기인 상태. 접을 땐 애니메이션이 끝난 뒤 false
    @Published var bodyVisible = false
    @Published var isFetching = false
    @Published var fetchError: String?
    @Published var lastFetchAt: Date?
    @Published var latest: Updater.Latest?
    @Published var updateState: UpdateState = .idle
    @Published var launchAtLogin = false
    @Published var bodyHeight: CGFloat = 0
    @Published var occupancy = MenuBarOccupancy.unknown
    /// 노치 화면이 다른 앱 풀스크린 중. 패널을 숨긴다
    @Published var fullScreenActive = false
    @Published var axTrusted = AXIsProcessTrusted()
    /// false 면 접힘 상태에서 알약 대신 노치 옆 세로 배터리 아이콘 하나만 그린다
    @Published var alwaysShowBatteries =
        UserDefaults.standard.object(forKey: NotchViewModel.alwaysShowKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(alwaysShowBatteries, forKey: Self.alwaysShowKey)
            onLayout?()
        }
    }

    /// 창 프레임 재계산 (NotchController 가 연결). 펼칠 땐 SwiftUI 렌더 전에 동기로 불러야
    /// 창 크기 변화가 reveal 애니메이션과 같은 트랜잭션에 섞이지 않는다
    var onLayout: (() -> Void)?

    let core = UsageCore()
    let updater = Updater()
    let version = Updater.currentVersion

    private var refreshTimer: Timer?
    private var updateTimer: Timer?
    private var clockTimer: Timer?
    private var probeTimer: Timer?
    private var probing = false
    private var probeAgain = false
    private var checkingUpdate = false
    private var lastUpdateCheckAt: Date?
    private var screenAwake = true
    private var systemAwake = true
    private var sessionActive = true
    private var started = false
    private var pendingProbe: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @Published var tick = 0 // 리셋 카운트다운 갱신용

    private var backgroundActive: Bool { screenAwake && systemAwake && sessionActive }
    private var refreshInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 600 : (isExpanded ? 120 : 300)
    }

    var hasUpdate: Bool {
        guard let l = latest else { return false }
        return Updater.cmpVer(l.version, version) > 0
    }

    var leftItems: [BatteryItem] { snapshot?.leftItems ?? [] }
    var rightItems: [BatteryItem] { snapshot?.rightItems ?? [] }
    /// 세로 배터리 아이콘에 표시할 잔량. 가장 적게 남은 항목 기준
    var minRemain: Double? { (leftItems + rightItems).map(\.remain).min() }

    // MARK: 날개 레이아웃 (메뉴바 점유 폭에 맞춰 좌우 따로)

    static func pillWidth(_ style: PillStyle) -> CGFloat {
        style == .full ? pillWidth : compactPillWidth
    }

    static func wingWidth(count n: Int, style: PillStyle) -> CGFloat {
        guard n > 0 else { return wingPadding * 2 }
        return CGFloat(n) * pillWidth(style) + CGFloat(n - 1) * pillSpacing + wingPadding * 2
    }

    /// 공간 정책: 다 들어가면 full, 아니면 compact, 그래도 넘치면 priority 큰 것부터 숨김.
    /// available=nil 은 측정 불가 → 제한 없음.
    static func fit(_ items: [BatteryItem], available: CGFloat?, minWidth: CGFloat = 0) -> WingLayout {
        let full = wingWidth(count: items.count, style: .full)
        guard let avail = available, full > avail else {
            return WingLayout(items: items, style: .full, width: max(full, minWidth))
        }
        var kept = items
        while !kept.isEmpty, wingWidth(count: kept.count, style: .compact) > avail {
            if let drop = kept.indices.max(by: { kept[$0].priority < kept[$1].priority }) {
                kept.remove(at: drop) // 표시 순서는 유지
            }
        }
        return WingLayout(items: kept, style: .compact,
                          width: max(wingWidth(count: kept.count, style: .compact), minWidth))
    }

    /// 노치 왼쪽에 남은 폭. nil = 앱 메뉴 폭을 모름(접근성 권한 없음)
    var leftAvailable: CGFloat? {
        occupancy.left.map { (geometry.notchMinX - geometry.screenFrame.minX) - $0 - Self.edgeMargin }
    }

    var rightAvailable: CGFloat {
        (geometry.screenFrame.maxX - geometry.notchMaxX) - occupancy.right - Self.edgeMargin
    }

    /// 배터리 숨김 + 접힘. 펼친 동안(bodyVisible)은 기존 알약을 그대로 보여준다
    var miniMode: Bool { !alwaysShowBatteries && !bodyVisible }

    var leftLayout: WingLayout {
        if miniMode { return WingLayout(items: [], style: .compact, width: 0) }
        return Self.fit(leftItems, available: leftAvailable)
    }

    var rightLayout: WingLayout {
        if miniMode {
            return WingLayout(items: [], style: .compact, width: Self.miniIconWidth + Self.wingPadding * 2)
        }
        // 둘 다 비면 오른쪽에 자리표시자를 그리므로 알약 하나 폭은 확보
        let minW = leftItems.isEmpty && rightItems.isEmpty ? Self.pillWidth + Self.wingPadding * 2 : 0
        return Self.fit(rightItems, available: rightAvailable, minWidth: minW)
    }

    var wingLeft: CGFloat { leftLayout.width }
    var wingRight: CGFloat { rightLayout.width }
    var notchSpan: CGFloat { geometry.notchWidth }

    var collapsedWidth: CGFloat { wingLeft + notchSpan + wingRight }
    /// 펼침은 노치 중심 대칭. 접힘 날개가 잘리지 않을 만큼은 넓힌다
    var expandedWidth: CGFloat {
        max(Self.expandedMinWidth, notchSpan + 2 * max(wingLeft, wingRight))
    }
    var currentWidth: CGFloat { bodyVisible ? expandedWidth : collapsedWidth }

    /// 창 왼쪽 x. 접힘: 노치 왼쪽 끝에서 왼쪽 날개만큼. 펼침: 노치 중심 기준 대칭
    var panelX: CGFloat {
        bodyVisible ? geometry.notchMidX - expandedWidth / 2 : geometry.notchMinX - wingLeft
    }
    /// 헤더 안에서 노치 자리가 시작하는 오프셋
    var headerLeftWidth: CGFloat { geometry.notchMinX - panelX }

    func dbg(_ m: String) {
        if ProcessInfo.processInfo.environment["AIU_DEBUG"] != nil {
            FileHandle.standardError.write("[\(Int(Date().timeIntervalSince1970) % 1000)] \(m)\n".data(using: .utf8)!)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        dbg("start")
        if let env = ProcessInfo.processInfo.environment["AIU_DEBUG_EXPAND"] {
            // 값이 초(≥2)면 그 시각에 펼치고 2초 뒤 접는다. 아니면 4초
            let t = max(Double(env) ?? 4, 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { self.dbg("auto-expand fire"); self.setExpanded(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 2) { self.dbg("auto-collapse fire"); self.setExpanded(false) }
        }
        refreshLoginState()
        dbg("login state ok")
        requestAccessibilityOnce()
        observeEnvironment()
        probe()
        refresh()
        checkUpdate()
        configureTimers()
    }

    // MARK: 백그라운드 작업 (화면·세션 활성 상태에서만)

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (NotchViewModel) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    private func observeEnvironment() {
        observe(.default, NSApplication.didChangeScreenParametersNotification) { vm in
            let geometry = NotchGeometry.detect()
            if vm.geometry != geometry { vm.geometry = geometry }
            vm.scheduleProbe()
        }
        observe(.default, .NSProcessInfoPowerStateDidChange) { $0.configureTimers() }
        let workspace = NSWorkspace.shared.notificationCenter
        // 앱 전환 직후엔 새 메뉴바가 AX 에 아직 안 올라와 있어 잠깐 뒤에 잰다
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            observe(workspace, name) { $0.scheduleProbe() }
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { vm in
            vm.changeActivity { vm.screenAwake = false }
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { vm in
            vm.changeActivity { vm.screenAwake = true }
        }
        observe(workspace, NSWorkspace.willSleepNotification) { vm in
            vm.changeActivity { vm.systemAwake = false }
        }
        observe(workspace, NSWorkspace.didWakeNotification) { vm in
            vm.changeActivity { vm.systemAwake = true }
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { vm in
            vm.changeActivity { vm.sessionActive = false }
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { vm in
            vm.changeActivity { vm.sessionActive = true }
        }
    }

    private func changeActivity(_ change: () -> Void) {
        let wasActive = backgroundActive
        change()
        guard wasActive != backgroundActive else { return }
        if !backgroundActive {
            pendingProbe?.cancel()
            pendingProbe = nil
            collapse()
        } else {
            probe()
            refreshIfStale()
            if Date().timeIntervalSince(lastUpdateCheckAt ?? .distantPast) >= 3600 { checkUpdate() }
        }
        configureTimers()
    }

    private func invalidateTimers() {
        for timer in [refreshTimer, updateTimer, clockTimer, probeTimer] { timer?.invalidate() }
        refreshTimer = nil
        updateTimer = nil
        clockTimer = nil
        probeTimer = nil
    }

    /// tolerance 로 다른 시스템 작업과 깨우기 시점을 합친다.
    private func timer(interval: TimeInterval, lastRun: Date? = nil,
                       action: @escaping @MainActor (NotchViewModel) -> Void) -> Timer {
        let next = max(Date().addingTimeInterval(1), (lastRun ?? Date()).addingTimeInterval(interval))
        let timer = Timer(fire: next, interval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.started, self.backgroundActive else { return }
                action(self)
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func configureTimers() {
        invalidateTimers()
        guard started, backgroundActive else { return }
        refreshTimer = timer(interval: refreshInterval, lastRun: lastFetchAt) { $0.refreshIfStale() }
        updateTimer = timer(interval: 3600, lastRun: lastUpdateCheckAt) { $0.checkUpdate() }
        probeTimer = timer(interval: ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : 30) { $0.probe() }
        if isExpanded {
            clockTimer = timer(interval: 60) { vm in
                if vm.isExpanded { vm.tick += 1 }
            }
        }
    }

    func stop() {
        started = false
        invalidateTimers()
        pendingProbe?.cancel()
        pendingProbe = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func refreshIfStale() {
        if Date().timeIntervalSince(lastFetchAt ?? .distantPast) >= refreshInterval { refresh() }
    }

    // MARK: 메뉴바 점유 폭 측정

    private func scheduleProbe() {
        pendingProbe?.cancel()
        guard started, backgroundActive else { return }
        pendingProbe = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.probe()
        }
    }

    func probe() {
        guard started, backgroundActive else { return }
        guard !probing else { probeAgain = true; return }
        probing = true
        let input = MenuBarProbe.Input(
            screenFrame: geometry.screenFrame,
            menuBarHeight: geometry.notchHeight,
            screens: NSScreen.screens.map(\.frame),
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            previous: occupancy
        )
        let wasFullScreen = fullScreenActive
        Task.detached(priority: .utility) {
            let o = MenuBarProbe.measure(input)
            var detected = MenuBarProbe.isFullScreen(input)
            // 숨기는 쪽은 한 번 더 확인 (상태 아이콘 창이 잠깐 빠지는 순간을 풀스크린으로 오인하지 않게)
            if detected && !wasFullScreen {
                try? await Task.sleep(for: .milliseconds(400))
                detected = MenuBarProbe.isFullScreen(input)
            }
            let fullScreen = detected
            let trusted = AXIsProcessTrusted()
            await MainActor.run {
                self.probing = false
                if self.probeAgain {
                    self.probeAgain = false
                    self.scheduleProbe()
                }
                guard self.started, self.backgroundActive else { return }
                if self.axTrusted != trusted { self.axTrusted = trusted }
                if self.fullScreenActive != fullScreen {
                    self.fullScreenActive = fullScreen
                    if fullScreen { self.collapse() }
                    self.dbg("fullScreen=\(fullScreen)")
                }
                if self.occupancy != o {
                    self.occupancy = o
                    self.dbg("occupancy L=\(o.left.map { "\(Int($0))" } ?? "?") R=\(Int(o.right)) avail L=\(self.leftAvailable.map { "\(Int($0))" } ?? "?") R=\(Int(self.rightAvailable)) wings=\(Int(self.wingLeft))/\(Int(self.wingRight)) style=\(self.leftLayout.style)/\(self.rightLayout.style)")
                }
            }
        }
    }

    // MARK: 접근성 권한 (왼쪽 앱 메뉴 폭 측정용)

    private static let axPromptedKey = "AccessibilityPrompted"
    private static let alwaysShowKey = "AlwaysShowBatteries"

    /// 첫 실행에 한 번만 시스템 다이얼로그. 이후엔 패널 버튼으로 설정 창을 연다
    func requestAccessibilityOnce() {
        guard !axTrusted, !UserDefaults.standard.bool(forKey: Self.axPromptedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.axPromptedKey)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        axTrusted = AXIsProcessTrustedWithOptions(opts)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }

    func toggle() { setExpanded(!isExpanded) }
    func collapse() { setExpanded(false) }

    /// 펼침: 창을 먼저 키우고 본문을 그린 뒤 뷰가 높이를 애니메이션.
    /// 접힘: 뷰가 높이를 줄이는 동안 본문을 유지하고, 끝나면 창을 줄인다.
    func setExpanded(_ on: Bool) {
        guard isExpanded != on else { return }
        isExpanded = on
        configureTimers()
        if on {
            bodyVisible = true
            onLayout?()
            probe()
            refreshIfStale()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.animDuration + 0.03) { [weak self] in
                guard let self, !self.isExpanded else { return }
                self.bodyVisible = false
                self.onLayout?()
            }
        }
    }

    func refresh(forceDetails: Bool = false) {
        guard started, backgroundActive, !isFetching else { return }
        isFetching = true
        let core = self.core
        dbg("fetch begin")
        Task.detached(priority: .utility) {
            let t0 = Date()
            let result = Result { try core.fetch(forceDetails: forceDetails) }
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
                self.configureTimers()
            }
        }
    }

    func checkUpdate() {
        guard started, backgroundActive, !checkingUpdate else { return }
        checkingUpdate = true
        lastUpdateCheckAt = Date()
        let updater = self.updater
        dbg("update check begin")
        Task.detached(priority: .background) {
            let t0 = Date()
            let l = updater.fetchLatest()
            await MainActor.run {
                self.dbg("update check done \(Int(Date().timeIntervalSince(t0)))s → \(String(describing: l))")
                if let l { self.latest = l }
                self.checkingUpdate = false
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
