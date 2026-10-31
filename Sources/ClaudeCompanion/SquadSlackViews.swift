import SwiftUI
import AppKit
import UniformTypeIdentifiers

// 부니 스쿼드 — 슬랙처럼 "단체방(채널)" 과 "개별 대화(DM)" 로 나눠 보여 주는 화면 조각들.
//  · 단체방: 지시·보고·검토의 한두 줄 요약만 (자세한 건 '상세 ›' 로 그 팀원의 DM 으로)
//  · DM: 팀장 ↔ 그 팀원이 주고받은 전문, 실시간 진행, Claude 에서 열기

// MARK: - 팔레트

enum SQ {
    // 색은 BuniTheme(docs/design-system.md) 토큰에서 가져온다
    static let rail  = Color.buniRail
    static let main  = Color.buniBg
    static let line  = Color.buniLine
    static let dim   = Color.buniDim
    static let hover = Color.buniRaised.opacity(0.6)

    private static let avatarColors: [Color] = [
        Color(red: 0.36, green: 0.52, blue: 0.95), Color(red: 0.25, green: 0.66, blue: 0.55),
        Color(red: 0.86, green: 0.50, blue: 0.30), Color(red: 0.68, green: 0.42, blue: 0.88),
        Color(red: 0.88, green: 0.40, blue: 0.55), Color(red: 0.55, green: 0.65, blue: 0.25),
        Color(red: 0.30, green: 0.62, blue: 0.82), Color(red: 0.80, green: 0.62, blue: 0.22),
    ]
    static func avatarColor(_ id: String) -> Color {
        if id == "lead" { return Color.buniAccent }
        if id == "user" { return Color(red: 0.40, green: 0.45, blue: 0.55) }
        let h = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return avatarColors[h % avatarColors.count]
    }
}

/// 사람 · 팀원 · 팀장 이름표 (아바타 이모지 + 이름)
struct SquadPeople {
    let job: TeamJob

    func name(_ id: String) -> String {
        switch id {
        case "lead":   return L.t("팀장", "Lead")
        case "user":   return L.t("나", "Me")
        case "all":    return L.t("모두", "Everyone")
        case "system": return ""
        default:       return job.plan?.roles?.first(where: { $0.id == id })?.name ?? id
        }
    }
    func icon(_ id: String) -> String {
        switch id {
        case "lead": return "🐰"
        case "user": return "🙂"
        case "system": return "•"
        default: return job.plan?.roles?.first(where: { $0.id == id })?.icon ?? "🧑‍💻"
        }
    }
    func roleIds() -> [String] { (job.plan?.roles ?? []).map { $0.id } }
}

struct SquadAvatar: View {
    let icon: String
    let id: String
    var size: CGFloat = 34
    var body: some View {
        Text(icon)
            .font(.system(size: size * 0.52))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24).fill(SQ.avatarColor(id).opacity(0.30)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24).stroke(SQ.avatarColor(id).opacity(0.55), lineWidth: 1))
    }
}

// MARK: - 요약 · 시간

/// 단체방에 보일 한두 줄 요약 — 마크다운 기호를 걷고 첫 줄을 자른다
func squadSummary(_ s: String, limit: Int = 110) -> (text: String, more: Bool) {
    let lines = s.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard let first = lines.first else { return ("", false) }
    var t = first
    while let c = t.first, "#>*-•` ".contains(c) { t.removeFirst() }
    t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    var more = lines.count > 1
    if t.count > limit { t = String(t.prefix(limit - 1)) + "…"; more = true }
    return (t, more)
}

private let squadClock: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
}()

private func dayLabel(_ ts: Double) -> String {
    let d = Date(timeIntervalSince1970: ts)
    let cal = Calendar.current
    if cal.isDateInToday(d) { return L.t("오늘", "Today") }
    if cal.isDateInYesterday(d) { return L.t("어제", "Yesterday") }
    let f = DateFormatter(); f.dateFormat = L.t("M월 d일 (E)", "MMM d (E)")
    return f.string(from: d)
}

// MARK: - 입력창 (Enter 보내기 · Shift/Option+Enter 줄바꿈)

struct SquadComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var onSend: () -> Void
    /// ⌘V 로 클립보드의 파일·이미지를 붙여넣으면 첨부로 올린다 (글이면 평소처럼 붙여넣는다)
    var onPasteFiles: (([URL]) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ComposerTextView()
        tv.onPasteFiles = { context.coordinator.parent.onPasteFiles?($0) }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 13)
        tv.textColor = .white
        tv.insertionPointColor = .white
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        let sv = NSScrollView()
        sv.documentView = tv
        sv.drawsBackground = false
        sv.hasVerticalScroller = false
        sv.borderType = .noBorder
        context.coordinator.textView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text; context.coordinator.measure() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SquadComposer
        weak var textView: NSTextView?
        init(_ p: SquadComposer) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            measure()
        }

        func measure() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            let clamped = min(max(h, 34), 150)
            if abs(parent.height - clamped) > 0.5 {
                DispatchQueue.main.async { self.parent.height = clamped }
            }
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if mods.contains(.shift) || mods.contains(.option) {
                tv.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            if tv.hasMarkedText() { return false }           // 한글 조합 중 Enter 는 글자 확정으로
            parent.onSend()
            return true
        }
    }
}

private final class ComposerTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
    var onPasteFiles: (([URL]) -> Void)?

    override func paste(_ sender: Any?) {
        let files = onPasteFiles == nil ? [] : TeamAttach.pasteboardFiles()
        if !files.isEmpty { onPasteFiles?(files); return }
        super.paste(sender)
    }
}

/// 슬랙처럼 둥근 테두리 안에 입력창 + 보내기 버튼
struct SquadComposerBar: View {
    let placeholder: String
    var hint: String? = nil
    var mentions: [(id: String, label: String)] = []
    var disabled = false
    /// 쓰던 글을 보관하는 열쇠 (`TeamDrafts.key`) — 비우면 보관하지 않는다
    var draftKey: String? = nil
    /// 보낸 글과 첨부 파일들 — 글 없이 첨부만 보내도 된다
    var onSend: (String, [URL]) -> Void

    @State private var text = ""
    @State private var height: CGFloat = 34
    @State private var restoredKey: String? = nil
    @State private var files: [URL] = []              // 보내기 전 첨부 (메모리만 — 입력 중 draft 저장과 무관)
    @State private var attachNote: String? = nil
    @State private var dropping = false

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !(trimmed.isEmpty && files.isEmpty) && !disabled }

    private var mentionMatches: [(id: String, label: String)] {
        guard text.hasPrefix("@"), !text.contains(" "), !text.contains("\n") else { return [] }
        let q = String(text.dropFirst()).lowercased()
        return mentions.filter { q.isEmpty || $0.label.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !mentionMatches.isEmpty {
                HStack(spacing: 6) {
                    ForEach(mentionMatches, id: \.id) { m in
                        Button { text = "@\(m.label) " } label: {
                            Text("@" + m.label).font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.35)))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
            AttachChips(files: $files, note: $attachNote)
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    SquadComposer(text: $text, height: $height, onSend: send, onPasteFiles: { addFiles($0) })
                    if text.isEmpty {
                        Text(placeholder).font(.system(size: 13)).foregroundColor(.buniDim)
                            .padding(.horizontal, 9).padding(.vertical, 7).allowsHitTesting(false)
                    }
                }
                .frame(height: height)
                AttachPickButton(files: $files, note: $attachNote)
                Button(action: send) {
                    Image(systemName: "paperplane.fill").font(.system(size: 12, weight: .bold))
                        .foregroundColor(canSend ? Color.buniAccentInk : Color.buniDim)
                        .frame(width: 30, height: 28)
                        .background(RoundedRectangle(cornerRadius: BuniTheme.rSm)
                            .fill(canSend ? Color.buniAccent : Color.buniRaised))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.bottom, 3)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: BuniTheme.rMd).fill(Color.buniField))
            .overlay(RoundedRectangle(cornerRadius: BuniTheme.rMd).stroke(dropping ? Color.buniAccent : Color.buniLine, lineWidth: dropping ? 2 : 1))
            .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
                TeamAttach.loadURLs(providers) { addFiles($0) }
                return true
            }
            Text((hint ?? L.t("Enter 보내기 · Shift+Enter 줄바꿈", "Enter to send · Shift+Enter for a new line")) + TeamAttach.hint)
                .font(.system(size: 10)).foregroundColor(.buniDim)
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)
        .onAppear { restore() }
        .onChange(of: text) { v in
            // 되살리는 중에 빈 글로 덮어쓰지 않는다
            if let k = draftKey, restoredKey == k { TeamDrafts.shared.set(k, v) }
        }
        .onChange(of: files) { v in
            if let k = draftKey, restoredKey == k { TeamAttachPending.shared.set(k, v) }
        }
    }

    private func restore() {
        guard let k = draftKey, restoredKey != k else { return }
        restoredKey = k
        text = TeamDrafts.shared.get(k)
        files = TeamAttachPending.shared.get(k).filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addFiles(_ urls: [URL]) {
        let r = TeamAttach.merge(urls, into: files)
        files = r.files; attachNote = r.note
    }

    private func send() {
        guard canSend else { return }
        onSend(trimmed, files)
        text = ""
        files = []; attachNote = nil
        height = 34
    }
}

// MARK: - 메시지 목록

private enum SquadRow: Identifiable {
    case day(String, Int)
    case msg(TeamChatMessage, header: Bool)
    case note(TeamChatMessage)
    case typing(String)

    var id: String {
        switch self {
        case .day(_, let i): return "d\(i)"
        case .msg(let m, _): return "m\(m.id)"
        case .note(let m):   return "m\(m.id)"
        case .typing:        return "typing"
        }
    }
}

private func buildRows(_ msgs: [TeamChatMessage], typing: String, grouping: Bool = true) -> [SquadRow] {
    var rows: [SquadRow] = []
    var lastDay = ""
    var prev: TeamChatMessage?
    for m in msgs {
        let day = dayLabel(m.ts)
        if day != lastDay { rows.append(.day(day, rows.count)); lastDay = day; prev = nil }
        if m.from == "system" || m.kind == "status" {
            rows.append(.note(m)); prev = nil; continue
        }
        // 지시·보고·검토는 대상·꼬리표가 있어서 늘 머리줄을 단다 (말·사용자 글만 이어 붙인다)
        let plain = (m.kind == "say" || m.kind == "user")
        let sameSender = plain && (prev.map { $0.from == m.from && $0.kind == m.kind && m.ts - $0.ts < 300 } ?? false)
        rows.append(.msg(m, header: !(grouping && sameSender)))
        prev = m
    }
    if !typing.isEmpty { rows.append(.typing(typing)) }
    return rows
}

private struct SquadMessageList: View {
    let rows: [SquadRow]
    let emptyText: String
    let render: (SquadRow) -> AnyView
    @State private var pinned = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text(emptyText).font(.system(size: 12)).foregroundColor(SQ.dim)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(rows) { r in render(r).id(r.id) }
                    Color.clear.frame(height: 6).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .onChange(of: rows.count) { _ in scrollDown(proxy) }
            .onAppear { scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

private struct DayDivider: View {
    let label: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(SQ.line).frame(height: 1)
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(SQ.dim)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .overlay(Capsule().stroke(SQ.line, lineWidth: 1))
            Rectangle().fill(SQ.line).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct MessageRow<Content: View>: View {
    let icon: String
    let id: String
    let name: String
    let time: Double
    let header: Bool
    var tag: (String, Color)? = nil
    var sub: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if header { SquadAvatar(icon: icon, id: id) }
            else {
                Text(squadClock.string(from: Date(timeIntervalSince1970: time)))
                    .font(.system(size: 9)).foregroundColor(.buniDim).frame(width: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                if header {
                    HStack(spacing: 6) {
                        Text(name).font(.system(size: 13, weight: .bold))
                        if let sub { Text(sub).font(.system(size: 11)).foregroundColor(SQ.dim) }
                        if let tag {
                            Text(tag.0).font(.system(size: 9, weight: .heavy)).foregroundColor(tag.1)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(tag.1.opacity(0.18)))
                        }
                        Text(squadClock.string(from: Date(timeIntervalSince1970: time)))
                            .font(.system(size: 10)).foregroundColor(.buniDim)
                    }
                }
                content()
            }
            Spacer(minLength: 24)
        }
        .padding(.horizontal, 16).padding(.top, header ? 8 : 1).padding(.bottom, 1)
    }
}

private func kindTag(_ kind: String) -> (String, Color)? {
    switch kind {
    case "instruction": return (L.t("지시", "ORDER"), .orange)
    case "report":      return (L.t("보고", "REPORT"), .green)
    case "review":      return (L.t("검토", "REVIEW"), .blue)
    default: return nil
    }
}

private struct SystemNote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10.5)).foregroundColor(.buniDim)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 24).padding(.vertical, 3)
            .multilineTextAlignment(.center)
    }
}

private struct TypingRow: View {
    let who: String
    let people: SquadPeople
    var body: some View {
        HStack(spacing: 8) {
            SquadAvatar(icon: people.icon(who), id: who, size: 26)
            ProgressView().controlSize(.mini)
            Text(people.name(who) + L.t(" 이(가) 입력하는 중…", " is typing…")).font(.system(size: 11)).foregroundColor(SQ.dim)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}

// MARK: - 단체방

/// 단체 채널 — 결과·지시·검토를 한두 줄로 요약해 보여 준다. 여기서 말하면 팀장이 듣고 나눠 지시한다.
struct SquadChannelView: View {
    let job: TeamJob
    var onOpenDM: (String) -> Void
    var onSeen: () -> Void
    @ObservedObject private var store = TeamStore.shared

    var body: some View {
        let people = SquadPeople(job: job)
        TeamLive {
            let msgs = TeamStore.readChat(jobId: job.id)
            let typing = TeamStore.readTyping(jobId: job.id)
            VStack(spacing: 0) {
                SquadProposalCards(job: job)
                SquadMessageList(rows: buildRows(msgs, typing: typing),
                                 emptyText: L.t("아직 대화가 없어요. 팀이 일을 시작하면 지시와 보고 요약이 여기에 쌓여요.",
                                                "Nothing yet — summaries of instructions and reports will show up here."),
                                 render: { AnyView(row($0, people)) })
                    .onChange(of: msgs.count) { _ in onSeen() }
                    .onAppear { onSeen() }
                Divider().background(SQ.line)
                SquadComposerBar(
                    placeholder: L.t("#스쿼드 에 메시지 보내기 — 팀장이 듣고 필요한 팀원에게 나눠 지시해요",
                                     "Message #squad — the lead splits work among teammates"),
                    hint: L.t("Enter 보내기 · Shift+Enter 줄바꿈 · @이름 으로 한 팀원에게만 지시",
                              "Enter to send · Shift+Enter new line · @name to instruct one teammate"),
                    mentions: [("lead", people.name("lead"))] + (job.plan?.roles ?? []).map { ($0.id, $0.name ?? $0.id) },
                    disabled: job.state == "cancelled",
                    draftKey: TeamDrafts.key(job.id, "channel")
                ) { send($0, $1) }
            }
        }
    }

    /// '@이름 …' 이면 그 팀원에게만(첨부도 그 팀원에게만), 아니면 팀장이 듣고 나눠 지시한다
    private func send(_ text: String, _ files: [URL]) {
        let roles = job.plan?.roles ?? []
        if text.hasPrefix("@") {
            let body = String(text.dropFirst())
            if let r = roles.first(where: { body.hasPrefix($0.name ?? $0.id) }) {
                let rest = String(body.dropFirst((r.name ?? r.id).count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty || !files.isEmpty { store.sendRoleNote(job, role: r.id, text: rest, files: files); return }
            }
            if body.hasPrefix(L.t("팀장", "Lead")) {
                let rest = String(body.dropFirst(L.t("팀장", "Lead").count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty || !files.isEmpty { store.sendChat(job, to: "lead", text: rest, files: files); return }
            }
        }
        store.sendChat(job, to: "lead", text: text, files: files)
    }

    @ViewBuilder
    private func row(_ r: SquadRow, _ people: SquadPeople) -> some View {
        switch r {
        case .day(let label, _): DayDivider(label: label)
        case .typing(let who):   TypingRow(who: who, people: people)
        case .note(let m):
            SystemNote(text: noteText(m, people))
        case .msg(let m, let header):
            message(m, header: header, people: people)
        }
    }

    private func noteText(_ m: TeamChatMessage, _ people: SquadPeople) -> String {
        let who = m.from == "system" ? m.to : m.from
        let prefix = ["all", "user", "lead", "system", ""].contains(who) ? "" : "\(people.icon(who)) \(people.name(who)) · "
        return prefix + squadSummary(m.text, limit: 90).text
    }

    @ViewBuilder
    private func message(_ m: TeamChatMessage, header: Bool, people: SquadPeople) -> some View {
        let sum = squadSummary(m.text)
        switch m.kind {
        case "instruction", "report", "review":
            // 지시·보고·검토는 요약 + '상세 ›' (그 팀원의 DM 으로)
            let member = m.kind == "report" ? m.from : m.to
            let showsTo = m.kind != "report" && m.to != "lead" && m.to != "all"
            MessageRow(icon: people.icon(m.from), id: m.from, name: people.name(m.from), time: m.ts, header: header,
                       tag: kindTag(m.kind),
                       sub: showsTo ? "→ \(people.icon(m.to)) \(people.name(m.to))" : nil) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sum.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if (sum.more || m.kind != "review"), member != "lead", member != "all", member != "user" {
                        Button { onOpenDM(member) } label: {
                            Text(L.t("상세 보기 ›", "Details ›")).font(.system(size: 11, weight: .semibold)).foregroundColor(.buniInfo)
                        }.buttonStyle(.plain)
                    }
                    AttachmentStrip(jobId: job.id, items: m.attachments)
                }
            }
        default:
            let toRole = m.from == "user" && m.to != "lead" && m.to != "all" && m.to != "user"
            MessageRow(icon: people.icon(m.from), id: m.from, name: people.name(m.from), time: m.ts, header: header,
                       sub: toRole ? "→ \(people.icon(m.to)) \(people.name(m.to))" : nil) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    AttachmentStrip(jobId: job.id, items: m.attachments)
                }
            }
        }
    }
}

// MARK: - 개별 대화 (DM)

/// 팀장 또는 한 팀원과의 1:1 — 상세 지시·보고 전문, 그 팀원의 실시간 진행, 이 팀원에게만 보내는 입력창
struct SquadDMView: View {
    let job: TeamJob
    let who: String                     // "lead" 또는 팀원 id
    var onSeen: () -> Void
    @ObservedObject private var store = TeamStore.shared
    @State private var cardOpen = true

    private var isLead: Bool { who == "lead" }

    var body: some View {
        let people = SquadPeople(job: job)
        TeamLive {
            let msgs = filter(TeamStore.readChat(jobId: job.id))
            let typing = isLead ? TeamStore.readTyping(jobId: job.id) : ""
            VStack(spacing: 0) {
                if !isLead { memberCard(people) } else { SquadProposalCards(job: job) }
                SquadMessageList(rows: buildRows(msgs, typing: typing, grouping: false),
                                 emptyText: isLead
                                    ? L.t("팀장과 나눈 대화가 여기에 모여요. 아래에 적으면 팀장이 답하고 팀원에게 나눠 지시해요.",
                                          "Your conversation with the lead. The lead replies and delegates.")
                                    : L.t("아직 \(people.name(who))와 주고받은 대화가 없어요.", "No messages with \(people.name(who)) yet."),
                                 render: { AnyView(row($0, people)) })
                    .onChange(of: msgs.count) { _ in onSeen() }
                    .onAppear { onSeen() }
                Divider().background(SQ.line)
                SquadComposerBar(
                    placeholder: isLead
                        ? L.t("팀장에게 메시지 보내기", "Message the lead")
                        : L.t("\(people.name(who)) 에게만 지시하기", "Instruct \(people.name(who)) only"),
                    hint: isLead
                        ? L.t("팀장이 이해해서 답하고, 필요한 팀원에게 나눠 지시해요 (약 1분)",
                              "The lead replies and delegates as needed (about a minute)")
                        : hint,
                    disabled: job.state == "cancelled",
                    draftKey: TeamDrafts.key(job.id, isLead ? "lead" : "dm:" + who)
                ) { text, files in
                    if isLead { store.sendChat(job, to: "lead", text: text, files: files) }
                    else { store.sendRoleNote(job, role: who, text: text, files: files) }
                }
            }
        }
    }

    /// 이 대화에 속한 메시지만
    private func filter(_ all: [TeamChatMessage]) -> [TeamChatMessage] {
        if isLead {
            return all.filter { ($0.from == "user" && ($0.to == "lead" || $0.to == "all"))
                              || ($0.from == "lead" && $0.to == "user" && $0.kind != "status") }
        }
        return all.filter { $0.from == who || $0.to == who }
    }

    private var hint: String {
        switch job.roles?[who]?.status ?? "pending" {
        case "running":  return L.t("지금 하는 일이 끝나면 반영해서 다시 진행해요.", "Applied by redoing the work once this run finishes.")
        case "pending", "revise": return L.t("이 팀원이 시작할 때 반영해요.", "Applied when this teammate starts.")
        default: return L.t("이미 끝난 팀원이면 다시 열어 반영해요. 이 팀원의 산출물을 쓰는 팀원도 다시 확인해요.",
                            "If already done, it is reopened. Teammates relying on it re-check too.")
        }
    }

    // MARK: 팀원 카드 (미션 · 진행 · 세션)

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    @ViewBuilder
    private func memberCard(_ people: SquadPeople) -> some View {
        let role = job.plan?.roles?.first(where: { $0.id == who })
        let st = job.roles?[who]
        let (label, color) = roleInfo(st?.status ?? "pending")
        let act = TeamStore.readActivity(jobId: job.id, key: who)
        let sessions = TeamStore.readSessions(jobId: job.id).filter { $0.key == who }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let dl = role?.dutyLabel, !dl.isEmpty {
                    Chip(text: dl, color: .buniDim)
                }
                Chip(text: label + ((st?.attempts ?? 0) > 1 ? L.t("  (\(st!.attempts!)회)", "  (×\(st!.attempts!))") : ""), color: color)
                if st?.notePending == true {
                    Text(L.t("📨 반영 대기", "📨 queued")).font(.system(size: 10)).foregroundColor(.orange)
                }
                if let d = role?.dependsOn, !d.isEmpty {
                    Text("← " + d.map { people.name($0) }.joined(separator: ", ")).font(.system(size: 10)).foregroundColor(SQ.dim)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text(L.t("모델", "Model")).font(.system(size: 10)).foregroundColor(SQ.dim)
                    SquadModelMenu(model: Binding(get: { role?.model ?? "" },
                                                  set: { store.setRoleModel(job, role: who, model: $0) }),
                                   defaultLabel: L.t("기본 (\(squadModelName(store.settings.model)))", "Default (\(squadModelName(store.settings.model)))"))
                }
                if let last = sessions.last {
                    Button { store.openSession(job, sessionId: last.id) } label: {
                        Text(L.t("💻 Claude에서 열기", "💻 Open in Claude")).font(.system(size: 11, weight: .semibold))
                    }.buttonStyle(PillButtonStyle(color: .gray))
                }
                if sessions.count > 1 {
                    Menu(L.t("이전 세션 \(sessions.count - 1)개", "\(sessions.count - 1) earlier")) {
                        ForEach(sessions.dropLast().reversed()) { s in
                            Button(Self.clock.string(from: Date(timeIntervalSince1970: s.started)) + "  " + s.label) {
                                store.openSession(job, sessionId: s.id)
                            }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                Button { withAnimation(.easeOut(duration: 0.15)) { cardOpen.toggle() } } label: {
                    Image(systemName: cardOpen ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundColor(SQ.dim)
                }.buttonStyle(.plain)
            }
            if cardOpen {
                if let mission = role?.mission, !mission.isEmpty {
                    Text(mission).font(.system(size: 11.5)).foregroundColor(.buniInk2)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                activityBox(act)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.buniPanel)
        .overlay(Rectangle().fill(SQ.line).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    private func activityBox(_ act: TeamActivity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if act.lines.isEmpty {
                Text(L.t("아직 시작하지 않았어요.", "Not started yet.")).font(.system(size: 11)).foregroundColor(SQ.dim)
            } else {
                ForEach(Array(act.lines.suffix(6).enumerated()), id: \.offset) { _, l in
                    HStack(alignment: .top, spacing: 6) {
                        Text(Self.clock.string(from: Date(timeIntervalSince1970: l.ts)))
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.buniDim)
                        Text(l.text).font(.system(size: 11)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if act.state == "running" {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(L.t("지금 진행 중", "Working now")).font(.system(size: 10)).foregroundColor(.green) }
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.22)))
    }

    // MARK: 메시지

    @ViewBuilder
    private func row(_ r: SquadRow, _ people: SquadPeople) -> some View {
        switch r {
        case .day(let label, _): DayDivider(label: label)
        case .typing(let w):     TypingRow(who: w, people: people)
        case .note(let m):
            SystemNote(text: squadSummary(m.text, limit: 120).text)
        case .msg(let m, let header):
            MessageRow(icon: people.icon(m.from), id: m.from, name: people.name(m.from), time: m.ts, header: true || header,
                       tag: kindTag(m.kind),
                       sub: m.from == "lead" && m.to != who && m.to != "user" && m.to != "all" ? "→ \(people.name(m.to))" : nil) {
                VStack(alignment: .leading, spacing: 3) {
                    if m.kind == "report" || (m.kind == "say" && m.text.contains("\n")) {
                        MarkdownView(text: m.text)
                    } else {
                        Text(m.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    AttachmentStrip(jobId: job.id, items: m.attachments)
                }
            }
        }
    }
}

// MARK: - 사이드바 조각

struct SquadSectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .heavy)).foregroundColor(.buniDim)
            .textCase(.uppercase)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 3)
    }
}

/// 사이드바의 한 줄 (채널 · DM · 현황)
struct SquadNavRow: View {
    let selected: Bool
    var leading: AnyView
    let title: String
    var subtitle: String? = nil
    var subtitleColor: Color = SQ.dim
    var unread = 0
    var tint: Color? = nil          // 진행 중(초록)·확인 필요(주황)일 때 행 전체를 옅게 물들인다
    var spinner = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if spinner { ProgressView().controlSize(.mini).frame(width: 14) }
                leading.frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: unread > 0 || selected ? .bold : .regular))
                    .foregroundColor(selected || unread > 0 ? .buniInk : .buniInk2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let subtitle {
                    Text(subtitle).font(.system(size: 9.5)).foregroundColor(selected ? .buniInk2 : subtitleColor).lineLimit(1)
                }
                if unread > 0 {
                    Text("\(min(unread, 99))").font(.system(size: 10, weight: .heavy)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.buniDanger))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: BuniTheme.rSm)
                .fill(selected ? Color.buniRaised : (tint?.opacity(hover ? 0.26 : 0.18) ?? (hover ? SQ.hover : .clear))))
            .overlay(RoundedRectangle(cornerRadius: BuniTheme.rSm).stroke(selected ? Color.clear : (tint?.opacity(0.45) ?? Color.clear), lineWidth: 1))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// 팀원 옆 상태 점 (작업 중 · 검토 대기 · 통과 · 대기)
struct SquadPresence: View {
    let icon: String
    let id: String
    let color: Color
    let working: Bool
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            SquadAvatar(icon: icon, id: id, size: 20)
            Circle().fill(color).frame(width: 7, height: 7)
                .overlay(Circle().stroke(SQ.rail, lineWidth: 1.5))
                .opacity(working ? 1 : 0.9)
                .offset(x: 2, y: 2)
        }
    }
}

// MARK: - 모델 고르기

/// 쓸 수 있는 모델 목록 (엔진의 MODEL_CHOICES 와 같게)
let squadModelChoices: [(id: String, ko: String, en: String)] = [
    ("", "기본 모델", "Default"),
    ("claude-fable-5-1", "Fable 5.1", "Fable 5.1"),
    ("claude-opus-5-5", "Opus 5.5", "Opus 5.5"),
    ("claude-sonnet-5-5", "Sonnet 5.5", "Sonnet 5.5"),
    ("claude-haiku-5-5", "Haiku 5.5 (빠르고 저렴)", "Haiku 5.5 (fast, cheap)"),
]

func squadModelName(_ id: String, defaultLabel: String? = nil) -> String {
    if let c = squadModelChoices.first(where: { $0.id == id }) { return id.isEmpty ? (defaultLabel ?? L.t(c.ko, c.en)) : L.t(c.ko, c.en) }
    return id.isEmpty ? (defaultLabel ?? L.t("기본 모델", "Default")) : id
}

struct SquadModelMenu: View {
    @Binding var model: String
    var allowDefault = true
    var defaultLabel: String? = nil
    var body: some View {
        Menu {
            ForEach(squadModelChoices, id: \.id) { c in
                Button(c.id.isEmpty ? (defaultLabel ?? L.t(c.ko, c.en)) : L.t(c.ko, c.en)) { model = c.id }
            }
        } label: {
            Text(squadModelName(model, defaultLabel: defaultLabel))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

// MARK: - 사전요구서 변경 확인

/// 사전요구서의 기존 내용과 다른 요청이 있으면 위쪽에 카드로 띄우고, 내가 정해야 요구서를 고치고 지시를 보낸다
struct SquadProposalCards: View {
    let job: TeamJob
    @ObservedObject private var store = TeamStore.shared

    var body: some View {
        let pending = job.pendingProposals
        if !pending.isEmpty {
            VStack(spacing: 8) {
                ForEach(pending) { p in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L.t("✋ 사전요구서와 달라요 — 수정할까요?", "✋ This differs from the requirements — change them?"))
                            .font(.system(size: 12, weight: .heavy)).foregroundColor(.orange)
                        if let was = p.was, !was.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Text(L.t("기존", "Was")).font(.system(size: 10, weight: .bold)).foregroundColor(SQ.dim).frame(width: 30, alignment: .leading)
                                Text(was).font(.system(size: 12)).strikethrough().foregroundColor(.buniDim).textSelection(.enabled)
                            }
                        }
                        HStack(alignment: .top, spacing: 6) {
                            Text(L.t("바뀜", "Now")).font(.system(size: 10, weight: .bold)).foregroundColor(.green).frame(width: 30, alignment: .leading)
                            Text(p.now ?? "").font(.system(size: 12, weight: .semibold)).textSelection(.enabled)
                        }
                        if let why = p.why, !why.isEmpty { Text(why).font(.system(size: 11)).foregroundColor(SQ.dim) }
                        HStack {
                            Button { store.resolveReqProposal(job, id: p.id, accept: true) } label: {
                                Text(L.t("✅ 요구서를 수정하고 진행", "✅ Change it and go ahead"))
                            }.buttonStyle(PillButtonStyle(color: .accentColor))
                            Button { store.resolveReqProposal(job, id: p.id, accept: false) } label: {
                                Text(L.t("기존 유지", "Keep the original"))
                            }.buttonStyle(PillButtonStyle(color: .gray))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.45), lineWidth: 1))
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }
}

/// 지금 적용 중인 사전요구서 (채팅으로 추가·변경된 내용 포함)
struct SquadRequirementsView: View {
    let job: TeamJob
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SquadProposalCards(job: job).padding(.horizontal, -16)
                Text(L.t("채팅으로 새 방향을 말하면 아래 \"추가 방향\"에 들어가고, 기존 내용과 다르면 먼저 확인을 받아 고쳐요.",
                         "New directions from chat are added under \"Added directions\"; anything that conflicts is confirmed before the text changes."))
                    .font(.system(size: 11)).foregroundColor(SQ.dim).fixedSize(horizontal: false, vertical: true)
                MarkdownView(text: job.requirements ?? "")
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
