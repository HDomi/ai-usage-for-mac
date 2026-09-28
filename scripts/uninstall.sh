#!/bin/bash
# AI Usage for Mac — 제거 (앱 종료, 앱 번들·로그인 항목·캐시 삭제)
set -e
pkill -x AIUsageNotch 2>/dev/null || true
rm -rf "/Applications/AI Usage.app" "$HOME/Applications/AI Usage.app"
defaults delete com.hdomi.ai-usage-for-mac 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/ai-usage-for-mac" "$HOME/Library/Logs/ai-usage-for-mac"
echo "✅ 제거 완료 (소스 체크아웃은 그대로 둠)"
