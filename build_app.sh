#!/bin/bash
# Claudy.app 번들 빌드 스크립트
# 사용: ./build_app.sh [--install]   --install 플래그 시 /Applications에 복사
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Claudy"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Claudy.app 빌드"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Swift Release 빌드
echo ""
echo "▶ Swift 빌드 중..."
cd "$SCRIPT_DIR"
swift build -c release
BINARY="$SCRIPT_DIR/.build/release/ClaudeCompanion"
echo "✓ 빌드 완료"

# ── 2. 앱 번들 구조 생성
echo ""
echo "▶ 앱 번들 생성 중..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# ── 3. 바이너리 복사
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
echo "✓ 바이너리 복사됨"

# ── 4. Info.plist 생성
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>Claudy</string>
    <key>CFBundleIdentifier</key>      <string>com.claudy.companion</string>
    <key>CFBundleName</key>            <string>Claudy</string>
    <key>CFBundleDisplayName</key>     <string>Claudy</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
</dict>
</plist>
PLIST
echo "✓ Info.plist 생성됨"

# ── 5. 아이콘 생성 (sips + iconutil)
echo ""
echo "▶ 아이콘 생성 중..."
ICONSET_DIR="$SCRIPT_DIR/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

declare -a SIZES=(16 32 64 128 256 512 1024)
for sz in "${SIZES[@]}"; do
    python3 "$SCRIPT_DIR/make_icon.py" "$ICONSET_DIR/tmp_${sz}.png" "$sz"
done

# iconutil 요구 파일명으로 복사
sips -z 16   16   "$ICONSET_DIR/tmp_16.png"   --out "$ICONSET_DIR/icon_16x16.png"   -s format png > /dev/null
sips -z 32   32   "$ICONSET_DIR/tmp_32.png"   --out "$ICONSET_DIR/icon_16x16@2x.png" -s format png > /dev/null
sips -z 32   32   "$ICONSET_DIR/tmp_32.png"   --out "$ICONSET_DIR/icon_32x32.png"   -s format png > /dev/null
sips -z 64   64   "$ICONSET_DIR/tmp_64.png"   --out "$ICONSET_DIR/icon_32x32@2x.png" -s format png > /dev/null
sips -z 128  128  "$ICONSET_DIR/tmp_128.png"  --out "$ICONSET_DIR/icon_128x128.png" -s format png > /dev/null
sips -z 256  256  "$ICONSET_DIR/tmp_256.png"  --out "$ICONSET_DIR/icon_128x128@2x.png" -s format png > /dev/null
sips -z 256  256  "$ICONSET_DIR/tmp_256.png"  --out "$ICONSET_DIR/icon_256x256.png" -s format png > /dev/null
sips -z 512  512  "$ICONSET_DIR/tmp_512.png"  --out "$ICONSET_DIR/icon_256x256@2x.png" -s format png > /dev/null
sips -z 512  512  "$ICONSET_DIR/tmp_512.png"  --out "$ICONSET_DIR/icon_512x512.png" -s format png > /dev/null
sips -z 1024 1024 "$ICONSET_DIR/tmp_1024.png" --out "$ICONSET_DIR/icon_512x512@2x.png" -s format png > /dev/null

# 임시 파일 제거
rm "$ICONSET_DIR"/tmp_*.png

# ICNS 생성
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR"
echo "✓ 아이콘 생성됨"

# ── 6. ad-hoc 서명 (Gatekeeper 없이 실행 가능)
echo ""
echo "▶ 앱 서명 중..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null && echo "✓ ad-hoc 서명 완료" || echo "⚠ 서명 생략 (codesign 없음)"

echo ""
echo "✅ $APP_BUNDLE 생성 완료"

# ── 7. /Applications 설치 (--install 옵션)
if [[ "$1" == "--install" ]]; then
    echo ""
    echo "▶ /Applications에 설치 중..."
    # 실행 중이면 종료
    osascript -e 'quit app "Claudy"' 2>/dev/null || true
    pkill -x "Claudy" 2>/dev/null || true
    sleep 0.5

    rm -rf "/Applications/$APP_NAME.app"
    cp -r "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    echo "✓ /Applications/Claudy.app 설치 완료"

    echo ""
    echo "▶ Claudy 시작 중..."
    open "/Applications/$APP_NAME.app"
    echo "✓ 실행됨"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$1" == "--install" ]]; then
    echo "  ✅ 설치 완료!"
    echo "  Launchpad 또는 Spotlight에서 'Claudy'로 검색하세요."
else
    echo "  빌드만 완료됨. 설치하려면:"
    echo "  ./build_app.sh --install"
    echo ""
    echo "  또는 직접 열기:"
    echo "  open \"$APP_BUNDLE\""
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
