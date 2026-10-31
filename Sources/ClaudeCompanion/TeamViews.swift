import SwiftUI
import AppKit

// MARK: - 창

@MainActor
final class TeamWindowController {
    static let shared = TeamWindowController()
    private var window: NSWindow?

    func show(jobId: String? = nil) {
        if window == nil {
            let hc = NSHostingController(rootView: TeamRootView(initialSelection: jobId))
            let w = NSWindow(contentViewController: hc)
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.title = L.t("부니 스쿼드", "Buni Squad")
            w.setContentSize(NSSize(width: 1120, height: 740))
            w.contentMinSize = NSSize(width: 900, height: 600)
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        else if let jobId { TeamStore.shared.focusJobId = jobId }      // 이미 열려 있으면 그 작업으로 옮긴다
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 단축키용 — 앞에 떠 있으면 닫고, 아니면(없거나 가려졌으면) 앞으로 연다
    func toggle() {
        if let w = window, w.isVisible, w.isKeyWindow, NSApp.isActive { w.close() }
        else { show() }
    }
}

// MARK: - 상태 이름 · 색

func statusInfo(_ s: String) -> (String, Color) {
    switch s {
    case "draft":               return (L.t("작성 중", "Draft"), .gray)
    case "interviewing":        return (L.t("질문 답변 중", "Answering"), .orange)
    case "review_requirements": return (L.t("요구서 승인 대기", "Awaiting approval"), .orange)
    case "queued":              return (L.t("예약됨", "Scheduled"), .blue)
    case "running":             return (L.t("진행 중", "Running"), .green)
    case "waiting_limit":       return (L.t("한도 대기", "Waiting (limit)"), .orange)
    case "paused":              return (L.t("잠시 멈춤", "Paused"), .orange)
    case "review":              return (L.t("검토 대기", "Ready to review"), .green)
    case "done":                return (L.t("검토 완료", "Done"), .gray)
    case "failed":              return (L.t("실패", "Failed"), .red)
    case "cancelled":           return (L.t("취소됨", "Cancelled"), .gray)
    default:                    return (s, .gray)
    }
}

func roleInfo(_ s: String) -> (String, Color) {
    switch s {
    case "running":         return (L.t("작업 중", "Working"), .green)
    case "done_unreviewed": return (L.t("검토 대기", "In review"), .orange)
    case "revise":          return (L.t("다시 작업", "Revising"), .orange)
    case "accepted":        return (L.t("통과", "Accepted"), .green)
    default:                return (L.t("대기", "Waiting"), .gray)
    }
}

/// 일하는 중 표시 — `ProgressView()` 는 쉬지 않고 화면을 다시 그려(디스플레이 링크) 배터리를 먹는다.
/// 0.5초마다 글자 하나만 바꾸는 이 표시는 창이 가려져 있으면 아예 그리지 않는다.
struct BuniSpinner: View {
    var size: CGFloat = 11
    private static let frames = ["◐", "◓", "◑", "◒"]
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            Text(Self.frames[Int(ctx.date.timeIntervalSinceReferenceDate / 0.5) % 4])
                .font(.system(size: size, weight: .bold)).foregroundColor(BT.accentText)
                .frame(width: size + 3)
        }
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var body: some View {
        Text("● " + text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
    }
}

// MARK: - 시간 도우미

private func minutes(_ hhmm: String) -> Int? {
    let p = hhmm.split(separator: ":")
    guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0...24).contains(h), (0..<60).contains(m) else { return nil }
    return (h % 24) * 60 + m
}

private func inWindow(_ now: Date, _ s: TeamSettings) -> Bool {
    guard let a = minutes(s.windowStart), let b = minutes(s.windowEnd) else { return false }
    let c = Calendar.current.dateComponents([.hour, .minute], from: now)
    let cur = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    if a == b { return true }
    return a < b ? (a <= cur && cur < b) : (cur >= a || cur < b)
}

private func nextWindowStart(_ now: Date, _ s: TeamSettings) -> Date? {
    guard let a = minutes(s.windowStart) else { return nil }
    var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
    comps.hour = a / 60; comps.minute = a % 60
    guard var d = Calendar.current.date(from: comps) else { return nil }
    if d <= now { d = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d }
    return d
}

private let shortDate: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f
}()

// MARK: - 루트 (슬랙처럼: 왼쪽에 프로젝트 → 채널 · 다이렉트 메시지, 오른쪽에 대화)

/// 오른쪽에 보여 줄 화면
enum SquadPane: Hashable {
    case overview            // 질문 · 요구서 · 진행 현황 · 결과 보고서
    case channel             // 단체방
    case requirements        // 지금 적용 중인 사전요구서
    case lead                // 팀장과 1:1
    case dm(String)          // 팀원과 1:1
    var key: String {
        switch self {
        case .overview: return "overview"
        case .channel:  return "channel"
        case .requirements: return "requirements"
        case .lead:     return "lead"
        case .dm(let r): return "dm:" + r
        }
    }
}

struct TeamRootView: View {
    @ObservedObject private var store = TeamStore.shared
    @ObservedObject private var lang = LanguageStore.shared
    @State private var selection: String?
    @State private var pane: [String: SquadPane] = [:]
    @State private var seen: [String: Double] = [:]          // "작업|화면" → 마지막으로 본 시각
    @State private var openedAt: [String: Double] = [:]      // 작업을 처음 연 시각 (이전 대화는 안 읽음으로 치지 않는다)
    @State private var showSettings = false
    @State private var settingsJob: TeamJob?                  // 프로젝트 설정 (모델) 시트
    @State private var showArchived = false                   // 보관된 팀원 보기
    @State private var boardOn = false                        // 현황 모니터링 화면

    init(initialSelection: String? = nil, initialPane: SquadPane? = nil) {
        _selection = State(initialValue: initialSelection)
        if let id = initialSelection, let p = initialPane { _pane = State(initialValue: [id: p]) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let problem = store.problem {
                Text("⚠ " + problem)
                    .font(.system(size: 11)).foregroundColor(.white)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.35))
            }
            HStack(spacing: 0) {
                sidebar.frame(width: 272)
                Rectangle().fill(SQ.line).frame(width: 1)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity).background(SQ.main)
            }
        }
        .background(SQ.main)
        .sheet(isPresented: $showSettings) { TeamSettingsSheet(isPresented: $showSettings) }
        .task {
            // 확인이 필요한 작업(반영 승인 대기 등)을 사이드바에 표시하려고 가끔 다시 본다
            while !Task.isCancelled {
                store.refreshAllApplyStates()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        .sheet(item: $settingsJob) { j in ProjectSettingsSheet(job: j) { settingsJob = nil } }
        .onAppear {
            if selection == nil, let j = store.jobs.last(where: { $0.state == "review" }) ?? store.jobs.last { selection = j.id }
            if let id = selection { touch(id) }
        }
        .onChange(of: selection) { id in if let id { touch(id) } }
        .onReceive(store.$focusJobId) { id in
            if let id { selection = id; boardOn = false; store.focusJobId = nil }
        }
    }

    private func touch(_ id: String) {
        if openedAt[id] == nil { openedAt[id] = Date().timeIntervalSince1970 }
    }

    private func hasRoom(_ j: TeamJob) -> Bool {
        j.plan != nil && ["queued", "running", "waiting_limit", "paused", "review", "done", "failed"].contains(j.state)
    }

    private func currentPane(_ j: TeamJob) -> SquadPane {
        if let p = pane[j.id] {
            if p == .overview || hasRoom(j) { return p }
            return .overview
        }
        return hasRoom(j) && ["queued", "running", "waiting_limit", "paused"].contains(j.state) ? .channel : .overview
    }

    private func markSeen(_ jobId: String, _ p: SquadPane) {
        seen[jobId + "|" + p.key] = Date().timeIntervalSince1970
    }

    // MARK: 사이드바

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L.t("🐰 부니 스쿼드", "🐰 Buni Squad")).font(.system(size: 15, weight: .heavy))
                Spacer()
                Button { store.setGlobalPause(!store.settings.paused) } label: {
                    Image(systemName: store.settings.paused ? "play.circle.fill" : "pause.circle")
                        .font(.system(size: 15)).foregroundColor(store.settings.paused ? BT.warning : .white.opacity(0.7))
                }.buttonStyle(.plain).help(store.settings.paused ? L.t("모든 작업 이어서 진행", "Resume all squad work") : L.t("모든 작업 잠시 멈추기", "Pause all squad work"))
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 13)).foregroundColor(.buniInk2)
                }.buttonStyle(.plain).help(L.t("스쿼드 설정", "Squad settings"))
                Button { selection = nil; boardOn = false } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 13)).foregroundColor(.buniInk)
                        .frame(width: 26, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(Color.buniRaised))
                }.buttonStyle(.plain).help(L.t("새 작업", "New job"))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Rectangle().fill(SQ.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    boardRow
                    SquadSectionTitle(text: L.t("프로젝트", "Projects"))
                    if store.jobs.isEmpty {
                        Text(L.t("아직 작업이 없어요.\n위의 ✎ 버튼으로 시작해 보세요.", "No jobs yet.\nStart with the ✎ button."))
                            .font(.system(size: 11)).foregroundColor(SQ.dim).padding(.horizontal, 16).padding(.top, 6)
                    }
                    ForEach(store.jobs.reversed()) { j in
                        projectRow(j)
                        if selection == j.id { children(j) }
                    }
                }
                .padding(.bottom, 12)
            }

            Rectangle().fill(SQ.line).frame(height: 1)
            let s = store.settings
            Text(s.paused ? L.t("⏸ 전체 일시정지 중", "⏸ All work paused")
                 : (s.scheduleMode == "anytime" ? L.t("⚡ 언제든 자동 진행 · 동시 \(s.concurrency)명", "⚡ Auto-run any time · \(s.concurrency) at a time")
                    : (s.scheduleMode == "window" ? L.t("🌙 \(s.windowStart)~\(s.windowEnd) 자동 진행 · 동시 \(s.concurrency)명", "🌙 Auto-run \(s.windowStart)–\(s.windowEnd) · \(s.concurrency) at a time")
                       : L.t("내가 시작할 때만 진행해요", "Runs only when I start it"))))
                .font(.system(size: 10)).foregroundColor(.buniDim)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(SQ.rail)
    }

    /// 사이드바 맨 위 — 모든 작업의 현황을 한눈에 (막힘이 있으면 숫자로 알린다)
    private var boardRow: some View {
        let blocked = SquadBoard.items(store.jobs).filter { $0.column == .blocked }.count
        return SquadNavRow(selected: boardOn,
                           leading: AnyView(Text("📊").font(.system(size: 12))),
                           title: L.t("전체 현황", "Overview"),
                           subtitle: L.t("보드 · 목록", "Board · List"),
                           unread: blocked) { boardOn = true }
    }

    private func projectRow(_ j: TeamJob) -> some View {
        let (name, color) = statusInfo(j.state)
        let open = selection == j.id && !boardOn
        let working = j.state == "running" && !store.settings.paused
        let attention = store.needsAttention(j)
        let tint: Color? = attention != nil ? BT.warning : (working ? BT.success : nil)
        return Button { selection = j.id; boardOn = false } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    .foregroundColor(.buniDim).frame(width: 12)
                Text(j.displayTitle).font(.system(size: 13, weight: open || j.state == "review" || tint != nil ? .bold : .medium))
                    .foregroundColor(Color.buniInk.opacity(open || tint != nil ? 1 : 0.85)).lineLimit(1)
                Spacer(minLength: 4)
                if working { BuniSpinner() }
                if let attention { Text(attention).font(.system(size: 9, weight: .bold)).foregroundColor(BT.warning).lineLimit(1) }
                Circle().fill(color).frame(width: 7, height: 7).help(name)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill((tint ?? .clear).opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke((tint ?? .clear).opacity(0.5), lineWidth: tint == nil ? 0 : 1))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L.t("이름 수정", "Rename")) { promptRename(j) }
            Button(L.t("프로젝트 설정", "Project settings")) { settingsJob = j }
            Divider()
            Button(L.t("삭제", "Delete")) { confirmDelete(j) }
        }
    }

    private func promptRename(_ j: TeamJob) {
        let a = NSAlert()
        a.messageText = L.t("프로젝트 이름 수정", "Rename project")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = j.displayTitle
        a.accessoryView = field
        a.addButton(withTitle: L.t("저장", "Save"))
        a.addButton(withTitle: L.t("취소", "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            let e = NSAlert(); e.messageText = L.t("이름을 비워 둘 수 없어요", "The name can't be empty"); e.runModal(); return
        }
        store.rename(j, to: t)
    }

    private func confirmDelete(_ j: TeamJob) {
        if j.state == "running" || j.busy == true {                 // 진행 중이면 거부 — 먼저 취소해야 한다
            let e = NSAlert()
            e.messageText = L.t("진행 중인 프로젝트예요", "This project is running")
            e.informativeText = L.t("먼저 취소한 뒤 삭제해 주세요.", "Cancel it first, then delete.")
            e.runModal(); return
        }
        let a = NSAlert()
        a.messageText = L.t("'\(j.displayTitle)' 프로젝트를 삭제할까요?", "Delete project '\(j.displayTitle)'?")
        a.informativeText = L.t("이 작업 기록을 지워요. (git 브랜치와 결과 파일은 남아요)", "Deletes this job record. (the git branch and result files remain)")
        a.alertStyle = .warning
        a.addButton(withTitle: L.t("삭제", "Delete"))
        a.addButton(withTitle: L.t("취소", "Cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.delete(j)
        if selection == j.id { selection = nil }
    }

    @ViewBuilder
    private func children(_ j: TeamJob) -> some View {
        let cur = currentPane(j)
        let (stateName, _) = statusInfo(j.state)
        let overviewTitle: String = {
            switch j.state {
            case "draft", "interviewing": return L.t("질문", "Questions")
            case "review_requirements":   return L.t("요구서", "Requirements")
            default:                      return L.t("프로젝트 현황", "Project status")
            }
        }()
        let attention = store.needsAttention(j)
        SquadNavRow(selected: cur == .overview,
                    leading: AnyView(Text(["draft", "interviewing", "review_requirements"].contains(j.state) ? "📋" : "🗂").font(.system(size: 12))),
                    title: overviewTitle, subtitle: attention ?? stateName,
                    subtitleColor: attention != nil ? BT.warning : SQ.dim,
                    unread: 0, tint: attention != nil ? BT.warning : (j.state == "running" && !store.settings.paused ? BT.success : nil),
                    spinner: j.state == "running" && attention == nil && !store.settings.paused) { pane[j.id] = .overview; boardOn = false }

        if j.requirements?.isEmpty == false {
            SquadNavRow(selected: cur == .requirements,
                        leading: AnyView(Text("📝").font(.system(size: 12))),
                        title: L.t("사전요구서", "Requirements"),
                        subtitle: j.pendingProposals.isEmpty ? nil : L.t("✋ 확인 필요", "✋ Confirm"),
                        subtitleColor: .orange,
                        unread: j.pendingProposals.count) { pane[j.id] = .requirements; boardOn = false }
        }
        if hasRoom(j) {
            TeamLive {
                let msgs = TeamStore.readChat(jobId: j.id)
                VStack(alignment: .leading, spacing: 1) {
                    SquadSectionTitle(text: L.t("채널", "Channels"))
                    SquadNavRow(selected: cur == .channel,
                                leading: AnyView(Text("#").font(.system(size: 15, weight: .bold)).foregroundColor(.buniDim)),
                                title: L.t("스쿼드", "squad"),
                                unread: unread(j, .channel, msgs)) { pane[j.id] = .channel; boardOn = false }

                    SquadSectionTitle(text: L.t("다이렉트 메시지", "Direct messages"))
                    SquadNavRow(selected: cur == .lead,
                                leading: AnyView(SquadAvatar(icon: "🐰", id: "lead", size: 20)),
                                title: L.t("팀장", "Team lead"), subtitle: leadStatus(j),
                                unread: unread(j, .lead, msgs)) { pane[j.id] = .lead; boardOn = false }
                    ForEach(TeamDuties.grouped(visibleRoles(j)), id: \.dept) { g in
                        SquadSectionTitle(text: g.name)
                        ForEach(g.members) { r in
                            let st = j.roles?[r.id]
                            let (label, color) = roleInfo(st?.status ?? "pending")
                            SquadNavRow(selected: cur == .dm(r.id),
                                        leading: AnyView(SquadPresence(icon: r.icon ?? "🧑‍💻", id: r.id, color: color,
                                                                      working: st?.status == "running")),
                                        title: r.name ?? r.id,
                                        subtitle: r.isArchived ? L.t("보관됨", "archived") : label,
                                        subtitleColor: color.opacity(0.9),
                                        unread: unread(j, .dm(r.id), msgs),
                                        tint: st?.status == "running" ? BT.success : (st?.status == "done_unreviewed" ? BT.warning : nil),
                                        spinner: st?.status == "running") { pane[j.id] = .dm(r.id); boardOn = false }
                                .opacity(r.isArchived ? 0.55 : 1)
                        }
                    }
                    let archivedCount = (j.plan?.roles ?? []).filter { $0.isArchived && !isWorking(j, $0) }.count
                    if archivedCount > 0 {
                        Button { showArchived.toggle() } label: {
                            Text(showArchived ? L.t("보관된 팀원 숨기기", "Hide archived teammates")
                                              : L.t("보관된 팀원 보기 (\(archivedCount))", "Show archived teammates (\(archivedCount))"))
                                .font(.system(size: 10.5)).foregroundColor(.buniDim)
                                .padding(.horizontal, 16).padding(.vertical, 4)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 사이드바에 보일 팀원 — 보관된 팀원은 토글을 켜거나 다시 일하는 중일 때만 (docs/team-structure.md §5)
    private func visibleRoles(_ j: TeamJob) -> [TeamRole] {
        (j.plan?.roles ?? []).filter { !$0.isArchived || showArchived || isWorking(j, $0) }
    }
    private func isWorking(_ j: TeamJob, _ r: TeamRole) -> Bool { j.roles?[r.id]?.status == "running" }

    private func leadStatus(_ j: TeamJob) -> String {
        switch j.phase {
        case "planning":  return L.t("팀 구성 중", "Planning")
        case "reviewing": return L.t("검토 중", "Reviewing")
        case "merging":   return L.t("합치는 중", "Merging")
        case "wrapup":    return L.t("정리 중", "Wrapping up")
        default:          return ""
        }
    }

    /// 마지막으로 본 뒤 도착한 (내가 쓰지 않은) 메시지 수
    private func unread(_ j: TeamJob, _ p: SquadPane, _ msgs: [TeamChatMessage]) -> Int {
        if currentPane(j) == p { return 0 }
        let since = seen[j.id + "|" + p.key] ?? openedAt[j.id] ?? Date().timeIntervalSince1970
        return msgs.filter { m in
            guard m.ts > since, m.from != "user", m.from != "system", m.kind != "status" else { return false }
            switch p {
            case .channel:  return true
            case .lead:     return m.from == "lead" && m.to == "user" && m.kind == "say"
            case .dm(let r): return m.from == r || (m.from == "lead" && m.to == r)
            case .overview, .requirements: return false
            }
        }.count
    }

    // MARK: 오른쪽

    @ViewBuilder
    private var detail: some View {
        if boardOn {
            SquadBoardView { item, p in                 // 상세에서 같은 프로젝트의 화면으로 (새 프로젝트를 만들지 않는다)
                selection = item.jobId
                pane[item.jobId] = p
                boardOn = false
            }
        } else if let id = selection, let job = store.jobs.first(where: { $0.id == id }) {
            let p = currentPane(job)
            VStack(spacing: 0) {
                header(job, p)
                Rectangle().fill(SQ.line).frame(height: 1)
                switch p {
                case .overview:
                    TeamJobDetail(job: job, onDeleted: { selection = nil }, onOpenDM: { pane[job.id] = .dm($0) })
                        .id(job.id + job.state + (job.busy == true ? "b" : ""))
                case .requirements:
                    SquadRequirementsView(job: job).id(job.id + "req" + String(job.requirements?.count ?? 0))
                case .channel:
                    SquadChannelView(job: job, onOpenDM: { pane[job.id] = .dm($0) }, onSeen: { markSeen(job.id, .channel) })
                        .id(job.id + "channel")
                case .lead:
                    SquadDMView(job: job, who: "lead", onSeen: { markSeen(job.id, .lead) }).id(job.id + "lead")
                case .dm(let r):
                    SquadDMView(job: job, who: r, onSeen: { markSeen(job.id, p) }).id(job.id + "dm" + r)
                }
            }
        } else {
            TeamNewJob(onCreated: { selection = $0 }, blocked: store.problem != nil)
        }
    }

    @ViewBuilder
    private func header(_ job: TeamJob, _ p: SquadPane) -> some View {
        let people = SquadPeople(job: job)
        let (stateName, stateColor) = statusInfo(job.state)
        HStack(spacing: 10) {
            switch p {
            case .overview:
                Text(job.displayTitle).font(.system(size: 15, weight: .heavy)).lineLimit(1)
                Chip(text: stateName, color: stateColor)
            case .requirements:
                Text("📝 " + L.t("사전요구서", "Requirements")).font(.system(size: 15, weight: .heavy))
                Text(job.displayTitle).font(.system(size: 11)).foregroundColor(SQ.dim).lineLimit(1)
            case .channel:
                Text("# " + L.t("스쿼드", "squad")).font(.system(size: 15, weight: .heavy))
                Text(L.t("\(job.displayTitle) · 팀원 \(job.plan?.roles?.count ?? 0)명", "\(job.displayTitle) · \(job.plan?.roles?.count ?? 0) teammates"))
                    .font(.system(size: 11)).foregroundColor(SQ.dim).lineLimit(1)
                Spacer()
                HStack(spacing: -6) {
                    SquadAvatar(icon: "🐰", id: "lead", size: 24)
                    ForEach((job.plan?.roles ?? []).prefix(6)) { r in SquadAvatar(icon: r.icon ?? "🧑‍💻", id: r.id, size: 24) }
                }
            case .lead:
                SquadAvatar(icon: "🐰", id: "lead", size: 26)
                Text(L.t("팀장", "Team lead")).font(.system(size: 15, weight: .heavy))
                Text(leadStatus(job)).font(.system(size: 11)).foregroundColor(SQ.dim)
            case .dm(let r):
                let st = job.roles?[r]
                let (label, color) = roleInfo(st?.status ?? "pending")
                SquadAvatar(icon: people.icon(r), id: r, size: 26)
                Text(people.name(r)).font(.system(size: 15, weight: .heavy))
                Chip(text: label, color: color)
            }
            if p != .channel { Spacer() }
        }
        .padding(.horizontal, 16).frame(height: 46)
    }
}

// MARK: - 새 작업

private struct TeamNewJob: View {
    var onCreated: (String) -> Void
    var blocked: Bool
    @State private var title = ""
    @State private var goal = ""
    @State private var project = ""
    @State private var web = false
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L.t("새 스쿼드 작업", "New squad job")).font(.system(size: 17, weight: .bold))
                Text(L.t("팀장 Claude가 필요한 역할(디자인·개발·마케팅 …)을 정해 일을 나누고, 검토하고, 합쳐서 결과물을 만들어요.\n"
                         + "사람이 없는 시간대에 진행하므로, 시작 전에 먼저 필요한 것을 질문해서 \"사전요구서\"로 확정해요.",
                         "A team-lead Claude picks the roles it needs, splits the work, reviews and merges the results.\n"
                         + "It runs while you are away, so it first asks what it needs and fixes it in a \"requirements\" document."))
                    .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

                field(L.t("제목", "Title")) { TextField("", text: $title).textFieldStyle(.roundedBorder) }
                field(L.t("맡길 내용 (자세할수록 좋아요)", "What to build (the more detail the better)")) {
                    TextEditor(text: $goal).font(.system(size: 12)).frame(height: 130)
                        .padding(4).background(RoundedRectangle(cornerRadius: 6).fill(Color.buniField))
                }
                field(L.t("프로젝트 폴더", "Project folder")) {
                    HStack {
                        TextField("", text: $project).textFieldStyle(.roundedBorder)
                        Button(L.t("찾아보기…", "Browse…")) { chooseFolder() }
                    }
                }
                Toggle(L.t("웹 검색 허용 (시장 조사·자료 찾기가 필요할 때)", "Allow web search (for research)"), isOn: $web)
                Text(L.t("안전 장치: 프로젝트 폴더 안에서만 작업하고, 파일 삭제·프로그램 설치·외부 전송은 막아요. 결과는 새 git 브랜치(buni/…)에 모아요.",
                         "Safety: works only inside the project folder; deleting files, installing software and sending data out are blocked. Results go to a new git branch (buni/…)."))
                    .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { create() } label: { Text(creating ? L.t("만드는 중…", "Creating…") : L.t("사전요구서 만들기 →", "Create requirements →")) }
                    .buttonStyle(PillButtonStyle(color: .accentColor))
                    .disabled(creating || blocked || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || project.isEmpty)
            }
            .padding(22)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold))
            content()
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { project = u.path }
    }

    private func create() {
        creating = true
        Task { @MainActor in
            if let j = await TeamStore.shared.create(title: title, goal: goal, project: project, web: web) { onCreated(j.id) }
            creating = false
        }
    }
}

// MARK: - 작업 상세

private struct TeamJobDetail: View {
    let job: TeamJob
    var onDeleted: () -> Void
    var onOpenDM: (String) -> Void = { _ in }
    @ObservedObject private var store = TeamStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let g = job.goal, !g.isEmpty {
                    Text(g.count > 200 ? String(g.prefix(198)) + "…" : g)
                        .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let ex = job.extraRequests, !ex.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(ex.enumerated()), id: \.offset) { _, e in
                            Text("➕ " + (e.text ?? "")).font(.system(size: 11)).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if let e = job.error, !e.isEmpty, job.state != "failed" {
                    Text("⚠ " + e).font(.system(size: 12)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(22)
        }
    }

    private var content: some View { statusContent }

    @ViewBuilder
    private var statusContent: some View {
        if job.busy == true, ["draft", "interviewing", "review_requirements"].contains(job.state) {
            VStack(alignment: .leading, spacing: 6) {
                HStack { BuniSpinner(); Text(job.busyMsg?.isEmpty == false ? job.busyMsg! : L.t("Claude가 작업 중…", "Claude is working…")).font(.system(size: 13)) }
                Text(L.t("보통 1~2분 걸려요. 창을 닫아도 계속돼요.", "Usually takes a minute or two. It continues if you close this window."))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                TeamCancelButton(job: job).padding(.top, 6)
            }.padding(.top, 8)
        } else {
            switch job.state {
            case "draft", "interviewing":
                if job.questions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L.t("질문을 아직 받지 못했어요.", "No questions yet.")).foregroundColor(.secondary)
                        HStack {
                            Button(L.t("🔁 다시 시도", "🔁 Retry")) { store.retryInterview(job) }.buttonStyle(PillButtonStyle(color: .accentColor))
                            TeamCancelButton(job: job)
                        }
                        if job.state == "interviewing" {
                            TeamAddRequestBox(button: L.t("➕ 요청 추가하고 질문 다시 받기", "➕ Add request & re-ask")) { text in
                                store.addRequest(job, text: text)
                            }
                        }
                    }
                } else { TeamQuestionsForm(job: job) }
            case "review_requirements": TeamRequirements(job: job, onDeleted: onDeleted)
            case "queued", "paused", "waiting_limit", "running", "review", "done":
                SquadProjectBoard(job: job, onOpenDM: onOpenDM)
            default: // failed / cancelled
                VStack(alignment: .leading, spacing: 10) {
                    Text(job.error?.isEmpty == false ? job.error! : L.t("취소된 작업이에요.", "This job was cancelled."))
                        .foregroundColor(job.state == "failed" ? .red : .secondary).fixedSize(horizontal: false, vertical: true)
                    TeamEvents(job: job, count: 6)
                    HStack {
                        if job.requirements?.isEmpty == false {
                            Button(L.t("🔁 다시 시도", "🔁 Retry")) { store.retry(job) }.buttonStyle(PillButtonStyle(color: .accentColor))
                        } else {
                            Button(L.t("↩ 질문부터 다시", "↩ Start over")) { store.restartInterview(job) }.buttonStyle(PillButtonStyle(color: .accentColor))
                        }
                        Button(L.t("🗑 삭제", "🗑 Delete")) { store.delete(job); onDeleted() }.buttonStyle(PillButtonStyle(color: .gray))
                    }
                }
            }
        }
    }
}

// MARK: 공용: 프로젝트 취소 · 요청 추가

/// 어느 단계에서든 프로젝트를 취소한다 (되돌릴 수 없어서 한 번 더 확인)
struct TeamCancelButton: View {
    let job: TeamJob
    var body: some View {
        Button(L.t("⛔ 프로젝트 취소", "⛔ Cancel project")) {
            let a = NSAlert()
            a.messageText = L.t("이 프로젝트를 취소할까요?", "Cancel this project?")
            a.informativeText = job.state == "running"
                ? L.t("진행 중인 팀원 작업을 멈춰요. 지금까지 만든 결과와 git 브랜치는 그대로 남아요.",
                      "Running work stops. What's been made so far and the git branch stay.")
                : L.t("질문·사전요구서 작업을 멈춰요. 나중에 '질문부터 다시'로 다시 시작할 수 있어요.",
                      "Question and requirements work stops. You can start over later.")
            a.addButton(withTitle: L.t("프로젝트 취소", "Cancel project"))
            a.addButton(withTitle: L.t("계속 진행", "Keep going"))
            a.alertStyle = .warning
            if a.runModal() == .alertFirstButtonReturn { TeamStore.shared.cancel(job) }
        }.buttonStyle(PillButtonStyle(color: .gray))
    }
}

/// 요청을 새로 적어 보내는 상자
private struct TeamAddRequestBox: View {
    var button: String
    var hint: String = ""
    var onSend: (String) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !hint.isEmpty { Text(hint).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
            TextEditor(text: $text).font(.system(size: 12)).frame(height: 60)
                .padding(4).background(RoundedRectangle(cornerRadius: 6).fill(Color.buniField))
            Button(button) {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return }
                text = ""
                onSend(t)
            }
            .buttonStyle(PillButtonStyle(color: .gray))
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.buniPanel))
    }
}

// MARK: 질문

private struct TeamQuestionsForm: View {
    let job: TeamJob
    @State private var picked: [String: String] = [:]
    @State private var custom: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let u = job.interview?.understanding, !u.isEmpty {
                Text(L.t("이해한 내용: ", "Understanding: ") + u).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(L.t("새벽에는 아무도 대답할 수 없어요. 아래 질문에 미리 답해 주세요. 모르겠으면 추천값 그대로 두면 돼요.",
                     "Nobody can answer at night. Please answer these now — leave the suggested value if unsure."))
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            ForEach(job.questions) { q in
                VStack(alignment: .leading, spacing: 5) {
                    Text(q.question ?? "").font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if let w = q.why, !w.isEmpty { Text(w).font(.system(size: 10)).foregroundColor(.secondary) }
                    ForEach(q.options ?? [], id: \.self) { opt in
                        Button { picked[q.id] = opt; custom[q.id] = "" } label: {
                            HStack(spacing: 6) {
                                Image(systemName: current(q) == opt && (custom[q.id] ?? "").isEmpty ? "largecircle.fill.circle" : "circle")
                                Text(opt).font(.system(size: 12))
                                if opt == q.default { Text(L.t("추천", "suggested")).font(.system(size: 9)).foregroundColor(.secondary) }
                            }
                        }.buttonStyle(.plain)
                    }
                    TextField(L.t("직접 입력", "Other"), text: Binding(get: { custom[q.id] ?? "" }, set: { custom[q.id] = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.buniField))
            }
            HStack {
                Button(L.t("답변 보내기 →", "Send answers →")) { TeamStore.shared.answer(job, answers: collected()) }
                    .buttonStyle(PillButtonStyle(color: .accentColor))
                Spacer()
                TeamCancelButton(job: job)
            }
            TeamAddRequestBox(button: L.t("➕ 요청 추가하고 질문 다시 받기", "➕ Add request & re-ask"),
                              hint: L.t("빠뜨린 요구사항이 있나요? 적어 주면 지금까지 적은 답과 함께 팀장에게 전달하고, 그에 맞는 질문을 다시 받아요.",
                                        "Missed something? Add it — it goes to the lead with your answers so far, and you'll get matching questions.")) { text in
                TeamStore.shared.addRequest(job, text: text, answers: collected())
            }
        }
    }

    /// 지금까지 고른·적은 답 (비운 질문은 추천값)
    private func collected() -> [String: String] {
        var data: [String: String] = [:]
        for q in job.questions {
            let c = (custom[q.id] ?? "").trimmingCharacters(in: .whitespaces)
            data[q.id] = c.isEmpty ? current(q) : c
        }
        return data
    }

    private func current(_ q: TeamQuestion) -> String {
        picked[q.id] ?? q.default ?? (q.options?.first ?? "")
    }
}

// MARK: 사전요구서

private struct TeamRequirements: View {
    let job: TeamJob
    var onDeleted: () -> Void
    @State private var text: String
    @ObservedObject private var store = TeamStore.shared

    init(job: TeamJob, onDeleted: @escaping () -> Void) {
        self.job = job; self.onDeleted = onDeleted
        _text = State(initialValue: job.requirements ?? "")
    }

    var body: some View {
        let s = store.settings
        VStack(alignment: .leading, spacing: 10) {
            Text(L.t("사전요구서 — 팀이 새벽에 이 문서만 보고 일해요. 읽어 보고 고칠 곳이 있으면 직접 고쳐도 돼요.",
                     "Requirements — the team works from this document alone at night. Edit it if needed."))
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).frame(minHeight: 300)
                .padding(4).background(RoundedRectangle(cornerRadius: 6).fill(Color.buniField))
            Text(L.t("바로 시작하면 지금 곧 일을 시작하고, 예약을 고르면 \(s.windowStart)~\(s.windowEnd) 사이에 자동으로 시작해요. 웹 검색: \(job.permissions?.web == true ? "허용" : "안 함").",
                     "Start now begins right away; schedule starts automatically between \(s.windowStart) and \(s.windowEnd). Web search: \(job.permissions?.web == true ? "allowed" : "off")."))
                .font(.system(size: 11)).foregroundColor(.secondary)
            HStack {
                Button(L.t("▶ 승인하고 지금 바로 시작", "▶ Approve & start now")) { store.approve(job, requirements: text, startNow: true) }.buttonStyle(PillButtonStyle(color: .accentColor))
                Button(L.t("🌙 승인하고 예약 시간에 시작", "🌙 Approve & start at scheduled time")) { store.approve(job, requirements: text) }.buttonStyle(PillButtonStyle(color: .gray))
                Button(L.t("↩ 질문부터 다시", "↩ Start over")) { store.restartInterview(job) }.buttonStyle(PillButtonStyle(color: .gray))
                Spacer()
                TeamCancelButton(job: job)
                Button(L.t("🗑 삭제", "🗑 Delete")) { store.delete(job); onDeleted() }.buttonStyle(PillButtonStyle(color: .gray))
            }
            TeamAddRequestBox(button: L.t("➕ 요청 추가하고 팀장에게 다시 묻기", "➕ Add request & ask the lead"),
                              hint: L.t("요구사항을 더 추가하고 싶나요? 적어 주면 위에서 고친 내용을 그대로 두고, 팀장이 필요한 질문을 다시 정리해요.",
                                        "Need more? Add it — your edits above are kept and the lead asks what else is needed.")) { text in
                store.addRequest(job, text: text, requirements: self.text)
            }
        }
    }
}

// MARK: 스쿼드 채팅방

/// 팀장의 지시 · 팀원의 보고 · 팀장의 검토 · 나의 지시를 시간순 채팅으로 보여 주고, 나도 말을 건다
private struct TeamChatView: View {
    let job: TeamJob
    @ObservedObject private var store = TeamStore.shared
    @State private var text = ""
    @State private var to = "lead"

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private func name(_ id: String) -> String {
        switch id {
        case "lead": return "🐰 " + L.t("팀장", "Lead")
        case "user": return L.t("나", "Me")
        case "all":  return L.t("모두", "Everyone")
        case "system": return ""
        default:
            if let r = job.plan?.roles?.first(where: { $0.id == id }) { return "\(r.icon ?? "🧑‍💻") \(r.name ?? id)" }
            return id
        }
    }

    var body: some View {
        TeamLive {
            let msgs = TeamStore.readChat(jobId: job.id)
            let typing = TeamStore.readTyping(jobId: job.id)
            VStack(alignment: .leading, spacing: 10) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if msgs.isEmpty {
                                Text(L.t("아직 대화가 없어요. 팀이 일을 시작하면 지시와 보고가 여기에 쌓여요.", "Nothing yet — instructions and reports show up here once the team starts."))
                                    .font(.system(size: 12)).foregroundColor(.secondary).padding(.top, 20)
                            }
                            ForEach(msgs) { m in bubble(m).id(m.id) }
                            if !typing.isEmpty {
                                HStack(spacing: 6) { BuniSpinner(); Text(name(typing) + L.t(" 이(가) 답을 쓰는 중…", " is replying…")).font(.system(size: 11)).foregroundColor(.secondary) }
                                    .id("typing")
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: msgs.count) { _ in withAnimation { proxy.scrollTo(msgs.last?.id ?? 0, anchor: .bottom) } }
                    .onChange(of: typing) { _ in proxy.scrollTo("typing", anchor: .bottom) }
                    .onAppear { proxy.scrollTo(msgs.last?.id ?? 0, anchor: .bottom) }
                }
                .frame(height: 430)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))
                composer
            }
        }
    }

    @ViewBuilder
    private func bubble(_ m: TeamChatMessage) -> some View {
        if m.from == "system" {
            HStack { Spacer(); Text(m.text).font(.system(size: 10)).foregroundColor(.secondary).multilineTextAlignment(.center); Spacer() }
        } else if m.from == "user" {
            HStack(alignment: .bottom, spacing: 6) {
                Spacer(minLength: 60)
                Text(Self.clock.string(from: Date(timeIntervalSince1970: m.ts))).font(.system(size: 9)).foregroundColor(.secondary)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(L.t("나 → ", "Me → ") + name(m.to)).font(.system(size: 10)).foregroundColor(Color.buniAccentInk.opacity(0.75))
                    Text(m.text).font(.system(size: 13)).foregroundColor(.buniAccentInk).textSelection(.enabled)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: BuniTheme.rLg).fill(Color.buniAccent))
            }
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name(m.from)).font(.system(size: 11, weight: .semibold))
                        Text("→ " + name(m.to)).font(.system(size: 10)).foregroundColor(.secondary)
                        if let tag = badge(m.kind) { Text(tag.0).font(.system(size: 9, weight: .semibold)).foregroundColor(tag.1) }
                    }
                    Text(m.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(m.from == "lead" ? Color.buniRaised : Color.buniField))
                Text(Self.clock.string(from: Date(timeIntervalSince1970: m.ts))).font(.system(size: 9)).foregroundColor(.secondary)
                Spacer(minLength: 60)
            }
        }
    }

    private func badge(_ kind: String) -> (String, Color)? {
        switch kind {
        case "instruction": return (L.t("지시", "ORDER"), .orange)
        case "report":      return (L.t("보고", "REPORT"), .green)
        case "review":      return (L.t("검토", "REVIEW"), .blue)
        default: return nil
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $to) {
                    Text("🐰 " + L.t("팀장 (전체)", "Lead (everyone)")).tag("lead")
                    ForEach(job.plan?.roles ?? []) { r in Text("\(r.icon ?? "🧑‍💻") \(r.name ?? r.id)").tag(r.id) }
                }
                .labelsHidden().frame(width: 170)
                TextField(to == "lead" ? L.t("팀장에게 지시하거나 물어보세요", "Tell or ask the lead")
                                      : L.t("이 팀원에게 바로 지시하세요", "Instruct this teammate directly"), text: $text)
                    .textFieldStyle(.roundedBorder).onSubmit(send)
                Button(L.t("보내기", "Send"), action: send)
                    .buttonStyle(PillButtonStyle(color: .accentColor))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || job.state == "cancelled")
            }
            Text(to == "lead"
                 ? L.t("팀장이 이해해서 답하고, 필요한 팀원에게 알아서 나눠 지시해요. (약 1분)", "The lead replies and splits instructions among teammates as needed (about a minute).")
                 : L.t("이 팀원에게만 가요. 일하는 중이면 끝나는 대로, 끝난 팀원이면 다시 열어 반영해요.", "Goes to this teammate only — applied when it finishes, or reopens it if done."))
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.sendChat(job, to: to, text: t)
        text = ""
    }
}

// MARK: 팀원(세션)별 진행 · 요구사항 전달

/// 팀장과 팀원을 한 줄씩 보여 주고, 누르면 그 세션의 실시간 진행·Claude 에서 열기·요구사항 전달이 펼쳐진다
private struct TeamSquadBoard: View {
    let job: TeamJob
    @State private var open: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if job.plan != nil {
                row(id: "lead", icon: "🐰", name: L.t("팀장", "Team lead"),
                    status: leadStatus, depends: [], canSend: false)
            }
            ForEach(job.plan?.roles ?? []) { r in
                let st = job.roles?[r.id]
                let (label, color) = roleInfo(st?.status ?? "pending")
                row(id: r.id, icon: r.icon ?? "🧑‍💻", name: r.name ?? r.id,
                    status: (label + ((st?.attempts ?? 0) > 1 ? L.t("  (\(st!.attempts!)회)", "  (×\(st!.attempts!))") : "")
                             + (st?.notePending == true ? L.t("  · 📨 반영 대기", "  · 📨 queued") : ""), color),
                    depends: r.dependsOn ?? [], canSend: true)
            }
        }
    }

    private var leadStatus: (String, Color) {
        switch job.phase {
        case "planning":  return (L.t("팀 구성 중", "Building the team"), .green)
        case "reviewing": return (L.t("검토 중", "Reviewing"), .green)
        case "merging":   return (L.t("결과 합치는 중", "Merging"), .green)
        case "wrapup":    return (L.t("정리 중", "Wrapping up"), .green)
        default:          return (L.t("대기", "Waiting"), .gray)
        }
    }

    @ViewBuilder
    private func row(id: String, icon: String, name: String, status: (String, Color), depends: [String], canSend: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open = (open == id) ? nil : id } label: {
                HStack {
                    Text("\(icon)  \(name)").font(.system(size: 13, weight: .semibold))
                    Chip(text: status.0, color: status.1)
                    Spacer()
                    if !depends.isEmpty { Text("← " + depends.joined(separator: ", ")).font(.system(size: 10)).foregroundColor(.secondary) }
                    Image(systemName: open == id ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open == id {
                TeamSessionPanel(job: job, key: id, canSend: canSend)
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.buniField))
    }
}

private struct TeamSessionPanel: View {
    let job: TeamJob
    let key: String
    let canSend: Bool
    @ObservedObject private var store = TeamStore.shared
    @State private var note = ""
    @State private var noteRestored = false
    @State private var sentFlash = false

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        // 진행 중에는 2초마다 파일을 다시 읽는다
        TeamLive {
            let act = TeamStore.readActivity(jobId: job.id, key: key)
            let sessions = TeamStore.readSessions(jobId: job.id).filter { $0.key == key }
            VStack(alignment: .leading, spacing: 8) {
                if let s = job.roles?[key]?.summary, !s.isEmpty, !canSendHidden {
                    Text(s).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                activityBox(act)
                if !sessions.isEmpty { sessionButtons(sessions) }
                if canSend { sender }
            }
        }
    }

    private var canSendHidden: Bool { false }

    @ViewBuilder
    private func activityBox(_ act: TeamActivity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if act.lines.isEmpty {
                Text(L.t("아직 시작하지 않았어요.", "Not started yet.")).font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                ForEach(Array(act.lines.suffix(12).enumerated()), id: \.offset) { _, l in
                    HStack(alignment: .top, spacing: 6) {
                        Text(Self.clock.string(from: Date(timeIntervalSince1970: l.ts)))
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        Text(l.text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if act.state == "running" {
                    HStack(spacing: 6) { BuniSpinner(); Text(L.t("지금 진행 중", "Working now")).font(.system(size: 10)).foregroundColor(.green) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.18)))
    }

    @ViewBuilder
    private func sessionButtons(_ sessions: [TeamSession]) -> some View {
        HStack(spacing: 8) {
            if let last = sessions.last {
                Button(L.t("💻 Claude에서 열기", "💻 Open in Claude")) { store.openSession(job, sessionId: last.id) }
                    .buttonStyle(PillButtonStyle(color: .gray))
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
            Text(L.t("터미널에서 이 세션을 이어서 열어요", "Opens this session in Terminal")).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private var sender: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notes = job.roles?[key]?.notes, !notes.isEmpty {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                    Text("📨 " + (n.text ?? "")).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                TextField(L.t("이 팀원에게만 전할 요구사항", "A request just for this teammate"), text: $note)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    .onSubmit(send)
                    .onAppear {
                        if !noteRestored { noteRestored = true; note = TeamDrafts.shared.get(TeamDrafts.key(job.id, "note:" + key)) }
                    }
                    .onChange(of: note) { v in
                        if noteRestored { TeamDrafts.shared.set(TeamDrafts.key(job.id, "note:" + key), v) }
                    }
                Button(sentFlash ? L.t("보냈어요 ✓", "Sent ✓") : L.t("📨 보내기", "📨 Send"), action: send)
                    .buttonStyle(PillButtonStyle(color: .accentColor))
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(hint).font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hint: String {
        switch job.roles?[key]?.status ?? "pending" {
        case "running":  return L.t("지금 하는 일이 끝나면 반영해서 다시 진행해요.", "Applied by redoing the work once this run finishes.")
        case "pending", "revise": return L.t("이 팀원이 시작할 때 반영해요.", "Applied when this teammate starts.")
        default: return L.t("이미 끝난 팀원이면 다시 열어 반영해서 진행해요. 이 팀원의 산출물을 쓰는 팀원도 다시 확인해요.",
                            "If already done, it's reopened and redone. Teammates relying on it re-check too.")
        }
    }

    private func send() {
        let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.sendRoleNote(job, role: key, text: t)
        note = ""
        sentFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sentFlash = false }
    }
}

// MARK: 진행

private struct TeamEvents: View {
    let job: TeamJob
    let count: Int
    var body: some View {
        let ev = Array((job.events ?? []).suffix(count))
        if !ev.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(L.t("진행 기록", "Log")).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                ForEach(Array(ev.enumerated()), id: \.offset) { _, e in
                    Text(timeText(e.ts) + "  " + e.msg).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }.padding(.top, 4)
        }
    }
    private func timeText(_ ts: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: 결과

private struct TeamResult: View {
    let job: TeamJob
    var onDeleted: () -> Void
    @ObservedObject private var store = TeamStore.shared

    var body: some View {
        let reportURL = TeamStore.jobsDir.appendingPathComponent(job.id).appendingPathComponent("REPORT.md")
        let doc = TeamStore.readReportView(jobId: job.id, fallback: job.summary ?? "")
        VStack(alignment: .leading, spacing: 12) {
            Text(job.state == "done" ? L.t("검토를 마친 작업이에요", "Reviewed") : L.t("✅ 끝났어요", "✅ Finished"))
                .font(.system(size: 13, weight: .bold)).foregroundColor(.green)
            if job.busy == true {
                HStack(spacing: 8) {
                    BuniSpinner()
                    Text(job.busyMsg ?? L.t("정리하는 중…", "Working…")).font(.system(size: 12))
                    Text(L.t("— 다음 작업 제안이 곧 아래 보고서에 추가돼요", "— next-step suggestions will appear in the report below"))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            // 보고서 한 장 — 안에 '지금 확인할 것' 버튼과 '다음에 할 일' 버튼이 들어 있다
            MarkdownView(text: doc, draftScope: job.id) { host, target in
                switch host {
                case "open", "run": store.openItem(job, itemId: target)
                case "followup":    store.startFollowup(job, stepId: target)
                case "view":        store.focusJobId = target
                case "apply":       store.applyResult(job)
                case "diff":        store.openDiff(job)
                case "ok":          store.reviewFeedback(job, itemId: target, verdict: "ok")
                default: break
                }
            } onFeedback: { itemId, text, files in
                store.reviewFeedback(job, itemId: itemId, verdict: "fix", text: text, files: files)
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.buniField))

            Text(L.t("브랜치: \(job.branch ?? "")  ·  원래 브랜치: \(job.baseRef ?? "")  ·  비용 약 $\(String(format: "%.2f", job.costUsd ?? 0))",
                     "Branch: \(job.branch ?? "")  ·  base: \(job.baseRef ?? "")  ·  cost ≈ $\(String(format: "%.2f", job.costUsd ?? 0))"))
                .font(.system(size: 10)).foregroundColor(.secondary)
            HStack {
                Button(L.t("📄 보고서 파일 열기", "📄 Open report file")) { NSWorkspace.shared.open(reportURL) }.buttonStyle(PillButtonStyle(color: .gray))
                if let f = job.resultFolder {
                    Button(L.t("📂 결과 폴더", "📂 Results folder")) { NSWorkspace.shared.open(f) }.buttonStyle(PillButtonStyle(color: .gray))
                }
                if job.state != "done" {
                    Button(L.t("✅ 검토 완료", "✅ Mark reviewed")) { store.markDone(job) }.buttonStyle(PillButtonStyle(color: .accentColor))
                }
                Button(L.t("🔄 다시 정리", "🔄 Redo list")) { store.wrapUp(job) }.buttonStyle(PillButtonStyle(color: .gray))
                Spacer()
                Button(L.t("🗑 삭제", "🗑 Delete")) { store.delete(job); onDeleted() }.buttonStyle(PillButtonStyle(color: .gray))
            }
        }
    }
}

// MARK: - 예약 설정

/// 프로젝트 단위 모델 — 비우면 전역 설정을 따른다 (우선순위: 팀원별 → 프로젝트 → 전역)
private struct ProjectSettingsSheet: View {
    let job: TeamJob
    var onClose: () -> Void
    @ObservedObject private var store = TeamStore.shared
    @State private var model = ""
    @State private var leadModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("프로젝트 설정", "Project settings")).font(.system(size: 15, weight: .bold))
            Text(job.displayTitle).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            Text(L.t("모델", "Models")).font(.system(size: 12, weight: .semibold))
            HStack { Text(L.t("팀원 기본", "Teammates")).frame(width: 80, alignment: .leading); SquadModelMenu(model: $model, allowDefault: true, defaultLabel: L.t("전역 설정과 같게", "Same as global")) }
            HStack { Text(L.t("팀장", "Lead")).frame(width: 80, alignment: .leading); SquadModelMenu(model: $leadModel, allowDefault: true, defaultLabel: L.t("전역 설정과 같게", "Same as global")) }
            Text(L.t("비워 두면 스쿼드 설정의 모델을 따라요. 팀원마다 고른 모델이 있으면 그게 먼저예요. 다음 실행부터 적용돼요.",
                     "Empty follows the Squad settings. A model picked for a teammate wins. Applies from the next run."))
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L.t("취소", "Cancel")) { onClose() }
                Button(L.t("저장", "Save")) {
                    store.setProjectSettings(job, model: model, leadModel: leadModel); onClose()
                }.buttonStyle(PillButtonStyle(color: .accentColor))
            }
        }
        .padding(20).frame(width: 400)
        .onAppear { model = job.model ?? ""; leadModel = job.leadModel ?? "" }
    }
}

private struct TeamSettingsSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var store = TeamStore.shared
    @State private var s = TeamSettings()
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t("스쿼드 설정", "Squad settings")).font(.system(size: 15, weight: .bold))
            Text(L.t("자동 진행 시간", "When auto-run works")).font(.system(size: 12, weight: .semibold))
            Picker("", selection: $s.scheduleMode) {
                Text(L.t("정해 둔 시간대 안에서만 (아래 시각)", "Only inside the hours below")).tag("window")
                Text(L.t("언제든 바로 진행", "Any time, right away")).tag("anytime")
                Text(L.t("내가 시작할 때만", "Only when I start it")).tag("off")
            }.pickerStyle(.radioGroup).labelsHidden()
            HStack {
                Text(L.t("시작 시각", "Start")).frame(width: 80, alignment: .leading)
                TextField("22:00", text: $s.windowStart).frame(width: 70).textFieldStyle(.roundedBorder)
                Text(L.t("끝나는 시각", "End")).frame(width: 80, alignment: .trailing)
                TextField("06:00", text: $s.windowEnd).frame(width: 70).textFieldStyle(.roundedBorder)
            }
            Stepper(L.t("동시에 일하는 팀원 수: \(s.concurrency)", "Teammates at once: \(s.concurrency)"), value: $s.concurrency, in: 1...4)
            Text(L.t("Claude 사용량 한도(일일 제한)에 닿으면", "When the Claude usage limit is reached")).font(.system(size: 12, weight: .semibold))
            Picker("", selection: $s.limitAction) {
                Text(L.t("멈추고, 내가 ▶ 이어서 를 누를 때까지 쉬기 (기본)", "Stop until I press Resume (default)")).tag("stop")
                Text(L.t("풀릴 때까지 기다렸다가 알아서 이어서", "Wait for the reset and continue by itself")).tag("wait")
            }.pickerStyle(.radioGroup).labelsHidden()
            Text(L.t("시간은 24시간제(예: 22:00). 플랜 사용량을 아끼려면 2명을 권해요. 한도에 걸리면 풀릴 때까지 기다렸다 이어서 해요.",
                     "24-hour time (e.g. 22:00). Two is recommended to save plan usage. If you hit the limit it waits and continues."))
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(L.t("업무 진행 방식", "How tasks run")).font(.system(size: 12, weight: .semibold))
            Picker("", selection: $s.runMode) {
                Text(L.t("자동 — 팀이 알아서 순서대로 진행 (기본)", "Auto — the team runs tasks in order (default)")).tag("auto")
                Text(L.t("수동 — 업무마다 내가 ▶ 시작을 눌러야 진행", "Manual — I press ▶ Start on each task")).tag("manual")
            }.pickerStyle(.radioGroup).labelsHidden()
            Text(L.t("작업마다 프로젝트 현황 위쪽에서 따로 바꿀 수도 있어요.", "You can also change it per project at the top of its board."))
                .font(.system(size: 11)).foregroundColor(.secondary)
            Divider()
            Text(L.t("결과를 내 폴더에 반영하는 방식", "How results reach your folder")).font(.system(size: 12, weight: .semibold))
            Picker("", selection: $s.applyMode) {
                Text(L.t("스마트 — 중요하지 않으면 바로, 중요하면 확인 (기본)", "Smart — auto unless important (default)")).tag("smart")
                Text(L.t("자동 — 무엇이든 끝나면 승인 없이 바로 반영", "Auto — always apply when done, no approval")).tag("auto")
                Text(L.t("확인 후 — 바뀐 내용을 보고 승인하면 반영", "Confirm — review, then approve")).tag("confirm")
                Text(L.t("수동 — 반영하지 않고 브랜치로만", "Manual — keep on a branch only")).tag("manual")
            }.pickerStyle(.radioGroup).labelsHidden()
            if s.applyMode == "smart" {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.t("이런 변경이 있으면 확인을 받아요", "Ask me first when a change involves")).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                    Toggle(L.t("결제·가격·라이선스 파일", "Payments, pricing, licensing"), isOn: $s.smartPayments)
                    Toggle(L.t("비밀값·키·인증·설정 파일", "Secrets, keys, auth, config"), isOn: $s.smartSecrets)
                    Toggle(L.t("빌드·설치·릴리스·훅·버전 파일", "Build, install, release, hooks, version"), isOn: $s.smartBuild)
                    Toggle(L.t("파일 삭제", "Deleting files"), isOn: $s.smartDeletes)
                    Toggle(L.t("큰 변경", "Large changes"), isOn: $s.smartBig)
                    if s.smartBig {
                        HStack(spacing: 8) {
                            Stepper(L.t("파일 \(s.smartBigFiles)개 이상", "≥ \(s.smartBigFiles) files"), value: $s.smartBigFiles, in: 5...300, step: 5)
                            Stepper(L.t("또는 \(s.smartBigLines)줄 이상", "or ≥ \(s.smartBigLines) lines"), value: $s.smartBigLines, in: 100...50000, step: 250)
                        }.font(.system(size: 11)).padding(.leading, 20)
                    }
                    HStack {
                        Text(L.t("그 밖에 확인받을 경로", "Other paths")).font(.system(size: 11)).frame(width: 110, alignment: .leading)
                        TextField("docs/*, *.plist", text: $s.smartCustom).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    }
                    Text(L.t("쉼표로 구분, * 사용 가능. 위에 해당하지 않으면 끝나는 대로 바로 반영해요.", "Comma-separated, * allowed. Anything else is applied right away."))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
                .font(.system(size: 12))
            }
            Text(L.t("어느 방식이든 커밋은 하지 않고, 내 폴더의 커밋 안 한 변경과 겹치면 아무것도 바꾸지 않아요.",
                     "No mode commits anything, and nothing changes if it overlaps your uncommitted edits."))
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle(L.t("다음에 할 일 자동 진행", "Auto-continue next steps"), isOn: $s.autoFollowup)
            Text(L.t("방향이 바뀌지 않는 후속 작업만 끝나면 이어서 시작해요 (연속 3단계까지). 가격·정책 변경, 게시·발송, push·릴리스는 내가 누를 때까지 기다려요.",
                     "Only follow-ups that don't change direction start on their own (up to 3 in a row). Pricing/policy changes, posting/sending, push and release wait for your click."))
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(L.t("변경 전·후 화면 캡처", "Before/after screen capture")).font(.system(size: 12, weight: .semibold))
            Text(L.t("화면·디자인 업무의 변경 전·후 화면은 자동으로 찍어요. 맥은 시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 화면 기록(화면 및 시스템 오디오 녹음)에서 부니를 허용해야 하고, Windows 는 Pillow 가 있어야 해요 (pip install Pillow). 못 찍으면 '캡처 아님 — 이유'로 보여요.",
                     "Before/after screens of UI and design tasks are captured automatically. On Mac, allow Buni under System Settings ▸ Privacy & Security ▸ Screen Recording (Screen & System Audio Recording); on Windows, Pillow must be installed (pip install Pillow). If a capture fails, it shows as 'Not a capture — reason'."))
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(L.t("모델", "Models")).font(.system(size: 12, weight: .semibold))
            HStack { Text(L.t("팀원 기본", "Teammates")).frame(width: 80, alignment: .leading); SquadModelMenu(model: $s.model, allowDefault: true) }
            HStack { Text(L.t("팀장", "Lead")).frame(width: 80, alignment: .leading); SquadModelMenu(model: $s.leadModel, allowDefault: true, defaultLabel: L.t("팀원 기본과 같게", "Same as teammates")) }
            Text(L.t("팀원마다 다르게 하려면 그 팀원의 대화(DM) 위쪽에서 고르세요.", "To set one teammate, use the model menu at the top of their DM."))
                .font(.system(size: 11)).foregroundColor(.secondary)
            if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundColor(.red) }
            HStack {
                Spacer()
                Button(L.t("취소", "Cancel")) { isPresented = false }
                Button(L.t("저장", "Save")) {
                    guard minutes(s.windowStart) != nil, minutes(s.windowEnd) != nil else {
                        error = L.t("시각 형식이 올바르지 않아요 (예: 22:00)", "Invalid time (e.g. 22:00)"); return
                    }
                    store.saveSettings(s); isPresented = false
                }.buttonStyle(PillButtonStyle(color: .accentColor))
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { s = store.settings }
    }
}
