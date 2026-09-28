import AppKit
import Combine
import SwiftUI

/// 노치에 붙는 비활성화 패널. 메뉴바보다 위 레벨, 모든 Space·풀스크린에서 유지.
final class NotchPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchController {
    let vm = NotchViewModel()
    private let panel: NotchPanel
    private var cancellables = Set<AnyCancellable>()
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {
        panel = NotchPanel(frame: NSRect(x: 0, y: 0, width: 300, height: 37))
        let hosting = NSHostingView(rootView: NotchView(vm: vm))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        layout()
        panel.orderFrontRegardless()

        // 배터리 개수, 화면 변경, 본문 높이, 메뉴바 점유 → 창 크기 재계산
        // @Published 는 willSet 시점에 emit 하므로 다음 런루프에서 읽는다
        // 펼침/접힘은 vm.setExpanded 가 onLayout 으로 동기 호출한다
        vm.onLayout = { [weak self] in self?.layout() }
        vm.$snapshot.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layout() }.store(in: &cancellables)
        vm.$geometry.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layout() }.store(in: &cancellables)
        // 본문 높이 측정 → 창 줄이기는 reveal 애니메이션이 끝난 뒤 (같이 하면 루트 크기 변화가 애니메이션에 섞임)
        vm.$bodyHeight.dropFirst().removeDuplicates()
            .delay(for: .seconds(NotchViewModel.animDuration + 0.05), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.layout() }.store(in: &cancellables)
        vm.$occupancy.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layout() }.store(in: &cancellables)

        // 패널 밖 클릭 → 접기 (글로벌 모니터는 자기 앱 이벤트를 받지 않음)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.vm.collapse() }
        }
        // ESC → 접기
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { self?.vm.collapse(); return nil }
            return ev
        }

        vm.start()
    }

    /// 창 프레임을 상태에 맞춰 잡는다. 접힘: 노치 폭 + 좌우 날개(비대칭 가능), 펼침: 본문 높이만큼.
    /// 펼친 직후 본문 높이를 모르므로 최대 높이로 열고, 측정되면 줄인다.
    /// 창 크기는 애니메이션하지 않는다. 남는 영역은 투명이고, 보이는 높이는 뷰가 애니메이션한다.
    func layout() {
        let g = vm.geometry
        let width = vm.currentWidth
        let body: CGFloat
        if vm.bodyVisible {
            body = vm.bodyHeight > 0 ? min(vm.bodyHeight, NotchViewModel.expandedMaxBody)
                                     : NotchViewModel.expandedMaxBody
        } else {
            body = 0
        }
        let height = g.notchHeight + body
        let x = vm.panelX
        let y = g.screenFrame.maxY - height
        let frame = NSRect(x: x, y: y, width: width, height: height).integral
        if panel.frame != frame {
            panel.setFrame(frame, display: true, animate: false)
        }
        if ProcessInfo.processInfo.environment["AIU_DEBUG"] != nil {
            FileHandle.standardError.write(
                "[\(Int(Date().timeIntervalSince1970) % 1000)][layout] expanded=\(vm.isExpanded) body=\(vm.bodyVisible) frame=\(frame) notch=\(g.notchWidth)x\(g.notchHeight) hasNotch=\(g.hasNotch) screen=\(g.screenFrame) visible=\(panel.isVisible) bodyH=\(vm.bodyHeight) items=\(vm.leftLayout.items.count)/\(vm.rightLayout.items.count) wings=\(vm.wingLeft)/\(vm.wingRight) occ=\(vm.occupancy)\n".data(using: .utf8)!
            )
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
