# 부니 디자인 시스템

맥 앱(SwiftUI) · Windows 앱(Tk) · 사이트(`docs/index.html`)가 같은 값을 쓴다. **값은 이 문서가 기준**이고, 코드에서는 아래 세 곳에만 적는다.

| 어디 | 파일 |
|---|---|
| 맥 | `Sources/ClaudeCompanion/BuniTheme.swift` (`BuniTheme`) |
| Windows | `windows/buni_theme.py` |
| 사이트 | `docs/index.html` 맨 위 `:root` |

값을 바꾸면 세 곳과 `tests/test_design_tokens.py` 가 서로 같은지 확인한다(시험이 색·간격·모서리 값을 세 파일에서 읽어 비교한다).

## 참고한 원칙 (로고·상표·에셋은 쓰지 않는다)
- **Raycast 쪽**: 어두운 바탕 위에 낮은 대비의 면(bg → panel → field)을 겹쳐 깊이를 만들고, 강조색은 한 가지만 아주 아끼며, 목록·키보드 중심의 촘촘하지만 숨 쉬는 간격을 쓴다.
- **Apple 쪽**: 시스템 서체 계층(제목·본문·보조), 4pt 격자, 둥근 모서리의 일관된 단계, 얕고 부드러운 그림자, 라이트/다크가 같은 의미의 색 이름을 공유한다.
- 부니만의 것: 픽셀아트 토끼의 당근색(carrot)을 유일한 브랜드 강조색으로 쓴다. 캐릭터 그림은 이 시스템의 영향을 받지 않는다.

## 1. 색 (이름 = 의미)
| 토큰 | 다크 | 라이트 | 쓰임 |
|---|---|---|---|
| `bg` | `#1E1E24` | `#F5F5F7` | 창 바탕 |
| `rail` | `#17171D` | `#ECECF0` | 사이드바 |
| `panel` | `#26262E` | `#FFFFFF` | 카드·패널 |
| `field` | `#2A2A34` | `#F0F0F4` | 입력창·칩 |
| `raised` | `#34343F` | `#E4E4EA` | 눌림·선택·호버 |
| `line` | `#3A3A44` | `#D8D8E0` | 1px 구분선·테두리 |
| `ink` | `#F2F2F6` | `#1D1D22` | 제목·본문 |
| `ink2` | `#C4C4CE` | `#4A4A55` | 보조 본문 |
| `dim` | `#8A8A98` | `#6A6A78` | 설명·라벨·placeholder |
| `accent` | `#F28C2E` | `#D9731A` | 브랜드 강조(주 버튼·선택 표시). 위 글자는 `accent_ink` |
| `accent_ink` | `#1A1206` | `#FFFFFF` | accent 위 글자 |
| `info` | `#6AA9FF` | `#2F6FD6` | 링크·정보 |
| `ok` | `#4DC780` | `#1F8F4E` | 성공·진행 중 |
| `warn` | `#D9B25A` | `#A9791A` | 주의·확인 필요 |
| `danger` | `#E65A66` | `#C8323F` | 오류·삭제·막힘 |

규칙: 한 화면에서 `accent` 는 주 행동 하나(또는 선택 표시)에만 쓴다. 의미색(`ok`/`warn`/`danger`/`info`)은 글자·점·테두리에 쓰고 넓은 면을 채우지 않는다(면은 12% 투명도 틴트).

## 2. 다크/라이트
- 같은 토큰 이름이 모드에 따라 다른 값을 가진다. 코드는 색 값을 직접 쓰지 않고 토큰 이름만 쓴다.
- 기본은 **다크**. 맥·Windows 앱 창은 지금까지처럼 다크 고정이고, 라이트 값은 코드에 정의만 해 둔다(`BuniTheme.light` / `buni_theme.LIGHT`, 팔레트를 고르는 함수 `palette(dark=True)`).
- 사이트는 다크 고정(그림 속 목업이 다크 전제). 라이트 대응이 필요하면 같은 이름의 변수만 `@media (prefers-color-scheme: light)` 에서 바꾼다.
- 글자 대비 최소 4.5:1(`ink`/`ink2` 가 `bg`·`panel` 위에서 충족, `dim` 은 보조 문구 전용).

## 3. 타이포
시스템 서체를 쓴다(맥 SF Pro, Windows Segoe UI → 한글 Malgun Gothic). 숫자·코드는 mono. 사이트는 Fredoka(제목)·Manrope(본문)·Press Start 2P(픽셀 라벨)을 그대로 두고 크기 단계만 맞춘다.

| 토큰 | 크기(pt/px) | 굵기 | 쓰임 |
|---|---|---|---|
| `title` | 18 | 700 | 창 제목 |
| `heading` | 13 | 600 | 구역 제목 |
| `body` | 12 | 400 | 본문 |
| `small` | 11 | 400 | 보조 |
| `caption` | 10 | 400 | 주석·힌트 |

Windows 는 9pt 기본(Tk 단위)이라 `FONT_SIZE = {title:14, heading:10, body:9, small:8, caption:8}` 로 환산한다.

## 4. 간격 (4pt 격자)
`xs 4 · sm 8 · md 12 · lg 16 · xl 24 · xxl 32`. 창 안쪽 여백은 `xl`(24), 구역 사이는 `lg`, 줄 사이는 `sm`/`xs`.

## 5. 모서리
`sm 6`(칩·입력창) · `md 10`(카드·버튼) · `lg 14`(큰 패널·말풍선) · `pill 999`. Tk 는 둥근 모서리가 없어 `flat` + 1px `line` 테두리로 대신하고, 값은 사이트·맥에서만 쓴다.

## 6. 그림자·깊이
다크에서는 그림자보다 **면 색 차이**로 깊이를 만든다(bg < panel < raised). 그림자는 떠 있는 것(말풍선·팝업)만.
- `shadow_sm`: y 2 · blur 6 · 검정 25%
- `shadow_md`: y 6 · blur 16 · 검정 35%
- 라이트: 같은 y/blur, 검정 12% / 18%

## 7. 적용 범위
- 맥: `ProViews.swift`(업그레이드 창·첫 실행 안내), `TeamViews.swift`·`SquadSlackViews.swift`·`SquadBoardViews.swift`(스쿼드).
- Windows: `buni_pro_ui.py`, `buni_team_ui.py` (색 상수를 `buni_theme` 에서 가져온다).
- 사이트: `docs/index.html` `:root` 의 변수와 버튼·카드 모서리·그림자.
- 건드리지 않은 것: 캐릭터 그림(`*CharacterView.swift`, `buni_items.py`), 상점·장비 화면, 말풍선 안의 의미색.

---

> 위의 `BuniTheme` 이 코드의 기준이다. 아래는 같은 팔레트를 `BuniTokens`(`BT`)로 정리한 v2 안으로, `BT` 를 쓰는 화면이 남아 있어 함께 둔다.

# 부록 — v2 토큰 (Raycast·Apple 톤, `BuniTokens` / `BT`)

> v2: 어두운 면은 거의 검정에 가까운 중립 회색(Raycast), 글자·회색 단계는 Apple 의 시스템 회색 체계(#F5F5F7 · #8E8E93)를 따랐다. 당근색 강조와 토큰 이름은 그대로.

맥 앱(Swift)·Windows 앱(Python Tk)·사이트(`docs/`)가 **같은 토큰 이름과 같은 값**을 쓴다.
Raycast·Apple 의 *원칙*(여백 리듬, 절제된 대비, 계층적 타이포, 부드러운 모서리·그림자, 다크/라이트 대응)만 참고했고, 로고·상표·에셋·폰트 파일은 가져오지 않았다. 글꼴은 각 OS 시스템 글꼴 이름만 쓴다.

## 1. 원칙
1. **조용한 화면, 선명한 토끼** — 화면은 낮은 채도의 중립색, 색은 부니(당근 주황)와 상태에만 쓴다. 픽셀아트 캐릭터는 이 시스템 밖(원래 팔레트 유지)이고, 토큰은 캐릭터 주변 UI 에만 적용한다.
2. **4 단위 리듬** — 모든 여백·크기는 4 의 배수(미세 간격 2 제외).
3. **면으로 계층, 선은 얇게** — 표면을 한 단계씩 쌓고 1px 테두리를 쓴다. 그림자는 떠 있는 것(팝업·말풍선·모달)에만.
4. **둥글되 픽셀은 각지게** — UI 모서리는 부드럽게, 픽셀아트 캐릭터는 각진 채로.
5. **다크가 기본** — 기존 앱이 다크 전용이라 다크 값은 기존 팔레트를 정리한 것이다. 라이트는 OS 설정(맥 `effectiveAppearance`, Windows 레지스트리 `AppsUseLightTheme`, 사이트 `prefers-color-scheme`)을 따른다.

## 2. 토큰 이름 규칙
`그룹.이름` (점 표기). 플랫폼별로 기계적으로 변환한다.

| 그룹 | 점 표기 | Swift | Python dict 키 | CSS 변수 |
|---|---|---|---|---|
| 색 | `bg.canvas` | `BuniTokens.Color.bgCanvas` | `'bg.canvas'` | `--bg-canvas` |
| 타이포 | `font.size.md` | `BuniTokens.Font.sizeMd` | `'font.size.md'` | `--font-size-md` |
| 간격 | `space.4` | `BuniTokens.Space.s4` | `'space.4'` | `--space-4` |
| 반경 | `radius.md` | `BuniTokens.Radius.md` | `'radius.md'` | `--radius-md` |
| 그림자 | `shadow.2` | `BuniTokens.Shadow.e2` | `'shadow.2'` | `--shadow-2` |

색 토큰은 `bg.*`(바탕) · `surface.*`(카드 등 면) · `border.*` · `text.*` · `accent.*` · 상태(`success`·`warning`·`danger`·`info`) 로 나눈다.

## 3. 색 (hex)

### 3.1 바탕·면·테두리
| 토큰 | 다크 | 라이트 | 용도 |
|---|---|---|---|
| `bg.canvas` | `#121214` | `#F5F5F7` | 창·페이지 바탕 |
| `bg.sidebar` | `#0E0E10` | `#ECECEE` | 사이드바(rail) |
| `surface.1` | `#1A1A1D` | `#FFFFFF` | 카드·패널 |
| `surface.2` | `#232326` | `#F2F2F4` | 입력창·호버 면 |
| `surface.3` | `#2C2C30` | `#E5E5E8` | 눌림·선택 면 |
| `border.subtle` | `#28282C` | `#E2E2E6` | 기본 1px 선 |
| `border.strong` | `#3C3C42` | `#C9C9CF` | 입력창 테두리·강조 구분 |

### 3.2 텍스트
| 토큰 | 다크 | 라이트 | 용도 |
|---|---|---|---|
| `text.primary` | `#F5F5F7` | `#1D1D1F` | 제목·본문 |
| `text.secondary` | `#C7C7CC` | `#515154` | 보조 본문 |
| `text.tertiary` | `#8E8E93` | `#6E6E73` | 메타·플레이스홀더 (바탕 대비 4.5:1 이상) |
| `text.onAccent` | `#1A1206` | `#1A1206` | 당근색 면 위 글자 |

### 3.3 강조·상태
| 토큰 | 다크 | 라이트 | 용도 |
|---|---|---|---|
| `accent.base` | `#F28C2E` | `#F28C2E` | 부니 당근. 주 버튼 면·강조 표시 |
| `accent.hover` | `#FFB066` | `#D97A1F` | 호버·눌림 |
| `accent.text` | `#FFB066` | `#A85500` | 글자·링크로 쓰는 강조 (라이트에서 흰 바탕 4.5:1 확보) |
| `accent.soft` | `#33261A` | `#FDEBD6` | 강조 옅은 배경 (선택 행, 배지) |
| `success` | `#4DC780` | `#1F8A4C` | 진행 중·통과·성공 |
| `warning` | `#E8C34A` | `#9A6B00` | 검토 대기·한도·주의 |
| `danger` | `#E6665A` | `#C93A2E` | 실패·위험·삭제 |
| `info` | `#6AA9FF` | `#2255BB` | 예약됨·정보·링크 |
| `leaf` | `#6BBF59` | `#4E9A3F` | 부니 잎(장식, 상태 의미 없음) |

업무 현황 칼럼 매핑: 대기 `info` · 진행 중 `success` · 검토 `warning` · 완료 `text.tertiary` · 확인 필요 `danger`.
상태 옅은 배경이 필요하면 상태색을 바탕에 다크 16%·라이트 12% 로 섞는다(별도 토큰 없음).

## 4. 타이포
글꼴 스택(시스템 글꼴만):

| 토큰 | 맥 | Windows | 사이트 CSS |
|---|---|---|---|
| `font.family.body` | SF Pro (`.system`) | `Malgun Gothic` | `-apple-system, 'Segoe UI', 'Malgun Gothic', system-ui, sans-serif` |
| `font.family.display` | SF Pro Rounded (`.rounded`) | `Malgun Gothic` | `ui-rounded, 'SF Pro Rounded', system-ui, sans-serif` |
| `font.family.mono` | SF Mono (`.monospaced`) | `Consolas` | `ui-monospace, 'SF Mono', Consolas, monospace` |

크기 스케일 (px 은 맥 pt·사이트 px, Tk 는 `tk pt` 열):

| 토큰 | px | tk pt | 굵기 | 행간 | 용도 |
|---|---|---|---|---|---|
| `font.size.xs` | 11 | 8 | 500 | 1.4 | 캡션·배지 |
| `font.size.sm` | 12 | 9 | 400 | 1.5 | 보조 설명·메타 |
| `font.size.md` | 13 | 10 | 400 | 1.5 | 본문(앱 기본) |
| `font.size.lg` | 15 | 11 | 600 | 1.4 | 항목 제목 |
| `font.size.xl` | 18 | 13 | 600 | 1.3 | 창·섹션 제목 |
| `font.size.2xl` | 24 | 17 | 700 | 1.25 | 화면 제목 |
| `font.size.3xl` | 32 | — | 700 | 1.2 | 사이트 소제목 |
| `font.size.4xl` | 48 | — | 700 | 1.1 | 사이트 히어로 |

굵기: `font.weight.regular` 400 · `medium` 500 · `semibold` 600 · `bold` 700 (Tk 는 normal/bold 두 단계라 600 이상 = bold). 글자 간격은 기본, `2xl` 이상 제목만 -1%.

## 5. 간격
`space.N` 의 N 은 단계 번호.

| 토큰 | px | 쓰임 |
|---|---|---|
| `space.1` | 2 | 아이콘-글자 미세 |
| `space.2` | 4 | 배지 안쪽 |
| `space.3` | 8 | 관련 요소 사이 |
| `space.4` | 12 | 컨트롤 안쪽 좌우 |
| `space.5` | 16 | 카드 안쪽·기본 간격 |
| `space.6` | 20 | 섹션 안 블록 사이 |
| `space.7` | 24 | 카드 사이·창 가장자리 |
| `space.8` | 32 | 섹션 사이(앱) |
| `space.9` | 48 | 사이트 블록 사이 |
| `space.10` | 64 | 사이트 섹션 (모바일) |
| `space.11` | 96 | 사이트 섹션 (데스크톱) |

## 6. 모서리 반경
| 토큰 | px | 쓰임 |
|---|---|---|
| `radius.none` | 0 | 픽셀아트·캐릭터 영역 |
| `radius.sm` | 4 | 배지·작은 칩 |
| `radius.md` | 8 | 버튼·입력창 |
| `radius.lg` | 12 | 카드·말풍선 |
| `radius.xl` | 16 | 모달·큰 패널 |
| `radius.pill` | 999 | 알약 버튼·카운트 |

## 7. 그림자 (elevation)
| 토큰 | 다크 | 라이트 | 쓰임 |
|---|---|---|---|
| `shadow.0` | 없음 | 없음 | 평평한 면 |
| `shadow.1` | `0 1px 2px rgba(0,0,0,.40)` | `0 1px 2px rgba(28,27,31,.08)` | 카드 호버 |
| `shadow.2` | `0 4px 12px rgba(0,0,0,.45)` | `0 4px 12px rgba(28,27,31,.12)` | 말풍선·메뉴 |
| `shadow.3` | `0 12px 32px rgba(0,0,0,.55)` | `0 12px 32px rgba(28,27,31,.18)` | 모달·창 |

Swift 는 `radius/x/y/opacity` 로 옮기고, Tk 는 그림자를 못 그리므로 `border.strong` 1px 선으로 대신한다. 다크에서는 `surface` 단계 차이 + `border.subtle` 이 계층의 주역이다.

## 8. 움직임
`motion.fast` 120ms · `motion.base` 200ms · `motion.slow` 320ms, 이징 ease-out. 사이트는 `prefers-reduced-motion` 에서 끈다.

## 9. 플랫폼 매핑 예시

### Swift (`Sources/ClaudeCompanion/BuniTokens.swift`)
```swift
import SwiftUI
import AppKit

enum BuniTokens {
    enum Color {
        static let bgCanvas     = dynamic(dark: 0x14161A, light: 0xFAF8F5)
        static let surface1     = dynamic(dark: 0x1B1E25, light: 0xFFFFFF)
        static let borderSubtle = dynamic(dark: 0x2C313B, light: 0xE6E1D9)
        static let textPrimary  = dynamic(dark: 0xEEF1F6, light: 0x1C1B1F)
        static let accentBase   = dynamic(dark: 0xF28C2E, light: 0xF28C2E)
        static let success      = dynamic(dark: 0x4DC780, light: 0x1F8A4C)
        // …3장의 모든 토큰을 같은 방식으로
        static func dynamic(dark: UInt32, light: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { ap in
                let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)   // hex → sRGB 변환 헬퍼
            })
        }
    }
    enum Space  { static let s1: CGFloat = 2, s2: CGFloat = 4, s3: CGFloat = 8, s4: CGFloat = 12, s5: CGFloat = 16 }
    enum Radius { static let sm: CGFloat = 4, md: CGFloat = 8, lg: CGFloat = 12, xl: CGFloat = 16 }
}
```

### Python (`windows/buni_tokens.py`)
```python
TOKENS = {
    'dark': {
        'bg.canvas': '#14161A', 'bg.sidebar': '#101216',
        'surface.1': '#1B1E25', 'surface.2': '#23272F', 'surface.3': '#2C313B',
        'border.subtle': '#2C313B', 'border.strong': '#3A3F4A',
        'text.primary': '#EEF1F6', 'text.secondary': '#B4BBC9', 'text.tertiary': '#8B93A6',
        'text.onAccent': '#1A1206',
        'accent.base': '#F28C2E', 'accent.hover': '#FFB066', 'accent.text': '#FFB066',
        'accent.soft': '#3A2A18', 'success': '#4DC780', 'warning': '#E8C34A',
        'danger': '#E6665A', 'info': '#6AA9FF', 'leaf': '#6BBF59',
    },
    'light': {
        'bg.canvas': '#FAF8F5', 'bg.sidebar': '#F2EFEA',
        'surface.1': '#FFFFFF', 'surface.2': '#F4F1EC', 'surface.3': '#E9E5DE',
        'border.subtle': '#E6E1D9', 'border.strong': '#CFC8BD',
        'text.primary': '#1C1B1F', 'text.secondary': '#4F4B55', 'text.tertiary': '#6B6773',
        'text.onAccent': '#1A1206',
        'accent.base': '#F28C2E', 'accent.hover': '#D97A1F', 'accent.text': '#A85500',
        'accent.soft': '#FDEBD6', 'success': '#1F8A4C', 'warning': '#9A6B00',
        'danger': '#C93A2E', 'info': '#2255BB', 'leaf': '#4E9A3F',
    },
}
SPACE = {1: 2, 2: 4, 3: 8, 4: 12, 5: 16, 6: 20, 7: 24, 8: 32}
RADIUS = {'sm': 4, 'md': 8, 'lg': 12, 'xl': 16}
```

### CSS (`docs/index.html` `:root`)
```css
:root {
  color-scheme: dark light;
  --bg-canvas:#14161A; --surface-1:#1B1E25; --surface-2:#23272F; --border-subtle:#2C313B;
  --text-primary:#EEF1F6; --text-tertiary:#8B93A6;
  --accent-base:#F28C2E; --accent-hover:#FFB066; --accent-text:#FFB066;
  --space-4:12px; --space-5:16px; --radius-md:8px; --radius-lg:12px;
  --shadow-2:0 4px 12px rgba(0,0,0,.45);
}
@media (prefers-color-scheme: light) {
  :root { --bg-canvas:#FAF8F5; --surface-1:#FFFFFF; --surface-2:#F4F1EC; --border-subtle:#E6E1D9;
          --text-primary:#1C1B1F; --text-tertiary:#6B6773;
          --accent-hover:#D97A1F; --accent-text:#A85500; --shadow-2:0 4px 12px rgba(28,27,31,.12); }
}
```
사이트의 기존 변수는 별칭으로 남겨 호환한다: `--bg`→`--bg-canvas`, `--surface`→`--surface-1`, `--line`→`--border-subtle`, `--ink`→`--text-primary`, `--muted`→`--text-tertiary`, `--carrot`→`--accent-base`, `--carrot-hi`→`--accent-hover`.

## 10. 적용 규칙 (맥·Windows·사이트 공통)
- 새 hex 를 코드에 직접 쓰지 않고 토큰만 쓴다. 필요한 색이 없으면 이 문서에 먼저 추가한다.
- **캐릭터 그림(`*CharacterView.swift`, `buni_items.py` Painter, 노트북·문서·탭 색 `LAP_*`/`DOC_*`/`TAB_*`)은 건드리지 않는다.** 정체성 영역.
- 주 버튼 = `accent.base` 면 + `text.onAccent` 글자. 보조 버튼 = `surface.2` + `border.strong`. 위험 = `danger`.
- **업무 카드 버튼 4종** (맥 `CardActionStyle` · Windows `_action_btn`): `primary` accent 면(승인하고 적용·시작 — 한 카드에 하나, 남는 폭을 채운다) · `danger` danger 12% 면 + danger 글자 + 35% 테두리(거절) · `secondary` `surface.2` + `border.strong`(변경 전·후 화면, 되돌리기, 다시 적용) · `quiet` 면 없음 + `text.secondary`(대화, 추가 요청, 변경 내용 보기). 높이 28 · 좌우 `space.4` · 반경 `radius.md` · 버튼 사이 `space.3`(조용한 버튼끼리는 `space.2`). 이모지 대신 시스템 기호(SF Symbols)를 글자 앞에 쓴다. 승인·거절은 한 줄(승인이 넓게), 변경 내용 보기는 그 아래 줄에 둔다.
- 기존 파란 `#3377E0` 주 버튼은 `accent.base` 로, 정보용 파랑은 `info` 로 옮긴다.
- 사이드바 = `bg.sidebar`, 본문 = `bg.canvas`, 카드 = `surface.1`, 입력창 = `surface.2` + `border.strong`.
- 글자는 3단계(`primary/secondary/tertiary`)만 쓰고 투명도로 회색을 만들지 않는다.

## 11. 가정
- A1. 기존 앱은 다크 전용이므로 다크 값은 기존 팔레트(앱 `#1E1E24`·`#2A2A34`·`#8A8A98`, 사이트 `#14161A`·`#1B1E25`)를 사이트 값 기준으로 하나로 합쳤다. 앱 바탕이 약간 푸른 쪽에서 중립 쪽으로 바뀐다.
- A2. 라이트 팔레트는 새로 정했다(따뜻한 흰색 계열, 당근색과 어울리게). 본문 대비 4.5:1 이상을 목표로 했다.
- A3. Tk 는 그림자·둥근 모서리·투명도를 기본 지원하지 않아 Windows 는 색·글꼴·간격 위주로 적용하고, 반경·그림자는 캔버스로 그리는 큰 요소에만 선택 적용한다. 값은 같고 표현만 단순화된다.
- A4. 사이트의 기존 웹폰트(Fredoka·Manrope·Press Start 2P·JetBrains Mono)는 이 시스템의 필수 토큰이 아니다. 시스템 글꼴 스택만으로 동작해야 하며 웹폰트 정리 여부는 사이트 담당이 정한다.
- A5. Raycast·Apple 의 로고·상표·에셋·폰트 파일·고유 색 값은 쓰지 않았다. 원칙만 참고했고 모든 값은 부니 기존 팔레트에서 도출했다.
- A6. Windows 라이트/다크 감지에 실패하면 다크로 간다.
