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
