import Foundation

/// Claude Code 트랜스크립트에서 세션 이름을 읽는다.
///
/// 트랜스크립트(`~/.claude/projects/<프로젝트>/<세션id>.jsonl`)에는 아래 형태의
/// 한 줄짜리 레코드가 이름이 정해지거나 바뀔 때마다 덧붙는다.
/// ```
/// {"type": "custom-title", "customTitle": "...", "sessionId": "..."}  // 사용자가 지정한 이름
/// {"type": "ai-title",     "aiTitle": "...",     "sessionId": "..."}  // 자동 생성된 이름
/// ```
/// 사용자가 지정한 이름이 있으면 그쪽을, 없으면 자동 생성 이름을 쓰고,
/// 같은 종류가 여러 번 있으면 가장 마지막(최신) 값을 쓴다.
enum SessionTitleReader {

    /// 메모 태그가 캐릭터 머리 위에 들어가는 폭이라 너무 긴 이름은 잘라 쓴다
    private static let maxLength = 24

    private struct TitleLine: Decodable {
        let type:        String?
        let customTitle: String?
        let aiTitle:     String?
        let sessionId:   String?
    }

    /// 세션 이름 — 찾지 못하면 nil
    static func title(for sessionId: String) -> String? {
        guard let url = transcriptURL(for: sessionId) else { return nil }

        // 제목 줄은 주기적으로 덧붙으므로 보통 파일 꼬리에 있다.
        // 꼬리에서 못 찾을 때만 전체를 훑어 큰 파일을 매번 읽지 않도록 한다.
        if let found = title(in: tailText(of: url, maxBytes: 256 * 1024), sessionId: sessionId) {
            return found
        }
        guard let full = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return title(in: full, sessionId: sessionId)
    }

    /// 세션 id에 해당하는 트랜스크립트 경로 — 프로젝트 폴더명을 모르므로 하위 폴더를 훑는다
    private static func transcriptURL(for sessionId: String) -> URL? {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(at: projects,
                                                    includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let url = dir.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func title(in text: String, sessionId: String) -> String? {
        var custom: String? = nil
        var ai:     String? = nil

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("-title") else { continue }   // 제목 줄만 파싱
            guard let data = line.data(using: .utf8),
                  let ev   = try? JSONDecoder().decode(TitleLine.self, from: data) else { continue }
            if let sid = ev.sessionId, sid != sessionId { continue }
            if let t = ev.customTitle, !t.isEmpty { custom = t }
            if let t = ev.aiTitle,     !t.isEmpty { ai     = t }
        }

        guard let picked = (custom ?? ai)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !picked.isEmpty else { return nil }
        return picked.count > maxLength ? String(picked.prefix(maxLength - 1)) + "…" : picked
    }

    /// 파일 끝에서 maxBytes 만큼 읽는다 (잘린 첫 줄은 버림)
    private static func tailText(of url: URL, maxBytes: Int) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }

        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        let offset = max(0, size - maxBytes)
        if offset > 0 { try? fh.seek(toOffset: UInt64(offset)) }
        guard let data = try? fh.readToEnd() else { return "" }

        // 중간부터 읽었으면 첫 줄은 잘려 있으므로 버린다
        if offset > 0, let nl = data.firstIndex(of: 0x0A) {
            return String(data: data[data.index(after: nl)...], encoding: .utf8) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
