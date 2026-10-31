# 작동 점검 기록 (부니 1.9.1)

사용자가 직접 확인할 필요 없는 시험·빌드·일치 점검의 상세 기록이다. 결정이 필요한 항목은 `REPORT.md` 에 있다. (이전 `REPORT.md` 에서 옮김)

## 한 일 (요약)

- 조사: `market-research.md` (비교 앱 7개, 가격 $3 / $24 / $49 유지)
- 라이선스: Ed25519 키, 맥·Windows 같은 형식 (`license-spec.md`), 발급 `tools/issue_license.py` (`tools/README.md`)
- Pro 잠금: 컬러 변형 6종, 클라우드 동기화(체험 종료 시 데이터 보존·동기화만 정지), 체험 기존 30일·신규 14일
- UI: 업그레이드 창, 첫 실행 안내, 설정 Pro 구역, 잠금 안내 (맥 `ProViews.swift`, Windows `buni_pro_ui.py`)
- 스쿼드: 단축키 맥 ⌃⌥S = Windows Ctrl+Alt+S, 스쿼드 채팅 요약/팀원 원문 분리, Enter 전송·Shift+Enter 줄바꿈
- 사이트: 가격표, 한/영 전환, 결제 버튼("준비 중" 기본), Plausible 자리
- 마케팅 초안: `docs/marketing/` (`copy-ko.md`·`copy-en.md` 등, "초안 · 미게시")
- `tools/README.md` 맨 위에 "판매 시작까지 순서" 표, `market-research.md` 에 가격 유지 사유 추가

## 상수·가격 일치

맥 `ProManager.swift` ↔ Windows `buni_pro.py` 상수 일치. 사이트 `docs/index.html` 가격(팩 $3.49·$3.99 → Pro $2.44·$2.79)과 앱 값 일치. 변경된 가격·상수 없음.

## 확인 결과 (2026-10-29)

| 확인 | 결과 |
|---|---|
| `python3 -m unittest discover -s tests -p "test_*.py"` | 30개 실행, 전부 OK (앞선 실행은 35개였고 줄어든 이유는 추적하지 못함) |
| `python3 -m py_compile windows/*.py` (파일별) | 오류 없음 |
| `swift build` | Build complete (경고만) |
| 비밀값 검색 (`sk_live`, `sk_test`, `whsec_`, `BEGIN PRIVATE`) | 없음 |
| `git status` | 작업 시작 시 깨끗함 |

## 업그레이드 흐름 점검 (코드 읽기)

체험(trial) → 만료(expired) → 키 입력 → `activate(key)` → 구독(subscribed) → `can()` 잠금 해제가 맥 `ProManager`/`ProViews` 와 Windows `buni_pro`/`buni_pro_ui` 에서 같은 순서로 이어져 있다. 공개키가 비면 `no_pubkey` 로 거절(앱은 안 죽음), 결제 링크가 없으면 "준비 중" 비활성 버튼.

## 못 돌린 것

- Swift 공유 라이선스 벡터 실행: `swiftc` 거절. Python 은 같은 벡터 통과. 맥에서 `tests/swift_vector_check.swift` 상단 명령으로 실행 가능.
- GUI·브라우저 실기 확인(맥 단축키, Windows RegisterHotKey, 줄바꿈 입력, 한글 입력 중 Enter).
- Windows 스쿼드 입력 저장: `buni.py` `_squad_send` 가 정의되지 않아 엔진 병합 때 연결 필요. 스쿼드 예약·병렬 잠금은 엔진이 없어 Windows 미연결.
- 브랜치 이름 `pro-payment-prep`: 팀 시스템이 `buni/job-6001` 에 커밋함(이름만 다름).
- 웹 조사·가격 조정: 근거 없음. 디자인 시스템(추가 방향)은 착수하지 못함.

## 최종 실행 결과 (2026-10-30, qa_docs — 이번에는 직접 돌림)

| 확인 | 결과 |
|---|---|
| `python3 -m unittest discover -s tests -p "test_*.py"` | 59개 실행, OK (1개 건너뜀 = Tk 화면 시험 `test_board_ui.py`, `BUNI_UI_TEST=1` 일 때만 돎) |
| `python3 -m py_compile windows/*.py` | 12개 파일 각각 오류 없음 (셸 반복문이 막혀 파일명을 나열해 실행) |
| `swift build` | Build complete |
| 상수 | 체험 기존 30일·신규 14일·팩 할인 30% 가 `buni_pro.py` 와 `ProManager.swift` 에서 같음 |

### 사이드바 우클릭 메뉴·프로젝트별 모델 (맥 ↔ Windows 코드 비교)

| 항목 | 결과 |
|---|---|
| 메뉴 | `이름 수정 / 프로젝트 설정 / 삭제` 순서·문구 같음 (맥 `TeamViews.swift` `.contextMenu`, Windows `_project_menu`) |
| 이름 수정 | 빈 이름 거부 문구 `이름을 비워 둘 수 없어요` 같음. 엔진 `rename_job` 이 최종 거부 |
| 삭제 | 진행 중이면 `진행 중인 프로젝트예요 / 먼저 취소한 뒤 삭제해 주세요.` 로 거부, 아니면 확인 문구 `'제목' 프로젝트를 삭제할까요? / 이 작업 기록을 지워요. (git 브랜치와 결과 파일은 남아요)` — 같음 |
| 모델 목록 | 맥 `squadModelChoices` = 엔진 `MODEL_CHOICES` (기본·Fable 5.1·Opus 5.5·Sonnet 5.5·Haiku 5.5) 같음 |
| 우선순위 | 팀원별 `role.model` → 프로젝트 `job.model`/`lead_model` → 전역. 판정은 엔진 `resolve_model` 하나를 양쪽이 공유 |
| 설정 창 문구 | `팀원 기본 / 팀장 / 전역 설정과 같게 / 비워 두면 …` 같음. **차이 하나를 고침**: Windows 영어 라벨 `Lead` → `Team lead` (맥과 맞춤) |
| 시험 | `tests/test_project_menu.py` 8개가 이름 수정·빈 이름·삭제·진행 중 거부·취소 후 삭제·우선순위·설정 저장·CLI 를 실제 엔진 호출로 확인. 맥 Swift 쪽 시험은 없음(코드 읽기만) |
| 못 한 것 | 맥 NSAlert/컨텍스트 메뉴, Windows Tk 팝업을 화면에 띄워 확인하지 못함. 가짜 `claude` 로 `--model` 인자가 실제로 붙는지는 확인하지 못함 |

## 후속 작업 "같은 프로젝트 안에서" 점검 (2026-10-29, qa_docs)

**직접 돌리지 못했다**: 이 세션은 Bash 가 거부돼 `unittest`·`py_compile`·`swift build` 를 실행하지 못했다. 아래는 코드 읽기 결과이고, 시험·빌드 통과 수치는 dev 가 적은 값(40개 통과, py_compile 통과, Build complete)을 옮긴 것이며 내가 확인한 것이 아니다.

| 점검 | 결과 (코드 읽기) |
|---|---|
| 엔진 `start_followup` | 새 job 을 만들지 않고 `add_role` 로 같은 job 에 팀원(`next_<id>`)을 붙임. 끝난 작업이면 `queued` 로 다시 열고, 진행 중이면 대기열. 같은 chat/sessions/wrapup 사용 |
| 시험 | `tests/test_followup.py` 가 `list_jobs()` 개수가 변하지 않음을 두 곳에서 확인 (`test_direction_unchanged_…`, `test_next_step_runs_inside_same_job`) |
| 맥 | `TeamStore.startFollowup` 이 CLI `followup` 만 부르고 `focusJobId` 를 건드리지 않음 (다른 프로젝트로 점프 안 함) |
| Windows | `_start_followup` 이 `buni_team.start_followup` 만 부르고 `self.sel` 을 바꾸지 않음 |
| 문구 | 버튼 `▶ 이 프로젝트에서 이어서 진행` 은 엔진이 `report_view.md` 에 적으므로 맥·Windows 가 같은 화면을 그림. 자동 진행 설정 문구도 양쪽 설정 화면이 같음(dev 기록) |
| 차이 | 맥 현황 보드(`SquadBoardViews.swift`)는 있으나 Windows 는 `board_column` 이 없어 동일성 미달. 새 요구사항 전달(`send_role_note`, `chat_send`)은 원래 같은 job 안에서 동작 |

실행해서 확인할 것: `python3 -m unittest discover -s tests -p "test_*.py"`, `python3 -m py_compile windows/*.py`, `swift build`.

## 업무 현황 화면 점검 (2026-10-30, qa_docs)

**직접 돌리지 못했다**: 이 세션도 Bash 가 거부돼(don't ask 모드) `unittest`·`py_compile`·`swift build` 를 실행하지 못했다. 아래는 코드·시험 파일 읽기 결과이며 통과 여부는 **미확인**이다. 위 "확인 결과 (2026-10-29)" 수치는 이전 실행분이고 현황 화면 변경 뒤 다시 돌린 것이 아니다.

| 점검 | 결과 (코드 읽기) |
|---|---|
| 맥·Windows 문구 | 칼럼 `대기/진행 중/검토/완료/확인 필요`, 범위 `전체/진행 중만/끝난 것만`, 자동 진행 표시 `자동 진행됨/확인 필요/상한으로 멈춤`(영어 `Auto-started/Needs your OK/Stopped at limit`)이 `SquadBoardViews.swift` 와 `buni_team.py`(`BOARD_*_NAMES`)에서 같음. 앞 기록의 `준비/막힘` 은 더는 쓰이지 않음 |
| 동작 | Windows `_show_board`(`buni_team_ui.py`)는 엔진 `board_cards/board_filter/board_summary/board_detail` 을 쓰고 맥 `SquadBoard` 는 같은 규칙. 앞 절의 "Windows 는 `board_column` 이 없어 동일성 미달" 은 해소됨(`buni_team.py:1861`). 실제 화면 모양은 양쪽 모두 눈으로 못 봄 |
| 시험 덮임 | `tests/test_board.py`: 칼럼 규칙, 이어서 진행한 업무·끝난 업무 카드, 막힘, 다음에 할 일(`confirm/limit/cap`, 이미 진행 중인 항목은 중복 안 됨), 요약, 검색(제목·담당자·내용·여러 낱말·없는 말), 상태·담당자·범위 필터, 정렬, 상세, 카드 조회가 job 을 늘리지 않음. `tests/test_board_ui.py`: 그리기·이동 |
| 빠진 시험 | 읽기로는 요구 범위가 덮여 있어 시험 파일은 고치지 않음. 맥 `SquadBoard` 는 Swift 시험이 없음(규칙 일치는 읽기로만 확인) |
| 문서 | `CLAUDE.md` 스쿼드 절에 업무 현황 설명이 이미 있음 |

## 카드 짧은 제목 · 채팅 초안 보관 점검 (2026-10-30, qa_docs — 직접 돌림)

| 확인 | 결과 |
|---|---|
| `python3 -m unittest discover -s tests -p "test_*.py"` | 73개 실행, OK (1개 건너뜀 = Tk 화면 시험 `test_board_ui.py`, `BUNI_UI_TEST=1` 일 때만 돎) |
| `python3 -m py_compile` (windows/*.py 14개 파일) | 오류 없음 |
| `swift build` | Build complete |

### 맥 ↔ Windows 코드 비교

| 항목 | 결과 |
|---|---|
| 카드 제목 | 길이 36(`SquadBoard.titleMax` = `BOARD_TITLE_MAX`), 첫 줄만·공백 하나로·넘으면 `…` 포함 36자 — 규칙 같음. 보드 카드·목록 줄은 짧은 제목만 그리고(맥 `SquadCard`/`SquadListRow`, Windows `_show_board` 의 `c['short_title']`), 카드를 눌러 연 상세에서 전체 제목·설명을 보여 줌(맥 `SquadItemDetail`, Windows `board_detail`) |
| 초안 열쇠 | `<작업id>\|<방>` 같음. 방 이름 `channel` · `lead` · `dm:<역할id>` · `note:<역할id>` · `fb:<항목id>` 양쪽 동일. 저장 파일 `drafts.json` 동일 |
| 복원 | 맥 `TeamDrafts`(메모리 + 파일): `TeamViews.swift` 가 방마다 `.id(job.id + 방)` 를 붙여 입력창을 새로 만들고 `restore()` 가 열쇠별 글을 되살림. Windows `_composer` 는 다시 그릴 때 `_drafts` → `_saved`(`drafts.json`) 순으로 채움 |
| 비우기 | 보낸 뒤에만: 맥 `send()` 가 `text = ""` → 공백뿐이면 항목 삭제, Windows `send()` 가 `delete` 후 `sync()` → `save_draft('')` 로 삭제. 다른 방 초안은 유지 |
| 차이 | 발견하지 못함 (코드 읽기 기준) |

### 시험이 실제로 검증하는지

- `tests/test_card_summary_drafts.py` (dev): 짧은 제목·긴 제목 말줄임·첫 줄/공백, 카드는 짧은 제목 + 상세는 전체, 초안 저장→재읽기→보낸 뒤 삭제(다른 방 유지), 깨진 파일 무시. 실제 엔진 함수를 호출해 검증하므로 빈 시험이 아님.
- `tests/test_parity_drafts_cards.py` (qa_docs, 새로 추가 8개): 맥·Windows 소스를 읽어 제목 길이 상수·방 이름·열쇠 형식·파일명·비우는 조건이 같은지, 카드 화면은 `jobTitle` 을 안 그리고 상세는 그리는지 확인 + 36자 경계, 프로젝트·팀원별 초안 분리, 공백뿐인 글 미보관.
- 못 한 것: 맥 SwiftUI 입력창·Windows Tk 입력창을 화면에 띄워 방을 옮겨 보는 실기 확인, Swift 단위 시험(없음). 위 비교는 소스 읽기와 문자열 시험이다.

## 새 부니가 계속 생기는 오류 수정 점검 (2026-10-30, qa_docs — 직접 돌림)

| 확인 | 결과 |
|---|---|
| `python3 -m unittest discover -s tests -p "test_*.py"` | 80개 실행, OK (1개 건너뜀 = Tk 화면 시험). `ResourceWarning`(닫지 않은 파일)만 나옴, 실패 없음 |
| `python3 -m py_compile` (windows/*.py 13개 파일) | 오류 없음 |
| `swift build` | Build complete |
| 시험 뒤 `git status` | 깨끗함 |

### (1) 원인 재현 경로와 맥 ↔ Windows 비교
- Windows: 기본 설치의 exe 내장 훅 `buni.py` `_run_hook` 은 고치기 전에 `BUNI_TEAM_RUN` 을 승인 게이트 건너뛰기(`skip_gate`)에만 쓰고 이벤트는 그대로 적었다 → 스쿼드가 `claude -p` 를 띄울 때마다 `session_id` 별 이벤트 파일이 생겨 새 부니가 떴다. 코드상 실제로 그렇게 되는 경로이며 지금은 `_run_hook` 맨 앞(`buni.py:468`)에서 종료한다.
- 맥 훅(`HookInstaller.swift` v6 스크립트 5개)과 Windows 파이썬 훅(`install_hooks.py` 5곳)은 이미 맨 앞에서 `BUNI_TEAM_RUN` 이면 종료한다 → 세 훅 모두 같은 방식. 맥 Swift 코드는 이번에 바뀌지 않음.
- 엔진: `squad_run_begin` 의 세션 기록 확인이 `_sq_lock` 안에 있어 병렬 팀원도 sessions.jsonl 에 한 줄만 남긴다. 이벤트 파일은 `squad-<작업id>` 하나.

### (2) 새 시험이 실제로 막는지
- `test_windows_exe_hook`: 진짜 `_run_hook` 을 실행해 보통 세션은 기록(대조), 스쿼드 세션은 무기록 확인 → **고치기 전 코드에서는 실패한다**(dev 가 수정을 잠깐 되돌려 확인했다고 기록. 내가 다시 되돌려 보지는 않음). 이 오류의 실제 회귀 시험은 이것 하나다.
- `test_repeated_instructions_keep_one_event_file_and_session`: 가짜 `claude` 로 지시 4번 + 병렬 3번 후 이벤트 파일 1개·squad 세션 1줄·`tool_use` 7건·마지막 `done` 을 확인 — 내용은 충실하다. 다만 이벤트를 쓰는 건 엔진뿐이고 훅은 가짜 `claude` 에서 돌지 않으므로, 훅 버그는 못 잡는다(엔진 측 중복·병렬 경쟁만 막는 시험).
- `test_mac_hook_scripts_have_the_skip`: 한계 — "훅 없이 돌렸을 때 파일이 생긴다"는 대조가 없어, 스크립트가 다른 이유로 일찍 죽어도 통과한다. 맥 훅 시험은 약한 편이며, 소스에 `BUNI_TEAM_RUN` 이 있는지 확인하는 부분이 실질 검증이다. 승인 창 대기 때문에 대조 실행은 넣지 않았다.
- 그 밖에 `test_two_jobs_get_two_buni`·`test_delete_removes_event_file`·`test_every_claude_call_is_marked_as_squad_run` 도 실제 값을 단정한다(빈 시험 아님).

### (3) 문서
`CLAUDE.md` 스쿼드 절의 "훅(v6, Windows 는 파이썬 훅과 exe 내장 훅 `_run_hook` 모두)은 `BUNI_TEAM_RUN` 이면 … 팀장 부니 하나" 설명이 위 코드와 맞다.

못 한 것: 맥·Windows 앱을 띄워 부니 창이 하나인지 눈으로 확인, 이 PC 에 설치된 `~/.claude` 훅 버전 확인(프로젝트 밖). 이미 설치된 옛 Windows exe 는 새 버전으로 바꿔야 고쳐진다.

## 마무리 재실행 + REPORT.md 정리 (2026-10-30, qa_docs — 직접 돌림)

| 확인 | 결과 |
|---|---|
| `python3 -m unittest discover -s tests -p "test_*.py"` | 103개 실행, OK (1개 건너뜀 = Tk 화면 시험). `ResourceWarning` 만 나옴 |
| `python3 -m py_compile` (windows/*.py 15개 파일) | 오류 없음 |
| `swift build` | Build complete |
| 상수 | 체험 기존 30일·신규 14일·팩 할인 30%, 가격 300/2400/4900센트가 `buni_pro.py` 와 `ProManager.swift` 에서 같음 |
| 비밀값 검색 | 저장소에 실제 키 없음 (이 파일의 검색어 나열만 걸림) |
| 시험 뒤 `git status` | 깨끗함 |

`REPORT.md` 는 결정 항목(가격 유지, 반영 승인, 마케팅 게시, 공개키·Stripe, 가정)만 남기고 시험·빌드 수치는 이 파일에만 둔다. 못 돌린 것: 화면 실기 확인, Swift 공유 라이선스 벡터 실행(위 "못 돌린 것").

## 보류 업무 승인·거절·의견 점검 (2026-10-30, qa_docs — 직접 돌림)

| 확인 | 결과 |
|---|---|
| `python3 -m unittest discover -s tests -p "test_*.py"` | 97개 실행, OK (1개 건너뜀 = Tk 화면 시험). 이번에 `test_step_decision.py` 에 2개 추가 |
| `python3 -m py_compile` (windows/*.py 15개 파일, 일부는 나눠서) | 오류 없음 |
| `swift build` | Build complete |

### 맥 ↔ Windows 비교
- 버튼 `✅ 승인 / 🚫 거절 / 💬 의견 남기기`(영어 `Approve / Reject / Leave a comment`), 입력 안내 `의견 · 이유 (의견 남기기에는 꼭 필요해요)` 가 맥 `SquadBoardViews.swift` `decisionBox` 와 Windows `buni_team_ui.py` `_draw_step_decision` 에서 같다. 두 화면 모두 결정은 엔진 `step_decision`(CLI `step-decision`) 하나로 보낸다. 거절 카드 문구 `거절함 / Rejected` 도 같다. 차이 없음(코드 읽기).

### 동작과 시험
| 요구 | 결과 |
|---|---|
| 승인 | `start_followup` 으로 같은 job 에 팀원이 붙고 새 프로젝트는 안 생김, 이력·채팅 기록 — `test_approve_continues_in_same_job_and_keeps_history` |
| 거절 후 자동 진행 안 함 | `rejected`/`auto='rejected'` 로 닫혀 `auto_followups` 가 건너뛰고, 다시 정리(`wrap_up`)해도 거절·이력이 이어짐. 나중에 다시 승인 가능 — `test_reject_closes_and_never_auto_runs_again_then_can_reapprove` |
| 의견이 팀원에게 전달 | 기존 시험은 팀장 프롬프트에 의견이 들어가는지만 봤음(전달까지는 미확인). **보강**: `test_comment_reaches_the_team_member_it_names` 가 팀장 답의 지시가 `dev` 팀원 `notes` 에 붙고 상태가 `revise` 로 바뀌며, 보류 항목은 시작되지 않고 job 이 늘지 않음을 확인 |
| 금지 항목 무승인 시작 금지 | **보강**: `test_unmarked_or_forbidden_steps_wait_for_approval` — 방향 변경 표시(릴리스 push·가격 인상) 또는 표시 없는 항목(기본 `direction_change=True`)은 `confirm` 으로 대기하고 `auto_followups` 를 다시 돌려도 시작되지 않음 |
| 의견 내용 없음 / 잘못된 결정 | `ValueError` — `test_comment_goes_to_lead_and_needs_text`, CLI 시험 |

한계: 항목이 push·게시·가격인지 판단하는 것은 팀장 Claude 가 적는 `direction_change` 에 의존한다(엔진은 문구를 직접 검사하지 않음, 애매하면 true 로 대기). 화면에서 버튼을 눌러 보는 실기 확인은 못 했다.

## 마무리 재실행 + 디자인 전후 비교 (2026-10-31, qa_docs — 직접 돌림)

| 확인 | 결과 |
|---|---|
| `python3 -m unittest discover -s tests -p "test_*.py"` | 121개 실행, OK (1개 건너뜀 = Tk 화면 시험 `BUNI_UI_TEST=1` 일 때만). `ResourceWarning` 만 나옴 |
| `swift build` | Build complete |
| `python3 -m py_compile windows/*.py` | **이번 세션에서는 못 돌림** — 반복문 명령이 거부됐고 단순 명령으로 나눠 다시 돌리지 않았다. 위 시험이 `windows/` 모듈을 모두 import 하므로 문법 오류는 없지만 py_compile 자체의 통과 기록은 앞 절(2026-10-30, 15개 OK)이 마지막이다 |
| 시험 뒤 부산물 | 시험이 `license_vectors.json` 을 쓴다고 출력함 (기존 동작) |

### 디자인 전후 비교
- 파일: `docs/monetization/design-before-after/index.html` (브라우저로 열기). 상단에 **"실제 캡처가 아니라 코드 값 기반 재현"** 표시. 대상: Pro 업그레이드 창, 업무 현황 보드, 스쿼드 화면, docs 사이트 + 토큰 값 요약.
- 바뀌기 전 값은 `git show 9be345b^:<경로>` 와 `git show 9be345b` 의 diff 로 읽었다(worktree 안 만듦). 바뀐 후는 현재 브랜치 파일.
- **실제 캡처는 하나도 없다.** 이 환경에는 화면이 없어 앱·브라우저를 띄우지 못했다. 모형은 색·모서리 값만 맞춘 근사이며 글꼴·정확한 배치는 다르다. 직접 켜서 보는 방법은 같은 HTML 맨 아래에 있다.
- 이 파일은 커밋하지 않고 만들기만 했다(요청대로).

## 최근 업무 재점검 (2026-10-31, qa_docs — 직접 돌림)

배터리 성능(perf_mac·perf_win)·업무보드 가독성·시험 보강 결과를 다시 읽고 점검했다. 목록과 우선순위는 `.buni-team/job-6001/qa_docs/NOTES.md`.

| 확인 | 결과 |
|---|---|
| `python3 -m unittest discover -s tests -p "test_*.py"` | 140개 실행, OK (1개 건너뜀 = Tk 화면 시험). 점검 전 130개 → 배터리 가드 시험 10개 추가 |
| `python3 -m py_compile` | `windows/buni.py`·`buni_team.py`·`buni_team_ui.py`·`buni_pro.py`·`buni_pro_ui.py`·`buni_shop.py` 통과 (나머지 파일은 이번엔 나열하지 않음) |
| `swift build` | Build complete |
| 추가 시험 | `tests/test_battery_guards.py` — 소스에 줄인 주기·멈춤 조건이 남아 있는지 확인(GetMessageW, 타이머 중복 방지, 가려지면 정지 등). 앱을 띄워 재는 시험이 아니다 |

못 한 것: 배터리 실측(전/후 CPU·전력)은 맥·Windows 모두 하지 못했다. perf 보고서의 수치는 코드 읽기 기준 추정이다. Windows 앱은 맥에서 실행할 수 없어 단축키·클릭 투과 동작은 확인하지 못했다.
