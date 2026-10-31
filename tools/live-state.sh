#!/bin/bash
# 지금 이 맥에서 부니가 실제로 어떻게 떠 있는지 — 읽기만 한다.
# 스쿼드 엔진이 팀원·팀장 프롬프트에 붙이고, 설치한 뒤와 쉬는 동안 스스로 점검할 때 다시 읽는다.
# '!종류 설명' 으로 시작하는 줄은 이상 신호다 (엔진이 알아채고 고친다): stale-build(설치본이 소스보다 오래됨) · stray-events(없는 작업의 이벤트 파일) · panels(패널이 세션보다 많음)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Buni.app/Contents/MacOS/Buni"
STATE="$HOME/Library/Application Support/Buni/live-state.json"
EVENTS="${BUNI_EVENTS_DIR:-/tmp}"

pid=$(pgrep -x Buni | head -1)
if [ -z "$pid" ]; then
  echo "부니 앱: 실행 중이 아니에요"
else
  echo "부니 앱: 실행 중 (pid $pid, 시작 $(ps -o lstart= -p "$pid" | sed 's/^ *//'))"
fi
if [ -f "$APP" ]; then
  echo "설치본: $(stat -f '%Sm' -t '%m-%d %H:%M' "$APP") 에 설치됨"
  newer=$(cd "$ROOT" && find Sources windows/buni_team.py Package.swift build_app.sh -type f -newer "$APP" 2>/dev/null | grep -v '\.DS_Store' | head -50)
  n=$(printf '%s' "$newer" | grep -c .)
  if [ "$n" -gt 0 ]; then
    echo "!stale-build 설치된 앱이 소스보다 오래됐어요 — 설치 뒤에 바뀐 파일 ${n}개 (예: $(printf '%s' "$newer" | head -2 | tr '\n' ' '))"
  fi
fi

panels=""
if [ -f "$STATE" ]; then
  panels=$(python3 - "$STATE" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
ps = d.get('panels') or []
print('떠 있는 부니 패널 %d개: %s' % (len(ps), ', '.join('%s(%s)' % (p.get('kind'), (p.get('id') or '')[:14]) for p in ps)))
sq = [p for p in ps if p.get('kind') == 'squad']
if len(sq) > 1:
    print('!panels 스쿼드 패널이 %d개예요 (하나여야 해요)' % len(sq))
PY
)
fi
[ -n "$panels" ] && echo "$panels" || echo "떠 있는 패널: (앱이 알려 주지 않았어요)"

recent=$(find "$EVENTS" -maxdepth 1 -name 'claude-companion-events-*.jsonl' -mmin -30 2>/dev/null | wc -l | tr -d ' ')
echo "최근 30분 안에 바뀐 이벤트 파일: ${recent}개"

# 없는 작업의 스쿼드 이벤트 파일 — 앱이 새 부니로 읽는다
TEAM="$HOME/Library/Application Support/Buni/team/jobs"
stray=0
for f in "$EVENTS"/claude-companion-events-squad-*.jsonl; do
  [ -e "$f" ] || continue
  id=$(basename "$f" .jsonl); id=${id#claude-companion-events-squad-}
  [ -d "$TEAM/$id" ] || stray=$((stray + 1))
done
[ "$stray" -gt 0 ] && echo "!stray-events 없는 작업의 스쿼드 이벤트 파일이 ${stray}개 남아 있어요"
echo "실행 중인 claude 프로세스: $(pgrep -f 'claude.*--output-format' | wc -l | tr -d ' ')개"
exit 0
