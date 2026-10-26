# 부니 계정 연동 설정 (선택 기능)

로그인하지 않아도 부니의 모든 기능은 그대로 동작합니다. 이 설정을 해두면, 원하는 사람이
**Google로 로그인**해서 코인·산 아이템·캐릭터별 착용·레벨을 다른 PC와 이어서 쓸 수 있습니다.
설정 파일(`cloud-config.json`)이 없으면 이 기능은 통째로 꺼진 채로 있습니다.

서버는 따로 만들지 않고 **Firebase**(로그인 + Firestore 데이터베이스)를 씁니다.

## 1. Firebase 프로젝트 만들기

1. <https://console.firebase.google.com> → **프로젝트 추가** (Google Analytics는 꺼도 됩니다).
2. **Authentication → 시작하기 → 로그인 방법 → Google → 사용 설정**, 지원 이메일을 고르고 저장.
3. **Firestore Database → 데이터베이스 만들기** → *프로덕션 모드*, 위치는 `asia-northeast3`(서울) 권장.
4. Firestore의 **규칙** 탭에 [`firestore.rules`](firestore.rules) 내용을 붙여 넣고 **게시**.

## 2. Google 로그인용 OAuth 클라이언트 만들기

1. 같은 프로젝트의 [Google Cloud 콘솔](https://console.cloud.google.com/apis/credentials) → **사용자 인증 정보**.
2. 처음이면 **OAuth 동의 화면**을 먼저 설정합니다. 앱 이름 `Buni`, 지원 이메일을 넣고,
   범위는 기본(`openid`, `email`, `profile`)만 씁니다. 다른 사람도 쓰게 하려면 **앱 게시**(프로덕션)를 누르세요.
   (이 범위는 민감 범위가 아니라 별도 심사가 필요 없습니다.)
3. **사용자 인증 정보 만들기 → OAuth 클라이언트 ID → 애플리케이션 유형: 데스크톱 앱**.
4. 만들어진 **클라이언트 ID**와 **클라이언트 보안 비밀**을 복사해 둡니다.
5. Firebase 콘솔 **Authentication → Sign-in method → Google**을 열고, 아래쪽
   *허용 목록에 추가할 외부 프로젝트의 클라이언트 ID*(Safelist client IDs)에 위 클라이언트 ID를 추가합니다.
   (로그인할 때 "audience"가 맞지 않는다는 오류가 나면 이 단계를 빠뜨린 것입니다.)

## 3. 설정 파일 만들기

Firebase **프로젝트 설정 → 일반**에서 `프로젝트 ID`와 `웹 API 키`를 복사해,
[`cloud-config.example.json`](cloud-config.example.json)을 참고해 `cloud-config.json`을 만듭니다.

```json
{
  "projectId": "…",
  "apiKey": "…",
  "googleClientId": "…apps.googleusercontent.com",
  "googleClientSecret": "GOCSPX-…"
}
```

두 가지 중 하나에 두면 됩니다.

- **저장소 루트**의 `cloud-config.json` → `./build_app.sh`가 앱 안에 넣어 줍니다 (배포용). 저장소에는 올라가지 않습니다(`.gitignore`).
- **`~/Library/Application Support/Buni/cloud-config.json`** → 이 맥에서만 쓸 때.

그다음 `./build_app.sh --install`로 다시 설치하고, 부니 메뉴 → 설정 → **계정 · 다른 PC와 연동**에서 로그인합니다.

### Windows

같은 `cloud-config.json`을 아래 중 한 곳에 두면 됩니다.

- **저장소 루트 또는 `windows/`** 의 `cloud-config.json` → `windows\build.bat`가 exe 안에 넣어 줍니다.
- GitHub Actions 릴리스 빌드는 저장소 시크릿 **`BUNI_CLOUD_CONFIG`**(파일 내용 전체)가 있으면 exe에 넣고, 없으면 계정 연동이 꺼진 채로 빌드합니다.
- **`%APPDATA%\Buni\cloud-config.json`** → 이 PC에서만 쓸 때.

로그인은 부니 설정 창의 **계정 연동**이나 상점 창의 **☁ 다른 PC와 연동** 버튼에서 합니다.
로그인 정보(갱신 토큰)는 Windows DPAPI로 암호화해 `%APPDATA%\Buni\cloud-token.bin`에 보관합니다.

## 무엇이 저장되나요?

`users/{계정 uid}` 문서 하나에 아래 값만 저장됩니다.

| 항목 | 용도 |
|---|---|
| 코인, 산 아이템 목록, 캐릭터별 착용 | 다른 PC에서 이어 쓰기 |
| 기기별 이번 달 토큰 수 (숫자) | 모든 PC를 합친 레벨 계산 |
| 계정의 고유 ID, 표시 이름 | 로그인 식별 (이메일은 저장하지 않습니다) |

대화 내용·코드·파일 이름은 저장하지 않습니다. 사용자는 설정에서 **로그아웃**하거나
**서버 데이터 삭제**를 언제든 할 수 있습니다. 다른 사람에게 배포한다면 이 내용을
개인정보 안내에 그대로 적어 두세요.

## 알아둘 점

- **코인은 클라이언트가 계산한 값**이라 사용자가 직접 조작할 수 있습니다. 꾸미기용 재화라
  괜찮다고 보고 서버에서 검증하지 않습니다. 코인이 실제 가치를 갖게 되면 서버 검증이 필요합니다.
- **레벨은 부니를 켜둔 PC들의 사용량 합**입니다. 계정 전체 사용량과 정확히 같지는 않습니다.
- 5분마다와 변경 4초 뒤에 동기화하므로, 사용자가 늘면 Firestore 무료 한도(일 읽기 5만 회)에
  닿을 수 있습니다. 그땐 주기를 늘리면 됩니다 (`CloudSync.swift`의 `periodic`).
- 두 PC가 동시에 바뀌면 코인은 **변화량을 더해서** 합치고, 착용은 **나중에 바꾼 쪽**이 이깁니다.
