# 부니 스쿼드 팀 구조 — 상시 직무 + 추가 배정

팀원은 업무(오류·기능 요청)마다 새로 만들지 않는다. **상위 부서 → 세부 담당(직무)** 으로 나눠 두고, 새 업무는 분야로 분류해 이미 있는 담당자에게 이어서 붙인다. 구현은 `windows/buni_team.py`(맥·Windows 공용 엔진), 시험은 `tests/test_team_duties.py`.

## 1. 직무 카탈로그

| 부서 (`dept`) | 직무 (`duty`) | 이름 | 맡는 곳 |
|---|---|---|---|
| `frontend` 프론트엔드 | `frontend_mac` | 프론트엔드 담당 (맥) | `Sources/ClaudeCompanion/` Swift 앱 |
| | `frontend_win` | 프론트엔드 담당 (Windows) | `windows/` Tkinter 화면 (`buni.py`, `buni_team_ui.py`, `buni_pro_ui.py`) |
| `backend` 백엔드 | `backend_server` | 백엔드 담당 (서버·엔진) | `windows/buni_team.py` 스쿼드 엔진, job.json, 예약·실행 |
| | `backend_license` | 백엔드 담당 (라이선스·결제) | `buni_license.py`, `buni_pro.py`, Ed25519 키, 결제 링크 |
| | `backend_chat_cloud` | 백엔드 담당 (채팅·클라우드) | `buni_chat.py`(방 코드·Realtime Database), `buni_cloud.py`(Google 로그인·Firestore) |

- 부서 `share`: 백엔드는 `true` — 해당 직무 담당자가 없으면 같은 부서의 다른 담당자가 겸한다. 프론트엔드는 `false` — 맥 담당자가 Windows 화면을 대신하지 않는다.
- 카탈로그는 코드의 `DEPARTMENTS` · `DUTIES` 한 곳에서 정의하고, 직무를 추가할 때는 거기에 한 줄만 넣는다 (`keys` 는 분류용 키워드 정규식).

## 2. 저장 형식 (화면이 읽을 필드)

`job.json` 의 `plan.roles[*]` 에 필드가 **추가**된다. 없는 예전 데이터도 그대로 읽힌다.

| 필드 | 형식 | 설명 |
|---|---|---|
| `dept` | 문자열 `"frontend"` / `"backend"` / (없음) | 부서 id |
| `duty` | 문자열 `"frontend_mac"` … / (없음) | 직무 id |
| `duty_history` | 배열 (선택) | 직무가 바뀐 이력 — 각 항목 `{name, icon, dept, duty, mission(300자), ts}` = 바뀌기 **전** 모습 |

화면은 이름 문구를 직접 만들지 않고 엔진 CLI 를 부르거나(맥) 함수를 부른다(Windows).

- `python3 buni_team.py duties [<작업id>]` → JSON 한 덩어리
  ```json
  {"catalog": [{"id":"backend","name":"백엔드","en":"Backend","icon":"⚙️","share":true,
                "duties":[{"id":"backend_server","name":"백엔드 담당 (서버·엔진)","short":"서버·엔진","en":"Backend (Server/Engine)","icon":"⚙️","mission":"…"}]}],
   "team": [{"dept":"backend","dept_name":"백엔드",
             "members":[{"id":"backend_server","name":"…","icon":"⚙️","duty":"backend_server","duty_label":"백엔드 · 서버·엔진","status":"accepted"}]}]}
  ```
  `team` 은 작업 id 를 줄 때만. 부서별로 묶이며 직무를 알 수 없는 팀원(예전 데이터 등)은 `dept: ""`, `dept_name: "기타"` 묶음에 들어간다.
- Windows(파이썬): `bt.team_structure(job)` · `bt.duty_catalog()` · `bt.duty_label(duty_id)` · `bt.role_duty(role)` · `bt.role_dept(role)`.
- **표시 문구**: `duty_label` = `"<부서> · <세부 담당>"` (예 `백엔드 · 서버·엔진`, `프론트엔드 · Windows`). 직무가 없으면 빈 문자열이니 그때는 아무것도 보여 주지 않는다. 맥은 `plan.roles[*].dept`/`duty` 가 있으면 위 표(§1)의 `short` 로 같은 문구를 만든다.
- 직무를 알 수 없는 예전 팀원은 `role_duty` 가 (1) 저장된 `duty` → (2) 팀원 id 가 직무 id 와 같을 때 → (3) 이름·임무에서 한 직무가 분명할 때(키워드 2회 이상, 2위보다 높음)만 짐작한다. 그래도 모르면 `''`.

## 3. 업무 자동 배정 규칙

입구는 세 곳이며 모두 같은 규칙(`assign_task`)을 쓴다: 채팅 지시(`chat_send` → `_dispatch_assignments`), wrap_up 의 다음 할 일(`start_followup`), 오류 수정 요청(채팅 지시와 같은 경로).

1. **분류** `classify_task(text)` — 업무 글에서 직무 키워드(파일 이름·기술 이름)가 가장 많이 나온 직무로 정한다. `windows/buni_team.py` 같은 경로의 `windows/` 는 Windows 화면으로 세지 않는다. 맥·Windows 가 동점이면 둘 다(양쪽에 지시), 백엔드끼리 동점이면 카탈로그 앞쪽 하나. 단서가 없으면 분류 없음 → 예전 방식 그대로(팀장이 정한 팀원 / 이 업무만 맡는 `next_*` 팀원).
2. **기존 담당자 재사용** `find_assignee` — 같은 직무 담당자 중 가장 한가한 사람(끝남 < 대기 < 다시 작업 < 작업 중). 일하는 중이면 끝나는 대로 이어서 하고(`note_pending`), 끝난 팀원은 다시 열린다. `share` 부서면 직무 담당자가 없을 때 같은 부서 사람.
3. **직무 변경** `reassign_role` — 맞는 담당자가 없으면 **모든 일이 끝나(통과) 더 할 일이 없는** 팀원의 직무를 바꿔 맡긴다. 직무 없는(예전) 팀원 → 같은 직무가 둘 이상인 팀원 순. 그 직무의 유일한 담당자와 일하는 팀원은 건드리지 않는다. 이름·아이콘·부서·직무·임무를 새 직무로 바꾸고 `kind` 는 `code`, 옛 모습은 `duty_history` 에 남긴다. 옛 이름으로 불러도 `resolve_role` 이 같은 사람을 찾는다.
4. **새 팀원** — 위 둘이 모두 안 될 때만. id 는 직무 id(`frontend_win` 등), `dept`·`duty` 가 적힌다.
5. 팀원은 **없애지 않는다.**
6. 어느 경로든 채팅(전체)에 **한 줄**로 알린다.
   - 재사용: `📌 업무 배정: <아이콘> <이름> (<부서 · 담당>) 에게 이어서 맡겨요 — 새 팀원은 만들지 않았어요.`
   - 직무 변경: `🔄 직무 변경: <옛 이름> → <새 이름> — 더 할 일이 없어 이 업무를 맡겨요 (팀원은 그대로예요).`
   - 새 팀원: `새 팀원 <이름> 이(가) 합류했어요 (<부서 · 담당>).`

`resolve_role(job, ref, text='')` 는 id · 이름 · 직무 id · 직무 이름 · 직무 변경 전 이름을 모두 알아듣고, 못 찾으면 `text` 를 분류해 기존 담당자를 찾는다.

채팅 지시(`_dispatch_assignments`):
- 팀장이 `new_roles` 로 새 팀원을 만들겠다고 해도, 분야가 분명하면 먼저 2~3 을 시도한다. 팀장이 쓴 새 id 로 낸 지시는 실제로 맡은 팀원에게 이어진다.
- `assignments` 의 역할이 팀원 현황에 없으면 지시 내용을 분류해 배정한다. 팀장이 [팀원 현황]에 있는 팀원을 직접 골랐으면 그 선택을 존중한다.

다음 할 일(`start_followup`): 분야가 정해지면 그 담당자에게 업무 메모(`send_role_note`)로 붙이고 `wrapup.json` 항목의 `role_id` 는 그 담당자 id 가 된다. 한 담당자가 여러 다음 업무를 맡으면 업무 현황 카드는 담당자 한 장에 가장 최근 업무 제목이 붙는다. 분야를 못 정하면 예전처럼 `next_<단계>` 팀원.

## 4. 팀장 프롬프트

- 구성 프롬프트(`PLAN_PROMPT`): 직무 구조를 보여 주고 앱 코드를 고치는 역할은 `duty` 에 직무 id 를 적게 한다 (조사·문서·마케팅은 비움).
- 채팅 프롬프트(`TRIAGE_PROMPT`): 직무 구조 · "새로 만들기 전에 기존 담당자 재사용" 규칙 · [팀원 현황]에 `부서 · 담당` 표시. `new_roles[*].duty` 도 받는다.

## 5. 안 쓰는 팀원 보관 (archived)

오류·업무마다 만든 일회성 팀원이 끝난 뒤에도 목록에 쌓이지 않게 한다. **삭제하지 않고** `plan.roles[*]` 에 보관 표시만 한다. `chat.jsonl` · `sessions.jsonl` · `wrapup.json` · 업무 현황 카드(기록)는 그대로다.

**저장 필드** (`plan.roles[*]`, 보관된 팀원에게만 있다. 없으면 보관 아님)

| 필드 | 형식 | 설명 |
|---|---|---|
| `archived` | `true` | 보관됨 |
| `archived_at` | 숫자(초, epoch) | 보관한 시각 |
| `archived_reason` | 문자열 | 화면에 보여 줄 한 줄 이유 (`끝났고 이어서 맡을 일이 없는 일회성 팀원`) |
| `origin` | `"added"` (선택) | 처음 구성이 아니라 나중에 만든 팀원 (`add_role` 이 적는다) |

**보관 기준** `archive_candidates` — 아래를 모두 만족하는 팀원만:
1. 일회성: 상시 직무 담당자가 아니고(id 가 직무 id 이거나 저장된 `duty` 가 없음, 팀장 아님), 나중에 만든 팀원 — `origin == "added"` · id 가 `next_` 로 시작 · (예전 데이터) 채팅에 `새 팀원 … 합류했어요` 기록이 있는 이름.
2. 상태가 `accepted`(통과)이고 `note_pending` 이 없다 → 진행 중·대기 중·다시 작업 중인 팀원은 건드리지 않는다.
3. 아직 안 끝난 다른 팀원이 `depends_on` 으로 기대고 있지 않다.

처음 팀 구성의 팀원(조사·마케팅·개발·검증 등)과 상시 팀원(`backend_server` · `frontend_mac` · `frontend_win` …)은 보관하지 않는다.

**엔진 함수 / CLI**
- `bt.archive_roles(job_id, role_ids=None, dry_run=False)` → `[{id, name, icon, reason}]` (보관한 사람, 채팅 전체방에 `🗂️ 안 쓰는 팀원 N명을 보관했어요 …` 한 줄) · CLI `buni_team.py archive-roles <작업id> [<팀원id>…] [--dry-run]` → `{"archived": [...]}`
- `bt.unarchive_role(job_id, role_id)` · CLI `unarchive-role <작업id> <팀원id>`. 보관된 팀원에게 `send_role_note` / DM / 채팅 지시를 보내면 자동으로 풀린다.
- `bt.is_archived(role)`, `bt.is_one_off(role)`, `bt.archive_candidates(job)`.

**화면이 읽을 것 (맥·Windows 동일)**
- 사이드바·단체방 팀원 목록: `bt.team_structure(job, include_archived=False)` — 기본은 보관된 사람을 뺀다(단, 보관됐어도 다시 일하는 중이면 보인다). `include_archived=True` 면 모두. 멤버 항목에 `archived`(bool) · `archived_reason`(문자열)이 더해졌다. CLI: `buni_team.py duties <작업id> [--with-archived]` → `{"catalog", "team", "archived_count"}`. 맥은 `plan.roles[*].archived == true` 로 같은 규칙을 적용한다.
- **'보관된 팀원 보기'** 토글(문구 고정): 목록 맨 아래에 `보관된 팀원 보기 (N)` / 켜면 `보관된 팀원 숨기기`. N = `archived_count`. 보관된 팀원은 흐리게, 옆에 `보관됨`, 눌렀을 때 `archived_reason`.
- 업무 현황: 카드(`board_cards`)에 `assignee_archived`(bool)가 있다. 카드는 목록에 그대로 있고 **담당자 필터 항목만** `bt.board_assignees(cards, show_archived=False)` → `[{id, name, icon, archived}]` 로 만든다. 같은 토글을 켜면 `show_archived=True`.
- 팀장 [팀원 현황] 프롬프트에서도 보관된 팀원은 빠진다. 이름·id 로 지목하면 `resolve_role` 이 그대로 찾아 주고, 지시가 가면 보관이 풀린다.

## 6. 한계

- 분류는 키워드 점수라 애매한 글은 분류 없음으로 빠진다 — 그때는 팀장의 선택/예전 방식이 그대로 쓰인다.
- 이미 일하는 팀원의 직무를 바꾸지 않으므로, 모두 바쁘면 새 팀원이 생긴다.

## 7. 변경 전·후 화면 캡처 (화면 업무 완료 시 자동)

화면·디자인을 바꾸는 팀원 업무는 엔진이 알아서 전·후 캡처를 시도한다 (`JobRunner._run_role` → `auto_capture`).

- **어떤 업무?** `bt.is_screen_task(role)` — 이름·임무·산출물에 디자인·화면·레이아웃·UI·프론트엔드 같은 낱말이 있고 `kind` 가 `readonly` 가 아닌 업무. 설정 `auto_capture`(기본 켜짐)를 끄면 안 찍는다. 가짜 claude 시험(`BUNI_CLAUDE`) 중에는 `BUNI_CAPTURE_TEST=1` 이 없으면 실제 화면을 찍지 않는다.
- **언제?** 시작할 때 첫 시도에서만 `before`(다시 하기 때는 처음 것을 덮어쓰지 않음), 끝날 때마다(다시 하기 포함) `after`. 화면 이름은 역할 id.
- **무엇을?** 팀원이 `.buni-team/<slug>/<역할id>/screens/<id>.before|after.png` 에 직접 찍어 둔 PNG 가 있으면 그것을 가져오고(팀원 프롬프트에 안내), 없으면 `grab_screen`(맥 `screencapture -x`, Windows Pillow `ImageGrab`)으로 전체 화면을 찍는다.
- **못 찍으면?** 캡처 실패가 업무를 막지 않는다. `captures.json` 에 이유가 남고, 채팅에 `캡처 아님 — <이유>` 한 줄이 오르며, `job_screens` 항목은 `captured=false` · `reason` 이다. 맥 `SquadBoardViews.swift`·Windows `buni_team_ui.py` 가 같은 `캡처 아님 — 이유` 로 그린다.
- **권한·Pillow 안내** (설정 화면 '변경 전·후 화면 캡처'에도 같은 문장): 화면·디자인 업무의 변경 전·후 화면은 자동으로 찍어요. 맥은 시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 화면 기록(화면 및 시스템 오디오 녹음)에서 부니를 허용해야 하고, Windows 는 Pillow 가 있어야 해요 (pip install Pillow). 못 찍으면 '캡처 아님 — 이유'로 보여요.
- **이유 문구** (엔진 상수 `CAPTURE_WHY_*`, 맥·Windows 화면이 그대로 보여 준다): 맥 권한 문제 → `캡처 도구가 실패했어요 (화면 기록 권한을 확인해 주세요)`, Windows Pillow 없음 → `Pillow(PIL)가 없어 화면을 찍지 못했어요`. 실패하면 이미 있던 전·후 파일은 그대로 남는다.
- 수동 호출: `buni_team.py capture <작업id> <이름> before|after [--from-file PNG] [--region x,y,w,h]`.
