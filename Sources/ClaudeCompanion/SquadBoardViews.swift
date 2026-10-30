import SwiftUI
import AppKit

// 부니 스쿼드 — 현황 모니터링 화면 (상태별 칼럼 보드 · 목록 · 요약 숫자 · 필터).
// 구성 원칙만 이슈 보드에서 참고했고, 색·간격은 SQ 팔레트(부니 디자인 시스템)를 따른다.
// 상태 판정(SquadBoard.column)은 windows/buni_team.py 의 board_column 과 같은 규칙이어야 한다.

// MARK: - 상태 판정 (칼럼)

enum SquadColumn: String, CaseIterable, Hashable {
    case ready, running, review, done, blocked

    var title: String {
        switch self {
        case .ready:   return L.t("대기", "Waiting")
        case .running: return L.t("진행 중", "In progress")
        case .review:  return L.t("검토", "Review")
        case .done:    return L.t("완료", "Done")
        case .blocked: return L.t("확인 필요", "Needs attention")
        }
    }
    var color: Color {
        switch self {
        case .ready:   return Color(red: 0.42, green: 0.62, blue: 0.95)
        case .running: return Color(red: 0.30, green: 0.75, blue: 0.50)
        case .review:  return Color(red: 0.93, green: 0.62, blue: 0.25)
        case .done:    return Color(red: 0.60, green: 0.62, blue: 0.70)
        case .blocked: return Color(red: 0.90, green: 0.35, blue: 0.40)
        }
    }
}

/// 보드의 카드 한 장 — 팀원이 맡은 일 하나, 아직 팀이 없는 작업은 작업 자체가 한 장
struct SquadItem: Identifiable, Equatable {
    var id: String
    var jobId: String
    var jobTitle: String
    var roleId: String?          // nil = 작업(팀장) 카드
    var assigneeId: String       // "lead" 또는 팀원 id
    var assignee: String
    var icon: String
    var column: SquadColumn
    var stateLabel: String
    var recent: String
    var since: Double            // 경과 시간의 기준 시각
    var progressDone: Int        // 작업 전체에서 통과한 팀원 수
    var progressTotal: Int
    var updated: Double
    var kind: String = "role"    // role(팀원 업무) · job(팀이 없는 작업) · next(아직 시작 안 한 다음에 할 일)
    var auto: String = ""        // started(자동 진행됨) · confirm(확인 필요) · limit(상한으로 멈춤)
    var summary: String = ""     // 결과 (팀원 보고 요약 · 다음 업무 목표)
    var searchText: String = ""  // 검색 대상 (제목·담당자·내용, 소문자)

    var autoLabel: String {
        switch auto {
        case "started": return L.t("자동 진행됨", "Auto-started")
        case "confirm": return L.t("확인 필요", "Needs your OK")
        case "limit":   return L.t("상한으로 멈춤", "Stopped at limit")
        default:        return ""
        }
    }
    var autoColor: Color {
        switch auto {
        case "started": return Color(red: 0.30, green: 0.75, blue: 0.50)
        case "limit":   return Color(red: 0.90, green: 0.35, blue: 0.40)
        default:        return Color(red: 0.93, green: 0.62, blue: 0.25)
        }
    }
}

/// 보드 범위 — 전체 · 진행 중만 · 끝난 것만
enum SquadBoardScope: String, CaseIterable {
    case all, active, finished
    var title: String {
        switch self {
        case .all:      return L.t("전체", "All")
        case .active:   return L.t("진행 중만", "Active only")
        case .finished: return L.t("끝난 것만", "Finished only")
        }
    }
}

enum SquadBoard {
    /// 작업 상태 + (있다면) 팀원 상태 → 칼럼.
    /// 취소·검토 완료는 완료, 실패·한도 대기·잠시 멈춤은 막힘(이미 통과한 팀원은 완료), 검토 대기는 검토,
    /// 그 밖에는 팀원 상태(통과 완료 · 검토 대기 검토 · 작업 중/다시 작업 진행 중 · 대기 준비)를 따른다.
    static func column(jobState: String, roleStatus: String?) -> SquadColumn {
        switch jobState {
        case "cancelled", "done": return .done
        case "review":            return .review
        default: break
        }
        if let r = roleStatus, r == "accepted" { return .done }
        if ["failed", "waiting_limit", "paused"].contains(jobState) { return .blocked }
        guard let r = roleStatus else { return jobState == "running" ? .running : .ready }
        switch r {
        case "running", "revise": return .running
        case "done_unreviewed":   return .review
        default:                  return .ready
        }
    }

    static func items(_ jobs: [TeamJob], now: Double = Date().timeIntervalSince1970) -> [SquadItem] {
        var out: [SquadItem] = []
        for j in jobs {
            let roles = j.plan?.roles ?? []
            let accepted = roles.filter { j.roles?[$0.id]?.status == "accepted" }.count
            let jobSince = j.updated ?? j.created ?? now
            let errorLine = (j.error?.isEmpty == false) ? j.error! : ""
            let steps = TeamStore.readWrapup(jobId: j.id)?.steps ?? []
            func searchable(_ it: SquadItem, _ extra: String...) -> SquadItem {
                var c = it
                c.searchText = ([c.jobTitle, j.goal ?? "", c.assignee, c.recent, c.summary, c.stateLabel] + extra).joined(separator: " ").lowercased()
                return c
            }
            if roles.isEmpty {
                let (name, _) = statusInfo(j.state)
                let col = column(jobState: j.state, roleStatus: nil)
                out.append(searchable(SquadItem(id: j.id, jobId: j.id, jobTitle: j.displayTitle, roleId: nil,
                                     assigneeId: "lead", assignee: L.t("팀장", "Team lead"), icon: "🐰",
                                     column: col, stateLabel: name,
                                     recent: !errorLine.isEmpty ? errorLine : (j.busyMsg ?? ""),
                                     since: jobSince, progressDone: 0, progressTotal: 0, updated: jobSince, kind: "job")))
                continue
            }
            let sessions = TeamStore.readSessions(jobId: j.id)
            defer {
                // 아직 시작하지 않은 '다음에 할 일' — 자동 진행되지 않은 이유(확인 필요 · 상한)를 카드로 보여 준다
                for s in steps where s.roleId == nil && s.jobId == nil {
                    let held = s.auto == "confirm" || s.auto == "limit"
                    var it = SquadItem(id: j.id + "|step:" + s.id, jobId: j.id, jobTitle: j.displayTitle + " › " + s.title, roleId: nil,
                                       assigneeId: "lead", assignee: L.t("팀장", "Team lead"), icon: "🐰",
                                       column: held ? .blocked : .ready,
                                       stateLabel: held ? SquadColumn.blocked.title : SquadColumn.ready.title,
                                       recent: s.why, since: jobSince, progressDone: 0, progressTotal: 0, updated: jobSince,
                                       kind: "next", auto: held ? (s.auto ?? "") : "", summary: s.goal)
                    it = searchable(it, s.title)
                    out.append(it)
                }
            }
            for r in roles {
                let st = j.roles?[r.id]
                let status = st?.status ?? "pending"
                let col = column(jobState: j.state, roleStatus: status)
                var label = roleInfo(status).0
                if col == .blocked { label = statusInfo(j.state).0 }
                else if col == .review, status == "pending" || status == "accepted" { label = statusInfo(j.state).0 }
                var recent = ""
                var since = jobSince
                if status == "running" {
                    let act = TeamStore.readActivity(jobId: j.id, key: r.id)
                    recent = act.lines.last?.text ?? ""
                    if let s = sessions.filter({ $0.key == r.id && $0.finished == nil }).map({ $0.started }).max() { since = s }
                }
                if recent.isEmpty, col == .blocked { recent = errorLine }
                if recent.isEmpty {
                    let first = (st?.summary ?? "").split(separator: "\n").first.map(String.init) ?? ""
                    recent = first
                }
                let step = steps.first(where: { $0.roleId == r.id })
                out.append(searchable(SquadItem(id: j.id + "|" + r.id, jobId: j.id, jobTitle: j.displayTitle, roleId: r.id,
                                     assigneeId: r.id, assignee: r.name ?? r.id, icon: r.icon ?? "🧑‍💻",
                                     column: col, stateLabel: label, recent: recent, since: since,
                                     progressDone: accepted, progressTotal: roles.count, updated: jobSince,
                                     auto: step?.auto == "started" ? "started" : "", summary: st?.summary ?? ""),
                                      r.mission ?? "", step?.title ?? ""))
            }
        }
        return out
    }

    static func elapsed(_ since: Double, now: Double = Date().timeIntervalSince1970) -> String {
        let s = max(0, Int(now - since))
        let m = s / 60, h = m / 60, d = h / 24
        if d > 0 { return L.t("\(d)일 \(h % 24)시간", "\(d)d \(h % 24)h") }
        if h > 0 { return L.t("\(h)시간 \(m % 60)분", "\(h)h \(m % 60)m") }
        if m > 0 { return L.t("\(m)분", "\(m)m") }
        return L.t("방금", "just now")
    }
}

// MARK: - 화면

enum SquadBoardSort: String, CaseIterable {
    case recent, oldest, state, assignee
    var title: String {
        switch self {
        case .recent:   return L.t("최근 변경순", "Recently updated")
        case .oldest:   return L.t("오래된 순", "Oldest first")
        case .state:    return L.t("상태순", "By status")
        case .assignee: return L.t("담당자순", "By assignee")
        }
    }
}

struct SquadBoardView: View {
    @ObservedObject private var store = TeamStore.shared
    var onGoto: (SquadItem, SquadPane) -> Void

    @State private var query = ""
    @State private var scope: SquadBoardScope = .all
    @State private var selectedId: String?
    @State private var listMode = false
    @State private var statusFilter: SquadColumn?
    @State private var assigneeFilter = ""       // "" = 모두
    @State private var sort: SquadBoardSort = .recent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { ctx in
            let now = ctx.date.timeIntervalSince1970
            let all = SquadBoard.items(store.jobs, now: now)
            let shown = filtered(all)
            VStack(spacing: 0) {
                toolbar(all)
                Rectangle().fill(SQ.line).frame(height: 1)
                summary(all)
                if all.isEmpty {
                    Spacer()
                    Text(L.t("아직 보여 줄 작업이 없어요.\n왼쪽 ✎ 버튼으로 새 작업을 시작해 보세요.", "Nothing to show yet.\nStart a job with the ✎ button."))
                        .font(.system(size: 12)).foregroundColor(SQ.dim).multilineTextAlignment(.center)
                    Spacer()
                } else {
                    HStack(spacing: 0) {
                        if listMode { listView(shown, now) } else { boardView(shown, now) }
                        if let sel = all.first(where: { $0.id == selectedId }) {
                            Rectangle().fill(SQ.line).frame(width: 1)
                            SquadItemDetail(item: sel, now: now, onGoto: onGoto, onClose: { selectedId = nil })
                                .frame(width: 280)
                        }
                    }
                }
            }
        }
    }

    // MARK: 필터 · 정렬

    private func filtered(_ items: [SquadItem]) -> [SquadItem] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let f = items.filter { it in
            (statusFilter == nil || it.column == statusFilter) && (assigneeFilter.isEmpty || it.assigneeId == assigneeFilter)
                && (scope == .all || (scope == .finished) == (it.column == .done))
                && words.allSatisfy { it.searchText.contains($0) }
        }
        switch sort {
        case .recent:   return f.sorted { $0.updated > $1.updated }
        case .oldest:   return f.sorted { $0.since < $1.since }
        case .state:    return f.sorted { (SquadColumn.allCases.firstIndex(of: $0.column) ?? 0) < (SquadColumn.allCases.firstIndex(of: $1.column) ?? 0) }
        case .assignee: return f.sorted { $0.assignee.localizedCompare($1.assignee) == .orderedAscending }
        }
    }

    private func toolbar(_ all: [SquadItem]) -> some View {
        var people: [(id: String, name: String)] = []
        for i in all where !people.contains(where: { $0.id == i.assigneeId }) { people.append((i.assigneeId, i.assignee)) }
        return HStack(spacing: 10) {
            Text("📊 " + L.t("업무 현황", "Task board")).font(.system(size: 15, weight: .heavy))
            Picker("", selection: $listMode) {
                Text(L.t("보드", "Board")).tag(false)
                Text(L.t("목록", "List")).tag(true)
            }.pickerStyle(.segmented).frame(width: 130).labelsHidden()
            TextField(L.t("🔎 제목·담당자·내용", "🔎 title · assignee · text"), text: $query)
                .textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 190)
            Picker("", selection: $scope) {
                ForEach(SquadBoardScope.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).frame(width: 210).labelsHidden()
            Spacer()
            Menu {
                Button(L.t("모든 상태", "All statuses")) { statusFilter = nil }
                ForEach(SquadColumn.allCases, id: \.self) { c in Button(c.title) { statusFilter = c } }
            } label: { filterLabel(L.t("상태", "Status"), statusFilter?.title ?? L.t("모두", "All")) }
                .menuStyle(.borderlessButton).fixedSize()
            Menu {
                Button(L.t("모든 담당자", "Everyone")) { assigneeFilter = "" }
                ForEach(people, id: \.id) { p in Button(p.name) { assigneeFilter = p.id } }
            } label: { filterLabel(L.t("담당자", "Assignee"), people.first(where: { $0.id == assigneeFilter })?.name ?? L.t("모두", "All")) }
                .menuStyle(.borderlessButton).fixedSize()
            Menu {
                ForEach(SquadBoardSort.allCases, id: \.self) { s in Button(s.title) { sort = s } }
            } label: { filterLabel(L.t("정렬", "Sort"), sort.title) }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 16).frame(height: 46)
    }

    private func filterLabel(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).foregroundColor(SQ.dim)
            Text(v).fontWeight(.semibold)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
    }

    // MARK: 요약 숫자

    private func summary(_ all: [SquadItem]) -> some View {
        func n(_ c: SquadColumn) -> Int { all.filter { $0.column == c }.count }
        return HStack(spacing: 10) {
            stat(L.t("전체", "Total"), all.count, .white, nil)
            stat(L.t("진행 중", "In progress"), n(.running), SquadColumn.running.color, .running)
            stat(L.t("완료", "Done"), n(.done), SquadColumn.done.color, .done)
            stat(L.t("확인 필요", "Needs attention"), n(.blocked), SquadColumn.blocked.color, .blocked)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func stat(_ title: String, _ value: Int, _ color: Color, _ filter: SquadColumn?) -> some View {
        Button { statusFilter = (statusFilter == filter) ? nil : filter } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)").font(.system(size: 22, weight: .heavy)).foregroundColor(color)
                Text(title).font(.system(size: 10.5)).foregroundColor(SQ.dim)
            }
            .frame(width: 96, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(statusFilter == filter && filter != nil ? 0.14 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(SQ.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: 보드

    private func boardView(_ items: [SquadItem], _ now: Double) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(SquadColumn.allCases, id: \.self) { col in
                    let list = items.filter { $0.column == col }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(col.color).frame(width: 7, height: 7)
                            Text(col.title).font(.system(size: 11, weight: .heavy)).foregroundColor(.white.opacity(0.8))
                            Text("\(list.count)").font(.system(size: 10, weight: .bold)).foregroundColor(SQ.dim)
                        }
                        .padding(.horizontal, 4)
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(list) { it in SquadCard(item: it, now: now, selected: it.id == selectedId) { selectedId = it.id } }
                                if list.isEmpty {
                                    Text(L.t("비어 있어요", "Empty")).font(.system(size: 10.5)).foregroundColor(SQ.dim.opacity(0.7))
                                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                                }
                            }
                        }
                    }
                    .padding(8).frame(width: 214)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: 10).fill(SQ.rail.opacity(0.7)))
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
    }

    // MARK: 목록

    private func listView(_ items: [SquadItem], _ now: Double) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                head(L.t("상태", "Status"), 92); head(L.t("프로젝트", "Project"), nil); head(L.t("담당자", "Assignee"), 120)
                head(L.t("진행률", "Progress"), 110); head(L.t("최근 활동", "Recent"), nil); head(L.t("경과", "Elapsed"), 80)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            Rectangle().fill(SQ.line).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { it in SquadListRow(item: it, now: now, selected: it.id == selectedId) { selectedId = it.id } }
                    if items.isEmpty {
                        Text(L.t("조건에 맞는 항목이 없어요.", "No items match.")).font(.system(size: 11)).foregroundColor(SQ.dim).padding(24)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func head(_ t: String, _ w: CGFloat?) -> some View {
        let v = Text(t).font(.system(size: 10, weight: .heavy)).foregroundColor(.white.opacity(0.4)).textCase(.uppercase)
        if let w { v.frame(width: w, alignment: .leading) } else { v.frame(maxWidth: .infinity, alignment: .leading) }
    }
}

// MARK: - 카드 · 목록 줄

private struct SquadCard: View {
    let item: SquadItem
    let now: Double
    var selected = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.jobTitle).font(.system(size: 12, weight: .bold)).foregroundColor(.white).lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    SquadAvatar(icon: item.icon, id: item.assigneeId, size: 18)
                    Text(item.assignee).font(.system(size: 11)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                    Spacer(minLength: 2)
                    Chip(text: item.stateLabel, color: item.column.color)
                }
                if !item.autoLabel.isEmpty {
                    Text("⟳ " + item.autoLabel).font(.system(size: 10, weight: .bold)).foregroundColor(item.autoColor)
                }
                if !item.recent.isEmpty {
                    Text(item.recent).font(.system(size: 10.5)).foregroundColor(SQ.dim).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 6) {
                    if item.progressTotal > 0 { SquadProgressBar(done: item.progressDone, total: item.progressTotal, color: item.column.color) }
                    Spacer(minLength: 2)
                    Text("⏱ " + SquadBoard.elapsed(item.since, now: now)).font(.system(size: 10)).foregroundColor(SQ.dim)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.white.opacity(0.12) : SQ.main))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? item.column.color : SQ.line, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L.t("눌러서 상세 보기", "Click for details"))
    }
}

private struct SquadListRow: View {
    let item: SquadItem
    let now: Double
    var selected = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Chip(text: item.stateLabel, color: item.column.color).frame(width: 92, alignment: .leading)
                HStack(spacing: 6) {
                    Text(item.jobTitle).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    if !item.autoLabel.isEmpty {
                        Text("⟳ " + item.autoLabel).font(.system(size: 9.5, weight: .bold)).foregroundColor(item.autoColor).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    SquadAvatar(icon: item.icon, id: item.assigneeId, size: 16)
                    Text(item.assignee).font(.system(size: 11)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                }.frame(width: 120, alignment: .leading)
                Group {
                    if item.progressTotal > 0 { SquadProgressBar(done: item.progressDone, total: item.progressTotal, color: item.column.color) }
                    else { Text("—").foregroundColor(SQ.dim) }
                }.frame(width: 110, alignment: .leading)
                Text(item.recent.isEmpty ? "—" : item.recent).font(.system(size: 11)).foregroundColor(SQ.dim).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(SquadBoard.elapsed(item.since, now: now)).font(.system(size: 11)).foregroundColor(SQ.dim)
                    .frame(width: 80, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(selected ? SQ.hover.opacity(1.6) : (hover ? SQ.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// 카드 상세 — 담당자 · 진행률 · 최근 활동 · 결과 · 관련 채팅, 같은 프로젝트의 화면(담당자 DM · 결과 · 스쿼드 채팅)과 Claude 로 이동
private struct SquadItemDetail: View {
    let item: SquadItem
    let now: Double
    var onGoto: (SquadItem, SquadPane) -> Void
    var onClose: () -> Void
    @ObservedObject private var store = TeamStore.shared

    var body: some View {
        let job = store.jobs.first(where: { $0.id == item.jobId })
        let hasRoom = job?.plan != nil
        let activity = item.roleId.map { TeamStore.readActivity(jobId: item.jobId, key: $0).lines.suffix(4).map(\.text) } ?? []
        let chat = TeamStore.readChat(jobId: item.jobId)
            .filter { item.roleId == nil || $0.from == item.roleId || $0.to == item.roleId }.suffix(4)
        let sessions = TeamStore.readSessions(jobId: item.jobId).filter { item.roleId == nil || $0.key == item.roleId }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(item.jobTitle).font(.system(size: 13, weight: .heavy)).foregroundColor(.white).lineLimit(3)
                Spacer(minLength: 4)
                Button { onClose() } label: { Text("✕").foregroundColor(SQ.dim) }.buttonStyle(.plain)
            }.padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        SquadAvatar(icon: item.icon, id: item.assigneeId, size: 18)
                        Text(item.assignee).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.85))
                        Chip(text: item.stateLabel, color: item.column.color)
                    }
                    if !item.autoLabel.isEmpty {
                        Text("⟳ " + item.autoLabel).font(.system(size: 10.5, weight: .bold)).foregroundColor(item.autoColor)
                    }
                    if item.progressTotal > 0 {
                        HStack(spacing: 6) {
                            Text(L.t("진행률", "Progress")).font(.system(size: 10.5)).foregroundColor(SQ.dim)
                            SquadProgressBar(done: item.progressDone, total: item.progressTotal, color: item.column.color)
                        }
                    }
                    Text("⏱ " + SquadBoard.elapsed(item.since, now: now)).font(.system(size: 10.5)).foregroundColor(SQ.dim)
                    section(L.t("최근 활동", "Recent activity"), activity.isEmpty ? (item.recent.isEmpty ? [] : [item.recent]) : activity)
                    section(L.t("결과", "Result"), item.summary.isEmpty ? [] : [String(item.summary.prefix(260))])
                    section(L.t("관련 채팅", "Related chat"), chat.map { "\(chatName($0.from, job)): \(String($0.text.prefix(70)))" })
                }.padding(.horizontal, 12).padding(.bottom, 8)
            }
            VStack(spacing: 6) {
                if let rid = item.roleId, hasRoom {
                    goButton("💬 " + L.t("\(item.assignee) 대화 열기", "Open \(item.assignee)'s chat")) { onGoto(item, .dm(rid)) }
                } else if hasRoom {
                    goButton("🐰 " + L.t("팀장 대화 열기", "Open lead's chat")) { onGoto(item, .lead) }
                }
                goButton("📄 " + L.t("결과·진행 보기", "Open result / progress")) { onGoto(item, .overview) }
                if hasRoom { goButton("# " + L.t("스쿼드 채팅 보기", "Open squad chat")) { onGoto(item, .channel) } }
                if let job, let last = sessions.last {
                    goButton("💻 " + L.t("Claude에서 열기", "Open in Claude")) { store.openSession(job, sessionId: last.id) }
                }
            }.padding(12)
        }
        .background(SQ.rail.opacity(0.7))
    }

    private func chatName(_ who: String, _ job: TeamJob?) -> String {
        switch who {
        case "lead": return L.t("팀장", "Lead")
        case "user": return L.t("나", "Me")
        case "all":  return L.t("모두", "Everyone")
        default:     return job?.plan?.roles?.first(where: { $0.id == who })?.name ?? who
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10, weight: .heavy)).foregroundColor(.white.opacity(0.4)).textCase(.uppercase)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 11)).foregroundColor(.white.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 4)
        }
    }

    private func goButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.1)))
        }.buttonStyle(.plain)
    }
}

private struct SquadProgressBar: View {
    let done: Int
    let total: Int
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(color).frame(width: total > 0 ? g.size.width * CGFloat(done) / CGFloat(total) : 0)
                }
            }
            .frame(width: 50, height: 5)
            Text("\(done)/\(total)").font(.system(size: 10)).foregroundColor(SQ.dim)
        }
    }
}
