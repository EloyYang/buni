#!/bin/bash
# 스쿼드가 내 폴더에 반영한 뒤(그리고 쉬는 동안 스스로 점검할 때) 돌리는 확인 — 실패하면 종료 코드가 0이 아니다.
# 환경변수 BUNI_CHANGED_FILES = 방금 바뀐 파일(줄바꿈으로 구분, 비어 있으면 전체 확인)
set -o pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1
export BUNI_TEAM_NO_SHOTS=1 BUNI_TEAM_NO_VERIFY=1
if [ -z "$BUNI_CHANGED_FILES" ] || printf '%s' "$BUNI_CHANGED_FILES" | grep -Eq '\.swift$|^Package\.swift$'; then
  echo "▶ swift build"
  swift build 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'error:|Build complete|Compiling|warning: unre' | sort -u | tail -30
  [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
fi
echo "▶ 시험"
python3 -m unittest discover -s tests -p 'test_*.py' 2>&1 | tail -40
rc=${PIPESTATUS[0]}
git checkout -- tests/license_vectors.json 2>/dev/null   # 시험이 다시 쓰는 파일 — 내 변경이 아니다
exit $rc
