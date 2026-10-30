# Buni 프로젝트

Claude Code 동반자 앱 — 픽셀아트 토끼 마스코트.
Claude Code 세션마다 화면 한쪽에 캐릭터 패널을 띄워 현재 상태(생각 중, 도구 사용, 완료 등)를 표시한다.

## 아키텍처

```
Buni/
├── Sources/ClaudeCompanion/   # macOS Swift 앱
│   ├── AppDelegate.swift       # 세션 스캐너, 프로세스 감지, 단축키
│   ├── CompanionController.swift  # 상태 머신 (idle/thinking/toolUse/completed 등)
│   ├── EventMonitor.swift      # JSONL 이벤트 파일 폴링
│   ├── SessionWindow.swift     # NSPanel 래퍼 (슬롯·드래그·표시)
│   ├── *CharacterView.swift    # 캐릭터별 픽셀아트 그림
│   ├── Chat{Client,Store,Views}.swift  # 채팅방 (Realtime Database, 방 코드·최대 10명)
│   ├── ProLicense.swift        # Pro 라이선스 키 Ed25519 검증 (공개키 한 곳)
│   ├── ProManager.swift        # 체험·구독 상태, 잠금 게이트, 팩 가격, Stripe 링크
│   ├── ProViews.swift          # 업그레이드 창·첫 실행 안내·설정 Pro 구역·ProGate
│   ├── ChatBubbleView.swift    # 상태 말풍선
│   ├── UpdateChecker.swift · SelfUpdater.swift  # 새 버전 확인 · 앱 안에서 내려받아 설치·재시작
│   ├── TeamStore.swift · TeamViews.swift  # 부니 스쿼드(에이전트 모드 · 업무 예약) 화면 — 엔진은 buni_team.py 를 상주 프로세스로 띄워 쓴다
│   └── ...
├── windows/
│   ├── buni.py                # Windows Tkinter 앱 (세션 창·트레이·상점 창)
│   ├── buni_shop.py           # 상점 로직 (코인·레벨·카탈로그·캐릭터별 착용)
│   ├── buni_items.py          # 아이템·무기·작업 도구 그리기 (Painter)
│   ├── buni_cloud.py          # Google 로그인 + Firestore 동기화 (선택 기능)
│   ├── buni_awake.py          # 덮개 닫아도 계속 실행 (powercfg)
│   ├── buni_chat.py           # 채팅방 (Realtime Database, 방 코드·최대 10명)
│   ├── buni_update.py         # 새 버전 확인 · 앱 안에서 내려받아 설치·재시작 (설치형/포터블)
│   ├── buni_license.py        # Pro 라이선스 키 검증 (순수 파이썬 Ed25519, 공개키 한 곳)
│   ├── buni_pro.py            # 체험(TRIAL_DAYS_*)·구독 판정, 잠금 `can()`, 팩 카탈로그·할인, Stripe 링크
│   ├── buni_pro_ui.py         # 업그레이드 창·온보딩·설정 Pro 구역
│   ├── buni_team.py           # 스쿼드 엔진 (맥·Windows 공용): 사전요구서 → 팀 구성 → 병렬 업무 → 검토 → 통합, 예약 시간대·한도 대기
│   └── buni_team_ui.py        # Windows 부니 스쿼드 창 (Tk)
├── tools/issue_license.py     # 라이선스 키 쌍 생성·발급·확인 (판매자 PC 전용, 사용법 tools/README.md)
├── tests/                     # 라이선스·Pro 시험, 맥·Windows 공용 벡터 (시험 전용 키)
├── docs/
│   ├── index.html · privacy.html · site-config.js  # 사이트 (결제 링크·Plausible 도메인은 site-config.js)
│   ├── monetization/          # market-research.md, license-spec.md, REPORT.md
│   └── marketing/             # 소개문·런칭 글·일정·광고 계획·posting-log.md
├── build_app.sh               # macOS 빌드 스크립트
├── release.sh                 # GitHub 릴리스 스크립트 (./release.sh <버전>)
├── install.sh                 # Claude Code 훅 설치
└── VERSION                    # 현재 버전 (예: 1.3.4)
```

## 부니 스쿼드 (에이전트 모드 · 업무 예약)

- 엔진 `windows/buni_team.py` 하나를 맥·Windows가 같이 쓴다. 맥 앱은 번들에 복사해 `python3 buni_team.py daemon` 으로 띄우고(`build_app.sh` 가 복사), Windows 앱은 모듈로 불러 쓴다.
- 상태는 `job.json`(앱 데이터 폴더 `Buni/team/jobs/<id>/`)으로 주고받는다. 화면은 이 파일을 읽고, 동작은 엔진 CLI/함수를 부른다.
- 사람이 없을 때는 `claude -p --permission-mode dontAsk` + 허용 목록만 쓴다. 이때 훅이 승인 창을 60초씩 기다리지 않도록 `dontAsk`/`BUNI_TEAM_RUN` 을 훅에서 건너뛴다 (훅 v5).
- 질문·요구서 단계에서도 `add_request`(CLI `interview-add`)로 요청을 추가하면 팀장이 질문을 다시 정리한다(추가마다 질문 3라운드를 새로 센다). 어느 단계에서든 `cancel` 로 프로젝트를 취소할 수 있고, 질문 정리 중이면 Claude 도 바로 끝낸다.
- 모든 Claude 호출은 `--output-format stream-json --verbose --session-id <uuid>` 로 돌린다. 세션은 `🐰 제목 · 역할` 이름으로 Claude 기록(`~/.claude/projects`)에 남고, 엔진이 `jobs/<id>/sessions.jsonl`(세션 목록)과 `activity-<역할>.json`(최근 활동)을 적어 화면이 진행을 보여 준다. "Claude에서 열기"는 `open_session_in_terminal` 이 `claude --resume` 을 터미널로 띄운다.
- 끝나면 팀장이 `wrap_up` 으로 `wrapup.json`(지금 확인할 것 `review_items` · 다음 작업 `next_steps`)을 만든다. 화면은 id 만 넘기고 `open_review_item`(파일·폴더·주소 열기, 명령은 눈에 보이는 터미널 창에서 실행 — 위험한 명령은 `unsafe_command` 로 막음)·`start_followup`(새 프로젝트를 만들지 않고 이 프로젝트에 새 팀원 업무로 이어 붙여 같은 브랜치 위에서 진행)을 부른다. 결과 파일은 `result_dir` 가 별도 worktree 로 꺼내 둔다. 보고서는 마크다운으로 그린다(맥 `MarkdownView`, Windows `render_markdown`).
- 끝난 작업의 결과 화면은 `report_view.md`(보고서 + 항목별 버튼 줄 `[라벨](buni://동작/대상)` + 항목 아래 채팅 입력창 `buni://feedbackbox/<id>` + 끝의 "다음에 할 일")를 마크다운으로 그린다. 입력창에 쓴 의견은 `review_feedback` 이 팀장에게 전해 해당 팀원에게 수정 지시를 내리게 하고 작업을 다시 연다. 작업을 열면 `ensure_wrapup` 이 보고서의 "검토하는 방법"에서 바로 누를 항목을 먼저 만들고(`quick_wrapup`) 팀장 정리를 한 번 돌린다.
- 스쿼드 채팅방: 엔진이 팀장의 지시·팀원의 보고·검토·내 지시를 `jobs/<id>/chat.jsonl` 에 덧붙이고(`chat_add`), 화면의 "💬 스쿼드 채팅" 탭이 시간순으로 보여 준다. 내가 팀원을 지목하면 `send_role_note` 로 바로 지시, 팀장(전체)에게 하면 `chat_send` 가 팀장 Claude 를 불러 답하고 필요한 팀원에게 나눠 지시한다(`chat_typing` 으로 답하는 중 표시). 스쿼드 세션이 끝나면 부니 완료 말풍선에 "스쿼드 결과 보기" 버튼이 뜬다(`TeamStore.jobId(forSession:)` / `find_job_for_session` 이 sessions.jsonl 로 작업을 찾는다).
- 팀원에게 요구사항 보내기: `send_role_note`(CLI `role-note`) — 시작 전이면 시작할 때, 일하는 중이면 끝나는 대로, 끝난 팀원이면 다시 열어 반영한다(기대던 팀원도 재확인, 끝난 작업이면 다시 연다).
- 업무 현황: 사이드바 맨 위 `📊 업무 현황`(맥 `SquadBoardViews.swift`, Windows `buni_team_ui.py` `_show_board`)이 모든 프로젝트의 업무를 `대기/진행 중/검토/완료/확인 필요` 칼럼 보드·목록으로 보여 준다. 판정은 엔진 `board_cards`/`board_filter`/`board_summary`(맥 `SquadBoard` 가 같은 규칙) — 팀원 업무(이어서 진행한 업무·끝난 지난 업무 포함)와 시작 전 '다음에 할 일'이 카드이고, 자동 진행됨/확인 필요/상한으로 멈춤을 표시한다. 검색·상태·담당자·`진행 중만/끝난 것만/전체` 필터, 카드를 누르면 같은 프로젝트의 DM·결과·스쿼드 채팅·Claude 열기로 이어지는 상세.
- 화면은 슬랙식이다 — 왼쪽 사이드바에 프로젝트 → (현황·보고서 / `# 스쿼드` 단체방 / 다이렉트 메시지: 팀장·팀원)이 펼쳐진다(맥 `TeamRootView` + `SquadSlackViews.swift`, Windows `buni_team_ui.py` 의 `_draw_room`). 단체방은 지시·보고·검토를 `squadSummary`/`_summary` 로 한두 줄만 보이고 `상세 보기 ›` 로 그 팀원 DM 에 넘긴다. DM 은 팀원과 오간 전문 + 그 팀원의 실시간 진행·세션 열기·그 팀원에게만 가는 입력창. 입력창은 여러 줄(Enter 보내기·Shift+Enter 줄바꿈), 단체방에서 `@이름 …` 은 그 팀원에게만. 안 읽은 메시지 수는 `마지막으로 본 시각`보다 늦은 것만 센다.
- 팀원 세션마다 부니가 생기지 않는다: 훅(v6)은 `BUNI_TEAM_RUN` 세션이면 이벤트를 안 적고 바로 끝낸다. 대신 엔진이 `claude-companion-events-squad-<작업id>.jsonl` 에 이벤트를 직접 적어(`squad_run_begin/end/maybe_done`) 팀장 부니 하나가 일하는 모습(`squad:` 도구 문구)과 끝났을 때 완료 말풍선을 보여 준다. 세션 id `squad-<작업id>` 는 sessions.jsonl 에 key `squad` 로 남아 '스쿼드 결과 보기' 버튼이 작업을 찾는다.
- 결과가 내 폴더에 합쳐지지 않았으면(별도 worktree·브랜치) 보고서 맨 위에 경고와 `결과를 내 폴더에 반영하기`(`apply_result`, `unmerged_info`)가 뜬다 — 내 폴더의 커밋 안 한 변경과 겹치면 거부하고 아무것도 바꾸지 않는다.
- 채팅 지시가 실제 일로 이어지게: `chat_send` 는 팀장 답의 `assignments` 를 `_dispatch_assignments` 로 실제 전달한다 — 역할 이름·id 는 `resolve_role` 로 맞추고, 팀원이 없으면 `new_roles` → `add_role` 로 만든다. 전달된 게 없으면 한 번 바로잡아 다시 묻고, 그래도 안 되면 답에 ⚠️ 를 붙여 솔직히 알린다(전달했을 때만 "📨 실제로 전달했어요").
- 내 폴더에 커밋 안 한 변경이 있으면 스쿼드는 그 '지금 모습'을 `_snapshot_commit` 으로 찍어(`job.snapshot`) 그 위 worktree 에서 일한다. 끝나면 설정 `apply_mode`(smart·auto)에 따라 `apply_result` 가 변경분만 내 폴더에 반영한다(커밋 안 함, 겹치면 거부하고 알림). 반영한 뒤 바뀐 것만 다시 반영하려고 `applied_tip` 을 기억한다.
- 사전요구서 관리: 채팅 지시를 팀장이 `requirements.add`(새 방향) / `requirements.change`(기존 문장 `was` → `now`)로 나눠 준다. 새 방향은 `requirements_add` 가 요구서의 "추가 방향" 절에 바로 덧붙이고, 기존 내용과 다른 것은 `add_req_proposal` 이 `req_proposals` 에 보류해 둔다 — 화면 위쪽 카드에서 내가 승인(`resolve_req_proposal`, CLI `req-resolve`)해야 요구서를 고치고 보류했던 `assignments` 를 전달하고, 거절하면 기존 그대로다. 사이드바의 `📝 사전요구서` 에서 지금 적용 중인 내용을 본다.
- 반영 방식은 설정 `apply_mode`: `smart`(**기본** — `classify_changes` 가 '중요한 변경'이 아니라고 보면 끝나는 대로 바로 반영, 중요하면 이유와 함께 승인 대기) · `auto`(전부 바로) · `confirm`(전부 승인 후) · `manual`(브랜치로만, `git merge` 안내). 중요한 변경의 기준은 설정 `smart_*`(결제·가격·라이선스 / 비밀값·키·설정 / 빌드·설치·릴리스·훅·버전 / 파일 삭제 / 큰 변경(`smart_big_files`·`smart_big_lines`) / 직접 정한 경로 `smart_custom`) — 맥·Windows 스쿼드 설정에서 켜고 끈다. 어느 쪽도 커밋은 안 하고 겹치면 거부한다. 못 들어온 이유는 `apply_state` 의 `note`(겹침)·`reasons`(중요한 변경)로 보드 배너에 그대로 보이고, `dismiss_apply` 로 닫을 수 있다. 끝나 있던 결과 중 중요하지 않은 것은 `Scheduler._retro_apply` 가 5분마다 한 번씩 이어서 반영한다.
- 모델: 설정 `model`(팀원 기본)·`lead_model`(팀장·질문 정리, 비면 기본)과 팀원별 `role.model`(`set_role_model`, CLI `role-model`, 맥·Windows 의 팀원 DM 위쪽 메뉴). `ClaudeRunner.run(model=…)` 이 우선순위(팀원별 → 팀장/기본)를 정한다. 목록은 `MODEL_CHOICES`(맥 `squadModelChoices` 와 같게).
- 메뉴바 없는(accessory) 앱이라 `installEditMenu` 로 보이지 않는 편집 메뉴를 달아야 ⌘C·⌘V 가 먹는다.
- 다음에 할 일 자동 진행: `wrap_up` 이 `next_steps` 마다 팀장에게서 `direction_change`(사업 방향이 바뀌는지, 애매하면 true)를 받아 적고, 직후 `auto_followups` 가 false 인 항목만 `start_followup(auto=True)` 로 같은 프로젝트 안에서 자동으로 이어서 진행한다(job 을 새로 만들지 않고 `role_id` 팀원으로 붙임 · 끝난 작업이면 다시 열고 진행 중이면 대기열 · 같은 chat/sessions/wrapup · 채팅에 한 줄). 옛 `job_id`(따로 만든 후속 job)·`parent_id` 는 그대로 읽는다. 가격·Pro 정책, 외부 게시·발송, push·릴리스 같은 방향 변경 항목은 사용자가 누를 때까지 대기한다. 연속 자동 단계는 `AUTO_FOLLOWUP_MAX`(3)까지, 한 번에 `AUTO_FOLLOWUP_PER_WRAPUP`(2)개까지이며 닿으면 멈추고 알린다. 설정 `auto_followup`(기본 켜짐, 맥·Windows 설정 화면에 같은 문구). 결과 화면 항목에는 `next_step_status` 가 자동 진행됨 / 진행 중 / 확인 필요(방향 변경) / 상한으로 멈춤을 보여 준다.
- 화면: 끝난 작업에도 보고서는 없다 — 프로젝트의 첫 화면은 업무 보드(`SquadProjectBoard` / Windows `_draw_project_board`: 대기·진행 중·검토 중·완료 칼럼, 팀원 = 업무 카드, 진행 중 카드는 실시간 한 줄, 완료 카드는 한 줄 결과·완료 시각)다. `SquadBoardViews.swift` 의 '현황' 은 모든 프로젝트를 한 번에 보는 별도 화면이다. 끝난 뒤 `_finish_message` 가 다음 할 일 정리(`wrap_up` → 자동 이어가기)를 조용히 돌리고, 이어 붙은 업무가 없을 때만 완료 요약을 채팅에 남긴다.
- 방식은 작업마다 보드 위쪽에서 바꾼다: 반영(`apply_mode`: auto 기본 · confirm · manual)과 진행(`run_mode`: auto 기본 · manual — 업무마다 ▶ 시작, `start_role`, 남은 업무가 모두 대기면 `HoldForUser` 로 `paused/waiting_start`). 빈 값 = 설정을 따른다(`set_job_modes`, CLI `job-modes`).
- 팀원 권한은 `READ_BASH`(읽기) + `CHECK_BASH`(시험·빌드) + `CODE_BASH`(코드 역할만: mkdir·cp·mv·python3 …). 복합 명령은 조각마다 허용돼야 하고 `cd … && 쓰기`·`>` 리다이렉트는 거절되므로 `TOOL_TIPS` 를 모든 세션에 덧붙여 알려 준다. 후속 작업은 내 폴더의 지금 모습 위에서 시작하고 앞 작업의 아직 반영 안 된 결과는 `_carry_parent_result` 로 이어받는다.
- 업무 보드는 **내가 지시한 업무(task)** 단위다 — 처음 계획의 팀원 미션, 채팅 지시 하나(`chat_send` → 담당 팀원 여럿), DM 메모 하나(`send_role_note`), 이어 붙은 다음 업무가 각각 `job.tasks` 의 업무 하나. 팀원들이 각자 끝내면 `_sync_tasks`(`save_job` 마다 실행)가 업무를 완료로 바꾸고(`part_status`·`done_at`), 이미 완료된 업무는 팀원이 다른 지시로 다시 일해도 다시 열리지 않는다. 우선순위(`urgent·high·normal·low`, `set_task_priority`, 팀장이 `priority` 로도 정함)는 `role_priority` 로 팀원 실행 순서를 정한다. `add_role(managed=True)` 로 만든 팀원은 업무를 따로 만든다(자동 업무 없음).
- 자동 진행: 설정 `schedule_mode`(window 시간대 안에서만 · anytime 언제든 · off 내가 시작할 때만), 한도 처리 `limit_action`(stop 기본 — 멈추고 `user_paused`, wait — 풀리면 이어서), 전체 일시정지 `paused`. 작업별 ⏸ 멈추기/▶ 이어서는 `pause_job`/`resume_job`(멈춘 작업은 시간대가 와도 `Scheduler` 가 시작하지 않는다). 자동·스마트 모드에서는 업무 하나가 끝날 때마다 `_apply_ready_tasks` 가 그 변경을 바로 내 폴더에 반영하고(중요한 변경·겹침이면 보류하고 알림) 다음 업무를 이어 간다.
- 사이드바: 진행 중인 프로젝트·팀원은 초록, 확인이 필요한 것(반영 승인·사전요구서 변경·시작 대기·한도로 멈춤, `TeamStore.needsAttention` / Windows `_attention_text`)은 주황으로 행 전체를 물들이고 업무 보드 행에 이유를 적는다.
- **시험·개발 중에는 `/tmp/claude-companion-events-*` 에 쓰지 말 것**: 설치된 부니가 그 파일마다 캐릭터를 새로 만든다. `BUNI_TEAM_HOME` 이 있으면 `squad_events_path` 가 그 폴더 안에 쓴다. 실제 `claude -p` 로 확인할 때는 `BUNI_TEAM_RUN=1` 을 줘 훅이 건너뛰게 하고, 지울 때는 `find /tmp/ …`(끝에 `/`) — 맥의 `/tmp` 는 심볼릭 링크라 `find /tmp` 는 안에 못 들어간다.
- 덮개 닫아도 실행의 "세션 실행 중에만" 모드(`enableUntilSessionsFinish` / `enable_until_sessions_finish`)는 부니 세션·스쿼드 작업이 모두 끝나고 1분 뒤 자동 해제한다(켠 뒤 10분간 세션이 안 시작되면 포기).
- 시험: 가짜 `claude`(스크립트)로 엔진 전체를 돌릴 수 있다 — `BUNI_CLAUDE=<경로>`, `BUNI_TEAM_HOME=<임시폴더>`.

## 이벤트 시스템

Claude Code 훅(`~/.claude/settings.json`)이 `/tmp/claude-companion-events-{session_id}.jsonl`에 이벤트를 기록하면 `EventMonitor`가 폴링해 상태를 갱신한다.

| 이벤트 타입 | 발생 시점 |
|---|---|
| `thinking` | UserPromptSubmit 훅 |
| `tool_use` | PreToolUse 훅 |
| `tool_done` | PostToolUse 훅 |
| `done` | Stop 훅 |
| `notification` | Notification 훅 |
| `permission_request` | 권한 요청 다이얼로그 |
| `usage` | 컨텍스트 사용량 갱신 |

## 에이전트 구성

| 에이전트 | 담당 |
|---|---|
| `ios` | `Sources/ClaudeCompanion/` Swift 소스 전담 |
| `windows` | `windows/` Python 소스 전담 |
| `관리자` | 루트 파일(빌드 스크립트, VERSION, README 등) 및 릴리스 조율 |

## 릴리스 방법

```bash
./release.sh 1.3.5   # 빌드 → ZIP → git 태그 → GitHub Release 생성
```

macOS 설치만 할 때: `./build_app.sh --install`

## Pro / 라이선스

- 기존 기능은 무료. Pro(월 $3 / 연 $24 / 평생 $49)는 프로 캐릭터·컬러 변형, 클라우드 동기화를 연다. 개별 팩은 Pro 30% 할인. (스쿼드 예약·병렬 잠금은 아직 연결 전 — 스쿼드 엔진은 `ProGate` 를 부르지 않는다.)
- 서버 없는 오프라인 Ed25519 서명 키(`BUNI-…`). 형식은 `docs/monetization/license-spec.md`. 공개키는 비어 있어 사용자가 `tools/README.md` 순서로 생성해 넣어야 한다.
- 체험 일수·할인율 상수: `windows/buni_pro.py`와 `ProManager.swift`(맥·Windows 값을 같이 고친다). 결제 링크는 환경변수 `BUNI_STRIPE_LINK_*` 또는 `pro-config.json`, 없으면 "준비 중".
- 시험: `python3 -m unittest discover -s tests -p "test_*.py"`. 자세한 내용은 `docs/monetization/REPORT.md`.
- 스쿼드 열기 단축키: 맥 ⌃⌥S / Windows Ctrl+Alt+S (설정 단축키 목록에 있음). 부니 스쿼드 창을 열고, 앞에 떠 있으면 닫는다(`TeamWindowController.toggle` / `_hk_squad`).

## 현재 버전

1.9.1
