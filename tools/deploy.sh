#!/bin/bash
# 확인을 통과한 결과를 내 맥에 실제로 설치하고 앱을 다시 켠다 (스쿼드 엔진이 팀이 쉴 때 호출).
# 앱·엔진에 영향 없는 변경(문서·시험 등)만이면 종료 코드 3 으로 건너뛴다.
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1
if [ -n "$BUNI_CHANGED_FILES" ] && ! printf '%s' "$BUNI_CHANGED_FILES" | grep -Eq '^(Sources/|windows/buni_team\.py|Package\.swift|build_app\.sh|VERSION)'; then
  echo "앱에 영향 없는 변경이라 설치하지 않아요"
  exit 3
fi
./build_app.sh --install 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -25
exit ${PIPESTATUS[0]}
