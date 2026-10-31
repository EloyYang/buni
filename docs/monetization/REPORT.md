# 결정 필요 항목 (부니 1.9.1 Pro 결제 준비)

**한 줄 결론**: 코드·사이트·문서는 "공개키와 Stripe 링크만 넣으면 판매" 상태다. 아래는 사용자만 정할 수 있는 것이다. 시험·빌드·상수 일치 등 작동 점검 기록은 [VERIFICATION.md](VERIFICATION.md) 에 있다.

각 항목: 무엇을 결정 · 추천 · 근거.

## 1. 승인·판단

| # | 결정할 것 | 추천 | 근거 |
|---|---|---|---|
| 1 | 가격 월 $3 / 연 $24 / 평생 $49, 체험 신규 14일·기존 30일, 팩 Pro 30% 할인을 그대로 둘지 | 유지 | 바꿀 만한 새 시장 근거가 없었음 (`market-research.md` 유지 사유) |
| 2 | 작업 결과를 내 폴더·`main` 에 반영할지 | 브랜치 `pro-payment-prep` 를 만들어 검토 후 직접 병합 | 변경은 작업 브랜치 `buni/job-6001` 에 로컬 커밋돼 있음 (`pro-payment-prep` 이름이 필요하면 `git branch -m`). push·태그·`main` 병합은 하지 않았음 |
| 3 | 마케팅 초안(`docs/marketing/copy-ko.md`·`copy-en.md`)을 언제·어디에 게시할지 | 아래 2의 1·2번 완료 후 직접 게시 | 결제 링크가 없으면 "준비 중" 버튼만 보임. 게시 전 `{SITE_URL}` 치환 필요 |
| 4 | 스쿼드 예약·병렬을 Pro 로 잠글지, 잠근다면 시점 | 판매 시작 후 별도 업무로 (잠그기 전에는 마케팅에 Pro 혜택으로 쓰지 않음) | 아직 Pro 에 연결 전이고 기존 무료 사용자에게 영향이 큼 (이번 범위 밖) |
| 6 | 이미 설치된 옛 Windows exe 를 새 버전으로 바꿀지 (스쿼드마다 새 부니가 뜨는 오류는 새 exe 에서 고쳐짐) | 다음 릴리스에 포함해 사용자에게 업데이트 안내 | 옛 exe 훅은 스쿼드 세션 이벤트도 적음. 맥은 앱 실행 때 훅이 v6 로 자동 갱신 |
| 7 | 디자인 시스템의 라이트 모드를 앱·사이트에 노출할지 (지금은 다크 고정, 라이트는 값 정의만) | 판매 시작 후 별도 업무로 | 전환 UI 가 없고 화면 실기 확인을 못 했음 (`docs/design-system.md`) |
| 8 | 새 디자인(당근색 주 버튼·어두운 면 단계)을 그대로 쓸지 | 비교 화면을 보고 승인 | 실제 캡처는 못 찍음. `design-before-after/index.html` 은 코드 값 기반 재현이라 앱을 직접 켜 본 뒤 판단 |

## 2. 사용자만 할 수 있는 일 (순서는 `tools/README.md` 맨 위 표)

1. **공개키 생성**: `python3 tools/issue_license.py keygen --out ~/buni-license-secret.key` → 공개키를 `windows/buni_license.py` `PUBLIC_KEY_HEX` 와 `ProLicense.swift` `publicKeyHex` 에 넣고 재빌드. 비밀키는 저장소 밖에 보관. 비어 있는 동안은 모든 키가 무료로 판정돼 안전하다.
2. **Stripe 링크 등록**: 월·연·평생 + 팩 3개 → `docs/site-config.js` 와 `BUNI_STRIPE_LINK_*` 또는 `pro-config.json`. 결제 후 `issue` 로 키를 만들어 이메일 전달.
3. **도메인·Plausible**: 쓰기로 했다면 `docs/site-config.js` `plausibleDomain` 입력 (안 쓰면 비워 둠).
4. **릴리스**: 위 1~2 후 `VERSION` 을 올리고 `./release.sh <버전>`. 환불·세금·약관 문구는 범위 밖이라 따로 판단.

## 3. 틀렸을 때 고를 가정

| 가정 | 현재 값 | 바꾸려면 |
|---|---|---|
| 팩 가격 | $2.99 / 3.49 / 3.99 (Pro 30% 할인) | `_PACKS`, `PRO_PACK_DISCOUNT_PERCENT`, `ProManager.swift`, `docs/index.html` |
| Pro 범위 | 새 색 변형·클라우드 동기화(새로 켜는 사용자부터)·팩 할인만. 기존 무료 기능 유지 | `_PACKS`, `cloud_sync_policy` |
| 통화 | 달러($) | 원화는 참고 문구로만 |

## 4. 못 돌린 것

- Swift 공유 라이선스 벡터 실행과 GUI·브라우저 실기 확인은 막혀서 하지 못했다. 상세는 VERIFICATION.md.
