#!/bin/bash
# 부니 스쿼드가 "화면이 바뀌었는지"를 변경 전·후로 비교할 때 부르는 스크립트.
#   BUNI_TREE      화면을 찍을 소스 트리 (변경 전 또는 후 — 엔진이 git 에서 꺼내 둔 폴더)
#   BUNI_SHOT_DIR  PNG 를 놓을 폴더
# 팀 현황 화면 몇 개를 같은 예시 데이터로 그려서 PNG 로 저장한다. (맥 전용 — 컴파일에 1~2분)
set -e
D="$(cd "$(dirname "$0")" && pwd)"
T="${BUNI_TREE:-$(cd "$D/.." && pwd)}"
OUT="${BUNI_SHOT_DIR:?BUNI_SHOT_DIR 가 필요해요}"
[ "$(uname)" = "Darwin" ] || { echo "맥에서만 찍어요"; exit 0; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$OUT"
python3 "$D/preview/make_sample.py" "$W/home"
SRC=$(ls "$T"/Sources/ClaudeCompanion/*.swift | grep -v '/main.swift$')
swiftc -module-name BuniPreview -o "$W/bin" $SRC "$D/preview/main.swift" 2> "$W/build.log" || { tail -20 "$W/build.log" >&2; exit 1; }
BUNI_TEAM_HOME="$W/home" BUNI_PREVIEW=1 "$W/bin" "$OUT"
