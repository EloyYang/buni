# 부니 라이선스 키 명세 (v1)

맥(`Sources/ClaudeCompanion/ProLicense.swift`)·Windows(`windows/buni_license.py`)·발급 스크립트(`tools/issue_license.py`)가 같은 형식을 쓴다. 서버 없이 오프라인으로 검증한다. **[가정-C]**

## 형식

```
BUNI-<base64url(payload)>.<base64url(signature)>
```

- base64url: RFC 4648 §5, 패딩(`=`) 없음. 허용 문자는 `A-Z a-z 0-9 - _` 뿐.
- `signature`: payload 바이트 전체에 대한 Ed25519 서명(RFC 8032, 64바이트).
- `payload`: ASCII 문자열, `|`로 구분한 4칸.

```
v1|<plan>|<expires>|<emailhash>
```

| 칸 | 값 |
|---|---|
| 버전 | 항상 `v1` |
| plan | `monthly` · `yearly` · `lifetime` (Pro) / `pack:<id>` (개별 코스메틱 팩, id는 `[a-z0-9_]{1,40}`) |
| expires | `YYYYMMDD`(UTC, 그날 끝까지 유효) 또는 `0`(만료 없음, 평생·팩) |
| emailhash | 소문자·공백제거한 이메일의 sha256 앞 16 hex, 이메일이 없으면 `0` (원문 이메일은 키에 넣지 않는다) |

## 판정 (무료로 떨어지는 경우)

| reason | 조건 |
|---|---|
| `format` | 접두사 없음, `.`이 정확히 1개가 아님, base64url 오류, 서명이 64바이트가 아님, payload 칸 수·버전·plan·expires 형식 오류 |
| `no_pubkey` | 앱에 공개키가 설정되지 않음 (모든 키가 무료로 판정됨) |
| `signature` | 서명 검증 실패 (변조, 다른 키로 서명) |
| `expired` | 서명은 맞지만 `expires`가 오늘(UTC)보다 과거 |

검증 순서는 format → 공개키 → 서명 → 만료. 앞 단계에서 실패하면 뒤는 보지 않는다. 키 앞뒤 공백은 무시한다.

## 공개키

- 앱에 hex 64자로 내장: Windows `buni_license.PUBLIC_KEY_HEX`, 맥 `ProLicense.publicKeyHex`. 두 곳은 같은 값이어야 한다.
- 개발용으로 환경변수 `BUNI_LICENSE_PUBKEY`가 내장값보다 우선한다.
- 저장소의 값은 **비어 있다**. 사용자가 키 쌍을 만들어 채운다 (`tools/README.md`).
- 비밀키는 저장소에 두지 않는다. 발급 도구는 저장소 안 경로로의 `keygen` 저장을 거부한다.

## 시험

- 시험 전용 키 쌍: RFC 8032 시험 벡터 1의 공개된 시드를 사용 (`tests/`). 실제 판매에 쓰면 안 된다.
- `python3 tests/test_license.py` — RFC 벡터, 올바른 키, 변조·만료·형식 오류.
- `python3 tests/gen_vectors.py` → `tests/license_vectors.json` 생성. 맥·Windows가 같은 파일(공개키 + 키 + 기대 결과 + 고정 시각)로 검증한다.
