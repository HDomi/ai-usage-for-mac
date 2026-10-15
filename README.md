# 🔋 AI Usage for Mac

> MacBook **노치(Notch)** 양옆에 **Claude Code · Cursor · Codex** 사용량 한도를 배터리 아이콘으로 상시 표시하는 네이티브 앱입니다.
> 노치를 클릭하면 아래로 패널이 펼쳐지며 Claude · Codex · Cursor 3열의 겹친 도넛 링·리셋 시간·비용·업데이트 버튼이 나옵니다.

메뉴바 앱이나 SwiftBar 같은 호스트 없이 단독으로 동작합니다.

```
        C5 ▮▮▮ 70   CW ▮▮▮ 91   CF ▮▮ 86  ┃ 노치 ┃  Cr ▮▮ 85   X ▮ 0   XW ▮▮▮ 84
```

- `C5` Claude 5시간 · `CW` Claude 주간 · `CF` Claude 모델(Fable) 주간
- `Cr` Cursor Models · `Co` Other Models
- `X` Codex 5시간 · `XW` Codex 주간

숫자는 **남은 %**. 초록 = 여유, 빨강 = 소진 직전.

---

## 요구 사항

| 항목 | 비고 |
|---|---|
| macOS 14+ | 노치 없는 Mac/외장 모니터에선 화면 상단 중앙에 가상 노치로 표시 |
| Swift 툴체인 | `xcode-select --install` 로 설치되는 Command Line Tools 면 충분 (Xcode 불필요) |
| Node.js 또는 Bun | 데이터 코어(`core/usage-core.js`) 실행용 |
| ccusage (선택) | Claude 블록 비용·오늘 모델별 비용. 없으면 `npx -y ccusage` 로 자동 실행 |
| 접근성 권한 (선택) | 앱 메뉴 폭을 읽어 왼쪽 날개가 메뉴를 덮지 않게 줄임. 없으면 왼쪽은 제한 없이 표시 |

## 설치

```bash
git clone https://github.com/HDomi/ai-usage-for-mac.git
cd ai-usage-for-mac
./install.sh
```

`install.sh` 가 하는 일: `swift build -c release` → `build/AI Usage.app` 번들 생성 → `/Applications` 에 복사 → 실행.
소스 경로를 `defaults` 에 기록해 두므로 앱 안의 업데이트 버튼이 이 체크아웃에서 `git pull` 합니다.

앱은 메뉴바·Dock 아이콘 없이 노치에만 붙습니다. **로그인 시 자동 실행**은 펼친 패널 하단 체크박스로 켭니다.

## 사용

| 동작 | 결과 |
|---|---|
| 노치 클릭 | 상세 패널 펼침 / 접힘 |
| 패널 밖 클릭 · ESC | 접힘 |
| 🆕 업데이트 버튼 | GitHub `main` 이 더 새 버전이면 초록 버튼. 클릭 시 `update.sh` 실행 |
| ⬆️ GitHub 최신으로 재설치 | 버전 같아도 강제 재빌드·재설치 |
| 🔄 새로고침 | 사용량·비용 즉시 재조회 (자동: 접힘 5분 / 펼침 2분 / 저전력 모드 10분) |
| 배터리 항상 표시 (체크 해제) | 접힘 상태에서 알약 대신 노치 오른쪽에 세로 배터리 아이콘 하나만 표시. 잔량은 가장 적게 남은 항목 기준. 클릭하면 그대로 펼쳐짐 |

### 배터리 절약

- 화면 꺼짐·시스템 잠자기·사용자 세션 비활성 상태에서는 자동 조회, 버전 확인, 메뉴바 측정 타이머를 멈춥니다. 다시 활성화되면 오래된 사용량을 갱신합니다.
- 리셋 카운트다운은 상세 패널을 펼쳐 둔 동안만 1분마다 갱신합니다.
- Claude 비용 집계(`ccusage blocks`, `daily`)는 10분간 캐시합니다. 수동 새로고침은 이 캐시를 무시하며, 날짜가 바뀌면 전날 비용을 재사용하지 않습니다.
- 타이머에 10% 허용 오차를 두어 macOS가 다른 작업과 실행 시점을 맞출 수 있게 합니다.

자동 비용 표시는 최대 10분 전 값일 수 있습니다. 사용량 한도는 위의 자동 조회 주기로 별도 갱신합니다.

### 업데이트 흐름

```
[앱] 1시간마다 GitHub commits SHA → VERSION 조회 (raw CDN 캐시 회피)
      └─ 새 버전이면 패널에 🆕 버튼
[버튼] update.sh: git pull --ff-only → scripts/build-app.sh → /Applications 교체 → 새 앱 실행 → 이전 프로세스 종료
      로그: ~/Library/Logs/ai-usage-for-mac/update.log
```

`git pull` 이 fast-forward 안 되면(로컬 수정) 실패로 표시되고 로그를 열 수 있습니다.

### 사용액

도넛 아래 "💳 오늘 약 $x · ₩y" 는 [ai-usage-battery](https://github.com/HDomi/ai-usage-battery) 와 같은 기준입니다.

| 서비스 | 근거 |
|---|---|
| Claude | `ccusage daily --breakdown` 오늘 모델별 합. 없으면 `ccusage blocks --active` 활성 블록 비용. API 요금 기준 토큰 비용 환산 |
| Codex | 토큰 비용 출처 없음 → 표시 안 함 |
| Cursor | 실제 청구액 (`totalSpendCents`) |

`ccusage` 가 설치돼 있지 않으면 `npx -y ccusage` 로 실행합니다 (첫 실행은 다운로드로 느릴 수 있음). `AIU_NO_CCUSAGE=1` 로 끌 수 있습니다. 원화는 코어가 받아온 환율(₩/$).

### 메뉴바 공간 정책

노치 양옆 날개는 메뉴바에 이미 있는 것(왼쪽 앱 메뉴, 오른쪽 상태 아이콘)과 겹치지 않게 좌우 따로 폭을 정합니다.

```
[앱 메뉴 ……… 도움말]  8pt  [C5 ▮ 70  CW ▮ 91  CF ▮ 86] ┃노치┃ [X ▮ 0  XW ▮ 84]  8pt  [상태 아이콘 …]
```

| 남은 공간 | 표시 |
|---|---|
| 충분 | 라벨 + 배터리 + 숫자 (64pt/개) |
| 부족 | 배터리 아이콘 제거, 라벨 + 숫자 (40pt/개) |
| 그래도 부족 | 우선순위 낮은 것부터 숨김 |

숨김 우선순위 (끝까지 남는 순): Claude `C5` > `CW` > `CF` · Codex `X` > `XW` > Cursor `Cr` > `Co`

- 오른쪽 상태 아이콘은 `CGWindowList` 로 권한 없이 측정
- 왼쪽 앱 메뉴는 최전방 앱의 `AXMenuBar` 로 측정 → **접근성 권한** 필요. 첫 실행에 한 번 요청하고, 거부하면 패널 하단에 "권한 설정 열기" 버튼
- 앱 전환·앱 실행/종료·화면/Space 변경 때 다시 재고, 30초마다 보정합니다 (저전력 모드는 60초). 빠르게 연속된 이벤트는 한 번으로 합칩니다.
- 다른 앱이 풀스크린(영상·게임·네이티브 풀스크린)이면 노치 패널을 숨깁니다. 화면 폭 전체를 메뉴바 아래부터 바닥까지 덮는 창이 있고 상단에 상태 아이콘이 하나도 없을 때를 풀스크린으로 봅니다 (최대화 창과 구분). 같은 측정 시점에 검사합니다.
- 앱은 ad-hoc 서명이라 designated requirement 를 번들 ID 로 고정해 재빌드 후에도 권한이 유지됩니다 (`scripts/build-app.sh`)

---

## 구조

```
┌───────────────────────────── AI Usage.app (Swift · AppKit + SwiftUI) ─────────────────────────────┐
│ NotchController  노치 위치 계산(NSScreen.auxiliaryTop*Area) · NSPanel(메뉴바 위 레벨) · 클릭/ESC   │
│ NotchViewModel   상태별 2~10분 조회 · 화면 꺼짐 시 중단 · 로그인 항목 · 날개 폭 정책                  │
│ MenuBarProbe     앱 메뉴 폭(AXMenuBar) · 상태 아이콘 폭(CGWindowList) 측정 → 날개 폭 좌우 따로 조절     │
│ Views/           NotchView(접힘: 배터리 알약) · ExpandedBody(펼침: Claude·Codex·Cursor 3열 도넛 링)  │
│ UsageCore        node core/usage-core.js 실행 → JSON 디코드                                        │
│ Updater          GitHub VERSION 조회 · update.sh 실행                                              │
└───────────────────────────────────────▲────────────────────────────────────────────────────────────┘
                                        │ JSON (UsageSnapshot)
┌───────────────────────────────────────┴────────────────────────────────────────────────────────────┐
│ core/usage-core.js (Node, 의존성 없음)                                                              │
│  Claude: Keychain "Claude Code-credentials" → GET api.anthropic.com/api/oauth/usage                │
│  Cursor: state.vscdb 토큰 → api2.cursor.sh GetCurrentPeriodUsage (free 계정은 숨김)               │
│  Codex : ~/.codex/auth.json → chatgpt.com/backend-api/wham/usage (401 이면 refresh_token 갱신)     │
│  캐시  : ~/Library/Application Support/ai-usage-for-mac/  (실패 시 마지막 값 폴백)                  │
└────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

토큰은 `curl -H @-` 로 stdin 주입해 프로세스 목록에 노출되지 않습니다.

## 개발

```bash
swift build                      # 디버그 빌드
AIU_DEBUG=1 .build/debug/AIUsageNotch          # 창 프레임·메뉴바 점유 폭 로그 stderr
AIU_DEBUG=1 AIU_DEBUG_EXPAND=10 .build/debug/AIUsageNotch  # 10초 뒤 자동 펼침, 2초 뒤 접힘 (레이아웃 확인용, 값은 초)
AIU_ANIM=1.0 .build/debug/AIUsageNotch                     # 펼침 애니메이션을 1초로 늘림 (프레임 확인용)
node core/usage-core.js | jq     # 코어 단독 실행
node --test core/usage-core.test.mjs # 비용 캐시·실패/날짜 변경·수동 갱신 회귀 테스트 (인증/네트워크 불필요)
./scripts/build-app.sh           # build/AI Usage.app 생성
./scripts/uninstall.sh           # 제거
```

환경 변수: `EXCHANGE_RATE_KRW` (환율 고정), `AIU_NO_CCUSAGE=1` (ccusage 생략), `AIU_STATE_DIR` (캐시 위치), `AIU_FORCE_DETAILS=1` (비용 캐시 무시).

## 라이선스

MIT
