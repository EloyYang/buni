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
        case .ready:   return .buniInfo
        case .running: return .buniOk
        case .review:  return .buniWarn
        case .done:    return .buniDim
        case .blocked: return .buniDanger
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
    var kind: String = "role"    // task(내가 지시한 업무) · role(옛 작업의 팀원 업무) · job(팀이 없는 작업) · next(아직 시작 안 한 다음에 할 일)
    var auto: String = ""        // started(자동 진행됨) · confirm(확인 필요) · limit(상한으로 멈춤)
    var summary: String = ""     // 결과 (팀원 보고 요약 · 다음 업무 목표)
    var stateNames: String = ""  // 상태 이름 한글·영어 둘 다 (검색용 — 엔진 card 의 state[0] state[1])
    var searchText: String = ""  // 검색 대상 (제목·담당자·내용, 소문자)
    var why: String = ""         // 상태 이유 한 줄 (엔진 board_why)
    var instruction: String = "" // 원래 지시 (팀원 미션 + 산출물 · 다음 업무 목표)
    var goal: String = ""        // 프로젝트 목표
    var changedFiles: Int = 0    // 바뀐 파일 수 (프로젝트 단위)
    var duty: String = ""        // 담당자의 직무 (예: 백엔드 · 서버·엔진) — 직무를 모르면 빈 문자열
    var stepId: String? = nil    // 이 카드가 가리키는 '다음에 할 일' (kind == next 이면 승인·거절·의견을 남길 수 있다)
    var taskId: String? = nil    // 내가 지시한 업무 하나 (kind == task) — 업무 보드와 같은 카드로 그린다

    /// 카드에 보이는 짧은 제목 — 엔진 `short_title` 과 같은 규칙. 전체는 상세 화면에서 본다
    var shortTitle: String { kind == "task" ? SquadBoard.shortTitle(jobTitle, max: 72) : SquadBoard.shortTitle(jobTitle) }   // 업무는 "프로젝트 › 업무" 를 넉넉히
    /// 카드의 한 줄 요약 — 엔진 `brief` 와 같다: 보고 요약 → 미션 → 다음 업무 제목 → 프로젝트 목표 순
    var brief: String { SquadBoard.briefLine(summary.isEmpty ? (mission.isEmpty ? (stepTitle.isEmpty ? goal : stepTitle) : mission) : summary) }
    var mission: String = ""
    var stepTitle: String = ""

    var autoLabel: String {
        switch auto {
        case "started": return L.t("자동 진행됨", "Auto-started")
        case "confirm": return L.t("확인 필요", "Needs your OK")
        case "limit":   return L.t("상한으로 멈춤", "Stopped at limit")
        case "rejected": return L.t("거절함", "Rejected")
        default:        return ""
        }
    }
    var autoColor: Color {
        switch auto {
        case "started": return .buniOk
        case "limit":   return .buniDanger
        case "rejected": return .buniDim
        default:        return .buniWarn
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

    /// 업무 하나의 칼럼 — 끝난 업무 완료, 내 승인·검토를 기다리는 업무 검토, 한도·오류·멈춤이면 확인 필요, 나머지는 업무 상태를 따른다
    static func taskColumn(jobState: String, task t: TeamTask) -> SquadColumn {
        if jobState == "cancelled" { return .done }
        switch t.status ?? "todo" {
        case "done":   return .done
        case "review": return .review
        default:       break
        }
        if ["failed", "waiting_limit", "paused"].contains(jobState) { return .blocked }
        return t.status == "doing" ? .running : .ready
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
                c.goal = j.goal ?? ""
                c.changedFiles = j.changedFiles ?? 0
                if c.instruction.isEmpty { c.instruction = c.mission.isEmpty ? c.goal : c.mission }
                c.searchText = ([c.jobTitle, j.goal ?? "", c.assignee, c.recent, c.summary, c.stateNames] + extra).joined(separator: " ").lowercased()
                return c
            }
            if roles.isEmpty {
                let (name, _) = statusInfo(j.state)
                let col = column(jobState: j.state, roleStatus: nil)
                var card = SquadItem(id: j.id, jobId: j.id, jobTitle: j.displayTitle, roleId: nil,
                                     assigneeId: "lead", assignee: L.t("팀장", "Team lead"), icon: "🐰",
                                     column: col, stateLabel: name,
                                     recent: !errorLine.isEmpty ? errorLine : (j.busyMsg ?? ""),
                                     since: jobSince, progressDone: 0, progressTotal: 0, updated: jobSince, kind: "job")
                card.stateNames = bothNames(jobNames[j.state] ?? (j.state, j.state))
                card.why = briefLine(why(col, nil, j.state, errorLine))
                out.append(searchable(card))
                continue
            }
            let sessions = TeamStore.readSessions(jobId: j.id)
            defer {
                // 아직 시작하지 않은 '다음에 할 일' — 자동 진행되지 않은 이유(확인 필요 · 상한)를 카드로 보여 준다
                for s in steps where s.roleId == nil && s.jobId == nil {
                    let held = s.auto == "confirm" || s.auto == "limit"
                    let closed = s.rejected                  // 거절해서 닫은 항목 — 완료 칼럼에 남겨 이력을 본다
                    var it = SquadItem(id: j.id + "|step:" + s.id, jobId: j.id, jobTitle: j.displayTitle + " › " + s.title, roleId: nil,
                                       assigneeId: "lead", assignee: L.t("팀장", "Team lead"), icon: "🐰",
                                       column: closed ? .done : held ? .blocked : .ready,
                                       stateLabel: closed ? L.t("거절함", "Rejected") : held ? SquadColumn.blocked.title : SquadColumn.ready.title,
                                       recent: s.why, since: jobSince, progressDone: 0, progressTotal: 0, updated: jobSince,
                                       kind: "next", auto: closed ? "rejected" : held ? (s.auto ?? "") : "", summary: s.goal)
                    it.stateNames = closed ? "거절함 Rejected" : held ? bothNames(("확인 필요", "Needs attention")) : bothNames(("대기", "Waiting"))
                    it.stepId = s.id
                    it.stepTitle = s.title
                    it.instruction = s.goal
                    it.why = briefLine(!s.why.isEmpty ? s.why : closed ? "거절해서 닫았어요" : "시작을 기다려요")
                    it = searchable(it, s.title)
                    out.append(it)
                }
            }
            if let tasks = j.tasks, !tasks.isEmpty {
                // 내가 지시한 업무마다 카드 한 장 — "프로젝트 › 업무" 로 어떤 업무인지 바로 보인다 (업무 보드의 카드와 같은 카드)
                for t in tasks.sorted(by: { ($0.rank, $0.created ?? 0) < ($1.rank, $1.created ?? 0) }) {
                    let col = taskColumn(jobState: j.state, task: t)
                    let ids = (t.parts ?? [:]).sorted { $0.value < $1.value }.map { $0.key }
                    let names = ids.map { rid in roles.first(where: { $0.id == rid })?.name ?? rid }
                    let doneParts = (t.partStatus ?? [:]).values.filter { $0 == "done" }.count
                    var label: String
                    switch col {
                    case .blocked: label = statusInfo(j.state).0
                    case .review:  label = taskNeedsApproval(t) ? L.t("승인 필요", "Needs OK") : L.t("검토 중", "In review")
                    default:       label = col.title
                    }
                    var recent = ""
                    if col == .running, let rid = ids.first(where: { t.partStatus?[$0] == "doing" }) {
                        recent = TeamStore.readActivity(jobId: j.id, key: rid).lines.last?.text ?? ""
                    } else if col == .blocked {
                        recent = errorLine
                    }
                    let sum = ids.compactMap { j.roles?[$0]?.summary }.first(where: { !$0.isEmpty }) ?? ""
                    if recent.isEmpty { recent = sum.split(separator: "\n").first.map(String.init) ?? "" }
                    var it = SquadItem(id: j.id + "|task:" + t.id, jobId: j.id, jobTitle: j.displayTitle + " › " + (t.title ?? ""), roleId: ids.first,
                                       assigneeId: ids.first ?? "lead", assignee: names.isEmpty ? L.t("팀장", "Team lead") : names.joined(separator: ", "),
                                       icon: roles.first(where: { $0.id == ids.first })?.icon ?? "🐰", column: col, stateLabel: label, recent: recent,
                                       since: t.created ?? jobSince, progressDone: doneParts, progressTotal: ids.count,
                                       updated: max(t.doneAt ?? 0, t.created ?? 0, col == .running ? now : 0), kind: "task", summary: sum)
                    it.taskId = t.id
                    if let step = steps.first(where: { $0.roleId != nil && $0.roleId == ids.first }) {
                        it.stepId = step.id
                        if step.auto == "started" { it.auto = "started" }
                    }
                    out.append(searchable(it, t.text ?? "", names.joined(separator: " ")))
                }
            } else {
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
                var card = SquadItem(id: j.id + "|" + r.id, jobId: j.id, jobTitle: j.displayTitle, roleId: r.id,
                                     assigneeId: r.id, assignee: r.name ?? r.id, icon: r.icon ?? "🧑‍💻",
                                     column: col, stateLabel: label, recent: recent, since: since,
                                     progressDone: accepted, progressTotal: roles.count, updated: jobSince,
                                     auto: step?.auto == "started" ? "started" : "", summary: st?.summary ?? "")
                let jobLevel = col == .blocked || (col == .review && (status == "pending" || status == "accepted"))
                card.stateNames = bothNames(jobLevel ? (jobNames[j.state] ?? (j.state, j.state)) : (roleNames[status] ?? roleNames["pending"]!))
                card.stepId = step?.id
                card.duty = r.dutyLabel
                card.mission = r.mission ?? ""
                card.stepTitle = step?.title ?? ""
                card.instruction = [r.mission ?? "", (r.deliverable ?? "").isEmpty ? "" : "산출물: " + r.deliverable!].filter { !$0.isEmpty }.joined(separator: "\n")
                card.why = briefLine(why(col, status, j.state, errorLine, st?.feedback ?? ""))
                out.append(searchable(card, r.mission ?? "", step?.title ?? ""))
            }
            }
        }
        return out
    }

    /// 엔진 `_BOARD_JOB_NAMES` / `_BOARD_ROLE_NAMES` — 상태 이름 (한글, 영어). 화면 언어와 상관없이 검색에 둘 다 쓴다
    static let jobNames: [String: (String, String)] = [
        "draft": ("작성 중", "Draft"), "interviewing": ("질문 답변 중", "Answering"),
        "review_requirements": ("요구서 승인 대기", "Awaiting approval"), "queued": ("예약됨", "Scheduled"),
        "running": ("진행 중", "Running"), "waiting_limit": ("한도 대기", "Waiting (limit)"),
        "paused": ("잠시 멈춤", "Paused"), "review": ("검토 대기", "Ready to review"), "done": ("검토 완료", "Done"),
        "failed": ("실패", "Failed"), "cancelled": ("취소됨", "Cancelled")]
    static let roleNames: [String: (String, String)] = [
        "running": ("작업 중", "Working"), "done_unreviewed": ("검토 대기", "In review"),
        "revise": ("다시 작업", "Revising"), "accepted": ("통과", "Accepted"), "pending": ("대기", "Waiting")]

    static func bothNames(_ p: (String, String)) -> String { p.0 + " " + p.1 }

    /// 담당자순 비교 — 엔진 `assignee_key` 와 같다: 대소문자 무시(소문자 유니코드 값 순) 후 같으면 원래 글자 순.
    /// 지역 설정에 따라 달라지는 localizedCompare 를 쓰지 않아 맥·Windows 순서가 같다 (영문 → 한글 순, 같은 이름은 원래 순서 유지).
    static func assigneeLess(_ a: String, _ b: String) -> Bool {
        let ka = Array(a.lowercased().unicodeScalars.map { $0.value }), kb = Array(b.lowercased().unicodeScalars.map { $0.value })
        if ka != kb { return ka.lexicographicallyPrecedes(kb) }
        return Array(a.unicodeScalars.map { $0.value }).lexicographicallyPrecedes(Array(b.unicodeScalars.map { $0.value }))
    }

    static let briefMax = 60       // 엔진 BRIEF_MAX

    /// 한 줄 요약 — 엔진 `brief_line` 과 같다: 첫 줄의 마크다운 머리표(#·-·>)를 떼고 공백을 하나로, 길면 briefMax 글자로
    static func briefLine(_ text: String, max n: Int = briefMax) -> String {
        let marks = CharacterSet(charactersIn: "#-> \t")
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }
        guard let first = lines.first(where: { !$0.trimmingCharacters(in: marks).isEmpty }) else { return "" }
        let t = first.trimmingCharacters(in: .whitespaces).drop(while: { "#-> \t".contains($0) })
        let one = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return one.count <= n ? one : String(one.prefix(n - 1)) + "…"
    }

    /// 상태 이유 한 줄 — 엔진 `board_why` 와 같은 문구
    static func why(_ col: SquadColumn, _ roleStatus: String?, _ jobState: String, _ err: String = "", _ feedback: String = "") -> String {
        switch col {
        case .blocked:
            if !err.isEmpty { return err }
            return ["failed": "실패로 멈췄어요", "waiting_limit": "플랜 한도가 풀리길 기다려요", "paused": "잠시 멈춰 있어요"][jobState] ?? "확인이 필요해요"
        case .done:    return roleStatus == "accepted" ? "통과했어요" : "프로젝트가 끝났어요"
        case .review:  return "결과가 나와 검토를 기다려요"
        case .running: return roleStatus == "revise" ? "고쳐 달라는 요청을 반영하는 중이에요" + (feedback.isEmpty ? "" : ": " + feedback) : "작업하는 중이에요"
        case .ready:   return "시작을 기다려요"
        }
    }

    static let titleMax = 36      // 엔진 BOARD_TITLE_MAX

    /// 첫 줄만, 공백을 하나로, 길면 titleMax 글자(말줄임표 포함)로 줄인다
    static func shortTitle(_ text: String, max n: Int = titleMax) -> String {
        let first = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { !$0.isEmpty }) ?? ""
        let t = first.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.count <= n ? t : String(t.prefix(n - 1)) + "…"
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
        TeamLive {
            let now = Date().timeIntervalSince1970
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
                    if listMode { listView(shown, now) } else { boardView(shown, now) }
                }
            }
            // 업무 상세 — 오른쪽 벽에 붙이지 않고 화면 가운데에 팝업으로 연다 (바깥을 누르거나 Esc 로 닫는다)
            .overlay {
                if let sel = all.first(where: { $0.id == selectedId }) {
                    detailPopup(sel, now)
                }
            }
        }
        .task {
            // 승인 대기 · 반영한 변경(되돌리기·화면 비교)은 git 으로 확인하는 일이라 가끔만 다시 본다
            while !Task.isCancelled {
                store.refreshAllApplyStates()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func detailPopup(_ sel: SquadItem, _ now: Double) -> some View {
        GeometryReader { g in
            ZStack {
                Color.black.opacity(0.45)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedId = nil }
                SquadItemDetail(item: sel, now: now, onGoto: onGoto, onClose: { selectedId = nil }).id(sel.id)
                    .frame(width: min(580, max(320, g.size.width - 48)), height: min(660, max(320, g.size.height - 48)))
                    .background(RoundedRectangle(cornerRadius: BuniTokens.Radius.xl, style: .continuous).fill(BT.surface1))
                    .overlay(RoundedRectangle(cornerRadius: BuniTokens.Radius.xl, style: .continuous).stroke(BT.borderStrong, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: BuniTokens.Radius.xl, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                Button("") { selectedId = nil }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)   // Esc
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .transition(.opacity)
    }

    // MARK: 필터 · 정렬

    private func filtered(_ items: [SquadItem]) -> [SquadItem] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)   // 엔진 str.split() — 탭·줄바꿈·전각 공백도 단어 구분
        let f = items.filter { it in
            (statusFilter == nil || it.column == statusFilter) && (assigneeFilter.isEmpty || it.assigneeId == assigneeFilter)
                && (scope == .all || (scope == .finished) == (it.column == .done))
                && words.allSatisfy { it.searchText.contains($0) }
        }
        switch sort {
        case .recent:   return f.sorted { $0.updated > $1.updated }
        case .oldest:   return f.sorted { $0.since < $1.since }
        case .state:    return f.sorted { (SquadColumn.allCases.firstIndex(of: $0.column) ?? 0) < (SquadColumn.allCases.firstIndex(of: $1.column) ?? 0) }
        case .assignee: return f.sorted { SquadBoard.assigneeLess($0.assignee, $1.assignee) }
        }
    }

    private func toolbar(_ all: [SquadItem]) -> some View {
        var people: [(id: String, name: String)] = []
        for i in all where !people.contains(where: { $0.id == i.assigneeId }) { people.append((i.assigneeId, i.assignee)) }
        return HStack(spacing: 10) {
            Text("📊 " + L.t("전체 현황", "Overview")).font(.system(size: 15, weight: .heavy))
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
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.buniField))
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
            .background(RoundedRectangle(cornerRadius: 8).fill(statusFilter == filter && filter != nil ? Color.buniRaised : Color.buniField))
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
                    VStack(alignment: .leading, spacing: BuniTokens.Space.s3) {
                        HStack(spacing: 6) {
                            Circle().fill(col.color).frame(width: 7, height: 7)
                            Text(col.title).font(.system(size: BuniTokens.Font.sizeXs, weight: .bold)).foregroundColor(BT.textSecondary).textCase(.uppercase)
                            Text("\(list.count)").font(.system(size: BuniTokens.Font.sizeXs, weight: .semibold)).foregroundColor(BT.textTertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(list) { it in
                                    if it.kind == "task", let job = store.jobs.first(where: { $0.id == it.jobId }), let task = job.tasks?.first(where: { $0.id == it.taskId }) {
                                        SquadTaskCard(job: job, task: task, column: taskBoardColumn(it.column), showProject: true,
                                                      onOpenDM: { rid in onGoto(it, .dm(rid)) })
                                            .overlay(RoundedRectangle(cornerRadius: BuniTokens.Radius.md + 2, style: .continuous)
                                                .stroke(it.id == selectedId ? it.column.color : .clear, lineWidth: 2).allowsHitTesting(false))
                                            .onTapGesture { selectedId = it.id }
                                    } else {
                                        SquadCard(item: it, now: now, selected: it.id == selectedId) { selectedId = it.id }
                                    }
                                }
                                if list.isEmpty {
                                    Text(L.t("비어 있음", "Empty")).font(.system(size: BuniTokens.Font.sizeXs)).foregroundColor(BT.textTertiary.opacity(0.7))
                                        .frame(maxWidth: .infinity, minHeight: 52)
                                        .overlay(RoundedRectangle(cornerRadius: BuniTokens.Radius.md, style: .continuous)
                                            .strokeBorder(BT.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                }
                            }
                        }
                    }
                    .padding(8).frame(width: 290)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: BuniTokens.Radius.lg, style: .continuous).fill(BT.surface1.opacity(0.55)))
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
        let v = Text(t).font(.system(size: 10, weight: .heavy)).foregroundColor(.buniDim).textCase(.uppercase)
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
                Text(item.shortTitle).font(.system(size: 12, weight: .bold)).foregroundColor(.white).lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    SquadAvatar(icon: item.icon, id: item.assigneeId, size: 18)
                    Text(item.assignee).font(.system(size: 11)).foregroundColor(.buniInk2).lineLimit(1)
                    Spacer(minLength: 2)
                    Chip(text: item.stateLabel, color: item.column.color)
                }
                if !item.duty.isEmpty {
                    Text(item.duty).font(.system(size: 10)).foregroundColor(SQ.dim).lineLimit(1)
                }
                if !item.autoLabel.isEmpty {
                    Text("⟳ " + item.autoLabel).font(.system(size: 10, weight: .bold)).foregroundColor(item.autoColor)
                }
                if !item.brief.isEmpty {
                    Text(item.brief).font(.system(size: 10.5)).foregroundColor(.buniInk2).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if !item.why.isEmpty {
                    Text("· " + item.why).font(.system(size: 10.5)).foregroundColor(SQ.dim).lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if !item.recent.isEmpty, item.recent != item.why {
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
            .background(RoundedRectangle(cornerRadius: BuniTheme.rMd).fill(hover ? Color.buniRaised : Color.buniPanel))
            .overlay(RoundedRectangle(cornerRadius: BuniTheme.rMd).stroke(selected ? item.column.color : SQ.line, lineWidth: selected ? 2 : 1))
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
                    Text(item.shortTitle).font(.system(size: 12, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    if !item.autoLabel.isEmpty {
                        Text("⟳ " + item.autoLabel).font(.system(size: 9.5, weight: .bold)).foregroundColor(item.autoColor).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    SquadAvatar(icon: item.icon, id: item.assigneeId, size: 16)
                    Text(item.assignee).font(.system(size: 11)).foregroundColor(.buniInk2).lineLimit(1)
                }.frame(width: 120, alignment: .leading)
                Group {
                    if item.progressTotal > 0 { SquadProgressBar(done: item.progressDone, total: item.progressTotal, color: item.column.color) }
                    else { Text("—").foregroundColor(SQ.dim) }
                }.frame(width: 110, alignment: .leading)
                Text(item.brief.isEmpty ? (item.recent.isEmpty ? "—" : item.recent) : item.brief).font(.system(size: 11)).foregroundColor(SQ.dim).lineLimit(1)
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

// MARK: - 변경 전·후 화면 (바뀐 영역은 엔진 job_screens 가 계산해 screens.json 에 저장 — Windows 와 같은 값)

struct SquadShot: Identifiable, Equatable {
    var name: String
    var before: String            // PNG 경로
    var after: String
    var w: Int                    // 이미지 크기(px) — 테두리 좌표의 기준
    var h: Int
    var boxes: [[Double]]         // [x, y, 너비, 높이] (px)
    var error: String             // 비어 있지 않으면 테두리 없이 이미지만, 이 이유를 보여 준다
    var captured: Bool = true     // false 면 전·후 중 한쪽이 없다 — '캡처 아님'으로 보여 준다
    var reason: String = ""       // 캡처하지 못한 이유
    var id: String { name }

    /// 작업 폴더의 screens.json — 엔진 `job_screens` 가 쓴다 (없으면 빈 목록)
    static func read(jobId: String) -> [SquadShot] {
        let url = TeamStore.jobsDir.appendingPathComponent(jobId).appendingPathComponent("screens.json")
        guard let data = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = o["items"] as? [[String: Any]] else { return [] }
        return items.map { i in
            SquadShot(name: i["name"] as? String ?? "", before: i["before"] as? String ?? "", after: i["after"] as? String ?? "",
                      w: (i["w"] as? NSNumber)?.intValue ?? 0, h: (i["h"] as? NSNumber)?.intValue ?? 0,
                      boxes: (i["boxes"] as? [[NSNumber]] ?? []).map { $0.map(\.doubleValue) }.filter { $0.count == 4 },
                      error: i["error"] as? String ?? "",
                      captured: i["captured"] as? Bool ?? true, reason: i["reason"] as? String ?? "")
        }
    }
}

/// 이미지 한 장 + 바뀐 영역 테두리(색은 accent 토큰). 테두리는 showBorder 로 켜고 끈다
private struct SquadShotImage: View {
    let path: String
    let shot: SquadShot
    let showBorder: Bool
    var body: some View {
        if path.isEmpty {
            Text(L.t("캡처 아님", "Not a capture")).font(.system(size: 11, weight: .bold)).foregroundColor(.buniWarn)
                .frame(maxWidth: .infinity, minHeight: 60)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(SQ.line, style: StrokeStyle(lineWidth: 1, dash: [3])))
        } else if let img = NSImage(contentsOfFile: path) {
            let pw = CGFloat(shot.w > 0 ? shot.w : Int(img.size.width)), ph = CGFloat(shot.h > 0 ? shot.h : Int(img.size.height))
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .overlay(GeometryReader { g in
                    if showBorder, pw > 0, ph > 0 {
                        ForEach(Array(shot.boxes.enumerated()), id: \.offset) { _, b in
                            Rectangle().stroke(Color.buniAccent, lineWidth: 2)
                                .frame(width: b[2] / pw * g.size.width, height: b[3] / ph * g.size.height)
                                .position(x: (b[0] + b[2] / 2) / pw * g.size.width, y: (b[1] + b[3] / 2) / ph * g.size.height)
                        }
                    }
                })
                .overlay(Rectangle().stroke(SQ.line, lineWidth: 1))
        } else {
            Text(L.t("이미지를 열지 못했어요", "Couldn't open the image")).font(.system(size: 10)).foregroundColor(SQ.dim)
        }
    }
}

/// 크게 보기 — 전/후를 오가며(←→·버튼) 보고, Esc·닫기·바깥 클릭으로 닫는다
private struct SquadShotZoom: View {
    let shots: [SquadShot]
    @State var index: Int
    @State var which: String            // "before" · "after"
    @Binding var showBorder: Bool
    var onClose: () -> Void

    var body: some View {
        let s = shots[min(index, shots.count - 1)]
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                tab(L.t("변경 전", "Before"), "before")
                tab(L.t("변경 후", "After"), "after")
                Button { showBorder.toggle() } label: { pill(showBorder ? L.t("테두리 끄기", "Hide outlines") : L.t("테두리 켜기", "Show outlines"), false) }
                    .buttonStyle(.plain).padding(.leading, 6)
                if shots.count > 1 {
                    Button { index = (index + shots.count - 1) % shots.count } label: { pill("‹", false) }.buttonStyle(.plain)
                    Button { index = (index + 1) % shots.count } label: { pill("›", false) }.buttonStyle(.plain)
                }
                Text(s.name).font(.system(size: 11)).foregroundColor(SQ.dim)
                Spacer()
                Button(action: onClose) { pill(L.t("닫기", "Close") + " (Esc)", false) }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            SquadShotImage(path: which == "before" ? s.before : s.after, shot: s, showBorder: showBorder)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !s.captured { Text("⚠ " + L.t("캡처 아님", "Not a capture") + (s.reason.isEmpty ? "" : " — " + s.reason)).font(.system(size: 11)).foregroundColor(.buniWarn) }
            else if !s.error.isEmpty { Text("⚠ " + s.error).font(.system(size: 11)).foregroundColor(.buniWarn) }
            Button("") { which = which == "after" ? "before" : "after" }.keyboardShortcut(.leftArrow, modifiers: []).hidden().frame(width: 0, height: 0)
            Button("") { which = which == "after" ? "before" : "after" }.keyboardShortcut(.rightArrow, modifiers: []).hidden().frame(width: 0, height: 0)
        }
        .padding(14).frame(minWidth: 640, minHeight: 460)
        .background(Color.buniPanel.contentShape(Rectangle()).onTapGesture { onClose() })
    }

    private func tab(_ title: String, _ key: String) -> some View {
        Button { which = key } label: { pill(title, which == key) }.buttonStyle(.plain)
    }

    private func pill(_ title: String, _ on: Bool) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(on ? .buniAccentInk : .white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.buniAccent : Color.buniRaised))
    }
}

/// 카드 상세 — 담당자 · 진행률 · 최근 활동 · 결과 · 관련 채팅, 같은 프로젝트의 화면(담당자 DM · 결과 · 스쿼드 채팅)과 Claude 로 이동
private struct SquadItemDetail: View {
    let item: SquadItem
    let now: Double
    var onGoto: (SquadItem, SquadPane) -> Void
    var onClose: () -> Void
    @ObservedObject private var store = TeamStore.shared
    @State private var shots: [SquadShot] = []
    @State private var showBorder = true
    @State private var zoom: SquadZoomTarget?

    struct SquadZoomTarget: Identifiable { let id = UUID(); let index: Int; let which: String }

    /// 변경 전·후 화면 — 썸네일(눌러서 크게 보기) + 테두리 켜기/끄기
    @ViewBuilder
    private var shotsSection: some View {
        if !shots.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("변경 전·후 화면", "Before / after screens")).font(.system(size: 10, weight: .heavy)).foregroundColor(.buniDim).textCase(.uppercase)
                Button { showBorder.toggle() } label: {
                    Text(showBorder ? L.t("테두리 끄기", "Hide outlines") : L.t("테두리 켜기", "Show outlines")).font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.white).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.buniRaised))
                }.buttonStyle(.plain)
                ForEach(Array(shots.enumerated()), id: \.offset) { i, s in
                    Text(s.name).font(.system(size: 10.5)).foregroundColor(.buniInk2)
                    HStack(alignment: .top, spacing: 6) {
                        ForEach([("before", L.t("변경 전", "Before")), ("after", L.t("변경 후", "After"))], id: \.0) { key, label in
                            VStack(spacing: 2) {
                                SquadShotImage(path: key == "before" ? s.before : s.after, shot: s, showBorder: showBorder)
                                    .frame(maxWidth: .infinity, maxHeight: 90)
                                    .onTapGesture { if !(key == "before" ? s.before : s.after).isEmpty { zoom = SquadZoomTarget(index: i, which: key) } }
                                Text(label + ((key == "before" ? s.before : s.after).isEmpty ? "" : " · " + L.t("눌러서 크게 보기", "click to enlarge"))).font(.system(size: 9)).foregroundColor(SQ.dim)
                            }
                        }
                    }
                    if !s.captured {
                        Text("⚠ " + L.t("캡처 아님", "Not a capture") + (s.reason.isEmpty ? "" : " — " + s.reason)).font(.system(size: 10.5)).foregroundColor(.buniWarn).fixedSize(horizontal: false, vertical: true)
                    } else if !s.error.isEmpty {
                        Text("⚠ " + s.error).font(.system(size: 10.5)).foregroundColor(.buniWarn).fixedSize(horizontal: false, vertical: true)
                    } else if s.boxes.isEmpty {
                        Text(L.t("바뀐 부분이 없어요", "No visible change")).font(.system(size: 10.5)).foregroundColor(SQ.dim)
                    } else {
                        Text(L.t("바뀐 영역 \(s.boxes.count)곳", "\(s.boxes.count) changed area(s)")).font(.system(size: 10.5)).foregroundColor(SQ.dim)
                    }
                }
            }.padding(.top, 4)
        }
    }

    private var draftKey: String { TeamDrafts.key(item.jobId, "step:" + (item.stepId ?? "")) }

    var body: some View {
        let job = store.jobs.first(where: { $0.id == item.jobId })
        let decisions = item.stepId.flatMap { sid in TeamStore.readWrapup(jobId: item.jobId)?.steps.first(where: { $0.id == sid })?.history } ?? []
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
                        Text(item.assignee).font(.system(size: 11.5)).foregroundColor(.buniInk)
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
                    section(L.t("상태 이유", "Why this status"), item.why.isEmpty ? [] : [item.why])
                    section(L.t("원래 지시", "Original instruction"), item.instruction.isEmpty ? [] : [String(item.instruction.prefix(300))])
                    section(L.t("바뀐 파일", "Changed files"), [item.changedFiles > 0 ? L.t("\(item.changedFiles)개", "\(item.changedFiles)") : L.t("기록 없음", "None recorded")])
                    section(L.t("전체 제목", "Full title"), [item.jobTitle])
                    section(L.t("설명", "Description"),
                            [item.roleId.flatMap { rid in job?.plan?.roles?.first(where: { $0.id == rid })?.mission }, job?.goal]
                                .compactMap { $0 }.filter { !$0.isEmpty })
                    section(L.t("최근 활동", "Recent activity"), activity.isEmpty ? (item.recent.isEmpty ? [] : [item.recent]) : activity)
                    section(L.t("결과 요약", "Result summary"), [item.summary.isEmpty ? L.t("아직 보고가 없어요", "No report yet") : String(item.summary.prefix(260))])
                    shotsSection
                    section(L.t("관련 채팅", "Related chat"), chat.map { "\(chatName($0.from, job)): \(String($0.text.prefix(70)))" })
                    section(L.t("결정 이력", "Decision history"), decisions.suffix(5).map { d in
                        let when = Date(timeIntervalSince1970: d.ts).formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                        return "\(d.label) · \(when)" + (d.text.isEmpty ? "" : " — \(String(d.text.prefix(60)))")
                    })
                    if item.kind == "next", let sid = item.stepId, let job { decisionBox(job, sid) }
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
        .onAppear { loadShots() }
        .sheet(item: $zoom) { z in
            SquadShotZoom(shots: shots, index: z.index, which: z.which, showBorder: $showBorder) { zoom = nil }
        }
    }

    /// 저장된 값을 바로 보여 주고, 엔진이 새로 계산하게 한 뒤(파일이 바뀐 때만 다시 계산) 다시 읽는다
    private func loadShots() {
        shots = SquadShot.read(jobId: item.jobId)
        let jid = item.jobId
        DispatchQueue.global(qos: .utility).async {
            _ = TeamStore.cli(["screens", jid])
            let fresh = SquadShot.read(jobId: jid)
            DispatchQueue.main.async { if fresh != shots { shots = fresh } }
        }
    }

    /// 보류 중인 '다음에 할 일' — 입력 글(`note`)을 자기 뷰 안에 가둬, 글자마다 상세 전체(body 의 파일 읽기)가 다시 돌지 않게 한다
    private func decisionBox(_ job: TeamJob, _ stepId: String) -> some View {
        SquadDecisionBox(job: job, stepId: stepId, draftKey: draftKey)
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
                Text(title).font(.system(size: 10, weight: .heavy)).foregroundColor(.buniDim).textCase(.uppercase)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 11)).foregroundColor(.buniInk2).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.top, 4)
        }
    }

    private func goButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.buniRaised))
        }.buttonStyle(.plain)
    }
}

/// [승인] [거절] [의견 남기기] — 처리한 뒤에도 언제든 다시 누를 수 있다 (Windows 와 같은 문구).
/// 입력 글은 이 뷰의 @State 에만 두고 저장은 `TeamDrafts`(메모리 + 0.6초 뒤 일괄 디스크)로 한다.
private struct SquadDecisionBox: View {
    let job: TeamJob
    let stepId: String
    let draftKey: String
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L.t("결정", "Decision")).font(.system(size: 10, weight: .heavy)).foregroundColor(.buniDim).textCase(.uppercase)
            TextField("", text: $note, axis: .vertical).textFieldStyle(.plain).lineLimit(1...4)
                .font(.system(size: 11)).foregroundColor(.white).padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.buniField))
                .onAppear { note = TeamDrafts.shared.get(draftKey) }
                .onChange(of: note) { TeamDrafts.shared.set(draftKey, $0) }
            Text(L.t("의견 · 이유 (의견 남기기에는 꼭 필요해요)", "Comment or reason (required to leave a comment)"))
                .font(.system(size: 10)).foregroundColor(SQ.dim)
            HStack(spacing: 6) {
                decideButton(L.t("✅ 승인", "✅ Approve"), Color.buniAccent) { send("approve") }
                decideButton(L.t("🚫 거절", "🚫 Reject"), Color.buniRaised) { send("reject") }
                decideButton(L.t("💬 의견 남기기", "💬 Leave a comment"), Color.buniRaised) { send("comment") }
            }
        }.padding(.top, 6)
    }

    private func send(_ decision: String) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if decision == "comment" && text.isEmpty { NSSound.beep(); return }
        note = ""                                       // 보낸 뒤에만 비운다 (초안도 함께 지워진다)
        TeamStore.shared.stepDecision(job, stepId: stepId, decision: decision, text: text)
    }

    private func decideButton(_ title: String, _ fill: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill))
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
                    Capsule().fill(Color.buniRaised)
                    Capsule().fill(color).frame(width: total > 0 ? g.size.width * CGFloat(done) / CGFloat(total) : 0)
                }
            }
            .frame(width: 50, height: 5)
            Text("\(done)/\(total)").font(.system(size: 10)).foregroundColor(SQ.dim)
        }
    }
}
