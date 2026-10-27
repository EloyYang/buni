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
│   ├── ChatBubbleView.swift    # 상태 말풍선
│   ├── UpdateChecker.swift · SelfUpdater.swift  # 새 버전 확인 · 앱 안에서 내려받아 설치·재시작
│   └── ...
├── windows/
│   ├── buni.py                # Windows Tkinter 앱 (세션 창·트레이·상점 창)
│   ├── buni_shop.py           # 상점 로직 (코인·레벨·카탈로그·캐릭터별 착용)
│   ├── buni_items.py          # 아이템·무기·작업 도구 그리기 (Painter)
│   ├── buni_cloud.py          # Google 로그인 + Firestore 동기화 (선택 기능)
│   ├── buni_awake.py          # 덮개 닫아도 계속 실행 (powercfg)
│   ├── buni_chat.py           # 채팅방 (Realtime Database, 방 코드·최대 10명)
│   └── buni_update.py         # 새 버전 확인 · 앱 안에서 내려받아 설치·재시작 (설치형/포터블)
├── build_app.sh               # macOS 빌드 스크립트
├── release.sh                 # GitHub 릴리스 스크립트 (./release.sh <버전>)
├── install.sh                 # Claude Code 훅 설치
└── VERSION                    # 현재 버전 (예: 1.3.4)
```

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

## 현재 버전

1.9.1
