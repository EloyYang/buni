// 맥 쪽 공유 시험 벡터 검증 (시험 전용). 실행:
//   swiftc -o /tmp/buni_vec Sources/ClaudeCompanion/ProLicense.swift tests/swift_vector_check.swift -parse-as-library
//   /tmp/buni_vec tests/license_vectors.json
import Foundation

@main
struct VectorCheck {
    static func main() {
        let path = CommandLine.arguments[1]
        let obj = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let pub = ProLicense.dataFromHex(obj["public_key_hex"] as! String)!
        let now = Date(timeIntervalSince1970: (obj["now"] as! NSNumber).doubleValue)
        var bad = 0
        for c in obj["cases"] as! [[String: Any]] {
            let r = ProLicense.verify(c["key"] as? String, publicKey: pub, now: now)
            let ok = r.valid == (c["valid"] as! Bool) && r.reason == (c["reason"] as! String)
                && (!r.valid || r.plan == (c["plan"] as! String))
            if !ok { bad += 1 }
            print(ok ? "OK  " : "FAIL", c["name"] as! String, r.valid, r.reason)
        }
        print(bad == 0 ? "ALL PASS" : "\(bad) FAILED")
        exit(bad == 0 ? 0 : 1)
    }
}
