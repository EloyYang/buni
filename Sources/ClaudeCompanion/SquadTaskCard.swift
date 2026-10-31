import SwiftUI
import AppKit

// 부니 스쿼드 — 업무 카드 한 장 (업무 보드와 업무 현황이 똑같이 쓴다)
// 업무 하나 = 내가 지시한 일 하나. 끝나면 "승인 → 바로 내 폴더에 적용", 화면이 바뀌었으면 변경 전·후를 나란히 보고 되돌릴 수 있다.

/// 승인이 필요한 업무인지 (중요한 변경이라 · 겹쳐서) — 아직 내 폴더에 안 들어온 것만
func taskNeedsApproval(_ t: TeamTask) -> Bool {
    (t.approval == "needs" || t.approval == "conflict") && t.applied == nil && t.rejected == nil
}

/// 업무 현황의 칼럼 → 업무 카드가 쓰는 칼럼
func taskBoardColumn(_ c: SquadColumn) -> BoardColumn {
    switch c {
    case .running: return .doing
    case .review:  return .review
    case .done:    return .done
    default:       return .todo
    }
}

/// 업무 카드의 버튼 — 용도마다 모양이 정해져 있다 (한 카드에 주 버튼은 하나만).
/// primary 승인·시작 · danger 거절 · secondary 화면 비교·되돌리기 · quiet 대화·추가 요청·변경 내용
struct CardActionStyle: ButtonStyle {
    enum Kind { case primary, danger, secondary, quiet }
    var kind: Kind = .secondary
    var fill = false                 // true 면 남는 가로 폭을 채운다 (주 버튼)
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: BuniTokens.Font.sizeSm, weight: .semibold))
            .lineLimit(1)
            .foregroundColor(textColor)
            .padding(.horizontal, BuniTokens.Space.s4)
            .frame(maxWidth: fill ? .infinity : nil, minHeight: 28, maxHeight: 28)
            .background(RoundedRectangle(cornerRadius: BuniTokens.Radius.md, style: .continuous).fill(bg(pressed)))
            .overlay(RoundedRectangle(cornerRadius: BuniTokens.Radius.md, style: .continuous).stroke(border, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: BuniTokens.Radius.md))
            .onHover { hover = $0 }
            .animation(.easeOut(duration: BuniTokens.Motion.fast), value: hover)
    }

    private var textColor: Color {
        switch kind {
        case .primary:   return BT.textOnAccent
        case .danger:    return BT.danger
        case .secondary: return BT.textPrimary
        case .quiet:     return BT.textSecondary
        }
    }
    private var border: Color {
        switch kind {
        case .primary, .quiet: return .clear
        case .danger:          return BT.danger.opacity(0.35)
        case .secondary:       return BT.borderStrong.opacity(0.7)
        }
    }
    private func bg(_ pressed: Bool) -> Color {
        switch kind {
        case .primary:   return pressed ? BT.accentHover.opacity(0.85) : (hover ? BT.accentHover : BT.accentBase)
        case .danger:    return BT.danger.opacity(pressed || hover ? 0.22 : 0.12)
        case .secondary: return pressed || hover ? BT.surface3 : BT.surface2
        case .quiet:     return pressed ? BT.surface3 : (hover ? BT.surface2 : .clear)
        }
    }
}

/// 아이콘 + 글자 — 이모지 대신 시스템 기호를 쓴다 (부니 디자인: 아이콘은 글자와 같은 굵기·색)
private func actionLabel(_ text: String, _ symbol: String) -> some View {
    HStack(spacing: BuniTokens.Space.s2) {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        Text(text)
    }
}

struct SquadTaskCard: View {
    let job: TeamJob
    let task: TeamTask
    var column: BoardColumn
    var showProject: Bool = false          // 업무 현황(여러 프로젝트)에서는 "프로젝트 › 업무" 로 어느 프로젝트의 업무인지 보여 준다
    var onOpenDM: (String) -> Void = { _ in }
    @ObservedObject private var store = TeamStore.shared
    @State private var hover = false
    @State private var moreOpen = false
    @State private var moreText = ""
    @State private var shotsOpen = false

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"; return f
    }()

    private var partIds: [String] { (task.parts ?? [:]).sorted { $0.value < $1.value }.map { $0.key } }
    private func role(_ id: String) -> TeamRole? { job.plan?.roles?.first { $0.id == id } }
    private var doneCount: Int { (task.partStatus ?? [:]).values.filter { $0 == "done" }.count }
    private var change: TeamStore.ChangeInfo? {
        guard let cid = task.changeId else { return nil }
        return store.applyStates[job.id]?.changes.first { $0.id == cid }
    }
    private var needsApproval: Bool { taskNeedsApproval(task) }

    var body: some View {
        let (pIcon, pName, pColor) = priorityInfo(task.priority)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(["urgent", "high", "normal", "low"], id: \.self) { p in
                        let i = priorityInfo(p)
                        Button { store.setTaskPriority(job, task: task, priority: p) } label: { Text((p == (task.priority ?? "normal") ? "✓ " : "") + i.0 + " " + i.1) }
                    }
                } label: {
                    Text(pIcon + " " + pName + " ▾").font(.system(size: 10, weight: .bold)).foregroundColor(pColor).lineLimit(1).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(pColor.opacity(0.16)))
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize().help(L.t("우선순위 — 급한 업무를 맡은 팀원부터 일해요", "Priority — urgent tasks go first"))
                if needsApproval {
                    Text(L.t("내 승인 필요", "Needs my OK")).font(.system(size: 10, weight: .bold)).foregroundColor(BT.warning).lineLimit(1).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(BT.warning.opacity(0.16)))
                }
                Spacer(minLength: 2)
                if let c = task.created, c > 0 { Text(Self.clock.string(from: Date(timeIntervalSince1970: c))).font(.system(size: 9.5)).foregroundColor(BT.textTertiary) }
            }
            titleView
            if let text = task.text, !text.isEmpty, (task.source == "chat" || task.source == "note"), text.count > (task.title?.count ?? 0) + 4 {
                Text(squadSummary(text, limit: 150).text).font(.system(size: BuniTokens.Font.sizeXs)).foregroundColor(BT.textTertiary).lineLimit(2)
            }
            parts
            progressLine
            detail
            reviewBlock
            actions
        }
        .padding(BuniTokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BuniTokens.Radius.md + 2, style: .continuous).fill(hover ? BT.surface2 : BT.surface1))
        .overlay(RoundedRectangle(cornerRadius: BuniTokens.Radius.md + 2, style: .continuous)
            .stroke(needsApproval ? BT.warning.opacity(0.6)
                    : (column == .doing ? BT.success.opacity(0.5) : (task.priority == "urgent" && column != .done ? BT.danger.opacity(0.5) : BT.borderSubtle)), lineWidth: 1))
        .onHover { hover = $0 }
        .animation(.easeOut(duration: BuniTokens.Motion.fast), value: hover)
        .sheet(isPresented: $shotsOpen) {
            if let c = change { SquadShotsSheet(job: job, change: c, task: task, close: { shotsOpen = false }) }
        }
    }

    /// 프로젝트 › 업무 — 어느 프로젝트의 어떤 업무인지 한눈에
    @ViewBuilder
    private var titleView: some View {
        if showProject {
            (Text(job.displayTitle).foregroundColor(BT.textTertiary) + Text("  ›  ").foregroundColor(BT.textTertiary)
                + Text(task.title ?? "").foregroundColor(BT.textPrimary))
                .font(.system(size: BuniTokens.Font.sizeMd, weight: .medium))
                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(task.title ?? "").font(.system(size: BuniTokens.Font.sizeMd, weight: .medium)).foregroundColor(BT.textPrimary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 이 업무를 맡은 팀원들과 각자 처리 상태
    private var parts: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(partIds, id: \.self) { rid in
                let st = task.partStatus?[rid] ?? "todo"
                HStack(spacing: 6) {
                    SquadAvatar(icon: role(rid)?.icon ?? "🧑‍💻", id: rid, size: 18)
                    Text(role(rid)?.name ?? rid).font(.system(size: BuniTokens.Font.sizeXs, weight: .medium)).foregroundColor(BT.textSecondary).lineLimit(1)
                    Spacer(minLength: 2)
                    switch st {
                    case "done":   Text(L.t("✓ 처리됨", "✓ Done")).font(.system(size: 10, weight: .semibold)).foregroundColor(BT.success)
                    case "doing":  HStack(spacing: 3) {
                        // 화면 비교용 캡처(BUNI_PREVIEW)에서는 돌아가는 아이콘 대신 고정 모양 — 같은 화면이 프레임 차이로 다르게 찍히지 않게
                        if ProcessInfo.processInfo.environment["BUNI_PREVIEW"] != nil { Text("◌").font(.system(size: 9)).foregroundColor(BT.success) } else { BuniSpinner() }
                        Text(L.t("처리 중", "Working")).font(.system(size: 10, weight: .semibold)).foregroundColor(BT.success)
                    }
                    case "review": Text(L.t("🔎 검토 중", "🔎 Review")).font(.system(size: 10, weight: .semibold)).foregroundColor(BT.warning)
                    default:
                        Text(job.roles?[rid]?.hold == true ? L.t("시작 대기", "Not started") : L.t("○ 대기", "○ Waiting"))
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(job.roles?[rid]?.hold == true ? BT.warning : BT.textTertiary)
                    }
                }
            }
            if partIds.isEmpty {
                Text(task.applyNote != nil ? "" : L.t("⏳ 담당 팀원 정하는 중 / 확인 대기", "⏳ Assigning / waiting for confirmation"))
                    .font(.system(size: BuniTokens.Font.sizeXs)).foregroundColor(BT.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var progressLine: some View {
        if partIds.count > 1 {
            HStack(spacing: 6) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(BT.surface3)
                        Capsule().fill(column == .done ? BT.success : BT.accentBase).frame(width: g.size.width * CGFloat(doneCount) / CGFloat(max(1, partIds.count)))
                    }
                }.frame(height: 4)
                Text("\(doneCount)/\(partIds.count)").font(.system(size: 10, weight: .semibold)).foregroundColor(BT.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch column {
        case .doing:
            if let rid = partIds.first(where: { task.partStatus?[$0] == "doing" }) {
                let act = TeamStore.readActivity(jobId: job.id, key: rid)
                Text("⏳ " + (act.lines.last?.text ?? L.t("시작하는 중…", "Starting…"))).font(.system(size: BuniTokens.Font.sizeXs))
                    .foregroundColor(BT.textSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        case .review, .done:
            if let rid = partIds.first(where: { task.partStatus?[$0] == "done" || task.partStatus?[$0] == "review" }),
               let s = job.roles?[rid]?.summary, !s.isEmpty {
                Text(squadSummary(s, limit: 120).text).font(.system(size: BuniTokens.Font.sizeXs)).foregroundColor(BT.textSecondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if let d = task.doneAt, column == .done || needsApproval {
                Text("✓ " + Self.clock.string(from: Date(timeIntervalSince1970: d)) + L.t(" 완료", " done")).font(.system(size: 10)).foregroundColor(BT.success)
            }
        case .todo:
            EmptyView()
        }
    }

    // MARK: 검토 — 승인·거절·되돌리기·화면 비교

    @ViewBuilder
    private var reviewBlock: some View {
        let a = store.applyStates[job.id] ?? TeamStore.ApplyState()
        if needsApproval {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.approval == "conflict"
                     ? L.t("내 폴더와 겹쳐서 다 넣지 못했어요", "Couldn't fully apply — overlaps with your folder")
                     : L.t("중요한 변경이라 내 승인을 기다려요", "Important change — waiting for your OK"))
                    .font(.system(size: BuniTokens.Font.sizeXs, weight: .semibold)).foregroundColor(BT.warning)
                ForEach(a.reasons, id: \.self) { r in
                    Text("• " + r).font(.system(size: BuniTokens.Font.sizeXs)).foregroundColor(BT.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if let n = task.applyNote, !n.isEmpty, a.reasons.isEmpty {
                    Text(n).font(.system(size: BuniTokens.Font.sizeXs)).foregroundColor(BT.textTertiary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
                if a.count > 0 {
                    Text(L.t("바뀐 파일 \(a.count)개 — 승인하면 바로 내 폴더에 적용돼요", "\(a.count) files — approve to apply right away"))
                        .font(.system(size: BuniTokens.Font.sizeXs)).foregroundColor(BT.textTertiary)
                }
                VStack(alignment: .leading, spacing: BuniTokens.Space.s3) {
                    HStack(spacing: BuniTokens.Space.s3) {
                        Button { store.approveChanges(job) } label: {
                            if store.busyJobs.contains(job.id) {
                                HStack(spacing: 6) { BuniSpinner(); Text(L.t("적용 중…", "Applying…")) }
                            } else if task.approval == "conflict" {
                                actionLabel(L.t("다시 정리해서 적용", "Retry apply"), "arrow.triangle.merge")
                            } else {
                                actionLabel(L.t("승인하고 적용", "Approve & apply"), "checkmark")
                            }
                        }
                        .buttonStyle(CardActionStyle(kind: .primary, fill: true)).disabled(store.busyJobs.contains(job.id))
                        Button { store.rejectChanges(job) } label: { actionLabel(L.t("거절", "Reject"), "xmark") }
                            .buttonStyle(CardActionStyle(kind: .danger)).disabled(store.busyJobs.contains(job.id))
                    }
                    Button { store.openDiff(job) } label: { actionLabel(L.t("변경 내용 보기", "View changes"), "doc.text.magnifyingglass") }
                        .buttonStyle(CardActionStyle(kind: .quiet))
                }
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BuniTokens.Radius.sm + 2, style: .continuous).fill(BT.warning.opacity(0.10)))
        } else if task.rejected != nil {
            Text(L.t("🚫 거절했어요 — 변경은 내 폴더에 넣지 않았어요", "🚫 Rejected — not applied to your folder")).font(.system(size: 10)).foregroundColor(BT.textTertiary)
        } else if let rb = task.rolledBack {
            VStack(alignment: .leading, spacing: 6) {
                Text("↩ " + L.t("되돌렸어요 · ", "Rolled back · ") + Self.clock.string(from: Date(timeIntervalSince1970: rb))).font(.system(size: 10)).foregroundColor(BT.textTertiary)
                if let c = change {
                    Button { store.reapplyChange(job, change: c) } label: { actionLabel(L.t("다시 적용", "Re-apply"), "arrow.uturn.forward") }
                        .buttonStyle(CardActionStyle(kind: .secondary)).disabled(store.busyJobs.contains(job.id))
                }
            }
        } else if let ap = task.applied {
            VStack(alignment: .leading, spacing: 6) {
                Text("📥 " + L.t("내 폴더에 반영됨 \(change?.files.count ?? task.files?.count ?? 0)개 파일 · ", "Applied \(change?.files.count ?? task.files?.count ?? 0) files · ")
                     + Self.clock.string(from: Date(timeIntervalSince1970: ap)))
                    .font(.system(size: 10)).foregroundColor(BT.info)
                if let c = change {
                    if !c.shots.isEmpty { shotStrip(c) }
                    HStack(spacing: BuniTokens.Space.s3) {
                        if !c.shots.isEmpty {
                            Button { shotsOpen = true } label: { actionLabel(L.t("변경 전·후 화면", "Before / After"), "rectangle.split.2x1") }
                                .buttonStyle(CardActionStyle(kind: .secondary, fill: true))
                        }
                        Button { store.rollbackChange(job, change: c) } label: { actionLabel(L.t("되돌리기", "Roll back"), "arrow.uturn.backward") }
                            .buttonStyle(CardActionStyle(kind: c.shots.isEmpty ? .secondary : .quiet, fill: c.shots.isEmpty))
                            .disabled(store.busyJobs.contains(job.id))
                    }
                }
            }
        } else if column == .done, let n = task.applyNote, !n.isEmpty {
            Text("✋ " + n).font(.system(size: 10)).foregroundColor(BT.warning).lineLimit(3)
        }
    }

    /// 바뀐 화면 맨 앞 한 곳을 작은 전·후 그림으로 — 눌러서 크게 본다
    private func shotStrip(_ c: TeamStore.ChangeInfo) -> some View {
        Button { shotsOpen = true } label: {
            HStack(spacing: 6) {
                if let s = c.shots.first {
                    shotThumb(s.before, L.t("전", "Before"))
                    Text("→").font(.system(size: 11)).foregroundColor(BT.textTertiary)
                    shotThumb(s.after, L.t("후", "After"))
                }
                if c.shots.count > 1 { Text("+\(c.shots.count - 1)").font(.system(size: 10, weight: .semibold)).foregroundColor(BT.textTertiary) }
            }
        }
        .buttonStyle(.plain)
    }

    private func shotThumb(_ path: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            if let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 92, maxHeight: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(BT.borderSubtle, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(BT.surface3).frame(width: 60, height: 40)
                    .overlay(Text("—").font(.system(size: 10)).foregroundColor(BT.textTertiary))
            }
            Text(label).font(.system(size: 9)).foregroundColor(BT.textTertiary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: BuniTokens.Space.s2) {
            if let hold = partIds.first(where: { job.roles?[$0]?.hold == true }) {
                Button { store.startRole(job, role: hold) } label: { actionLabel(L.t("시작", "Start"), "play.fill") }
                    .buttonStyle(CardActionStyle(kind: .primary))
            }
            if let first = partIds.first {
                Button { onOpenDM(first) } label: { actionLabel(L.t("대화", "Chat"), "bubble.left") }
                    .buttonStyle(CardActionStyle(kind: .quiet))
            }
            Button { moreOpen = true } label: { actionLabel(L.t("추가 요청", "Ask for more"), "plus.bubble") }
                .buttonStyle(CardActionStyle(kind: .quiet))
                .popover(isPresented: $moreOpen, arrowEdge: .bottom) { morePopover }
            Spacer(minLength: 0)
        }
    }

    private var morePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("이 업무에 추가로 요청하기", "Ask for more on this task")).font(.system(size: 12, weight: .semibold)).foregroundColor(BT.textPrimary)
            Text(task.title ?? "").font(.system(size: 11)).foregroundColor(BT.textTertiary).lineLimit(2)
            TextEditor(text: $moreText)
                .font(.system(size: 12)).frame(width: 300, height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(BT.borderSubtle, lineWidth: 1))
            HStack {
                Text(L.t("팀장이 알아듣고 이 업무를 이어서 개선해요", "The lead will pick this up and keep improving")).font(.system(size: 10)).foregroundColor(BT.textTertiary)
                Spacer()
                Button { moreOpen = false } label: { Text(L.t("취소", "Cancel")) }.buttonStyle(CardActionStyle(kind: .quiet))
                Button {
                    let t = moreText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    store.requestMore(job, task: task, text: t)
                    moreText = ""; moreOpen = false
                } label: { Text(L.t("보내기", "Send")) }
                    .buttonStyle(CardActionStyle(kind: .primary))
                    .disabled(moreText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14).frame(width: 330)
    }
}

// MARK: - 변경 전·후 화면 비교

struct SquadShotsSheet: View {
    let job: TeamJob
    let change: TeamStore.ChangeInfo
    let task: TeamTask
    var close: () -> Void
    @ObservedObject private var store = TeamStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t("변경 전·후 화면", "Before / After")).font(.system(size: 15, weight: .semibold)).foregroundColor(BT.textPrimary)
                    Text(job.displayTitle + "  ›  " + (task.title ?? change.title)).font(.system(size: 11)).foregroundColor(BT.textTertiary).lineLimit(2)
                }
                Spacer()
                Button { close() } label: { Text(L.t("닫기", "Close")) }.buttonStyle(CardActionStyle(kind: .quiet))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(change.shots, id: \.name) { s in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(s.name.replacingOccurrences(of: ".png", with: "")).font(.system(size: 12, weight: .semibold)).foregroundColor(BT.textSecondary)
                            HStack(alignment: .top, spacing: 12) {
                                shot(s.before, L.t("변경 전", "Before"), BT.textTertiary)
                                shot(s.after, L.t("변경 후", "After"), BT.success)
                            }
                        }
                    }
                    Text(L.t("바뀐 파일", "Changed files")).font(.system(size: 11, weight: .bold)).foregroundColor(BT.textTertiary).textCase(.uppercase)
                    Text(change.files.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).foregroundColor(BT.textSecondary).textSelection(.enabled)
                }
            }
            HStack(spacing: 8) {
                if change.rolledBack > 0 {
                    Button { store.reapplyChange(job, change: change); close() } label: { actionLabel(L.t("변경 후로 다시 적용", "Re-apply"), "arrow.uturn.forward") }.buttonStyle(CardActionStyle(kind: .primary))
                } else {
                    Button { store.rollbackChange(job, change: change); close() } label: { actionLabel(L.t("변경 전으로 되돌리기", "Roll back to before"), "arrow.uturn.backward") }.buttonStyle(CardActionStyle(kind: .primary))
                }
                Text(change.rolledBack > 0 ? L.t("지금은 변경 전 상태예요", "Currently rolled back") : L.t("변경 전이 더 낫다면 되돌려요 — 파일만 되돌리고 커밋은 건드리지 않아요", "Prefer the old look? Roll back — files only, no commits"))
                    .font(.system(size: 10)).foregroundColor(BT.textTertiary)
            }
        }
        .padding(20).frame(width: 860, height: 640).background(BT.bgCanvas)
    }

    private func shot(_ path: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(color)
            if let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(BT.borderSubtle, lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(BT.surface2).frame(maxWidth: .infinity, minHeight: 120)
                    .overlay(Text(L.t("이 쪽에는 없는 화면이에요", "Not in this version")).font(.system(size: 11)).foregroundColor(BT.textTertiary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
