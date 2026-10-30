# 경쟁 앱 조사와 가격 결정

조사일: 2026-10-28 (웹 검색 요약). 아래 가격은 검색 결과에서 확인된 값이며, 집계 사이트 값은 **추정**으로 표시했다. 공식 페이지 가격은 수시로 바뀌므로 출시 전 다시 확인한다.

## 비교 앱

| 앱 | 분류 | 가격·판매 방식 | 무료/유료 경계 | 출처 |
|---|---|---|---|---|
| Bartender 6 | 메뉴바 정리 | 6 버전 영구 라이선스 약 $20(1인·모든 Mac). 별도 Bartender Pro는 연 구독(14일 체험), 평생 티어도 있음(가격 미확인) | 체험 후 구매. 신기능(노치 위젯 등)은 Pro 구독 | [Macworld](https://www.macworld.com/article/540429/mac-gems-bartender-4-review.html) · [macbartender.com](https://www.macbartender.com/purchase/) · [AlternativeTo](https://alternativeto.net/news/2026/5/bartender-pro-expands-beyond-the-menu-bar-with-notch-widgets-activities-and-music-controls/) |
| Raycast | 런처·생산성 | Pro 월 $10 / 연 결제 시 월 $8(추정, 집계 사이트 다수 일치), AI 상위 플랜 별도 | 핵심 기능 무료, 클라우드 동기화·AI 등이 Pro | [Raycast 블로그](https://www.raycast.com/blog/changing-how-raycast-ai-is-priced) · [The Sweet Setup](https://thesweetsetup.com/heres-what-you-need-to-know-about-raycast-pro/) |
| CleanShot X | 스크린샷 | 일회성 $29(업데이트 1년 포함, 이후 $19 갱신 선택), 클라우드는 별도 구독 약 월 $8(추정) | 앱은 유료 일회성, 클라우드만 구독 | [TrustRadius](https://trustradius.com/products/cleanshot-x/pricing) · [Toolradar](https://toolradar.com/tools/cleanshot-x/pricing) |
| Things 3 | 할 일 관리 | 기기별 일회성: iPhone $9.99, Mac $49.99(추정, 출처 간 차이) | 체험 후 구매, 구독 없음 | [Toolradar](https://toolradar.com/tools/things-3/pricing) · [TechRepublic](https://www.techrepublic.com/article/things-3-review/) |
| Desktop Pet Project (Steam) | 데스크톱 펫 | 약 $2.99(할인 시 $2.39) 일회성 | 전체 유료 일회성 | [Steambase](https://steambase.io/games/desktop-pet-project/info) · [Dekudeals](https://www.dekudeals.com/items/desktop-pet-project) |
| Desktop Pet (Steam) | 데스크톱 펫 | 약 $3.99 일회성(2025-09 기준) | 전체 유료 일회성 | [SteamDB](https://steamdb.info/sub/780452) |
| Shimeji Desktop Mascot | 데스크톱 펫 | 무료(Windows 전용, 오픈소스) | 전부 무료 | [SourceForge](https://sourceforge.net/projects/shimeji-desktop/) |

## 관찰

- 데스크톱 펫류는 무료이거나 $2~4 일회성이다. 부니의 개별 코스메틱 팩($2.99~3.99)은 이 범위와 맞는다.
- 생산성·메뉴바 앱은 일회성 $20~50 또는 월 $8~10 구독이다. 소형 보조 앱이 월 $10 근처를 받기는 어렵다.
- 무료 핵심 + 클라우드·고급 기능만 구독으로 거는 구조(Raycast, CleanShot Cloud)는 부니의 "기존 기능 무료 + Pro" 구조와 같다.
- Claude Code 동반자라는 정확히 같은 카테고리의 유료 경쟁 앱은 이번 검색에서 확인하지 못했다(없다고 단정하지 않음).

## 가격 결정

| 항목 | 결정 | 근거 |
|---|---|---|
| Pro 월 | **$3** | 펫 앱 일회성 가격대, Raycast $8~10의 1/3 이하로 부담 없는 진입 |
| Pro 연 | **$24** (월 $2 꼴, 33% 할인) | 연 결제를 유도하되 Raycast 연 환산 $96보다 한참 낮게 |
| Pro 평생 | **$49** | 연 구독 2년 치. Bartender 6 영구 $20보다는 높지만 Pro는 앞으로의 기능 포함이고, Things Mac $49.99와 비슷 |
| 개별 팩 | **$2.99 / $3.49 / $3.99** | 데스크톱 펫 앱 가격대 |
| Pro 팩 할인 | **30%** | 사전요구서 가정-F |

기본안 그대로 확정한다. 한계: 가격 탄력성은 실제 판매 데이터가 없어 검증되지 않았다. 출시 후 전환율을 보고 평생 가격을 조정한다. 가격 위치는 `windows/buni_pro.py`(`_PACKS`), `Sources/ClaudeCompanion/ProManager.swift`, `docs/index.html` 가격 카드.

## 2026-10-29 재점검: 가격 유지 사유

이번 작업(결제 준비)에서 research 팀원의 산출물(`.buni-team/job-6001/research/`)이 비어 있었고 새 출처를 확인하지 못했다. 사전요구서의 막혔을 때 규칙("근거가 부족하면 가격을 바꾸지 않고 유지 사유를 적는다")에 따라 **월 $3 / 연 $24 / 평생 $49, 체험 신규 14일·기존 30일, 팩 Pro 30% 할인을 그대로 유지**한다. 위 표의 출처와 판단이 근거다. 새 근거가 생기면 `buni_pro.py`·`ProManager.swift`·`docs/index.html`을 함께 고친다(변동 ±30% 이내).
