"""이벤트 파일 목록에서 새로 부니 창을 만들 세션을 고르는 규칙 (맥 SessionDedupe.swift 와 같다).

- 이미 창이 있는 세션 id 는 다시 만들지 않는다.
- 스쿼드 세션(`squad-<작업id>`)은 작업마다 파일이 생기지만 부니는 하나만 — 이미 스쿼드 창이 있으면 더 만들지 않고,
  없으면 가장 최근에 갱신된 스쿼드 파일 하나만 고른다.
"""

SQUAD_PREFIX = 'squad-'


def pick_new_sessions(found: dict, existing, squad_removed_at: float = 0.0) -> list:
    """found: {세션 id: 파일 수정 시각}, existing: 이미 창이 있는(또는 만들기를 예약해 둔) 세션 id 들 → 새로 만들 세션 id 목록.
    squad_removed_at: 스쿼드 패널을 마지막으로 치운 시각 — 그 뒤로 갱신되지 않은 스쿼드 파일(다른 작업의 묵은 파일)은 되살리지 않는다."""
    existing = set(existing)
    out = [s for s in found if s not in existing and not s.startswith(SQUAD_PREFIX)]
    if not any(s.startswith(SQUAD_PREFIX) for s in existing):
        squads = [(m, s) for s, m in found.items() if s.startswith(SQUAD_PREFIX) and m > squad_removed_at]
        if squads:
            out.append(max(squads)[1])
    return sorted(out)


def squad_panels_to_close(panels: dict) -> list:
    """panels: {열려 있는 세션 id: 이벤트 파일 수정 시각} → 닫을 스쿼드 세션 id 목록.
    스쿼드 패널은 하나만 남긴다(가장 최근에 갱신된 것) — 나머지는 패널만 닫고 파일·데이터는 그대로 둔다."""
    squads = [(m, s) for s, m in panels.items() if s.startswith(SQUAD_PREFIX)]
    if len(squads) < 2:
        return []
    keep = max(squads)[1]
    return sorted(s for _, s in squads if s != keep)
