import Foundation

/// 클라우드 동기화(선택 기능)에 필요한 Firebase·Google 값.
///
/// 이 파일이 없으면 동기화 기능은 통째로 꺼진 채로 있고, 앱은 지금처럼 로컬에서만 동작한다.
/// 로그인은 필수가 아니다 — 다른 PC와 설정·레벨을 이어가고 싶은 사람만 쓰는 기능이다.
///
/// 값은 아래 순서로 찾는다.
///  1. 앱 번들 안의 cloud-config.json (build_app.sh가 저장소 루트의 파일을 복사해 넣는다)
///  2. ~/Library/Application Support/Buni/cloud-config.json (직접 둘 때)
///
/// 형식은 cloud/cloud-config.example.json 참고. Firebase API 키는 공개돼도 되는 값이고
/// (접근 통제는 Firestore 보안 규칙이 한다), Google 데스크톱 클라이언트의 secret도
/// 데스크톱 앱에서는 비밀이 아니다 — 그래도 저장소에는 올리지 않도록 .gitignore에 뒀다.
struct CloudConfig: Decodable {
    let projectId: String
    let apiKey: String
    let googleClientId: String
    /// 데스크톱(설치형 앱) 클라이언트는 토큰 교환에 이 값을 요구한다. 비어 있으면 생략한다.
    let googleClientSecret: String?
    /// 채팅(Realtime Database)이 쓰는 주소. 비어 있으면 기본 주소(미국 리전)를 쓴다.
    /// 리전을 서울 가까이(싱가포르 등)로 만들었다면 그 주소를 적는다.
    let databaseURL: String?

    /// Realtime Database 기본 주소 (끝의 / 없음)
    var rtdbBase: String {
        let raw = (databaseURL?.isEmpty == false) ? databaseURL! : "https://\(projectId)-default-rtdb.firebaseio.com"
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    static let shared: CloudConfig? = load()

    private static func load() -> CloudConfig? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "cloud-config", withExtension: "json") {
            candidates.append(bundled)
        }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("Buni/cloud-config.json"))
        }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(CloudConfig.self, from: data),
                  !config.projectId.isEmpty, !config.apiKey.isEmpty, !config.googleClientId.isEmpty
            else { continue }
            return config
        }
        return nil
    }
}
