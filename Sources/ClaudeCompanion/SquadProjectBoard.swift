import SwiftUI
import AppKit

// 부니 스쿼드 — 업무 보드 (Jira 처럼: 누가 지금 무슨 업무를 하고 있고, 어떤 업무가 끝났는지)
// 칼럼: 대기 · 진행 중 · 검토 중 · 완료.  보고서는 두지 않는다 — 카드 하나가 업무 하나다.

enum BoardColumn: CaseIterable {
    case todo, doing, review, done
    var title: String {
        switch self {
        case .todo:   return L.t("대기", "To do")
        case .doing:  return L.t("진행 중", "In progress")
        case .review: return L.t("검토 중", "In review")
        case .done:   return L.t("완료", "Done")
        }
    }
    var color: Color {
        switch self {
        case .todo:   return BT.info
        case .doing:  return BT.success
        case .review: return BT.warning
        case .done:   return BT.textTertiary
        }
    }
}

/// 보드에 올릴 업무 — 엔진이 적어 둔 '내가 지시한 업무'가 있으면 그것, 옛 작업이면 팀원 미션을 업무로 본다
func boardTasks(_ job: TeamJob) -> [TeamTask] {
    if let t = job.tasks, !t.isEmpty { return t }
    return (job.plan?.roles ?? []).map { r in
        let st = job.roles?[r.id]?.status ?? "pending"
        let s: String = ["running": "doing", "revise": job.state == "running" ? "doing" : "todo", "done_unreviewed": "review", "accepted": "done"][st] ?? "todo"
        return TeamTask(id: r.id, title: squadSummary(r.mission ?? "", limit: 70).text, text: r.mission, source: "plan", priority: "normal",
                        created: job.created, status: s, partStatus: [r.id: s], doneAt: job.roles?[r.id]?.finished, applied: nil, files: nil, applyNote: nil, parts: [r.id: 0])
    }
}

func taskColumn(_ t: TeamTask) -> BoardColumn {
    switch t.status ?? "todo" {
    case "doing":  return .doing
    case "review": return .review
    case "done":   return .done
    default:       return .todo
    }
}

func priorityInfo(_ p: String?) -> (String, String, Color) {
    switch p ?? "normal" {
    case "urgent": return ("🔴", L.t("긴급", "Urgent"), BT.danger)
    case "high":   return ("🟠", L.t("높음", "High"), BT.warning)
    case "low":    return ("⚪️", L.t("낮음", "Low"), BT.textTertiary)
    default:       return ("🔵", L.t("보통", "Normal"), BT.info)
    }
}

struct SquadProjectBoard: View {
    let job: TeamJob
    var onOpenDM: (String) -> Void
    var onOpenTask: (String) -> Void = { _ in }      // 업무 카드를 누르면 상세 팝업을 연다 (팝업은 이 화면을 감싼 쪽이 그린다 — 여기는 스크롤 안이라 크기를 알 수 없다)
    @ObservedObject private var store = TeamStore.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: BuniTokens.Space.s5) {
                    header
                    applyBanner
                    if let s = job.plan?.summary, !s.isEmpty {
                        Text(s).font(.system(size: BuniTokens.Font.sizeSm)).foregroundColor(BT.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    columns
                    activityLog
                }
                .padding(BuniTokens.Space.s7)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { store.refreshApplyState(job) }
        .onChange(of: job.state) { _ in store.refreshApplyState(job) }
        .task(id: job.id) {
            // 반영할 변경이 있는지는 git 으로 확인하는 일이라 가끔만 다시 본다
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                store.refreshApplyState(job)
            }
        }
    }

    private var applyState: TeamStore.ApplyState { store.applyStates[job.id] ?? TeamStore.ApplyState() }

    // MARK: 머리 — 상태 · 방식 · 버튼

    private var header: some View {
        VStack(alignment: .leading, spacing: BuniTokens.Space.s3) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(headline.0).font(.system(size: BuniTokens.Font.sizeLg, weight: .semibold)).foregroundColor(headline.1)
                Spacer()
                modeMenus
            }
            HStack(spacing: 8) {
                if job.userPaused == true || store.settings.paused {
                    Button { if store.settings.paused { store.setGlobalPause(false) }; if job.userPaused == true { store.resumeJob(job) } } label: { Text(L.t("▶ 이어서", "▶ Resume")) }
                        .buttonStyle(PillButtonStyle(color: BT.accentBase))
                } else if ["queued", "running", "waiting_limit"].contains(job.state) || (job.state == "paused" && job.phase != "waiting_start") {
                    Button { store.pauseJob(job) } label: { Text(L.t("⏸ 멈추기", "⏸ Pause")) }
                        .buttonStyle(PillButtonStyle(color: BT.quiet))
                }
                if ["queued", "paused", "waiting_limit"].contains(job.state), job.userPaused != true {
                    Button { store.runNow(job) } label: { Text(L.t("▶ 지금 바로 시작", "▶ Start now")) }
                        .buttonStyle(PillButtonStyle(color: BT.accentBase))
                }
                if job.state == "failed" {
                    Button { store.retry(job) } label: { Text(L.t("🔁 다시 시도", "🔁 Retry")) }
                        .buttonStyle(PillButtonStyle(color: BT.accentBase))
                }
                if job.state == "review" {
                    Button { store.markDone(job) } label: { Text(L.t("✅ 완료 처리", "✅ Mark done")) }
                        .buttonStyle(PillButtonStyle(color: BT.accentBase))
                }
                if ["queued", "running", "paused", "waiting_limit"].contains(job.state) { TeamCancelButton(job: job) }
                Button { store.delete(job) } label: { Text(L.t("🗑 삭제", "🗑 Delete")) }
                    .buttonStyle(PillButtonStyle(color: BT.quiet))
                Spacer()
                Text(L.t("약 $\(String(format: "%.2f", job.costUsd ?? 0))", "≈ $\(String(format: "%.2f", job.costUsd ?? 0))"))
                    .font(.system(size: BuniTokens.Font.sizeXs)).foregroundColor(BT.textTertiary)
            }
            if let e = job.error, !e.isEmpty, job.state == "failed" {
                Text("⚠ " + e).font(.system(size: BuniTokens.Font.sizeSm)).foregroundColor(BT.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: (String, Color) {
        let s = store.settings
        if store.settings.paused { return (L.t("⏸ 모든 작업이 일시정지 중이에요 — ▶ 이어서 를 눌러 주세요", "⏸ All squad work is paused — press Resume"), BT.warning) }
        if job.userPaused == true && !["review", "done", "cancelled"].contains(job.state) {
            let limit = (job.events?.last?.msg.contains("한도") ?? false)
            return (limit ? L.t("⏸ Claude 사용량 한도에 닿아 멈췄어요 — 한도가 풀리면 ▶ 이어서", "⏸ Stopped at the Claude usage limit — resume once it resets")
                          : L.t("⏸ 멈춰 있어요 — ▶ 이어서 를 누르면 계속해요", "⏸ Paused — press Resume to continue"), BT.warning)
        }
        switch job.state {
        case "running":
            let phase: String = {
                switch job.phase {
                case "planning":  return L.t("팀을 꾸리는 중", "Building the team")
                case "working":   return L.t("팀원들이 일하는 중", "Team is working")
                case "reviewing": return L.t("팀장이 검토하는 중", "Lead is reviewing")
                case "merging":   return L.t("팀장이 결과를 합치는 중", "Lead is merging")
                default:          return L.t("진행 중", "Running")
                }
            }()
            return ("● " + phase, BT.success)
        case "waiting_limit":
            let at = job.resumeAt.map { shortClock.string(from: Date(timeIntervalSince1970: $0)) } ?? "?"
            return (L.t("⏸ 플랜 사용량 한도 — \(at) 이후에 이어서 해요", "⏸ Plan limit — continues after \(at)"), BT.warning)
        case "paused" where job.phase == "waiting_start":
            return (L.t("▶ 수동 진행 — 시작할 업무 카드의 [▶ 시작]을 눌러 주세요", "▶ Manual — press ▶ Start on a card"), BT.warning)
        case "queued", "paused":
            var msg = L.t("대기 중", "Waiting")
            if s.enabled, let n = nextWindowStartPublic(s) { msg = L.t("🌙 \(shortClock.string(from: n)) 에 시작해요", "🌙 Starts \(shortClock.string(from: n))") }
            else if !s.enabled { msg = L.t("예약이 꺼져 있어요 — 지금 바로 시작을 눌러 주세요", "Scheduling is off — press Start now") }
            return (msg, BT.info)
        case "review", "done":
            return (L.t("✓ 모든 업무가 끝났어요", "✓ All tasks are done"), BT.success)
        case "failed":
            return (L.t("✕ 오류로 멈췄어요", "✕ Stopped on an error"), BT.danger)
        case "cancelled":
            return (L.t("취소된 작업이에요", "Cancelled"), BT.textTertiary)
        default:
            return (statusInfo(job.state).0, BT.textSecondary)
        }
    }

    private var modeMenus: some View {
        HStack(spacing: 6) {
            modeMenu(title: L.t("진행", "Run"), current: job.runMode ?? "", effective: applyState.runMode,
                     options: [("", L.t("설정 따름", "Follow settings")), ("auto", L.t("자동", "Auto")), ("manual", L.t("수동 (업무마다 ▶ 시작)", "Manual (▶ per task)"))]) {
                store.setJobModes(job, run: $0)
            }
            modeMenu(title: L.t("반영", "Apply"), current: job.applyMode ?? "", effective: applyState.mode,
                     options: [("", L.t("설정 따름", "Follow settings")), ("smart", L.t("스마트 — 중요하면 확인", "Smart")), ("auto", L.t("자동 — 전부 바로", "Auto")),
                               ("confirm", L.t("확인 후 — 승인하면", "Confirm")), ("manual", L.t("수동 — 브랜치로만", "Manual"))]) {
                store.setJobModes(job, apply: $0)
            }
        }
    }

    private func modeMenu(title: String, current: String, effective: String, options: [(String, String)], pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.0) { o in
                Button { pick(o.0) } label: { Text((o.0 == current ? "✓ " : "") + o.1) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).foregroundColor(BT.textTertiary)
                Text(modeLabel(effective)).foregroundColor(BT.textPrimary)
            }
            .font(.system(size: BuniTokens.Font.sizeXs, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: BuniTokens.Radius.sm + 2, style: .continuous).fill(BT.surface2))
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func modeLabel(_ m: String) -> String {
        switch m {
        case "manual": return L.t("수동", "Manual")
        case "confirm": return L.t("확인 후", "Confirm")
        case "smart": return L.t("스마트", "Smart")
        default: return L.t("자동", "Auto")
        }
    }

    // MARK: 반영 배너 (자동이 아니거나, 자동 반영이 못 된 경우)

    @ViewBuilder
    private var applyBanner: some View {
        let a = applyState
        let finished = ["review", "done", "failed"].contains(job.state)
        if a.pending, finished || a.mode == "confirm" || a.mode == "manual" {
            VStack(alignment: .leading, spacing: 8) {
                Text(bannerTitle(a)).font(.system(size: BuniTokens.Font.sizeMd, weight: .semibold)).foregroundColor(BT.warning)
                if !a.reasons.isEmpty {
                    ForEach(a.reasons, id: \.self) { r in
                        Text("• " + r).font(.system(size: BuniTokens.Font.sizeSm)).foregroundColor(BT.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !a.note.isEmpty {
                    Text(a.note).font(.system(size: BuniTokens.Font.sizeXs)).foregroundColor(BT.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                Text(a.files.prefix(8).joined(separator: "\n") + (a.count > 8 ? "\n… " + L.t("외 \(a.count - 8)개", "+\(a.count - 8) more") : ""))
                    .font(.system(size: BuniTokens.Font.sizeXs, design: .monospaced)).foregroundColor(BT.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                HStack(spacing: 8) {
                    if a.mode != "manual" {
                        Button { store.approveChanges(job) } label: { Text(L.t("✅ 승인 — 바로 적용", "✅ Approve & apply now")) }
                            .buttonStyle(PillButtonStyle(color: BT.accentBase))
                    }
                    Button { store.openDiff(job) } label: { Text(L.t("📄 변경 내용 보기", "📄 View changes")) }
                        .buttonStyle(PillButtonStyle(color: BT.quiet))
                    Button { store.rejectChanges(job) } label: { Text(L.t("🚫 거절", "🚫 Reject")) }
                        .buttonStyle(PillButtonStyle(color: BT.quiet))
                    if a.mode == "manual" {
                        Text("git merge \(a.branch)").font(.system(size: BuniTokens.Font.sizeXs, design: .monospaced))
                            .foregroundColor(BT.textTertiary).textSelection(.enabled)
                    }
                }
            }
            .padding(BuniTokens.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BuniTokens.Radius.lg, style: .continuous).fill(BT.warning.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: BuniTokens.Radius.lg, style: .continuous).stroke(BT.warning.opacity(0.35), lineWidth: 1))
        } else if a.applied, !a.pending, ["review", "done"].contains(job.state) {
            Text(L.t("✓ 결과를 내 폴더에 반영했어요 (커밋은 안 했어요) — 앱은 다시 빌드해야 보여요",
                     "✓ Applied to your folder (not committed) — rebuild the app to see it"))
                .font(.system(size: BuniTokens.Font.sizeSm)).foregroundColor(BT.success)
        }
    }

    /// 왜 아직 안 들어왔는지를 제목에 그대로 쓴다
    private func bannerTitle(_ a: TeamStore.ApplyState) -> String {
        if a.mode == "manual" { return L.t("📦 수동 — 바뀐 파일 \(a.count)개는 브랜치 \(a.branch) 에만 있어요", "📦 Manual — \(a.count) changed files are only on branch \(a.branch)") }
        if !a.note.isEmpty { return L.t("⚠️ 자동 반영이 안 됐어요 (내 폴더와 겹침) — 바뀐 파일 \(a.count)개", "⚠️ Couldn't apply (conflicts with your folder) — \(a.count) files") }
        if !a.reasons.isEmpty { return L.t("✋ 중요한 변경이라 확인이 필요해요 — 바뀐 파일 \(a.count)개", "✋ Important change — please confirm — \(a.count) files") }
        if a.mode == "confirm" { return L.t("✋ 내 폴더에 반영할까요? 바뀐 파일 \(a.count)개", "✋ Apply to your folder? \(a.count) files") }
        return L.t("⏳ 아직 반영되지 않았어요 — 바뀐 파일 \(a.count)개 (곧 자동으로 반영해요)", "⏳ Not applied yet — \(a.count) files (will apply automatically)")
    }

    // MARK: 칼럼 — 내가 지시한 업무 단위

    private var columns: some View {
        let tasks = boardTasks(job).sorted { ($0.rank, $0.created ?? 0) < ($1.rank, $1.created ?? 0) }
        return ViewThatFits(in: .horizontal) {
            columnRow(tasks)
            ScrollView(.horizontal, showsIndicators: false) { columnRow(tasks) }
        }
    }

    private func columnRow(_ tasks: [TeamTask]) -> some View {
        HStack(alignment: .top, spacing: BuniTokens.Space.s4) {
            ForEach(BoardColumn.allCases, id: \.self) { col in
                let items = tasks.filter { taskColumn($0) == col }
                VStack(alignment: .leading, spacing: BuniTokens.Space.s3) {
                    HStack(spacing: 6) {
                        Circle().fill(col.color).frame(width: 7, height: 7)
                        Text(col.title).font(.system(size: BuniTokens.Font.sizeXs, weight: .bold)).foregroundColor(BT.textSecondary).textCase(.uppercase)
                        Text("\(items.count)").font(.system(size: BuniTokens.Font.sizeXs, weight: .semibold)).foregroundColor(BT.textTertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    VStack(spacing: BuniTokens.Space.s3) {
                        ForEach(col == .done ? items.sorted { ($0.doneAt ?? 0) > ($1.doneAt ?? 0) } : items) { t in
                            SquadTaskCard(job: job, task: t, column: col, onOpenDM: onOpenDM)
                                .onTapGesture { onOpenTask(t.id) }
                        }
                        if items.isEmpty {
                            Text(L.t("비어 있음", "Empty")).font(.system(size: BuniTokens.Font.sizeXs)).foregroundColor(BT.textTertiary.opacity(0.7))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .overlay(RoundedRectangle(cornerRadius: BuniTokens.Radius.md, style: .continuous)
                                    .strokeBorder(BT.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        }
                    }
                }
                .padding(BuniTokens.Space.s3)
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: BuniTokens.Radius.lg, style: .continuous).fill(BT.surface1.opacity(0.55)))
            }
        }
    }

    // MARK: 최근 활동

    @ViewBuilder
    private var activityLog: some View {
        let ev = Array((job.events ?? []).suffix(10).reversed())
        if !ev.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("최근 활동", "Activity")).font(.system(size: BuniTokens.Font.sizeXs, weight: .bold)).foregroundColor(BT.textTertiary).textCase(.uppercase)
                ForEach(Array(ev.enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(shortClock.string(from: Date(timeIntervalSince1970: e.ts)))
                            .font(.system(size: BuniTokens.Font.sizeXs, design: .monospaced)).foregroundColor(BT.textTertiary)
                        Text(e.msg).font(.system(size: BuniTokens.Font.sizeSm)).foregroundColor(BT.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private let shortClock: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f
}()

private func nextWindowStartPublic(_ s: TeamSettings) -> Date? {
    guard let m = squadMinutes(s.windowStart) else { return nil }
    let cal = Calendar.current
    var d = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    if d <= Date() { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
    return d
}

private func squadMinutes(_ hhmm: String) -> Int? {
    let p = hhmm.split(separator: ":")
    guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
    return h * 60 + m
}
