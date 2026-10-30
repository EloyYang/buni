# 채널별 런칭 글 (게시 직전 원고)

공통: 링크는 `{SITE_URL}`·GitHub(https://github.com/EloyYang/buni). 후기·수치 없음. 게시 전 결제 링크가 열렸는지 확인하고, 안 열렸으면 "Pro는 준비 중" 문장으로 바꾼다. 상태는 모두 **미게시** — `posting-log.md` 참고.

---
## 1. GeekNews (news.hada.io) — Show GeekNews
**제목:** Show GeekNews: 부니 – Claude Code 상태를 화면 구석 픽셀 토끼로 보여주는 앱 (macOS/Windows)

**본문:**
Claude Code를 돌려두고 다른 일을 하다 보면 "지금 생각 중인지, 권한을 기다리는지, 끝났는지"를 보려고 터미널로 돌아오게 되더라고요. 그래서 세션마다 작은 픽셀 토끼 패널을 화면 구석에 띄우는 앱을 만들었습니다.

- 훅(UserPromptSubmit/PreToolUse/PostToolUse/Stop/Notification)이 `/tmp`의 JSONL 파일에 이벤트를 쓰고, 앱이 폴링해서 상태를 바꿉니다. 서버 없음.
- 권한 요청이 오면 말풍선에서 허용·전체 허용·거부
- 토큰 사용량 게이지, 세션별 다른 캐릭터(6종), 코인 상점, 덮개 닫아도 계속 실행, 방 코드 채팅(최대 10명), SSH Remote 지원
- macOS(Swift)·Windows(Python/Tkinter), 앱에는 분석·원격 수집이 없습니다.

기존 기능은 계속 무료이고, Pro(월 $3 / 연 $24 / 평생 $49)는 스쿼드 고급 기능(업무 예약·병렬), 프로 캐릭터·테마, 클라우드 동기화를 엽니다. 라이선스는 오프라인 서명(Ed25519) 키라 서버 확인이 없습니다. 피드백 환영합니다.
{SITE_URL} · https://github.com/EloyYang/buni

---
## 2. Reddit
규칙(자기홍보 비율, 플레어)은 게시 전 각 서브레딧에서 직접 확인. 후보: r/ClaudeAI, r/SideProject, r/macapps (금요일 등 자기홍보 허용일 확인).

**제목:** I made a pixel-art rabbit that shows what Claude Code is doing (macOS + Windows)

**본문:**
I kept alt-tabbing to the terminal just to check whether Claude Code was still thinking, waiting for a permission, or done. So I built Buni: a small rabbit panel per session in the corner of your screen.

- Thinking / tool use / permission request / done each have their own gesture and speech bubble
- Allow / Allow all / Deny right from the bubble
- Token usage gauge, 6 characters, a coin shop, keep-running-with-lid-closed, chat rooms by code (up to 10), SSH remote support
- Hooks write events to a local JSONL file and the app polls it — no server. No analytics inside the app.

Everything above is free. I'm adding a Pro tier ($3/mo, $24/yr, $49 lifetime) for advanced squad features (scheduled/parallel jobs), extra characters/themes and cloud sync; license keys are verified offline. Honest feedback on pricing and what's missing would help a lot.
{SITE_URL} · https://github.com/EloyYang/buni

---
## 3. Product Hunt
- **Name:** Buni
- **Tagline (≤60자):** A pixel rabbit that shows what Claude Code is doing
- **Description (≤260자):** Buni sits in the corner of your screen and shows each Claude Code session's state — thinking, using a tool, asking permission, done. Allow/deny from the bubble, track token usage, customize with a coin shop. macOS & Windows. Core is free; Pro is optional.
- **First comment:** Hi, I'm the maker. I built Buni because I kept checking the terminal to see if Claude Code had finished. It's a small always-on-top rabbit per session, fed by Claude Code hooks writing to a local file — no server, and no analytics in the app. The current features stay free; Pro ($3/mo · $24/yr · $49 lifetime) adds scheduled/parallel squad jobs, extra characters & themes and cloud sync. What would make this useful for your workflow?
- **Topics:** Developer Tools, Artificial Intelligence, Productivity
- **Gallery:** `video-image-scripts.md`의 이미지 1~4

---
## 4. X / Threads
**한국어 (X, 280자 내):**
Claude Code 돌려두고 딴짓하다 터미널 확인하러 돌아오는 거 지겨워서 만들었어요 🐰
부니 — 생각 중·권한 요청·완료를 화면 구석 픽셀 토끼가 알려줘요. macOS/Windows, 기본 기능 무료.
{SITE_URL}

**English (X):**
I got tired of alt-tabbing to check if Claude Code was done, so I made Buni 🐰 — a pixel rabbit in the corner of your screen that shows thinking / permission request / done. macOS + Windows, core features free.
{SITE_URL}

**Threads (스레드형, 3개):**
1) 위와 같은 첫 글 + 영상 1
2) 권한 요청 말풍선에서 바로 허용·거부하는 모습 (영상 2) — "터미널로 안 돌아가도 돼요"
3) "Pro는 월 $3 / 연 $24 / 평생 $49, 기존 기능은 그대로 무료예요. 앱엔 분석이 없어요."

---
## 5. 국내 개발자 커뮤니티
규칙 확인 후 허용되는 곳만: 디스콰이엇(disquiet.io), OKKY, 커뮤니티 "Claude Code 한국 사용자" 계열(공개 여부 확인), velog/Tistory 개인 블로그.

**제목:** Claude Code 상태를 화면 구석 토끼가 알려주는 앱 "부니"를 만들었어요

**본문:**
Claude Code를 켜놓고 다른 작업을 하다 보면 계속 터미널을 확인하게 돼서, 상태를 보여주는 작은 앱을 만들었어요.
- 생각 중 / 도구 사용 / 권한 요청 / 완료를 토끼 몸짓과 말풍선으로 표시
- 권한 요청은 말풍선에서 허용·전체 허용·거부
- 토큰 사용량 게이지, 캐릭터 6종, 코인 상점, 덮개 닫아도 계속 실행, 채팅(방 코드·최대 10명), SSH Remote
- macOS · Windows, 앱 안에는 분석이 없어요

기존 기능은 계속 무료고, Pro(스쿼드 예약·병렬, 프로 캐릭터·테마, 클라우드 동기화)는 월 $3 / 연 $24 / 평생 $49 예정이에요. 가격이나 빠진 기능에 대한 솔직한 의견 부탁드려요!
{SITE_URL} · https://github.com/EloyYang/buni

(블로그용 확장: 훅 → JSONL → 폴링 구조 설명, 오프라인 서명 라이선스(Ed25519) 설계 이야기를 덧붙이면 개발자 독자에게 유효)
