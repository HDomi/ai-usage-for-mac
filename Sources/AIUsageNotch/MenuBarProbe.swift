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

/// 메뉴바 점유 폭 측정.
/// 오른쪽: 상태 아이콘은 status 레벨 윈도우라 CGWindowList 로 권한 없이 읽는다.
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
        let right = measureRight(screen: target, menuBarHeight: i.menuBarHeight)

        let left: CGFloat?
        if !AXIsProcessTrusted() {
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

    /// 최전방 앱 AXMenuBar 자식들의 오른쪽 끝 → 그 화면 왼쪽 끝부터의 거리
    static func measureLeft(pid: pid_t, screens: [CGRect]) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5) // 앱이 멈춰 있어도 오래 안 기다림
        guard let bar: AXUIElement = attr(app, kAXMenuBarAttribute),
              let items: [AXUIElement] = attr(bar, kAXChildrenAttribute) else { return nil }
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, y: CGFloat = 0
        for item in items {
            guard let p = axValue(item, kAXPositionAttribute, .cgPoint, CGPoint.zero),
                  let s = axValue(item, kAXSizeAttribute, .cgSize, CGSize.zero), s.width > 0
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

    private static func axValue<T>(_ el: AXUIElement, _ name: String, _ type: AXValueType, _ zero: T) -> T? {
        guard let v: AXValue = attr(el, name) else { return nil }
        var out = zero
        return AXValueGetValue(v, type, &out) ? out : nil
    }
}
