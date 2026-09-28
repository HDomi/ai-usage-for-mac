import SwiftUI

/// 검은 노치 영역 + 펼친 본문
struct NotchView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        let g = vm.geometry
        let w = vm.currentWidth
        ZStack(alignment: .top) {
            // 투명 영역(본문 측정 전 여유분) 클릭 → 접기
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.collapse() }

            VStack(spacing: 0) {
                header
                    .frame(width: w, height: g.notchHeight)
                if vm.isExpanded {
                    ExpandedBody(vm: vm)
                        .frame(width: w)
                        .background(
                            // 본문 실제 높이를 창 크기에 반영 (preference 는 background 안에서 전달이 불안정해 onChange 사용)
                            GeometryReader { p in
                                Color.clear
                                    .onAppear { vm.bodyHeight = ceil(p.size.height) }
                                    .onChange(of: p.size.height) { _, h in vm.bodyHeight = ceil(h) }
                            }
                        )
                        .transition(.opacity)
                }
            }
            .background(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: vm.isExpanded ? 20 : 12,
                    bottomTrailingRadius: vm.isExpanded ? 20 : 12
                )
                .fill(.black)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.15), value: vm.isExpanded)
        .preferredColorScheme(.dark)
    }

    /// 노치 양옆 날개: 왼쪽 Claude, 오른쪽 Cursor·Codex. 폭은 메뉴바 점유에 맞춰 좌우 따로
    private var header: some View {
        let left = vm.leftLayout
        let right = vm.rightLayout
        let leftW = vm.headerLeftWidth
        let rightW = vm.currentWidth - leftW - vm.notchSpan
        return HStack(spacing: 0) {
            HStack(spacing: NotchViewModel.pillSpacing) {
                ForEach(left.items) { BatteryPill(item: $0, style: left.style) }
            }
            .padding(.trailing, NotchViewModel.wingPadding)
            .frame(width: leftW, alignment: .trailing)

            Spacer().frame(width: vm.notchSpan)

            HStack(spacing: NotchViewModel.pillSpacing) {
                ForEach(right.items) { BatteryPill(item: $0, style: right.style) }
                if vm.leftItems.isEmpty && vm.rightItems.isEmpty {
                    Text(vm.isFetching ? "…" : "🔋 —")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.gray)
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

/// 노치 옆 미니 배터리: 라벨 + 잔량 바 + 숫자. compact 면 바 없이 라벨 + 숫자
struct BatteryPill: View {
    let item: BatteryItem
    var style: PillStyle = .full

    var body: some View {
        HStack(spacing: 3) {
            Text(item.label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color(white: 0.6))
                .lineLimit(1)
                .fixedSize()
                .frame(width: 18, alignment: .trailing)
            if style == .full {
                HStack(spacing: 1) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .stroke(Color(white: 0.45), lineWidth: 1)
                            .frame(width: 20, height: 10)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(heatColor(item.remain))
                            .frame(width: max(1.5, 17 * item.remain / 100), height: 7)
                            .padding(.leading, 1.5)
                    }
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color(white: 0.45))
                        .frame(width: 1.5, height: 4)
                }
            }
            Text("\(Int(item.remain.rounded()))")
                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(heatColor(item.remain))
                .lineLimit(1)
                .fixedSize()
                .frame(width: 18, alignment: .leading)
        }
        .frame(width: NotchViewModel.pillWidth(style))
    }
}
