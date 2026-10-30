# 소개문 / Product copy

> 사실만 쓴다. 후기·사용자 수·별점·"인기" 같은 수치는 아직 없으므로 쓰지 않는다.
> 가격: Pro 월 $3 / 연 $24 / 평생 $49, 신규 14일·기존 30일 체험. 결제 링크가 열리기 전에는 "출시 예정"으로 쓴다.
> 사이트: {SITE_URL} (현재 사이트 주소로 교체 — 이 저장소에서 확인되지 않아 자리표시) · GitHub: https://github.com/EloyYang/buni

## 한 줄
Claude Code가 지금 뭘 하는지, 화면 구석의 픽셀 토끼가 알려줘요.
*A pixel-art rabbit in the corner of your screen that shows what Claude Code is doing.*

## 한국어 (짧게, ~100자)
부니는 Claude Code 세션 상태(생각 중 · 도구 사용 · 권한 요청 · 완료)를 화면 구석의 픽셀 토끼로 보여주는 macOS·Windows 앱이에요. 터미널을 계속 보지 않아도 돼요.

## 한국어 (보통, ~400자)
Claude Code가 일하는 동안 터미널을 계속 들여다보고 계신가요? 부니는 세션마다 화면 한쪽에 작은 토끼 패널을 띄워, 생각 중인지·권한이 필요한지·끝났는지를 몸짓과 말풍선으로 알려줘요.
- 권한 요청이 오면 말풍선에서 바로 허용 · 전체 허용 · 거부
- 토큰 사용량과 남은 시간을 게이지로 확인
- 세션마다 다른 캐릭터(6종), 작업이 끝나면 쌓이는 코인으로 꾸미는 상점
- 노트북 덮개를 닫아도 계속 실행, 방 코드 채팅(최대 10명), SSH Remote 지원
세션 패널·상태 표시·채팅 같은 기존 기능은 계속 무료예요. Pro(월 $3 / 연 $24 / 평생 $49)는 스쿼드 고급 기능(업무 예약·병렬), 프로 캐릭터·테마, 클라우드 동기화를 열어줘요. 앱에는 분석·원격 수집이 없어요.

## English (short)
Buni is a macOS and Windows app that shows your Claude Code session state — thinking, using a tool, asking permission, done — as a pixel rabbit in the corner of your screen. No more staring at the terminal.

## English (medium)
Do you keep watching the terminal while Claude Code works? Buni puts a small rabbit panel on your screen for each session and shows whether it's thinking, needs permission, or is finished — with gestures and speech bubbles.
- Allow / Allow all / Deny straight from the permission bubble
- Token usage and time-left gauge
- A different rabbit per session (6 characters), plus a shop where coins earned from finished tasks buy outfits
- Keep running with the lid closed, chat rooms by code (up to 10 people), SSH remote support
Everything that exists today — session panels, status display, chat — stays free. Pro ($3/mo, $24/yr, $49 lifetime) unlocks advanced squad features (scheduled and parallel jobs), Pro characters & themes and cloud sync. The app has no analytics or remote collection.

## 사실 점검 (과장 방지)
| 문구 | 근거 |
|---|---|
| 캐릭터 6종 | docs/index.html 기능 카드 |
| 채팅 최대 10명 | CLAUDE.md, 방침 문서 |
| 앱 분석 없음 | 사전요구서 §4, 방침 7항 |
| Pro 잠금 3종 | `windows/buni_pro.py`, `ProManager.swift` |
| 체험 14/30일 | `TRIAL_DAYS_NEW/EXISTING` |
| 스쿼드 창 단축키(Windows 기본 Ctrl+Alt+S, 한 번 더 누르면 닫기) | `windows/buni.py`, `windows/buni_squad.py`. 맥에는 없음 — 글에 쓸 땐 "Windows" 명시 |
| 스쿼드 공용 채팅은 요약 한 줄, 팀원 개인 채팅은 원문 전문 · Enter 전송 / Shift+Enter 줄바꿈 | `windows/buni_squad.py`. 이 브랜치엔 스쿼드 엔진이 없어 GUI 동작은 직접 확인 전 — 홍보 글에서 강조하지 않음 |
| 쓰지 않는 것 | 사용자 수, 후기, 별점, "가장 빠른/유일한" 같은 비교 표현 |
