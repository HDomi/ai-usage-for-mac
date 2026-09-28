import SwiftUI

/// 노치를 클릭하면 펼쳐지는 상세 패널
struct ExpandedBody: View {
    @ObservedObject var vm: NotchViewModel

    private var now: Int { Int(Date().timeIntervalSince1970) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = vm.snapshot {
                if s.hasClaude { claudeSection(s) }
                if s.hasCursor, let cu = s.cursor { cursorSection(cu, rate: s.exchangeRateKRW) }
                if s.hasCodex, let cx = s.codex { codexSection(cx) }
                if s.isEmpty {
                    Text("Claude Code / Cursor / Codex 로그인 후 사용량이 표시됩니다")
                        .font(.system(size: 12))
                        .foregroundStyle(.gray)
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
    private func claudeSection(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(
                title: "Claude Code",
                live: s.claude?.live,
                measuredAt: s.claude?.measuredAt,
                source: "Anthropic usage API", now: now
            )
            if let c = s.claude {
                if let w = c.fiveHour { GaugeRow(label: "5시간", window: w, now: now) }
                if let w = c.weekly { GaugeRow(label: "주간", window: w, now: now) }
                if let w = c.fable { GaugeRow(label: w.model ?? "모델", window: w, now: now) }
            } else if let b = s.claudeBlock {
                GaugeRow(label: "5시간", window: UsageWindow(pct: b.elapsedPct, resetsAt: now + b.remainMin * 60), now: now)
            }
            if let b = s.claudeBlock {
                SubLine(
                    "블록 비용 \(Fmt.usd(b.cost)) (\(Fmt.krw(b.cost, rate: s.exchangeRateKRW)))  ·  \(Fmt.tok(b.tokens)) 토큰  ·  \(b.costPerHour.map { Fmt.usd($0, 1) } ?? "?")/h"
                )
            }
            if let m = s.claudeModels, !m.models.isEmpty {
                SubLine("오늘 모델별  ·  합 \(Fmt.usd(m.total, 0)) (\(Fmt.krw(m.total, rate: s.exchangeRateKRW)))")
                let maxCost = m.models.first?.cost ?? 1
                ForEach(m.models) { mc in
                    HStack(spacing: 8) {
                        Text(mc.short)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(white: 0.8))
                            .frame(width: 76, alignment: .leading)
                        Bar(fraction: mc.cost / max(maxCost, 0.01), color: Color(white: 0.55))
                            .frame(width: 120, height: 6)
                        Text("\(Fmt.usd(mc.cost, 1)) (\(Fmt.krw(mc.cost, rate: s.exchangeRateKRW)))  \(Fmt.tok(mc.tokens))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(white: 0.7))
                    }
                }
            }
            let usd = s.claudeModels?.total ?? s.claudeBlock?.cost ?? 0
            if usd > 0 {
                SpentLine(name: "Claude", usd: usd, rate: s.exchangeRateKRW)
            }
        }
    }

    // MARK: Cursor

    @ViewBuilder
    private func cursorSection(_ cu: CursorUsage, rate: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Cursor AI", live: cu.live, measuredAt: cu.measuredAt, source: "Cursor API", now: now)
            let autoUsed = cu.autoPercentUsed ?? cu.usedPct
            GaugeRow(label: "Cursor Models", window: UsageWindow(pct: autoUsed, resetsAt: cu.cycleEnd), now: now)
            if let api = cu.apiPercentUsed {
                GaugeRow(label: "Other Models", window: UsageWindow(pct: api, resetsAt: cu.cycleEnd), now: now)
            }
            if let msg = cu.displayMsg { SubLine(msg) }
            if let cents = cu.totalSpendCents, cents > 0 {
                SpentLine(name: "Cursor", usd: cents / 100, rate: rate)
            }
        }
    }

    // MARK: Codex

    @ViewBuilder
    private func codexSection(_ cx: CodexUsage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Codex (ChatGPT)", live: cx.live, measuredAt: cx.measuredAt, source: "ChatGPT wham/usage", now: now)
            if let w = cx.fiveHour { GaugeRow(label: "5시간", window: w, now: now) }
            if let w = cx.weekly { GaugeRow(label: "주간", window: w, now: now) }
            if let plan = cx.planType {
                SubLine("plan \(plan)\(cx.creditsBalance.map { "  ·  credits \($0)" } ?? "")")
            }
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

struct SectionHeader: View {
    let title: String
    let live: Bool?
    let measuredAt: Int?
    let source: String
    let now: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.85))
            if let live {
                if live {
                    Text("라이브 · \(source)").font(.system(size: 10)).foregroundStyle(.gray)
                } else if let m = measuredAt {
                    Text("측정 \(Fmt.dur(now - m)) 전 · 캐시 폴백")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.82, green: 0.6, blue: 0.13))
                }
            }
        }
    }
}

/// 라벨 · 잔량 바 · 남은% · 사용% · 리셋
struct GaugeRow: View {
    let label: String
    let window: UsageWindow
    let now: Int

    var body: some View {
        let r = window.remain
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(white: 0.8))
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
            Bar(fraction: r / 100, color: heatColor(r))
                .frame(height: 8)
            Text("\(Int(r.rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(heatColor(r))
                .frame(width: 40, alignment: .trailing)
            Text("사용 \(Int(window.pct.rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.gray)
                .frame(width: 62, alignment: .leading)
            Text(Fmt.reset(window.resetsAt, now: now) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.gray)
                .frame(width: 92, alignment: .leading)
        }
    }
}

struct Bar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { p in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.18))
                Capsule().fill(color)
                    .frame(width: max(0, min(1, fraction)) * p.size.width)
            }
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

struct SpentLine: View {
    let name: String
    let usd: Double
    let rate: Double
    var body: some View {
        Text("💳 지금까지 \(name) 약 \(Fmt.krw(usd, rate: rate))(\(Fmt.usd(usd)))을 사용하셨습니다!")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
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
