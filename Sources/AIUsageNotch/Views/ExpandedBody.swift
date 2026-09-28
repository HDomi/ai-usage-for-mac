import SwiftUI

/// 노치를 클릭하면 펼쳐지는 상세 패널. 왼쪽부터 Claude · Codex · Cursor 3등분, 각각 겹친 도넛 링
struct ExpandedBody: View {
    @ObservedObject var vm: NotchViewModel

    private var now: Int { Int(Date().timeIntervalSince1970) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = vm.snapshot {
                HStack(alignment: .top, spacing: 16) {
                    claudeColumn(s).frame(maxWidth: .infinity, alignment: .leading)
                    codexColumn(s).frame(maxWidth: .infinity, alignment: .leading)
                    cursorColumn(s).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if vm.isFetching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("사용량 불러오는 중…").font(.system(size: 12)).foregroundStyle(.gray)
                }
            }

            if let e = vm.fetchError {
                Text("⚠︎ \(e)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.82, green: 0.6, blue: 0.13))
                    .lineLimit(2)
            }

            Divider().overlay(Color(white: 0.2))
            footer
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .id(vm.tick) // 리셋 카운트다운 30초마다 갱신
    }

    // MARK: Claude

    @ViewBuilder
    private func claudeColumn(_ s: UsageSnapshot) -> some View {
        let rings: [RingSpec] = {
            if let c = s.claude {
                var r: [RingSpec] = []
                if let w = c.fiveHour { r.append(.init(id: "5h", label: "5시간", window: w)) }
                if let w = c.weekly { r.append(.init(id: "wk", label: "주간", window: w)) }
                if let w = c.fable { r.append(.init(id: "model", label: w.model ?? "모델", window: w)) }
                return r
            }
            if let b = s.claudeBlock {
                return [.init(id: "5h", label: "5시간",
                              window: UsageWindow(pct: b.elapsedPct, resetsAt: now + b.remainMin * 60))]
            }
            return []
        }()
        // ai-usage-battery 와 같은 기준: ccusage 오늘 모델별 합, 없으면 활성 블록 비용
        let spend: SpendInfo? = {
            let usd = s.claudeModels?.total ?? s.claudeBlock?.cost ?? 0
            guard usd > 0 else { return nil }
            var basis = "ccusage 토큰 비용 환산"
            if let b = s.claudeBlock {
                basis = "블록 \(Fmt.usd(b.cost))\(b.costPerHour.map { " · \(Fmt.usd($0, 0))/h" } ?? "") · ccusage"
            }
            return SpendInfo(usd: usd, period: "오늘", basis: basis, estimated: true)
        }()
        UsageColumn(
            title: "Claude", icon: .claude, live: s.claude?.live, measuredAt: s.claude?.measuredAt,
            source: "Anthropic usage API", rings: rings, spend: spend, rate: s.exchangeRateKRW, now: now
        ) {
            if let b = s.claudeBlock {
                SubLine("블록 \(Fmt.tok(b.tokens)) 토큰\(b.projCost.map { "  ·  예상 \(Fmt.usd($0, 0))" } ?? "")")
            }
            if let m = s.claudeModels, !m.models.isEmpty {
                SubLine("오늘 모델별")
                ForEach(m.models.prefix(4)) { mc in
                    SubLine("  \(mc.short)  \(Fmt.usd(mc.cost, 1)) (\(Fmt.krw(mc.cost, rate: s.exchangeRateKRW)))")
                }
            }
        }
    }

    // MARK: Codex

    @ViewBuilder
    private func codexColumn(_ s: UsageSnapshot) -> some View {
        let cx = s.codex
        let rings: [RingSpec] = {
            guard let cx else { return [] }
            var r: [RingSpec] = []
            if let w = cx.fiveHour { r.append(.init(id: "5h", label: "5시간", window: w)) }
            if let w = cx.weekly { r.append(.init(id: "wk", label: "주간", window: w)) }
            return r
        }()
        // Codex 는 토큰 비용 출처가 없어 사용액 없음
        UsageColumn(
            title: "Codex", icon: .openai, live: cx?.live, measuredAt: cx?.measuredAt,
            source: "ChatGPT wham/usage", rings: rings, spend: nil, rate: s.exchangeRateKRW, now: now
        ) {
            if let plan = cx?.planType {
                SubLine("plan \(plan)\(cx?.creditsBalance.map { "  ·  credits \($0)" } ?? "")")
            }
        }
    }

    // MARK: Cursor

    @ViewBuilder
    private func cursorColumn(_ s: UsageSnapshot) -> some View {
        let cu = s.cursor
        let rings: [RingSpec] = {
            guard let cu else { return [] }
            var r: [RingSpec] = [
                .init(id: "models", label: "Models", window: UsageWindow(pct: cu.autoPercentUsed ?? cu.usedPct, resetsAt: cu.cycleEnd))
            ]
            if let api = cu.apiPercentUsed {
                r.append(.init(id: "other", label: "Other", window: UsageWindow(pct: api, resetsAt: cu.cycleEnd)))
            }
            return r
        }()
        let spend: SpendInfo? = {
            guard let cu, let cents = cu.totalSpendCents else { return nil }
            let limit = cu.limitCents.map { "한도 \(Fmt.usd($0 / 100, 0)) · " } ?? ""
            return SpendInfo(usd: cents / 100, period: "이번 달", basis: "\(limit)Cursor 청구 기준", estimated: false)
        }()
        UsageColumn(
            title: "Cursor", icon: .cursor, live: cu?.live, measuredAt: cu?.measuredAt,
            source: "Cursor API", rings: rings, spend: spend, rate: s.exchangeRateKRW, now: now
        ) {
            if let msg = cu?.displayMsg { SubLine(msg) }
        }
    }

    // MARK: Footer (버전 · 업데이트 · 새로고침 · 로그인 · 종료)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch vm.updateState {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("업데이트 중… git pull → swift build → 재설치 (1~3분). 끝나면 자동으로 다시 열려")
                        .font(.system(size: 11)).foregroundStyle(.gray)
                    PanelButton("로그", tint: .gray) { vm.openLog() }
                }
            case .failed(let tail):
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("❌ 업데이트 실패").font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                        PanelButton("로그 열기", tint: .gray) { vm.openLog() }
                        PanelButton("다시 시도", tint: .gray) { vm.runUpdate() }
                    }
                    Text(tail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(white: 0.6))
                        .lineLimit(6)
                }
            case .idle:
                HStack(spacing: 8) {
                    if vm.hasUpdate, let l = vm.latest {
                        PanelButton("🆕 v\(l.version) 업데이트 (현재 v\(vm.version))", tint: Color(red: 0.16, green: 0.59, blue: 0.25)) {
                            vm.runUpdate()
                        }
                    } else {
                        PanelButton("⬆️ GitHub 최신으로 재설치", tint: Color(white: 0.25)) { vm.runUpdate() }
                        Text(vm.latest.map { "최신 v\($0.version)\($0.sha.map { " · \($0.prefix(7))" } ?? "")" } ?? "버전 확인 중…")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.gray)
                    }
                    Spacer()
                    PanelButton(vm.isFetching ? "갱신 중…" : "🔄 새로고침", tint: Color(white: 0.25)) { vm.refresh() }
                        .disabled(vm.isFetching)
                }
            }

            if !vm.axTrusted {
                HStack(spacing: 8) {
                    Text("⚠︎ 접근성 권한 없음 · 앱 메뉴와 겹치는지 못 재서 왼쪽 날개를 못 줄여")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0.82, green: 0.6, blue: 0.13))
                        .lineLimit(1)
                    PanelButton("권한 설정 열기", tint: Color(white: 0.25)) { vm.openAccessibilitySettings() }
                }
            }

            HStack(spacing: 10) {
                Text("v\(vm.version)  ·  AI Usage for Mac")
                    .font(.system(size: 10)).foregroundStyle(.gray)
                if let t = vm.lastFetchAt {
                    Text("갱신 \(Fmt.dur(Int(Date().timeIntervalSince(t)))) 전")
                        .font(.system(size: 10)).foregroundStyle(.gray)
                }
                Spacer()
                Toggle("로그인 시 실행", isOn: Binding(
                    get: { vm.launchAtLogin },
                    set: { vm.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
                .foregroundStyle(.gray)
                PanelButton("⭐ GitHub", tint: Color(white: 0.2)) { vm.openRepo() }
                PanelButton("✕ 종료", tint: Color(white: 0.2)) { vm.quit() }
            }
        }
    }
}

// MARK: - 부품

/// 도넛 링 하나의 데이터
struct RingSpec: Identifiable {
    let id: String
    let label: String
    let window: UsageWindow
    var remain: Double { window.remain }
}

/// 한 열: 제목 · 상태 · 겹친 링 · 범례 · 부가 정보
struct UsageColumn<Extra: View>: View {
    let title: String
    let icon: BrandIcon
    let live: Bool?
    let measuredAt: Int?
    let source: String
    let rings: [RingSpec]
    let spend: SpendInfo?
    let rate: Double
    let now: Int
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    BrandLogo(icon: icon, size: 16, dimmed: rings.isEmpty)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(white: rings.isEmpty ? 0.45 : 0.85))
                }
                statusLine
            }
            RingStack(rings: rings)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            if let spend {
                SpendBlock(spend: spend, rate: rate)
            }
            if rings.isEmpty {
                Text("로그인 후 표시")
                    .font(.system(size: 11)).foregroundStyle(.gray)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rings) { r in LegendRow(ring: r, now: now) }
                }
            }
            extra()
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let live {
            if live {
                Text("라이브 · \(source)").font(.system(size: 10)).foregroundStyle(.gray)
            } else if let m = measuredAt {
                Text("측정 \(Fmt.dur(now - m)) 전 · 캐시 폴백")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.82, green: 0.6, blue: 0.13))
            }
        } else {
            Text(source).font(.system(size: 10)).foregroundStyle(Color(white: 0.35))
        }
    }
}

/// 겹친 도넛 링. rings[0] 이 가장 바깥, 가운데엔 바깥 링 잔량
struct RingStack: View {
    let rings: [RingSpec]
    var size: CGFloat = 128
    var lineWidth: CGFloat = 9
    var gap: CGFloat = 3

    var body: some View {
        ZStack {
            // 데이터 없으면 빈 트랙 3겹
            let n = max(rings.count, rings.isEmpty ? 3 : 0)
            ForEach(0..<n, id: \.self) { i in
                let inset = CGFloat(i) * (lineWidth + gap) + lineWidth / 2
                Circle()
                    .stroke(Color(white: 0.16), lineWidth: lineWidth)
                    .padding(inset)
                if i < rings.count {
                    let r = rings[i]
                    Circle()
                        .trim(from: 0, to: max(0.003, r.remain / 100))
                        .stroke(heatColor(r.remain), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(inset)
                        .animation(.easeOut(duration: 0.4), value: r.remain)
                }
            }
            if let outer = rings.first {
                VStack(spacing: 0) {
                    Text("\(Int(outer.remain.rounded()))%")
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(heatColor(outer.remain))
                    Text(outer.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
            } else {
                Text("—").font(.system(size: 15, weight: .bold)).foregroundStyle(Color(white: 0.3))
            }
        }
        .frame(width: size, height: size)
    }
}

/// 도넛 아래 사용액: 달러 · 환율 적용 원화 · 산출 근거
struct SpendBlock: View {
    let spend: SpendInfo
    let rate: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text("💳 \(spend.period)\(spend.estimated ? " 약" : "")")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.8))
                Text("\(Fmt.usd(spend.usd, spend.usd < 10 ? 2 : 1))  ·  \(Fmt.krw(spend.usd, rate: rate))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
            }
            Text("\(spend.basis) · ₩\(Int(rate.rounded()))/$")
                .font(.system(size: 9))
                .foregroundStyle(.gray)
                .lineLimit(1)
        }
        .padding(.bottom, 2)
    }
}

/// 범례 한 줄: 색점 · 라벨 · 남은% · 리셋
struct LegendRow: View {
    let ring: RingSpec
    let now: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(heatColor(ring.remain)).frame(width: 7, height: 7)
            Text(ring.label)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.8))
                .lineLimit(1)
                .frame(width: 52, alignment: .leading)
            Text("\(Int(ring.remain.rounded()))%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(heatColor(ring.remain))
                .frame(width: 36, alignment: .trailing)
            Text(Fmt.reset(ring.window.resetsAt, now: now) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.gray)
                .lineLimit(1)
        }
    }
}

struct SubLine: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.gray)
            .lineLimit(1)
    }
}

struct PanelButton: View {
    let title: String
    let tint: Color
    let action: () -> Void
    init(_ title: String, tint: Color, action: @escaping () -> Void) {
        self.title = title; self.tint = tint; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(tint))
        }
        .buttonStyle(.plain)
    }
}
