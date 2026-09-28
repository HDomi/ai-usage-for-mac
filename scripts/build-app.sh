#!/bin/bash
# AI Usage for Mac — swift build 후 build/AI Usage.app 번들 생성
# Xcode 없이 Command Line Tools 만으로 동작한다.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
APP="build/AI Usage.app"
BIN="AIUsageNotch"
BUNDLE_ID="com.hdomi.ai-usage-for-mac"

echo "🔨 swift build -c release (v$VERSION)"
swift build -c release 2>&1 | grep -vE '^\s*$' | tail -n 20
BUILT="$(swift build -c release --show-bin-path)/$BIN"
[ -x "$BUILT" ] || { echo "❌ 빌드 산출물 없음: $BUILT"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILT" "$APP/Contents/MacOS/$BIN"
cp core/usage-core.js "$APP/Contents/Resources/usage-core.js"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleExecutable</key><string>$BIN</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>AI Usage</string>
  <key>CFBundleDisplayName</key><string>AI Usage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
# designated requirement 를 identifier 로 고정: ad-hoc 기본값(cdhash)이면 재빌드마다 접근성 권한이 풀린다
codesign --force --deep --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP" >/dev/null 2>&1 \
  || echo "ⓘ ad-hoc codesign 실패 (무시 가능)"
echo "✅ 번들 생성: $APP"
