#!/bin/bash
# Buni 릴리즈 스크립트
# 사용: ./release.sh <버전>   예) ./release.sh 1.0.1
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:?사용법: ./release.sh <버전>  예) ./release.sh 1.0.1}"
APP_BUNDLE="$SCRIPT_DIR/Buni.app"
ZIP_NAME="Buni-macOS-${VERSION}.zip"
ZIP_PATH="$SCRIPT_DIR/$ZIP_NAME"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Buni v$VERSION 릴리즈"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. VERSION 파일 업데이트 & 빌드
echo ""
echo "▶ 버전 설정: $VERSION"
echo "$VERSION" > "$SCRIPT_DIR/VERSION"

echo ""
echo "▶ 앱 빌드 중..."
"$SCRIPT_DIR/build_app.sh"

# ── 2. ZIP 생성
echo ""
echo "▶ ZIP 패키징 중..."
rm -f "$ZIP_PATH"
cd "$SCRIPT_DIR"
zip -r "$ZIP_NAME" "Buni.app" > /dev/null
echo "✓ $ZIP_NAME 생성됨"

# ── 3. SHA256
SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
echo "✓ SHA256: $SHA256"

# ── 4. git 커밋 + 태그
echo ""
echo "▶ git 커밋 & 태그..."
cd "$SCRIPT_DIR"
git add VERSION
git commit -m "chore: release v$VERSION" || echo "  (변경 없음, 태그만 추가)"
git tag -f "v$VERSION"
git push origin main --tags
echo "✓ v$VERSION 태그 푸시됨"

# ── 5. GitHub Release 생성
echo ""
echo "▶ GitHub Release 생성 중..."
gh release create "v$VERSION" \
    "$ZIP_PATH#Buni-macOS.zip" \
    --title "Buni v$VERSION" \
    --notes "## 🍎 macOS 설치

1. **Buni-macOS.zip** 다운로드 후 압축 해제
2. **Buni.app** 을 Applications 폴더로 드래그
3. 처음 실행 시 Gatekeeper 경고가 뜨면:
   - 시스템 설정 → 개인정보 보호 및 보안 → **확인 없이 열기**
   - 또는 터미널: \`xattr -dr com.apple.quarantine /Applications/Buni.app\`
4. 실행하면 Claude Code 훅이 **자동으로 설치**됩니다.

---

## 🪟 Windows 설치

### 설치형 (권장)
1. **Buni-Windows-Setup-$VERSION.exe** 다운로드 후 실행
2. 설치 마법사를 따라 진행
3. Claude Code 훅이 **자동으로 설치**됩니다.

### 포터블 (설치 없이 바로 실행)
1. **Buni-Windows.exe** 다운로드 후 실행

> *(Windows 파일은 GitHub Actions가 자동 빌드해 수 분 내 추가됩니다)*

---

## 🔗 VS Code SSH Remote 지원 (Cursor, VSCodium 포함)

VS Code(또는 Cursor, VSCodium)로 SSH 원격 서버에 접속해 Claude Code를 사용할 경우도 지원합니다.

**로컬 쪽은 자동**: Buni 실행 시 설치된 VS Code 계열 에디터의 \`settings.json\`에 포트 포워딩(\`-R 58765:localhost:58765\`)이 자동으로 추가됩니다.

**원격 호스트는 한 번만 직접 설치** (Buni는 데스크톱 전용이라 원격 서버에는 훅 스크립트만 필요):

\`\`\`bash
ssh <원격호스트> 'bash -s' < remote-install.sh
\`\`\`

이후 VS Code로 새로 SSH 접속해 \`claude\`를 실행하면 원격 세션이 로컬 Buni에 자동으로 표시됩니다."

RELEASE_URL="https://github.com/EloyYang/buni/releases/tag/v$VERSION"
echo "✓ 릴리즈 완료: $RELEASE_URL"

# ── 6. Homebrew tap 업데이트 (tap repo가 있을 때만)
TAP_DIR="$HOME/homebrew-buni"
if [ -d "$TAP_DIR" ]; then
    echo ""
    echo "▶ Homebrew tap 업데이트 중..."
    cat > "$TAP_DIR/Casks/buni.rb" << RUBY
cask "buni" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/EloyYang/buni/releases/download/v#{version}/Buni-macOS.zip"
  name "Buni"
  desc "Claude Code 메뉴바 컴패니언 앱"
  homepage "https://github.com/EloyYang/buni"

  app "Buni.app"

  zap trash: [
    "~/Library/Preferences/com.buni.companion.plist",
    "/tmp/claude-companion-events.jsonl",
  ]

  caveats <<~EOS
    Buni는 Apple 공증 없이 배포됩니다.
    처음 실행 시 Gatekeeper 경고가 뜨면:
      시스템 설정 → 개인정보 보호 및 보안 → '확인 없이 열기'
    또는: xattr -dr com.apple.quarantine /Applications/Buni.app
  EOS
end
RUBY
    cd "$TAP_DIR"
    git add Casks/buni.rb
    git commit -m "buni $VERSION"
    git push
    echo "✓ Homebrew tap 업데이트됨"
else
    echo ""
    echo "ℹ Homebrew tap 미설정 (선택사항)"
    echo "  tap을 만들려면: ./setup_homebrew_tap.sh"
fi

# ── 7. 임시 ZIP 정리
rm -f "$ZIP_PATH"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Buni v$VERSION 릴리즈 완료!"
echo "  $RELEASE_URL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
