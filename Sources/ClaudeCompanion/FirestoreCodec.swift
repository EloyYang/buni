import Foundation

// MARK: - Firestore 값 변환 (REST는 모든 값에 타입 이름을 붙인다)

enum FS {
    private static func iso() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }

    static func int(_ n: Int) -> [String: Any] { ["integerValue": String(n)] }
    static func str(_ s: String) -> [String: Any] { ["stringValue": s] }
    static func time(_ d: Date) -> [String: Any] { ["timestampValue": iso().string(from: d)] }
    /// 삼항식 안에 서로 다른 딕셔너리 리터럴을 두면 컴파일러가 타입을 추론하지 못해서 if로 풀었다
    static func strArray(_ items: [String]) -> [String: Any] {
        var inner: [String: Any] = [:]
        if !items.isEmpty {
            let values: [[String: Any]] = items.map { str($0) }
            inner["values"] = values
        }
        return ["arrayValue": inner]
    }

    static func map(_ fields: [String: [String: Any]]) -> [String: Any] {
        var inner: [String: Any] = [:]
        if !fields.isEmpty { inner["fields"] = fields }
        return ["mapValue": inner]
    }

    static func encode(_ d: CloudDoc) -> [String: Any] {
        // 한 식에 중첩 딕셔너리를 다 쓰면 컴파일러가 타입을 못 잡는다 — 한 단계씩 타입을 적어 쌓는다
        var equippedFields: [String: [String: Any]] = [:]
        for (character, slots) in d.equipped {
            var slotFields: [String: [String: Any]] = [:]
            for (slot, itemId) in slots { slotFields[slot] = str(itemId) }
            equippedFields[character] = map(slotFields)
        }

        var tokenFields: [String: [String: Any]] = [:]
        for (month, devices) in d.tokens {
            var deviceFields: [String: [String: Any]] = [:]
            for (device, count) in devices { deviceFields[device] = int(count) }
            tokenFields[month] = map(deviceFields)
        }

        let changedAt: Date = d.equippedUpdatedAt == .distantPast ? Date(timeIntervalSince1970: 0) : d.equippedUpdatedAt

        var fields: [String: Any] = [:]
        fields["coins"] = int(d.coins)
        fields["owned"] = strArray(d.owned.sorted())
        fields["equipped"] = map(equippedFields)
        fields["equippedUpdatedAt"] = time(changedAt)
        fields["tokens"] = map(tokenFields)
        fields["schema"] = int(1)
        fields["updatedAt"] = time(Date())
        return fields
    }

    static func decode(_ f: [String: Any]) -> CloudDoc {
        var doc = CloudDoc()
        doc.coins = intValue(f["coins"]) ?? 0
        doc.owned = Set(arrayStrings(f["owned"]))

        for (character, slotsValue) in mapFields(f["equipped"]) {
            var slots: [String: String] = [:]
            for (slot, itemValue) in mapFields(slotsValue) {
                if let itemId = stringValue(itemValue) { slots[slot] = itemId }
            }
            doc.equipped[character] = slots
        }

        if let changedAt = timeValue(f["equippedUpdatedAt"]) { doc.equippedUpdatedAt = changedAt }

        for (month, devicesValue) in mapFields(f["tokens"]) {
            var devices: [String: Int] = [:]
            for (device, countValue) in mapFields(devicesValue) {
                if let count = intValue(countValue) { devices[device] = count }
            }
            doc.tokens[month] = devices
        }
        return doc
    }

    private static func intValue(_ v: Any?) -> Int? {
        guard let s = (v as? [String: Any])?["integerValue"] as? String else { return nil }
        return Int(s)
    }
    private static func stringValue(_ v: Any?) -> String? { (v as? [String: Any])?["stringValue"] as? String }
    private static func mapFields(_ v: Any?) -> [String: Any] {
        ((v as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any] ?? [:]
    }
    private static func arrayStrings(_ v: Any?) -> [String] {
        let values = ((v as? [String: Any])?["arrayValue"] as? [String: Any])?["values"] as? [Any] ?? []
        return values.compactMap { stringValue($0) }
    }
    private static func timeValue(_ v: Any?) -> Date? {
        guard let s = (v as? [String: Any])?["timestampValue"] as? String else { return nil }
        if let d = iso().date(from: s) { return d }
        // 서버가 소수점 자릿수를 다르게 줄 때를 대비해 소수부를 떼고 다시 읽는다
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
