# 🔋 AI Usage for Mac

> MacBook **노치(Notch)** 양옆에 **Claude Code · Cursor · Codex** 사용량 한도를 배터리 아이콘으로 상시 표시하는 네이티브 앱입니다.
> 노치를 클릭하면 아래로 패널이 펼쳐지며 상세 게이지·리셋 시간·비용·업데이트 버튼이 나옵니다.

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
| ccusage (선택) | 있으면 Claude 블록 비용·오늘 모델별 비용 표시 |
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
| 🔄 새로고침 | 즉시 재조회 (기본 2분마다 자동) |

### 업데이트 흐름

```
[앱] 1시간마다 GitHub commits SHA → VERSION 조회 (raw CDN 캐시 회피)
      └─ 새 버전이면 패널에 🆕 버튼
[버튼] update.sh: git pull --ff-only → scripts/build-app.sh → /Applications 교체 → 새 앱 실행 → 이전 프로세스 종료
      로그: ~/Library/Logs/ai-usage-for-mac/update.log
```

`git pull` 이 fast-forward 안 되면(로컬 수정) 실패로 표시되고 로그를 열 수 있습니다.

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
- 3초마다 + 앱 전환 때 다시 잽니다
- 앱은 ad-hoc 서명이라 designated requirement 를 번들 ID 로 고정해 재빌드 후에도 권한이 유지됩니다 (`scripts/build-app.sh`)

---

## 구조

```
┌───────────────────────────── AI Usage.app (Swift · AppKit + SwiftUI) ─────────────────────────────┐
│ NotchController  노치 위치 계산(NSScreen.auxiliaryTop*Area) · NSPanel(메뉴바 위 레벨) · 클릭/ESC   │
│ NotchViewModel   2분 타이머 · 업데이트 체크 · 로그인 항목(SMAppService) · 날개 폭 정책(full/compact/숨김)│
│ MenuBarProbe     앱 메뉴 폭(AXMenuBar) · 상태 아이콘 폭(CGWindowList) 측정 → 날개 폭 좌우 따로 조절     │
│ Views/           NotchView(접힘: 배터리 알약) · ExpandedBody(펼침: 게이지·비용·푸터)               │
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
AIU_DEBUG=1 AIU_DEBUG_EXPAND=1 .build/debug/AIUsageNotch   # 4초 뒤 자동 펼침 (레이아웃 확인용)
node core/usage-core.js | jq     # 코어 단독 실행
./scripts/build-app.sh           # build/AI Usage.app 생성
./scripts/uninstall.sh           # 제거
```

환경 변수: `EXCHANGE_RATE_KRW` (환율 고정), `AIU_NO_CCUSAGE=1` (ccusage 생략), `AIU_STATE_DIR` (캐시 위치).

## 라이선스

MIT
