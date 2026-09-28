#!/bin/bash
# AI Usage for Mac — 설치 스크립트 (빌드 → /Applications 배치 → 실행)
set -e
cd "$(dirname "$0")"

echo "🔋 AI Usage for Mac — 설치"
echo "────────────────────────────────────"

# 1) Swift 툴체인 (Command Line Tools 면 충분)
if ! command -v swift >/dev/null 2>&1; then
  echo "❌ swift 가 필요합니다: xcode-select --install"
  exit 1
fi
echo "✅ Swift: $(swift --version 2>&1 | head -1)"

# 2) JS 런타임 (node 또는 bun) — 앱이 usage-core.js 를 이걸로 실행
if command -v node >/dev/null 2>&1 || [ -x /opt/homebrew/bin/node ] || [ -d "$HOME/.nvm/versions/node" ]; then
  echo "✅ node 감지"
elif command -v bun >/dev/null 2>&1 || [ -x "$HOME/.bun/bin/bun" ]; then
  echo "✅ bun 감지"
else
  echo "⚠️  node/bun 없음 — 설치 후 패널이 채워집니다: brew install node"
fi

# 3) 선택 항목 안내
command -v ccusage >/dev/null 2>&1 && echo "✅ ccusage (Claude 비용 상세 표시)" || echo "ⓘ  ccusage 없음 — 배터리 정상, Claude 비용 상세만 생략"
[ -f "$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb" ] && echo "✅ Cursor 세션 DB" || echo "ⓘ  Cursor 세션 DB 없음"
[ -f "$HOME/.codex/auth.json" ] && echo "✅ Codex auth.json" || echo "ⓘ  Codex auth.json 없음"

# 4) 빌드
./scripts/build-app.sh

# 5) 배치
DEST_DIR="${AIU_INSTALL_DIR:-/Applications}"
[ -w "$DEST_DIR" ] || DEST_DIR="$HOME/Applications"
mkdir -p "$DEST_DIR"
APP="$DEST_DIR/AI Usage.app"

pkill -x AIUsageNotch 2>/dev/null || true
sleep 0.5
rm -rf "$APP"
cp -R "build/AI Usage.app" "$APP"
defaults write com.hdomi.ai-usage-for-mac SourceDir -string "$(pwd)"
echo "✅ 설치: $APP"

# 6) 실행
open "$APP"
echo "────────────────────────────────────"
echo "✅ 노치 양옆에 배터리가 뜹니다. 노치를 클릭하면 상세·업데이트·로그인 시 실행 설정."
