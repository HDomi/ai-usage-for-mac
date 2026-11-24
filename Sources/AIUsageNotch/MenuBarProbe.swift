import AppKit
import ApplicationServices

/// 메뉴바에서 앱 메뉴(왼쪽)·상태 아이콘(오른쪽)이 차지하는 폭. 화면 가장자리부터 pt.
struct MenuBarOccupancy: Equatable {
    /// 왼쪽 끝부터 마지막 앱 메뉴까지. nil = 접근성 권한 없어 측정 불가
    var left: CGFloat?
    /// 오른쪽 끝부터 첫 상태 아이콘까지
    var right: CGFloat

    static let unknown = MenuBarOccupancy(left: nil, right: 0)
}

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray?

/// 메뉴바 점유 폭 측정.
/// 오른쪽: 상태 아이콘은 status 레벨 윈도우라 CGWindowList 로 권한 없이 읽는다.
///   그렇게 안 잡히는 macOS 에서는 MenuBarAgent 의 AX 로 읽는다 (접근성 권한 필요).
/// 왼쪽: 앱 메뉴는 윈도우가 아니라 최전방 앱의 AXMenuBar 로 읽는다 (접근성 권한 필요).
enum MenuBarProbe {
    struct Input {
        var screenFrame: CGRect      // 노치 화면 (AppKit 좌표)
        var menuBarHeight: CGFloat
        var screens: [CGRect]        // 전체 화면 (AppKit 좌표), 첫 번째가 주 화면
        var frontmostPID: pid_t?
        var previous: MenuBarOccupancy
    }

    static let statusLevel = Int(CGWindowLevelForKey(.statusWindow))

    /// AppKit(좌하단 원점) → CG(주 화면 좌상단 원점)
    static func cgRect(_ f: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: f.minX, y: primaryMaxY - f.maxY, width: f.width, height: f.height)
    }

    static func measure(_ i: Input) -> MenuBarOccupancy {
        let primaryMaxY = i.screens.first?.maxY ?? i.screenFrame.maxY
        let cgScreens = i.screens.map { cgRect($0, primaryMaxY: primaryMaxY) }
        let target = cgRect(i.screenFrame, primaryMaxY: primaryMaxY)
        let trusted = AXIsProcessTrusted()
        var right = measureRight(screen: target, menuBarHeight: i.menuBarHeight)
        if right == 0, trusted, let ax = measureRightAX(screen: target) { right = ax }

        let left: CGFloat?
        if !trusted {
            left = nil
        } else if let pid = i.frontmostPID, pid != ProcessInfo.processInfo.processIdentifier {
            left = measureLeft(pid: pid, screens: cgScreens)
        } else {
            left = i.previous.left // 우리 앱이 최전방이면 메뉴바는 직전 앱 것이 남아 있다
        }
        return MenuBarOccupancy(left: left, right: right)
    }

    /// 이 화면 상단에 붙은 status 레벨 윈도우 중 가장 왼쪽 x → 오른쪽 끝부터의 거리
    static func measureRight(screen sc: CGRect, menuBarHeight: CGFloat) -> CGFloat {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        var minX = sc.maxX
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == statusLevel,
                  (w[kCGWindowOwnerPID as String] as? Int) != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"],
                  abs(y - sc.minY) <= 2, h <= menuBarHeight + 4,
                  wd < sc.width / 2, x >= sc.minX, x < sc.maxX
            else { continue }
            minX = min(minX, x)
        }
        return sc.maxX - minX
    }

    /// 메뉴바를 그리는 시스템 프로세스 (상태 아이콘이 개별 창이 아닌 macOS)
    static let menuBarAgentBundleID = "com.apple.MenuBarAgent"

    /// measureRight 가 못 재는 macOS 용. 메뉴바 전체를 MenuBarAgent 가 화면마다 창 하나로 그려
    /// 상태 아이콘이 status 레벨 창으로 안 잡히므로, 그 창의 AX 자식(상태 아이콘 그룹) 위치를 읽는다.
    /// 접근성 권한 필요. nil = 측정 불가
    static func measureRightAX(screen sc: CGRect) -> CGFloat? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: menuBarAgentBundleID)
            .first?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bars: [AXUIElement] = attr(app, kAXChildrenAttribute) else { return nil }
        var minX = CGFloat.infinity
        // 같은 화면에 메뉴바 창이 여러 장 겹쳐 있다. 이 화면 것만 전부 본다
        for bar in bars {
            guard let bp = axPoint(bar, kAXPositionAttribute),
                  let bs = axSize(bar, kAXSizeAttribute),
                  abs(bp.x - sc.minX) <= 2, abs(bp.y - sc.minY) <= 2, abs(bs.width - sc.width) <= 2,
                  let items: [AXUIElement] = attr(bar, kAXChildrenAttribute)
            else { continue }
            for item in items {
                guard let p = axPoint(item, kAXPositionAttribute),
                      let s = axSize(item, kAXSizeAttribute),
                      s.width > 0, s.width < sc.width / 2, p.x >= sc.midX, p.x < sc.maxX
                else { continue }
                minX = min(minX, p.x)
            }
        }
        return minX.isFinite ? sc.maxX - minX : nil
    }

    /// 노치 화면이 다른 앱 풀스크린 Space(영상·게임·네이티브 풀스크린)에 들어가 있으면 true.
    /// .canJoinAllSpaces 창은 .fullScreenAuxiliary 를 빼도 풀스크린 Space 에 따라가므로 직접 감지한다.
    /// 1순위: 노치 화면의 현재 Space 종류 (nativeFullScreen).
    /// 2순위(Space 조회 실패 시): 다른 앱 일반 레벨 창이 화면 폭 전체 + 메뉴바(노치 아래)부터 바닥까지 덮고,
    /// 화면 상단에 상태 아이콘이 하나도 없다 (최대화 창과 구분 — 메뉴바가 보이면 상태 아이콘이 있다).
    /// 2순위만으로는 상태 아이콘이 status 레벨 창으로 안 잡히는 macOS 에서 최대화 창을 풀스크린으로 오인한다.
    static func isFullScreen(_ i: Input) -> Bool {
        let primaryMaxY = i.screens.first?.maxY ?? i.screenFrame.maxY
        let sc = cgRect(i.screenFrame, primaryMaxY: primaryMaxY)
        if let native = nativeFullScreen(screen: sc) { return native }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        var covered = false
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int) != me,
                  let layer = w[kCGWindowLayer as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let h = b["Height"]
            else { continue }
            if layer == statusLevel, abs(y - sc.minY) <= 2, x >= sc.minX, x < sc.maxX {
                return false
            }
            if layer == 0, ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
               x <= sc.minX + 1, x + wd >= sc.maxX - 1,
               y >= sc.minY - 1, y <= sc.minY + i.menuBarHeight + 1, y + h >= sc.maxY - 1 {
                covered = true
            }
        }
        return covered
    }

    /// 이 화면(CG 좌표)의 현재 Space 가 네이티브 풀스크린 Space 인지. nil = 판단 불가.
    /// 공개 API 로는 Space 종류를 알 수 없어 CGS(비공개) 를 쓴다. 실패하면 nil 로 돌려 창 배치 추정에 맡긴다.
    static func nativeFullScreen(screen sc: CGRect) -> Bool? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success,
              let id = ids.prefix(Int(count)).first(where: {
                  let b = CGDisplayBounds($0)
                  return abs(b.minX - sc.minX) <= 1 && abs(b.minY - sc.minY) <= 1 && abs(b.width - sc.width) <= 1
              }),
              let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let uuid = CFUUIDCreateString(nil, cfUUID) as String?,
              let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]]
        else { return nil }
        // "디스플레이마다 별도 Spaces" 가 꺼져 있으면 항목이 하나("Main")뿐이다
        let match = displays.first { ($0["Display Identifier"] as? String) == uuid }
            ?? (displays.count == 1 ? displays[0] : nil)
        guard let current = match?["Current Space"] as? [String: Any],
              let type = current["type"] as? Int
        else { return nil }
        return type == fullScreenSpaceType
    }

    /// CGS Space 종류: 0 = 일반 데스크톱, 4 = 풀스크린
    static let fullScreenSpaceType = 4

    /// 최전방 앱 AXMenuBar 자식들의 오른쪽 끝 → 그 화면 왼쪽 끝부터의 거리
    static func measureLeft(pid: pid_t, screens: [CGRect]) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5) // 앱이 멈춰 있어도 오래 안 기다림
        guard let bar: AXUIElement = attr(app, kAXMenuBarAttribute),
              let items: [AXUIElement] = attr(bar, kAXChildrenAttribute) else { return nil }
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, y: CGFloat = 0
        for item in items {
            guard let p = axPoint(item, kAXPositionAttribute),
                  let s = axSize(item, kAXSizeAttribute), s.width > 0
            else { continue }
            minX = min(minX, p.x)
            maxX = max(maxX, p.x + s.width)
            y = p.y
        }
        guard maxX > minX else { return nil }
        // AX 는 메뉴바를 어느 화면 좌표로 주는지 정해져 있지 않아, 그 화면 왼쪽 끝 기준 폭으로 환산
        let origin = screens.first { $0.contains(CGPoint(x: minX, y: y + 1)) }?.minX ?? (minX - 10)
        return maxX - origin
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private static func axPoint(_ el: AXUIElement, _ name: String) -> CGPoint? {
        guard let v: AXValue = attr(el, name) else { return nil }
        var out = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &out) ? out : nil
    }

    private static func axSize(_ el: AXUIElement, _ name: String) -> CGSize? {
        guard let v: AXValue = attr(el, name) else { return nil }
        var out = CGSize.zero
        return AXValueGetValue(v, .cgSize, &out) ? out : nil
    }
}
