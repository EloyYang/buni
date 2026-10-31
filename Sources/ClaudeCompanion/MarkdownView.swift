import SwiftUI

/// 마크다운 문서를 읽기 좋게 그린다 — 제목·목록·체크리스트·표·코드·인용·굵게/기울임/링크.
/// (SwiftUI 의 Text 는 줄 안쪽 서식만 알아서, 블록 구조는 여기서 나눠 그린다)
struct MarkdownView: View {
    let text: String
    /// 항목 아래 입력창에 쓰던 글을 보관할 때 쓰는 프로젝트 id — 비우면 보관하지 않는다
    var draftScope: String = ""
    /// `[라벨](buni://동작/대상)` 한 줄은 버튼으로 그린다 — 눌리면 (동작, 대상) 을 알려 준다
    var onAction: ((String, String) -> Void)? = nil
    /// 항목 아래 채팅 입력창에서 보낸 글 — (대상, 내용, 첨부 파일들)
    var onFeedback: ((String, String, [URL]) -> Void)? = nil

    private enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet(level: Int, marker: String, text: String)
        case quote(String)
        case code(String)
        case table(header: [String], rows: [[String]])
        case rule
        case actions([(label: String, host: String, target: String)])
        case feedbackBox(String)
    }

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in view(for: b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: 그리기

    @ViewBuilder
    private func view(for b: Block) -> some View {
        switch b {
        case .heading(let level, let t):
            Self.inline(t)
                .font(.system(size: [0, 20, 17, 15, 14, 13, 13][min(level, 6)], weight: .bold))
                .padding(.top, level <= 2 ? 8 : 4)
                .fixedSize(horizontal: false, vertical: true)
            if level <= 2 { Divider().opacity(0.5) }
        case .paragraph(let t):
            Self.inline(t).font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .bullet(let level, let marker, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).font(.system(size: 13)).frame(minWidth: 14, alignment: .trailing)
                Self.inline(t).font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 18)
        case .quote(let t):
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Self.inline(t).font(.system(size: 13)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let t):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(t).font(.system(size: 12, design: .monospaced)).padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { ForEach(Array(header.enumerated()), id: \.offset) { _, h in Self.inline(h).font(.system(size: 12, weight: .bold)) } }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow { ForEach(Array(r.enumerated()), id: \.offset) { _, c in Self.inline(c).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) } }
                    }
                }.padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.buniPanel))
        case .rule:
            Divider()
        case .feedbackBox(let id):
            MarkdownFeedbackBox(draftKey: draftScope.isEmpty ? nil : TeamDrafts.key(draftScope, "fb:" + id)) { text, files in onFeedback?(id, text, files) }
        case .actions(let items):
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, a in
                    Button { onAction?(a.host, a.target) } label: {
                        Text(a.label).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Self.color(for: a.host)))
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private static func color(for host: String) -> Color {
        switch host {
        case "run", "apply": return .orange
        case "diff":     return .gray
        case "followup": return Color(red: 0.45, green: 0.30, blue: 0.85)
        case "view":     return .gray
        case "ok":       return Color(red: 0.20, green: 0.62, blue: 0.35)
        case "feedback": return Color(red: 0.30, green: 0.45, blue: 0.80)
        default:         return .accentColor
        }
    }

    /// 줄 안쪽 서식(굵게·기울임·`코드`·링크)
    static func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(s)
    }

    // MARK: 읽기

    private static func parse(_ src: String) -> [Block] {
        let lines = src.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [Block] = []
        var para: [String] = []
        var i = 0

        func flush() {
            guard !para.isEmpty else { return }
            let joined = para.joined(separator: " ")
            para = []
            // 버튼 줄: 문단이 `[라벨](buni://동작/대상)` 들로만 이루어져 있으면 버튼으로
            let re = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(buni://([a-z]+)/([^)\s]+)\)"#)
            let ns = joined as NSString
            let ms = re.matches(in: joined, range: NSRange(location: 0, length: ns.length))
            if ms.count == 1, ns.substring(with: ms[0].range(at: 2)) == "feedbackbox",
               re.stringByReplacingMatches(in: joined, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                .trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(.feedbackBox(ns.substring(with: ms[0].range(at: 3))))
                return
            }
            if !ms.isEmpty {
                let rest = re.stringByReplacingMatches(in: joined, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                if rest.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append(.actions(ms.map { (label: ns.substring(with: $0.range(at: 1)), host: ns.substring(with: $0.range(at: 2)),
                                                  target: ns.substring(with: $0.range(at: 3))) }))
                    return
                }
            }
            out.append(.paragraph(joined))
        }
        func cells(_ line: String) -> [String] {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") { t.removeLast() }
            return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func isSeparatorRow(_ line: String) -> Bool {
            let c = cells(line)
            return !c.isEmpty && c.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {                                   // 코드 블록
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(lines[i]); i += 1 }
                out.append(.code(code.joined(separator: "\n")))
                i += 1; continue
            }
            if line.isEmpty { flush(); i += 1; continue }

            if let m = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {   // 제목
                flush()
                let level = line[m].filter { $0 == "#" }.count
                out.append(.heading(level, String(line[m.upperBound...]).trimmingCharacters(in: .whitespaces)))
                i += 1; continue
            }
            if line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {   // 구분선
                flush(); out.append(.rule); i += 1; continue
            }
            if line.hasPrefix("|"), i + 1 < lines.count, isSeparatorRow(lines[i + 1]) {          // 표
                flush()
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var r = cells(lines[i])
                    while r.count < header.count { r.append("") }
                    rows.append(Array(r.prefix(max(header.count, 1))))
                    i += 1
                }
                out.append(.table(header: header, rows: rows)); continue
            }
            if line.hasPrefix(">") {                                                              // 인용
                flush()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                out.append(.quote(q.joined(separator: " "))); continue
            }
            if let m = raw.range(of: #"^\s*([-*+]|\d+[.)])\s+"#, options: .regularExpression) {   // 목록
                flush()
                let head = String(raw[m])
                let indent = head.prefix { $0 == " " || $0 == "\t" }.count
                var marker = head.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: .whitespaces)
                var body = String(raw[m.upperBound...])
                marker = marker.first.map { "-*+".contains($0) } == true ? "•" : marker
                // 체크리스트: [ ] [x] [O] [X] [△] ...
                if let c = body.range(of: #"^\[(.)\]\s*"#, options: .regularExpression) {
                    let mark = body[c].dropFirst().first!
                    let icon: String
                    switch mark {
                    case "x", "X", "o", "O", "✓", "✔": icon = (mark == "X" ? "❌" : "✅")
                    case "△", "~", "/": icon = "⚠️"
                    case " ": icon = "☐"
                    default: icon = "☐"
                    }
                    // [X] 는 보고서에서 '못 함' 의미, [x] 는 체크됨 — 대문자 X 만 실패로 본다
                    marker = mark == "x" ? "✅" : icon
                    body = String(body[c.upperBound...])
                }
                out.append(.bullet(level: min(indent / 2, 4), marker: marker, text: body))
                i += 1; continue
            }
            para.append(line)
            i += 1
        }
        flush()
        return out
    }
}


/// 검토 항목 바로 아래에 떠 있는 채팅 입력창 — 보고 나서 바로 의견을 적어 보낸다 (Enter 로도 전송)
private struct MarkdownFeedbackBox: View {
    var draftKey: String? = nil
    var onSend: (String, [URL]) -> Void
    @State private var text = ""
    @State private var restored = false
    @State private var sent = false
    @State private var files: [URL] = []              // 보내기 전 첨부 (메모리만)
    @State private var attachNote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AttachChips(files: $files, note: $attachNote)
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.text.bubble.right").foregroundColor(.secondary)
                TextField(L.t("이 항목을 보고 느낀 점·고칠 점을 적어 보내세요", "Write what you'd change about this item"), text: $text)
                    .textFieldStyle(.plain).font(.system(size: 13)).onSubmit(send)
                AttachPickButton(files: $files, note: $attachNote)
                Button(action: send) {
                    Text(sent ? L.t("보냈어요 ✓", "Sent ✓") : L.t("보내기", "Send"))
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(canSend ? Color.accentColor : Color.gray.opacity(0.5)))
                }
                .buttonStyle(.plain).disabled(!canSend)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.buniLine, lineWidth: 1))
        .onAppear {
            if !restored {
                restored = true
                if let k = draftKey { text = TeamDrafts.shared.get(k); files = TeamAttachPending.shared.get(k).filter { FileManager.default.fileExists(atPath: $0.path) } }
            }
        }
        .onChange(of: text) { v in
            if restored, let k = draftKey { TeamDrafts.shared.set(k, v) }
        }
        .onChange(of: files) { v in
            if restored, let k = draftKey { TeamAttachPending.shared.set(k, v) }
        }
    }

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }                  // 피드백은 글이 있어야 한다 (첨부는 거기에 덧붙인다)
        onSend(t, files)
        text = ""
        files = []; attachNote = nil
        sent = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sent = false }
    }
}
