# 작업 브랜치 커밋 정리 (`main..HEAD`)

> 기준: 브랜치 `buni/job-6001`, `git log main..HEAD` — 커밋 37개 (2026-10-31 확인). 커밋 메시지가 `buni: <담당> — 부니` 로 같아서, **각 커밋이 건드린 파일**로 주제를 나눴다. 이 문서 자체는 목록이며 커밋·브랜치를 바꾸지 않는다.

## 브랜치 이름 안내

사전요구서의 이름은 `pro-payment-prep` 이고 지금은 `buni/job-6001` 이다 (2026-10-31 점검: `pro-payment-prep` 이름의 브랜치는 아직 없고, 작업 폴더 `…/Buni/team/worktrees/job-6001` 이 `buni/job-6001` 을 쓰는 중이며 내 폴더는 `main`).

### 점검 결과: 지금 바꾸면 엔진 참조가 끊긴다 → **프로젝트가 끝난 뒤에만 바꾼다**

엔진(`windows/buni_team.py`)은 브랜치 이름을 `job.json` 의 `branch` 필드에 적어 두고 그 이름으로 다시 찾는다. git 의 이름만 바꾸고 `job.json` 은 그대로면 다음이 일어난다.

| 엔진 동작 | 위치 | 이름이 바뀌면 |
|---|---|---|
| 작업 공간 준비 | `prepare_workspace` (1720~1744줄) | `git branch --list buni/job-6001` 이 비어 "없는 브랜치"로 보고 같은 이름의 **새 브랜치**를 만들어 버린다 (이어서 하던 커밋과 갈라짐) |
| 결과 폴더 꺼내기 | `result_dir` (2207~2217줄) | 브랜치가 없다고 보고 결과 worktree 를 만들지 않는다 |
| 내 폴더에 반영·변경 보기 | `unmerged_info` (3290~3308줄), `apply_result`, `changes_diff` | `None` 을 돌려줘 "합쳐진 것 없음"처럼 보이고, 자동 반영(`apply_mode=auto`)이 조용히 건너뛴다. `applied_tip` 기준도 못 쓴다 |
| 화면 표시 | 맥 `TeamViews.swift`, Windows `buni_team_ui.py` | 옛 이름을 그대로 보여 준다 |

- 이 작업이 진행 중이거나 후속 업무(자동 진행·피드백으로 다시 열기)가 남아 있으면 위 문제가 바로 난다. 따라서 **지금은 이름을 바꾸라고 안내하지 않는다.** 코드는 바꾸지 않았다(이름 변경 기능은 이번 범위 밖).
- 이 점검에서 `git branch -m` 을 실제로 실행해 보지는 않았다(저장소 상태를 바꾸므로). 엔진 코드를 읽어서 판단했다.

### 프로젝트가 끝난 뒤 바꾸는 순서 (사용자가 직접)

1. 스쿼드 작업이 모두 끝났고 내 폴더에 반영도 끝났는지 확인한다(진행 중·대기 중 업무 없음).
2. 작업 폴더(worktree)에서 **옛 이름까지 적어서** 실행한다. 이름을 하나만 적는 `git branch -m pro-payment-prep` 은 *지금 있는 브랜치*를 바꾸므로, 내 폴더(`main`)에서 실행하면 `main` 이 바뀌어 버린다.

```bash
git branch -m buni/job-6001 pro-payment-prep
```

3. 그 프로젝트를 스쿼드에서 다시 열 일이 없으면 `job.json` 은 그대로 둔다. 다시 열 일이 있으면 앱을 끈 뒤 `Buni/team/jobs/<작업 id>/job.json` 의 `"branch"` 값도 `pro-payment-prep` 으로 고친다.

- 이름만 바뀌고 커밋은 그대로다. 바꾸지 않아도 결과물에는 영향이 없다.
- push·태그는 하지 않았고 이 문서도 하지 않는다.

## 주제별 목록

### 0. 시작점 (전체에 걸침)
| 커밋 | 내용 |
|---|---|
| `b21f621` | 작업 시작 시점의 내 폴더 — 이미 있던 커밋 안 한 변경(Pro·스쿼드·맥/Windows 소스·문서·시험)을 한 번에 담은 스냅샷. 주제를 나눌 수 없어 따로 둔다 (가정 B) |

### 1. Pro 문서·마케팅
| 커밋 | 내용 |
|---|---|
| `13c3a47` | 한·영 마케팅 초안 `docs/marketing/copy-ko.md`, `copy-en.md` |
| `de8ab6e` | `docs/monetization/REPORT.md`, `market-research.md`, `tools/README.md` 정비 |
| `318f4db` | 옛 마케팅 글(`intro.md`, `launch-posts.md`)의 Pro 혜택 문구 정리 |

### 2. 디자인 시스템
| 커밋 | 내용 |
|---|---|
| `9be345b` | 정의 `docs/design-system.md`, 토큰 `BuniTheme.swift`·`buni_theme.py`, Pro 창·스쿼드 화면·사이트 적용, `test_design_tokens.py` |
| `3b396d5` | 남은 흰색 반투명 면을 디자인 토큰으로 (맥 화면 4곳) |
| `c8a77a3` | 토큰 미적용 화면 확장 (`ChatViews`, `ShortcutSettingsView`, `UsageBarView`, `buni.py`) + 시험 |
| `a377c41` | 화면 실기 확인 체크리스트 `UI-CHECKLIST.md` |

### 3. 스쿼드 기능 (맥 + Windows)
| 커밋 | 내용 |
|---|---|
| `69d3d09` | 업무 현황 보드 화면 (`SquadBoardViews.swift`) |
| `2783add` | 다음에 할 일 자동 진행·같은 프로젝트 이어서 진행 |
| `e09be8a` | 자동 진행 보완 (`TeamStore`, 엔진, UI) |
| `10c0fb9` | 업무 현황 보드·목록·필터 |
| `3287bf3` | 프로젝트 우클릭 메뉴(이름 수정·프로젝트 설정·삭제) |
| `0cbe8f8` | 카드 제목 요약, 채팅 입력 초안 보관 |
| `36ba8cd` | 스쿼드 중 부니 캐릭터 하나만 (`buni.py` 훅) |
| `b055e9d` | 보류 업무 승인·거절·의견 남기기 |
| `7757811` | 결과 자동 반영(`apply_mode` 기본 auto) |
| `b411039` | 업무 현황 검색·정렬 판정 보강 (`SquadBoardViews.swift`, `buni_team.py`) |

### 4. 시험
| 커밋 | 내용 |
|---|---|
| `180a5a2` | `test_board_parity.py` (멈추기 전까지 진행분) |
| `563fbdb` | `test_board_swift_rules.py` — 맥 판정과 Python 판정 비교 |
| `c048b6a` | `test_fake_claude_flow.py` — 가짜 claude 로 `--model`·자동 진행 |
| (3번 커밋에 함께) | `test_followup`, `test_board`, `test_board_ui`, `test_project_menu`, `test_card_summary_drafts`, `test_single_buni`, `test_step_decision`, `test_auto_apply` |

### 5. 검증·문서 담당 (점검 기록)
`VERIFICATION.md`·`REPORT.md` 갱신, 비교용 화면 `design-before-after/index.html` 만 건드린 커밋들.

`89b279b`, `b8da148`, `53a8a81`, `1a35727`, `0bb0921`, `ac4d5d2`, `ebbab20`, `74faa0c`, `895d1b2`, `de49ff9`
(`ac4d5d2` 는 `test_parity_drafts_cards.py` 도 추가, `0bb0921` 은 `buni_team_ui.py` 한 줄 보정)

### 6. 팀 시스템 마커 (내용 변경 없음)
`7e02e8c`, `3840a8c`, `1eb3367`, `18fe5f3` — `buni: 부니 완료` (보고서만 갱신, 프로젝트 파일 변경 없음)

## 분류 한계
- 자동 생성된 같은 제목의 커밋이 많아 파일 경로로만 판단했다. 한 커밋이 두 주제에 걸치면(예: 스쿼드 기능 + 시험) 더 큰 쪽에 넣고 시험은 4번에 따로 적었다.
- 커밋 순서·내용은 건드리지 않았다. 되돌릴 때는 위 해시를 `git show <해시> --stat` 으로 먼저 확인한다.
