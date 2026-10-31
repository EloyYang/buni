#!/bin/bash
# 스쿼드가 내 폴더에 반영한 뒤(그리고 쉬는 동안 스스로 점검할 때) 돌리는 확인 — 실패하면 종료 코드가 0이 아니다.
# 환경변수 BUNI_CHANGED_FILES = 방금 바뀐 파일(줄바꿈으로 구분, 비어 있으면 전체 확인)
set -o pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1
export BUNI_TEAM_NO_SHOTS=1 BUNI_TEAM_NO_VERIFY=1
if [ -z "$BUNI_CHANGED_FILES" ] || printf '%s' "$BUNI_CHANGED_FILES" | grep -Eq '\.swift$|^Package\.swift$'; then
  echo "▶ swift build"
  SCR=""; case "$PWD" in */CloudStorage/*) SCR="--scratch-path $HOME/.cache/buni-verify";; esac   # 클라우드 동기화 폴더 안의 .build 는 'Stale NFS file handle' 로 링크가 깨진다
  swift build $SCR 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'error:|Build complete|Compiling|warning: unre' | sort -u | tail -30
  [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1
fi
echo "▶ 시험"
python3 -m unittest discover -s tests -p 'test_*.py' 2>&1 | tail -40
rc=${PIPESTATUS[0]}
# Windows 화면(Tk)은 Tk 가 있는 파이썬이 있을 때 실제로 열어 본다 — 문법 검사만으로는 "창이 안 뜨는" 오류를 못 잡는다
for py in python3.12 python3.13 python3.11 /usr/local/bin/python3 python3; do
  if $py -c "import tkinter" 2>/dev/null; then
    echo "▶ Windows 화면 열어 보기 ($py)"
    BUNI_UI_TEST=1 $py -m unittest discover -s tests -p 'test_board_ui.py' 2>&1 | tail -15
    [ "${PIPESTATUS[0]}" -eq 0 ] || rc=1
    break
  fi
done
git checkout -- tests/license_vectors.json 2>/dev/null   # 시험이 다시 쓰는 파일 — 내 변경이 아니다
exit $rc
