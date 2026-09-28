#!/bin/bash
# AI Usage for Mac — 앱 안 "업데이트" 버튼에서 호출됨
# git pull → 재빌드 → 재설치 → 새 앱 실행 → 이전 프로세스 종료
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
cd "$SRC"

LOG="${AIU_LOG:-$HOME/Library/Logs/ai-usage-for-mac/update.log}"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

echo "== $(date '+%F %T') update start ($SRC)"

if ! command -v git >/dev/null 2>&1; then
  echo "❌ git 없음"; exit 1
fi

git fetch origin main
if ! git pull --ff-only origin main; then
  echo "❌ git pull 실패: 로컬 변경으로 fast-forward 불가. $SRC 를 정리한 뒤 다시 시도"
  exit 1
fi
echo "HEAD: $(git rev-parse --short HEAD)  v$(tr -d '[:space:]' < VERSION)"

./scripts/build-app.sh

APP_PATH="${AIU_APP_PATH:-/Applications/AI Usage.app}"
case "$APP_PATH" in *.app) ;; *) APP_PATH="/Applications/AI Usage.app" ;; esac
mkdir -p "$(dirname "$APP_PATH")"
rm -rf "$APP_PATH"
cp -R "build/AI Usage.app" "$APP_PATH"
defaults write com.hdomi.ai-usage-for-mac SourceDir -string "$SRC"
echo "설치: $APP_PATH"

if [ -n "${AIU_OLD_PID:-}" ]; then
  kill "$AIU_OLD_PID" 2>/dev/null || true
  sleep 1
fi
open "$APP_PATH"
echo "✅ v$(tr -d '[:space:]' < VERSION) 업데이트 완료"
