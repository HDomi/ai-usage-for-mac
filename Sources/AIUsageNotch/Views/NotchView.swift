import SwiftUI

/// 검은 노치 영역 + 펼친 본문.
/// 헤더+본문은 항상 전체 크기로 위에 붙여 두고, 보이는 높이(reveal)만 애니메이션한다.
/// VStack 자체 크기를 애니메이션하면 중간 프레임에서 헤더가 아래로 밀린다.
struct NotchView: View {
    @ObservedObject var vm: NotchViewModel
    @State private var reveal: CGFloat = 0
    @State private var radius: CGFloat = 12

    /// 목표 높이. 본문 높이를 아직 모르면 헤더 높이 유지 (측정되면 갱신)
    private var targetHeight: CGFloat {
        let g = vm.geometry
        guard vm.isExpanded, vm.bodyHeight > 0 else { return g.notchHeight }
        return g.notchHeight + min(vm.bodyHeight, NotchViewModel.expandedMaxBody)
    }

    var body: some View {
        let g = vm.geometry
        let w = vm.currentWidth
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
        ZStack(alignment: .top) {
            // 투명 영역(본문 측정 전 여유분) 클릭 → 접기
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.collapse() }

            VStack(spacing: 0) {
                header
                    .frame(width: w, height: g.notchHeight)
                if vm.bodyVisible {
                    ExpandedBody(vm: vm)
                        .frame(width: w)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(
                            // 본문 실제 높이를 창 크기에 반영 (preference 는 background 안에서 전달이 불안정해 onChange 사용)
                            GeometryReader { p in
                                Color.clear
                                    .onAppear { vm.bodyHeight = ceil(p.size.height) }
                                    .onChange(of: p.size.height) { _, h in vm.bodyHeight = ceil(h) }
                            }
                        )
                }
            }
            .frame(width: w, height: reveal > 0 ? reveal : g.notchHeight, alignment: .top)
            .background(shape.fill(.black))
            .clipShape(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: targetHeight, initial: true) { _, t in
            withAnimation(.easeOut(duration: NotchViewModel.animDuration)) {
                reveal = t
                radius = vm.isExpanded ? 20 : 12
            }
        }
        .preferredColorScheme(.dark)
    }

    /// 노치 양옆 날개: 왼쪽 Claude, 오른쪽 Cursor·Codex. 폭은 메뉴바 점유에 맞춰 좌우 따로.
    /// 배터리 숨김 모드면 선택한 항목 하나를 왼쪽 라벨+%, 오른쪽 가로 배터리로 나눠 그린다
    private var header: some View {
        let left = vm.leftLayout
        let right = vm.rightLayout
        let leftW = vm.headerLeftWidth
        let rightW = vm.currentWidth - leftW - vm.notchSpan
        let mini = vm.miniMode ? vm.miniItem : nil
        return HStack(spacing: 0) {
            HStack(spacing: NotchViewModel.pillSpacing) {
                if vm.miniMode {
                    MiniLabel(item: mini)
                } else {
                    ForEach(left.items) { BatteryPill(item: $0, style: left.style) }
                }
            }
            .padding(.trailing, NotchViewModel.wingPadding)
            .frame(width: leftW, alignment: .trailing)

            Spacer().frame(width: vm.notchSpan)

            HStack(spacing: NotchViewModel.pillSpacing) {
                if vm.miniMode {
                    MiniBattery(remain: mini?.remain)
                } else {
                    ForEach(right.items) { BatteryPill(item: $0, style: right.style) }
                    if vm.leftItems.isEmpty && vm.rightItems.isEmpty {
                        Text(vm.isFetching ? "…" : "🔋 —")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.gray)
                    }
                }
            }
            .padding(.leading, NotchViewModel.wingPadding)
            .frame(width: rightW, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { vm.toggle() }
    }
}

/// 남은 % 를 초록→빨강으로
func heatColor(_ remain: Double) -> Color {
    let r = max(0, min(100, remain)) / 100
    return Color(hue: 0.33 * r, saturation: 0.85, brightness: 0.95)
}

/// 배터리 숨김 모드의 노치 왼쪽: 라벨 + 잔량 %. item=nil 이면 자리표시
struct MiniLabel: View {
    let item: BatteryItem?

    var body: some View {
        HStack(spacing: 3) {
            Text(item?.label ?? "—")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color(white: 0.6))
            Text(item.map { "\(Int($0.remain.rounded()))%" } ?? "")
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(item.map { heatColor($0.remain) } ?? .gray)
        }
        .lineLimit(1)
        .fixedSize()
        .frame(width: NotchViewModel.miniContentWidth)
    }
}

/// 배터리 숨김 모드의 노치 오른쪽 가로 배터리. remain=nil 이면 빈 외곽선만
struct MiniBattery: View {
    let remain: Double?

    private static let bodyW: CGFloat = 30
    private static let bodyH: CGFloat = 11
    private static let inset: CGFloat = 1.5

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color(white: 0.5), lineWidth: 1)
                    .frame(width: Self.bodyW, height: Self.bodyH)
                if let r = remain {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(heatColor(r))
                        .frame(width: max(1.5, (Self.bodyW - Self.inset * 2) * max(0, min(100, r)) / 100),
                               height: Self.bodyH - Self.inset * 2)
                        .padding(.leading, Self.inset)
                }
            }
            RoundedRectangle(cornerRadius: 0.8)
                .fill(Color(white: 0.5))
                .frame(width: 2, height: 4)
        }
        .frame(width: NotchViewModel.miniContentWidth)
    }
}

/// 노치 옆 미니 배터리: 라벨 + 잔량 바(안에 %). compact 면 바 없이 라벨 + 숫자
struct BatteryPill: View {
    let item: BatteryItem
    var style: PillStyle = .full

    private static let bodyW: CGFloat = 30
    private static let bodyH: CGFloat = 14
    private static let inset: CGFloat = 1.5

    var body: some View {
        if style == .full { fullBody } else { compactBody }
    }

    private var label: some View {
        Text(item.label)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(Color(white: 0.6))
            .lineLimit(1)
            .fixedSize()
    }

    /// 라벨·숫자를 고정 칸에 정렬하면 글자 폭 차이만큼 알약 사이 간격이 들쭉날쭉해진다.
    /// 자연 폭으로 붙여 그리고, 날개 폭 계산은 compactPillWidth 를 상한으로 쓴다
    private var compactBody: some View {
        HStack(spacing: 3) {
            label
            Text("\(Int(item.remain.rounded()))")
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(heatColor(item.remain))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var fullBody: some View {
        HStack(spacing: 3) {
            label
                .frame(width: 18, alignment: .trailing)
            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3.5)
                        .stroke(Color(white: 0.5), lineWidth: 1)
                        .frame(width: Self.bodyW, height: Self.bodyH)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(heatColor(item.remain))
                        .frame(width: max(2, (Self.bodyW - Self.inset * 2) * item.remain / 100),
                               height: Self.bodyH - Self.inset * 2)
                        .padding(.leading, Self.inset)
                    Text("\(Int(item.remain.rounded()))")
                        .font(.system(size: 8.5, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.9), radius: 1)
                        .shadow(color: .black.opacity(0.6), radius: 0.5)
                        .frame(width: Self.bodyW, height: Self.bodyH)
                }
                RoundedRectangle(cornerRadius: 0.8)
                    .fill(Color(white: 0.5))
                    .frame(width: 2, height: 5)
            }
        }
        .frame(width: NotchViewModel.pillWidth)
    }
}
