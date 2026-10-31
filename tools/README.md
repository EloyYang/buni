# 라이선스 키 발급 (tools/issue_license.py)

표준 라이브러리만 쓰는 Python 3 스크립트. 판매자 본인 PC에서만 실행한다. 형식은 `docs/monetization/license-spec.md`.

## 변경 전·후 화면 캡처 필요 조건

- 맥: 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹화에서 부니(또는 부니를 띄운 터미널)를 허용해야 `screencapture` 가 화면을 찍는다.
- Windows: Pillow 가 있어야 한다 (`pip install Pillow`). 읽기 전용 진단: `python windows\buni_team.py capture-diag`.
- 못 찍으면 보드에 `캡처 아님 — 이유` 로 보인다(맥·Windows 같은 문구). 절차: `docs/monetization/UI-CHECKLIST.md` 5번.

## 판매 시작까지 순서 (아침에 그대로 따라 하기)

값을 넣는 곳은 **종류별로 한 곳씩**이다. 비워 두면 앱은 죽지 않고 모든 키를 무료로 판정하며 결제 버튼은 "준비 중"으로 보인다.

| 순서 | 할 일 | 넣는 곳 |
|---|---|---|
| 1 | 키 쌍 생성 (아래 1항) | 비밀키는 저장소 밖 파일 |
| 2 | 공개키 반영 후 재빌드 | 맥 `Sources/ClaudeCompanion/ProLicense.swift` `publicKeyHex`, Windows `windows/buni_license.py` `PUBLIC_KEY_HEX` (시험·임시로는 환경변수 `BUNI_LICENSE_PUBKEY`) |
| 3 | Stripe 결제 링크 만들기 (월·연·평생 + 팩) | 앱: 환경변수 `BUNI_STRIPE_LINK_MONTHLY/YEARLY/LIFETIME` 또는 `pro-config.json` · 사이트: `docs/site-config.js` |
| 4 | 결제 알림을 받으면 키 발급 (아래 2항) 후 이메일로 전달 | `tools/issue_license.py issue` |
| 5 | 발급한 키로 앱 확인 | 업그레이드 창 입력칸 또는 아래 3항 `verify` |
| 6 | 시험 | `python3 -m unittest discover -s tests -p "test_*.py"` |

## 1. 키 쌍 만들기 (한 번만)

```bash
python3 tools/issue_license.py keygen --out ~/buni-license-secret.key
```

- 비밀키는 **저장소 밖** 파일에 저장된다(권한 600). 저장소 안 경로는 거부한다. 백업은 비밀번호 관리자 등에.
- 화면에 나온 공개키(hex 64자)를 `windows/buni_license.py`의 `PUBLIC_KEY_HEX`와 `Sources/ClaudeCompanion/ProLicense.swift`의 `publicKeyHex`에 넣고 앱을 다시 빌드한다.
- 비밀키를 잃어버리면 새 키 쌍으로 앱을 다시 배포해야 한다(기존 키는 무효가 됨).

## 2. 키 발급

```bash
# 연 구독 (오늘부터 366일)
python3 tools/issue_license.py issue --secret ~/buni-license-secret.key --plan yearly --days 366 --email buyer@example.com
# 월 구독
python3 tools/issue_license.py issue --secret ~/buni-license-secret.key --plan monthly --days 32
# 평생
python3 tools/issue_license.py issue --secret ~/buni-license-secret.key --plan lifetime
# 개별 팩
python3 tools/issue_license.py issue --secret ~/buni-license-secret.key --plan pack:sakura
```

`BUNI-…` 한 줄이 출력된다. 구매자에게 이메일로 보내면 앱의 라이선스 입력칸에 붙여 넣는다. `--expires YYYYMMDD`로 만료일을 직접 줄 수도 있다.

## 3. 키 확인

```bash
python3 tools/issue_license.py verify --pubkey <공개키 hex> BUNI-...
```

## 시험

```bash
python3 tests/test_license.py
python3 tests/test_pro.py
python3 tests/gen_vectors.py   # 맥·Windows 공용 시험 벡터(시험 전용 키) 재생성
```

`tests/`의 키는 **시험 전용**(공개된 RFC 8032 시드)이다. 실제 키 발급에 쓰지 말 것.
