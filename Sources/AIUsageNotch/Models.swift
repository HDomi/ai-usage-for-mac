import Foundation

/// 5시간·주간 등 하나의 사용량 창. pct = 사용률(0~100)
struct UsageWindow: Codable, Equatable {
    var pct: Double
    var resetsAt: Int?
    var model: String?

    var remain: Double { max(0, 100 - pct) }
}

struct ClaudeUsage: Codable, Equatable {
    var measuredAt: Int
    var live: Bool
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    var fable: UsageWindow?
    /// Keychain claudeAiOauth 의 구독 정보. 요금 환산용
    var subscriptionType: String?
    var rateLimitTier: String?
}

struct ClaudeBlock: Codable, Equatable {
    var elapsedPct: Double
    var remainMin: Int
    var cost: Double
    var tokens: Double
    var projCost: Double?
    var costPerHour: Double?
}

struct ModelCost: Codable, Equatable, Identifiable {
    var name: String
    var short: String
    var cost: Double
    var tokens: Double
    var id: String { name }
}

struct ClaudeModels: Codable, Equatable {
    var models: [ModelCost]
    var total: Double
}

struct CursorUsage: Codable, Equatable {
    var usedPct: Double
    var remainPct: Double
    var autoPercentUsed: Double?
    var apiPercentUsed: Double?
    var cycleEnd: Int?
    var displayMsg: String?
    var totalSpendCents: Double?
    var includedSpendCents: Double?
    var limitCents: Double?
    var measuredAt: Int
    var live: Bool
}

struct CodexUsage: Codable, Equatable {
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    var planType: String?
    var creditsBalance: String?
    var measuredAt: Int
    var live: Bool
}

/// usage-core.js 가 출력하는 JSON 전체
struct UsageSnapshot: Codable, Equatable {
    var coreVersion: String
    var now: Int
    var exchangeRateKRW: Double
    var claude: ClaudeUsage?
    var claudeBlock: ClaudeBlock?
    var claudeModels: ClaudeModels?
    var cursor: CursorUsage?
    var codex: CodexUsage?
    var ccusage: Bool?
    var errors: [String]

    var hasClaude: Bool { claude != nil || claudeBlock != nil }
    var hasCursor: Bool { cursor != nil }
    var hasCodex: Bool { codex != nil }
    var isEmpty: Bool { !hasClaude && !hasCursor && !hasCodex }
}

/// 노치 양옆에 그리는 미니 배터리 하나
struct BatteryItem: Identifiable, Equatable {
    enum Side { case left, right }
    let label: String
    let remain: Double
    let side: Side
    /// 공간 부족 시 숨김 순서. 작을수록 끝까지 남는다
    let priority: Int
    var id: String { label }
}

extension UsageSnapshot {
    /// 노치 왼쪽: Claude
    var leftItems: [BatteryItem] {
        var items: [BatteryItem] = []
        if let c = claude {
            if let w = c.fiveHour { items.append(.init(label: "C5", remain: w.remain, side: .left, priority: 0)) }
            if let w = c.weekly { items.append(.init(label: "CW", remain: w.remain, side: .left, priority: 1)) }
            if let w = c.fable { items.append(.init(label: "CF", remain: w.remain, side: .left, priority: 2)) }
        } else if let b = claudeBlock {
            items.append(.init(label: "C5", remain: max(0, 100 - b.elapsedPct), side: .left, priority: 0))
        }
        return items
    }

    /// 노치 오른쪽: Cursor · Codex. 숨김 우선순위는 Codex 5시간 > Codex 주간 > Cursor
    var rightItems: [BatteryItem] {
        var items: [BatteryItem] = []
        if let cu = cursor {
            let autoUsed = cu.autoPercentUsed ?? cu.usedPct
            items.append(.init(label: "Cr", remain: max(0, 100 - autoUsed), side: .right, priority: 2))
            if let api = cu.apiPercentUsed {
                items.append(.init(label: "Co", remain: max(0, 100 - api), side: .right, priority: 3))
            }
        }
        if let cx = codex {
            if let w = cx.fiveHour { items.append(.init(label: "X", remain: w.remain, side: .right, priority: 0)) }
            if let w = cx.weekly { items.append(.init(label: "XW", remain: w.remain, side: .right, priority: 1)) }
        }
        return items
    }
}

// MARK: - 구독 요금 환산

/// 구독 요금표 (USD/월). 사용률 × 요금으로 "이번 주 얼마 썼는지" 를 추정한다.
/// 정확한 청구액이 아니라 구독료를 사용률만큼 나눈 값. defaults 로 덮어쓸 수 있다:
///   defaults write com.hdomi.ai-usage-for-mac ClaudePlanUSD -float 100
///   defaults write com.hdomi.ai-usage-for-mac CodexPlanUSD -float 20
enum PlanPricing {
    struct Plan: Equatable {
        let name: String
        let monthlyUSD: Double
    }

    static func claude(subscriptionType: String?, rateLimitTier: String?) -> Plan? {
        if let v = override("ClaudePlanUSD") { return Plan(name: "설정값", monthlyUSD: v) }
        let tier = (rateLimitTier ?? "").lowercased()
        let sub = (subscriptionType ?? "").lowercased()
        if tier.contains("max_20x") { return Plan(name: "Max 20x", monthlyUSD: 200) }
        if tier.contains("max_5x") {
            return sub == "team" ? Plan(name: "Team Premium", monthlyUSD: 150) : Plan(name: "Max 5x", monthlyUSD: 100)
        }
        if sub == "team" { return Plan(name: "Team", monthlyUSD: 30) }
        if sub == "enterprise" { return nil }
        if sub == "max" { return Plan(name: "Max", monthlyUSD: 100) }
        if sub == "pro" || tier.contains("pro") { return Plan(name: "Pro", monthlyUSD: 20) }
        return nil
    }

    static func codex(planType: String?) -> Plan? {
        if let v = override("CodexPlanUSD") { return Plan(name: "설정값", monthlyUSD: v) }
        switch (planType ?? "").lowercased() {
        case "plus": return Plan(name: "Plus", monthlyUSD: 20)
        case "pro": return Plan(name: "Pro", monthlyUSD: 200)
        case "team", "business": return Plan(name: "Team", monthlyUSD: 30)
        case "free": return Plan(name: "Free", monthlyUSD: 0)
        default: return nil
        }
    }

    /// 월 요금을 7일치로 나눠 주간 사용률만큼
    static func weeklySpend(_ plan: Plan, weeklyPct: Double) -> Double {
        plan.monthlyUSD * 7 / 30.44 * max(0, min(100, weeklyPct)) / 100
    }

    private static func override(_ key: String) -> Double? {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : nil
    }
}

/// 도넛 아래 표시하는 사용액
struct SpendInfo {
    var usd: Double
    var period: String   // "이번 주" · "이번 달"
    var basis: String    // 산출 근거 한 줄
    var estimated: Bool  // true = 구독료 환산, false = 실제 청구
}

// MARK: - 포맷 헬퍼

enum Fmt {
    static func dur(_ secs: Int) -> String {
        if secs <= 0 { return "0m" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func tok(_ n: Double) -> String {
        if n >= 1e9 { return String(format: "%.1fB", n / 1e9) }
        if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
        if n >= 1e3 { return String(format: "%.0fK", n / 1e3) }
        return String(format: "%.0f", n)
    }

    static func usd(_ v: Double, _ digits: Int = 2) -> String {
        String(format: "$%.\(digits)f", v)
    }

    static func krw(_ usd: Double, rate: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        let n = NSNumber(value: (usd * rate).rounded())
        return "₩" + (f.string(from: n) ?? "\(Int(usd * rate))")
    }

    /// resetsAt 기준 "리셋 3h 18m" / "리셋됨"
    static func reset(_ ts: Int?, now: Int) -> String? {
        guard let ts else { return nil }
        return ts < now ? "리셋됨" : "리셋 \(dur(ts - now))"
    }
}
