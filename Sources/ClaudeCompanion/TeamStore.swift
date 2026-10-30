import Foundation
import Combine
import AppKit
import UserNotifications

// MARK: - 모델 (엔진 buni_team.py 가 쓰는 job.json 을 그대로 읽는다 — 모든 칸이 선택값이라 필드가 늘어도 깨지지 않는다)

struct TeamQuestion: Codable, Identifiable, Equatable {
    var id: String
    var question: String?
    var why: String?
    var options: [String]?
    var `default`: String?
}

struct TeamRole: Codable, Identifiable, Equatable {
    var id: String
    var name: String?
    var icon: String?
    var kind: String?
    var mission: String?
    var deliverable: String?
    var dependsOn: [String]?
    var model: String?
    enum CodingKeys: String, CodingKey {
        case id, name, icon, kind, mission, deliverable, model
        case dependsOn = "depends_on"
    }
}

struct TeamRoleState: Codable, Equatable {
    var status: String?
    var attempts: Int?
    var summary: String?
    var notes: [TeamExtraRequest]?
    var notePending: Bool?
    var hold: Bool?
    var finished: Double?
    enum CodingKeys: String, CodingKey {
        case status, attempts, summary, notes, hold, finished
        case notePending = "note_pending"
    }
}

/// 세션 하나(= claude 한 번 실행) — Claude 에서 이어 볼 수 있다
struct TeamSession: Identifiable, Equatable {
    var id: String
    var key: String
    var label: String
    var started: Double
    var finished: Double?
}

/// 스쿼드 채팅방의 한 줄
struct TeamChatMessage: Identifiable, Equatable {
    var id: Int               // 파일 안에서의 순번
    var ts: Double
    var from: String          // lead / user / system / 팀원 id
    var to: String            // lead / user / all / 팀원 id
    var kind: String          // instruction / report / review / status / user / say
    var text: String
}

/// 팀장이 정리해 준 '지금 확인할 것' 한 건
struct TeamReviewItem: Identifiable, Equatable {
    var id: String
    var title: String
    var why: String
    var kind: String          // file / folder / url / command
    var target: String
    var expect: String
    var blocked: Bool
}

/// 팀장이 제안한 '다음에 할 일' 한 건
struct TeamNextStep: Identifiable, Equatable {
    var id: String
    var title: String
    var why: String
    var goal: String
    var doneCriteria: [String]
    var jobId: String?        // 예전 방식으로 따로 시작해 둔 작업 (지금은 같은 프로젝트에 이어 붙이므로 role_id 를 쓴다)
    var roleId: String?       // 이 프로젝트에서 이어서 진행하는 팀원
    var directionChange: Bool = true   // 사업 방향이 바뀌는 일이면 자동으로 시작하지 않고 대기
    var auto: String?         // started(자동 시작) · manual · confirm(확인 필요) · limit(단계 상한) · cap · off
}

struct TeamWrapup: Equatable {
    var items: [TeamReviewItem]
    var steps: [TeamNextStep]
}

/// 세션이 지금 하는 일 (최근 도구 사용·말 몇 줄)
struct TeamActivity: Equatable {
    var lines: [(ts: Double, text: String)]
    var state: String
    static func == (a: TeamActivity, b: TeamActivity) -> Bool { a.state == b.state && a.lines.count == b.lines.count }
    static let empty = TeamActivity(lines: [], state: "")
}

struct TeamEvent: Codable, Equatable {
    var ts: Double
    var msg: String
}

struct TeamInterview: Codable, Equatable {
    var round: Int?
    var ready: Bool?
    var understanding: String?
    var questions: [TeamQuestion]?
}

struct TeamPlan: Codable, Equatable {
    var summary: String?
    var roles: [TeamRole]?
}

struct TeamPermissions: Codable, Equatable {
    var web: Bool?
}

struct TeamExtraRequest: Codable, Equatable {
    var text: String?
    var ts: Double?
}

/// 사전요구서의 기존 내용과 다른 요청 — 내가 정하기 전에는 요구서도, 관련 지시도 그대로다
struct TeamReqProposal: Codable, Identifiable, Equatable {
    var id: String
    var was: String?
    var now: String?
    var why: String?
    var status: String?
}

/// 내가 한 지시 하나 = 업무 하나 — 담당 팀원(parts)이 각자 끝내면 완료
struct TeamTask: Codable, Identifiable, Equatable {
    var id: String
    var title: String?
    var text: String?
    var source: String?            // plan · chat · note · followup
    var priority: String?          // urgent · high · normal · low
    var created: Double?
    var status: String?            // todo · doing · review · done
    var partStatus: [String: String]?
    var doneAt: Double?
    var applied: Double?
    var files: [String]?
    var applyNote: String?
    var parts: [String: Double]?
    enum CodingKeys: String, CodingKey {
        case id, title, text, source, priority, created, status, applied, files, parts
        case partStatus = "part_status", doneAt = "done_at", applyNote = "apply_note"
    }
    var rank: Int { ["urgent": 0, "high": 1, "normal": 2, "low": 3][priority ?? "normal"] ?? 2 }
}

struct TeamJob: Codable, Identifiable, Equatable {
    var id: String
    var slug: String?
    var title: String?
    var goal: String?
    var projectDir: String?
    var created: Double?
    var updated: Double?
    var status: String?
    var phase: String?
    var busy: Bool?
    var busyMsg: String?
    var permissions: TeamPermissions?
    var interview: TeamInterview?
    var requirements: String?
    var plan: TeamPlan?
    var roles: [String: TeamRoleState]?
    var branch: String?
    var baseRef: String?
    var workdir: String?
    var resumeAt: Double?
    var error: String?
    var costUsd: Double?
    var report: String?
    var summary: String?
    var events: [TeamEvent]?
    var extraRequests: [TeamExtraRequest]?
    var resultDir: String?
    var reqProposals: [TeamReqProposal]?
    var applyMode: String?
    var runMode: String?
    var tasks: [TeamTask]?
    var userPaused: Bool?
    var pendingProposals: [TeamReqProposal] { (reqProposals ?? []).filter { $0.status == "pending" } }

    enum CodingKeys: String, CodingKey {
        case id, slug, title, goal, created, updated, status, phase, busy, permissions, interview, requirements, plan, roles
        case reqProposals = "req_proposals", applyMode = "apply_mode", runMode = "run_mode", tasks, userPaused = "user_paused"
        case branch, workdir, error, report, summary, events
        case extraRequests = "extra_requests", resultDir = "result_dir", projectDir = "project_dir", busyMsg = "busy_msg", baseRef = "base_ref", resumeAt = "resume_at", costUsd = "cost_usd"
    }

    var displayTitle: String { (title?.isEmpty == false ? title! : goal) ?? L.t("작업", "Job") }
    var state: String { status ?? "draft" }
    var questions: [TeamQuestion] { interview?.questions ?? [] }
    var resultFolder: URL? {
        guard let slug else { return nil }
        let fm = FileManager.default
        // 작업 공간이 남아 있으면 거기, 아니면 엔진이 꺼내 둔 결과 폴더, 그것도 없으면 프로젝트 폴더
        let base: String
        if let w = workdir, !w.isEmpty, fm.fileExists(atPath: w) { base = w }
        else if let r = resultDir, !r.isEmpty, fm.fileExists(atPath: r) { base = r }
        else { base = projectDir ?? "" }
        return URL(fileURLWithPath: base).appendingPathComponent(".buni-team/\(slug)")
    }
}

struct TeamSettings: Codable, Equatable {
    var enabled: Bool = true
    var windowStart: String = "22:00"
    var windowEnd: String = "06:00"
    var concurrency: Int = 2
    var maxRevisions: Int = 2
    var model: String = ""                 // 팀원 기본 모델 (빈 값 = Claude Code 기본)
    var leadModel: String = ""             // 팀장 모델 (빈 값 = 위 기본 모델)
    var applyMode: String = "smart"        // smart(중요하지 않으면 바로) · auto · confirm · manual
    var smartPayments = true               // 중요한 변경으로 볼 것들 (smart 모드)
    var smartSecrets = true
    var smartBuild = true
    var smartDeletes = true
    var smartBig = true
    var smartBigFiles = 30
    var smartBigLines = 1500
    var smartCustom = ""
    var runMode: String = "auto"           // auto · manual (업무마다 ▶ 시작)
    var autoFollowup: Bool = true          // 방향이 안 바뀌는 '다음에 할 일'은 자동으로 이어서 시작
    var scheduleMode: String = "window"    // window(시간대 안에서만) · anytime(언제든) · off(내가 시작할 때만)
    var limitAction: String = "stop"       // stop(한도에 닿으면 멈춤) · wait(풀리면 이어서)
    var paused: Bool = false               // 모든 작업 일시정지

    enum CodingKeys: String, CodingKey {
        case enabled, concurrency, model
        case leadModel = "lead_model", applyMode = "apply_mode", runMode = "run_mode", autoFollowup = "auto_followup"
        case scheduleMode = "schedule_mode", limitAction = "limit_action", paused
        case windowStart = "window_start", windowEnd = "window_end", maxRevisions = "max_revisions"
        case smartPayments = "smart_payments", smartSecrets = "smart_secrets", smartBuild = "smart_build", smartDeletes = "smart_deletes"
        case smartBig = "smart_big", smartBigFiles = "smart_big_files", smartBigLines = "smart_big_lines", smartCustom = "smart_custom"
    }

    init() {}
    init(from decoder: Decoder) throws {          // 없는 칸은 기본값으로 — 설정 파일이 일부만 있어도 읽힌다
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        windowStart = try c.decodeIfPresent(String.self, forKey: .windowStart) ?? "22:00"
        windowEnd = try c.decodeIfPresent(String.self, forKey: .windowEnd) ?? "06:00"
        concurrency = try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? 2
        maxRevisions = try c.decodeIfPresent(Int.self, forKey: .maxRevisions) ?? 2
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        leadModel = try c.decodeIfPresent(String.self, forKey: .leadModel) ?? ""
        applyMode = try c.decodeIfPresent(String.self, forKey: .applyMode) ?? "smart"
        smartPayments = try c.decodeIfPresent(Bool.self, forKey: .smartPayments) ?? true
        smartSecrets = try c.decodeIfPresent(Bool.self, forKey: .smartSecrets) ?? true
        smartBuild = try c.decodeIfPresent(Bool.self, forKey: .smartBuild) ?? true
        smartDeletes = try c.decodeIfPresent(Bool.self, forKey: .smartDeletes) ?? true
        smartBig = try c.decodeIfPresent(Bool.self, forKey: .smartBig) ?? true
        smartBigFiles = try c.decodeIfPresent(Int.self, forKey: .smartBigFiles) ?? 30
        smartBigLines = try c.decodeIfPresent(Int.self, forKey: .smartBigLines) ?? 1500
        smartCustom = try c.decodeIfPresent(String.self, forKey: .smartCustom) ?? ""
        runMode = try c.decodeIfPresent(String.self, forKey: .runMode) ?? "auto"
        autoFollowup = try c.decodeIfPresent(Bool.self, forKey: .autoFollowup) ?? true
        scheduleMode = try c.decodeIfPresent(String.self, forKey: .scheduleMode) ?? (enabled ? "window" : "off")
        limitAction = try c.decodeIfPresent(String.self, forKey: .limitAction) ?? "stop"
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }
}

// MARK: - 저장소 (엔진과 파일로만 주고받는다)

@MainActor
final class TeamStore: ObservableObject {
    static let shared = TeamStore()

    @Published private(set) var jobs: [TeamJob] = []
    @Published private(set) var settings = TeamSettings()
    /// 이 맥에서 부니 스쿼드을 돌릴 수 있는지 — 안 되면 사유를 화면에 보여 준다
    @Published private(set) var problem: String?
    @Published private(set) var claudePath: String = ""

    private var timer: Timer?
    private var lastStamp = ""
    private var lastStatus: [String: String] = [:]
    private var daemon: Process?
    private var teamEnabledAwake = false

    private init() {}

    // MARK: 경로

    nonisolated static var home: URL {
        if let env = ProcessInfo.processInfo.environment["BUNI_TEAM_HOME"], !env.isEmpty {     // 시험용 (엔진과 같은 이름)
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Buni/team", isDirectory: true)
    }
    nonisolated static var jobsDir: URL { home.appendingPathComponent("jobs", isDirectory: true) }

    nonisolated private static var scriptURL: URL? {
        if let u = Bundle.main.url(forResource: "buni_team", withExtension: "py") { return u }
        // 개발 중(앱 번들 밖)에는 저장소의 원본을 쓴다
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("windows/buni_team.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    nonisolated private static let python = "/usr/bin/python3"

    // MARK: 시작

    func start() {
        guard timer == nil else { return }
        checkEnvironment()
        reload(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        startDaemon()
    }

    /// python3(개발자 도구)와 claude 명령이 있는지 확인한다
    func checkEnvironment() {
        Task.detached {
            var problem: String?
            var claude = ""
            let py = FileManager.default.isExecutableFile(atPath: Self.python)
            let clt = Self.run("/usr/bin/xcode-select", ["-p"]).status == 0
            if !py || !clt {
                problem = L.t("부니 스쿼드에는 macOS 개발자 도구가 필요해요. 터미널에서 `xcode-select --install` 을 실행해 설치한 뒤 Buni를 다시 켜 주세요.",
                              "Buni Squad needs the macOS developer tools. Run `xcode-select --install` in Terminal, then restart Buni.")
            } else if Self.scriptURL == nil {
                problem = L.t("스쿼드 엔진 파일을 찾지 못했어요. Buni를 다시 설치해 주세요.", "The team engine file is missing. Please reinstall Buni.")
            } else if let r = Self.cli(["check"]), let obj = try? JSONSerialization.jsonObject(with: r) as? [String: Any] {
                claude = obj["claude"] as? String ?? ""
                if claude.isEmpty {
                    problem = L.t("Claude Code(claude 명령)를 찾지 못했어요. 먼저 Claude Code를 설치해 주세요.", "Claude Code (the `claude` command) wasn't found. Install Claude Code first.")
                } else if !(obj["git"] as? Bool ?? false) {
                    problem = L.t("git 을 찾지 못했어요. 개발자 도구를 설치해 주세요.", "git wasn't found. Please install the developer tools.")
                }
            }
            await MainActor.run { self.problem = problem; self.claudePath = claude }
        }
    }

    // MARK: 상주 프로세스 (예약 시간대에 알아서 시작·중단한다)

    private func startDaemon() {
        guard daemon?.isRunning != true, FileManager.default.isExecutableFile(atPath: Self.python),
              let script = Self.scriptURL else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.python)
        p.arguments = [script.path, "daemon", "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        p.environment = Self.environment()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            // 앱이 살아 있는데 죽었다면 잠시 뒤 다시 띄운다
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { Task { @MainActor in self?.startDaemon() } }
        }
        do { try p.run(); daemon = p } catch { daemon = nil }
    }

    func stopDaemon() {
        daemon?.terminationHandler = nil
        daemon?.terminate()
        daemon = nil
    }

    // MARK: 읽기

    func reload(force: Bool = false) {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(atPath: Self.jobsDir.path)) ?? []
        var stamp = ""
        for d in dirs.sorted() {
            let p = Self.jobsDir.appendingPathComponent(d).appendingPathComponent("job.json").path
            if let a = try? fm.attributesOfItem(atPath: p), let m = a[.modificationDate] as? Date {
                stamp += "\(d):\(m.timeIntervalSince1970);"
            }
        }
        let sp = Self.home.appendingPathComponent("settings.json").path
        if let a = try? fm.attributesOfItem(atPath: sp), let m = a[.modificationDate] as? Date { stamp += "s:\(m.timeIntervalSince1970)" }
        guard force || stamp != lastStamp else { return }
        lastStamp = stamp

        let dec = JSONDecoder()
        var loaded: [TeamJob] = []
        for d in dirs {
            let url = Self.jobsDir.appendingPathComponent(d).appendingPathComponent("job.json")
            if let data = try? Data(contentsOf: url), let job = try? dec.decode(TeamJob.self, from: data) { loaded.append(job) }
        }
        loaded.sort { ($0.created ?? 0) < ($1.created ?? 0) }
        if let data = try? Data(contentsOf: Self.home.appendingPathComponent("settings.json")),
           let s = try? dec.decode(TeamSettings.self, from: data) { settings = s }
        notifyChanges(old: lastStatus, new: loaded)
        lastStatus = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0.state) })
        jobs = loaded
        syncAwake()
    }

    /// 검토를 기다리는 작업 수 (메뉴 배지)
    var reviewCount: Int { jobs.filter { $0.state == "review" }.count }
    var runningJob: TeamJob? { jobs.first { $0.state == "running" } }

    // MARK: 알림

    private func notifyChanges(old: [String: String], new: [TeamJob]) {
        guard !old.isEmpty || !jobs.isEmpty else { return }
        for j in new {
            guard let before = old[j.id], before != j.state else { continue }
            switch j.state {
            case "review":   post(L.t("✅ 스쿼드 작업 완료", "✅ Squad job finished"), j.displayTitle + L.t(" — 아침에 검토해 주세요", " — ready to review"))
            case "failed":   post(L.t("⚠ 스쿼드 작업이 멈췄어요", "⚠ Squad job stopped"), j.displayTitle + ((j.error?.isEmpty == false) ? " — \(j.error!)" : ""))
            case "waiting_limit": post(L.t("⏸ 플랜 한도 대기", "⏸ Waiting for plan limit"), j.displayTitle)
            case "paused":   if before == "running" { post(L.t("🌙 예약 시간이 끝나 멈췄어요", "🌙 Scheduled time ended"), j.displayTitle) }
            default: break
            }
        }
    }

    private func post(_ title: String, _ body: String) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: 덮개를 닫아도 계속 (이미 "덮개 닫아도 실행"을 쓰도록 설정해 둔 사람만)

    private func syncAwake() {
        let awake = AwakeManager.shared
        if runningJob != nil {
            if !awake.isActive, awake.isHelperInstalled {
                teamEnabledAwake = awake.enable(duration: 10 * 3600, bySchedule: true)
            }
        } else if teamEnabledAwake {
            awake.disable()
            teamEnabledAwake = false
        }
    }

    // MARK: 명령 (엔진 CLI)

    @discardableResult
    func create(title: String, goal: String, project: String, web: Bool) async -> TeamJob? {
        var args = ["new", "--title", title, "--goal", goal, "--project", project]
        if web { args.append("--web") }
        guard let data = await Task.detached(operation: { Self.cli(args) }).value else { return nil }
        guard let job = try? JSONDecoder().decode(TeamJob.self, from: data) else { return nil }
        reload(force: true)
        fire(["interview-start", job.id])
        return job
    }

    func answer(_ job: TeamJob, answers: [String: String]) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("buni-team-answers-\(UUID().uuidString).json")
        if let data = try? JSONSerialization.data(withJSONObject: answers) { try? data.write(to: tmp) }
        fire(["interview-answer", job.id, "--answers", tmp.path])
    }

    func retryInterview(_ job: TeamJob) { fire(["interview-resume", job.id]) }

    /// 이 세션(claude 한 번 실행)이 어느 스쿼드 작업의 것인지 — 부니 완료 말풍선에서 결과로 바로 가는 데 쓴다.
    /// 엔진이 적어 둔 sessions.jsonl 을 훑는다 (작업이 많지 않아 가볍다).
    nonisolated static func jobId(forSession sessionId: String) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: jobsDir.path)) ?? []
        for d in dirs.sorted(by: >) {                                  // 최근 작업부터
            let url = jobsDir.appendingPathComponent(d).appendingPathComponent("sessions.jsonl")
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(sessionId) { return d }
        }
        return nil
    }

    /// 채팅 탭을 열어 둔 작업 (상태가 바뀌어 화면이 다시 만들어져도 유지)
    @Published var chatOpen: Set<String> = []

    // MARK: 채팅방

    nonisolated static func readChat(jobId: String) -> [TeamChatMessage] {
        let url = jobsDir.appendingPathComponent(jobId).appendingPathComponent("chat.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [TeamChatMessage] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            out.append(TeamChatMessage(id: out.count, ts: o["ts"] as? Double ?? 0, from: o["from"] as? String ?? "",
                                       to: o["to"] as? String ?? "", kind: o["kind"] as? String ?? "say", text: o["text"] as? String ?? ""))
        }
        return out
    }

    /// 지금 답을 쓰는 중인 쪽 (없으면 빈 문자열)
    nonisolated static func readTyping(jobId: String) -> String {
        let url = jobsDir.appendingPathComponent(jobId).appendingPathComponent("chat_typing.json")
        guard let data = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = o["ts"] as? Double, Date().timeIntervalSince1970 - ts < 600 else { return "" }
        return o["who"] as? String ?? ""
    }

    /// 채팅방에서 말을 건다 — 팀원을 지목하면 그 팀원에게 바로, 팀장(lead)에게 하면 팀장이 이해해서 나눠 지시한다
    func sendChat(_ job: TeamJob, to: String, text: String) {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("buni-team-chat-\(UUID().uuidString).txt")
        try? text.write(to: f, atomically: true, encoding: .utf8)
        fire(["chat-send", job.id, "--to", to, "--text-file", f.path], wait: true)
    }

    /// 결과 화면에서 후속 작업을 시작하면 그 작업으로 이동하게 알린다
    @Published var focusJobId: String?

    // MARK: 검토할 것 · 다음 작업

    nonisolated static func readWrapup(jobId: String) -> TeamWrapup? {
        let url = jobsDir.appendingPathComponent(jobId).appendingPathComponent("wrapup.json")
        guard let data = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let items = (o["review_items"] as? [[String: Any]] ?? []).map {
            TeamReviewItem(id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "", why: $0["why"] as? String ?? "",
                           kind: $0["kind"] as? String ?? "file", target: $0["target"] as? String ?? "",
                           expect: $0["expect"] as? String ?? "", blocked: $0["blocked"] as? Bool ?? false)
        }
        let steps = (o["next_steps"] as? [[String: Any]] ?? []).map {
            TeamNextStep(id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "", why: $0["why"] as? String ?? "",
                         goal: $0["goal"] as? String ?? "", doneCriteria: $0["done_criteria"] as? [String] ?? [],
                         jobId: $0["job_id"] as? String, roleId: $0["role_id"] as? String, directionChange: $0["direction_change"] as? Bool ?? true,
                         auto: $0["auto"] as? String)
        }
        return TeamWrapup(items: items, steps: steps)
    }

    /// 보고서 하나로 읽는 문서 — 보고서 안에 '지금 확인할 것' 버튼 줄과 '다음에 할 일'이 들어 있다
    nonisolated static func readReportView(jobId: String, fallback: String) -> String {
        let dir = jobsDir.appendingPathComponent(jobId)
        for name in ["report_view.md", "REPORT.md"] {
            if let t = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) { return t }
        }
        return fallback
    }

    private var wrapupChecked = Set<String>()
    /// 끝난 작업은 열자마자 보고서에서 바로 누를 항목이 보이도록 — 없으면 만들고, 팀장 정리를 한 번 돌린다
    private func ensureWrapups() {
        for j in jobs where ["review", "done"].contains(j.state) && j.busy != true && !wrapupChecked.contains(j.id) {
            wrapupChecked.insert(j.id)
            fire(["ensure-wrapup", j.id], wait: true)
        }
    }

    /// 확인한 항목에 대한 반응 — verdict: "ok"(문제 없어요) / "fix"(피드백). 피드백은 팀장이 해당 팀원에게 수정 지시를 내려 반영한다
    func reviewFeedback(_ job: TeamJob, itemId: String, verdict: String, text: String = "") {
        var args = ["review-feedback", job.id, itemId, "--verdict", verdict]
        if !text.isEmpty {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("buni-team-fb-\(UUID().uuidString).txt")
            try? text.write(to: f, atomically: true, encoding: .utf8)
            args += ["--text-file", f.path]
        }
        fire(args, wait: true)
        // 보고서 파일은 job.json 과 별개라 화면이 알아채지 못하므로, '전달하는 중' 표시가 보이게 곧 한 번 다시 그리게 한다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.objectWillChange.send() }
    }

    /// 팀장에게 '검토할 것·다음 작업'을 (다시) 정리하게 한다
    func wrapUp(_ job: TeamJob) { fire(["wrap-up", job.id], wait: true) }

    // MARK: 업무 보드

    struct ApplyState: Equatable {
        var pending = false
        var files: [String] = []
        var count = 0
        var branch = ""
        var mode = "auto"
        var runMode = "auto"
        var applied = false
        var jobApplyMode = ""
        var jobRunMode = ""
        var note = ""
        var reasons: [String] = []
    }
    @Published var applyStates: [String: ApplyState] = [:]

    func refreshApplyState(_ job: TeamJob) {
        Task.detached {
            guard let data = Self.cli(["apply-state", job.id]),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            var s = ApplyState()
            s.pending = o["pending"] as? Bool ?? false
            s.files = o["files"] as? [String] ?? []
            s.count = o["count"] as? Int ?? s.files.count
            s.branch = o["branch"] as? String ?? ""
            s.mode = o["mode"] as? String ?? "auto"
            s.runMode = o["run_mode"] as? String ?? "auto"
            s.applied = o["applied"] as? Bool ?? false
            s.note = o["note"] as? String ?? ""
            s.reasons = o["reasons"] as? [String] ?? []
            s.jobApplyMode = o["job_apply_mode"] as? String ?? ""
            s.jobRunMode = o["job_run_mode"] as? String ?? ""
            await MainActor.run { if TeamStore.shared.applyStates[job.id] != s { TeamStore.shared.applyStates[job.id] = s } }
        }
    }

    /// 이 작업만 반영·진행 방식을 바꾼다 (빈 값 = 설정을 따름)
    func setJobModes(_ job: TeamJob, apply: String? = nil, run: String? = nil) {
        var args = ["job-modes", job.id]
        if let apply { args += ["--apply", apply] }
        if let run { args += ["--run", run] }
        Task.detached {
            _ = Self.cli(args)
            await MainActor.run { TeamStore.shared.reload(force: true); TeamStore.shared.refreshApplyState(job) }
        }
    }

    /// 이 작업을 멈추거나(⏸) 이어서 한다(▶)
    func pauseJob(_ job: TeamJob) { fire(["pause-job", job.id], wait: true) }
    func resumeJob(_ job: TeamJob) { fire(["resume-job", job.id], wait: true) }
    /// 모든 작업 일시정지 / 해제
    func setGlobalPause(_ on: Bool) {
        Task.detached {
            _ = Self.cli(["global-pause", on ? "on" : "off"])
            await MainActor.run { TeamStore.shared.reload(force: true) }
        }
    }
    /// 업무 우선순위 (urgent · high · normal · low) — 급한 업무를 맡은 팀원부터 일한다
    func setTaskPriority(_ job: TeamJob, task: TeamTask, priority: String) {
        fire(["task-priority", job.id, task.id, priority], wait: true)
    }

    /// 사이드바용 — 모든 작업의 '반영 대기' 상태를 가끔 갱신한다 (확인이 필요한 작업을 표시하려고)
    func refreshAllApplyStates() {
        for j in jobs where ["review", "done", "failed", "paused", "running", "queued"].contains(j.state) { refreshApplyState(j) }
    }

    /// 확인이 필요한 상황인가 — 반영 승인 대기 · 사전요구서 변경 확인 · 수동 진행에서 시작 대기 · 한도로 멈춤
    func needsAttention(_ j: TeamJob) -> String? {
        if !j.pendingProposals.isEmpty { return L.t("사전요구서 변경 확인", "Confirm requirement change") }
        if let a = applyStates[j.id], a.pending, !["auto"].contains(a.mode) || !a.reasons.isEmpty || !a.note.isEmpty {
            if a.mode == "manual" { return nil }
            return !a.reasons.isEmpty ? L.t("중요한 변경 — 승인 필요", "Important change — approve") : (a.note.isEmpty ? L.t("반영 승인 필요", "Approve to apply") : L.t("자동 반영 실패", "Apply failed"))
        }
        if j.state == "paused", j.phase == "waiting_start" { return L.t("▶ 시작 대기", "Waiting to start") }
        if j.state == "paused", j.userPaused == true, j.error?.isEmpty != false, let e = j.events?.last?.msg, e.contains("한도") { return L.t("한도로 멈춤", "Stopped at limit") }
        return nil
    }

    /// 반영하지 않고 닫는다 (결과는 브랜치에 남는다)
    func dismissApply(_ job: TeamJob) {
        Task.detached {
            _ = Self.cli(["apply-dismiss", job.id])
            await MainActor.run { TeamStore.shared.refreshApplyState(job) }
        }
    }

    /// 수동 진행 모드 — 이 업무를 지금 시작한다
    func startRole(_ job: TeamJob, role: String) { fire(["start-role", job.id, role], wait: true) }

    /// 사전요구서와 다른 요청에 대한 내 결정 — 승인하면 요구서를 고치고 보류했던 지시를 보낸다
    func resolveReqProposal(_ job: TeamJob, id: String, accept: Bool) {
        fire(accept ? ["req-resolve", job.id, id, "--accept"] : ["req-resolve", job.id, id], wait: true)
    }

    /// 팀원 한 명의 모델을 바꾼다 (빈 값 = 기본 모델)
    func setRoleModel(_ job: TeamJob, role: String, model: String) {
        fire(["role-model", job.id, role, "--model", model], wait: true)
    }

    /// 반영하기 전에 팀이 바꾼 내용(diff)을 연다
    func openDiff(_ job: TeamJob) {
        Task.detached {
            let data = Self.cli(["open-diff", job.id])
            let o = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if o?["ok"] as? Bool != true {
                await MainActor.run {
                    let a = NSAlert(); a.messageText = L.t("열지 못했어요", "Couldn't open it")
                    a.informativeText = (o?["error"] as? String) ?? ""; a.runModal()
                }
            }
        }
    }

    /// 검토 항목 하나를 연다 — 파일·폴더는 바로, 주소는 브라우저로, 명령은 터미널 창에서. 못 열면 이유를 알려 준다.
    func openItem(_ job: TeamJob, item: TeamReviewItem) { openItem(job, itemId: item.id) }

    func openItem(_ job: TeamJob, itemId: String) {
        Task.detached {
            guard let data = Self.cli(["open-item", job.id, itemId]),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if o["ok"] as? Bool != true {
                let msg = o["error"] as? String ?? L.t("열지 못했어요", "Couldn't open it")
                await MainActor.run {
                    let a = NSAlert()
                    a.messageText = L.t("열지 못했어요", "Couldn't open it")
                    a.informativeText = msg
                    a.runModal()
                }
            }
        }
    }

    /// 별도 작업 공간에 있는 결과를 내 폴더에 반영한다 (커밋은 하지 않는다)
    func applyResult(_ job: TeamJob) {
        Task.detached {
            let data = Self.cli(["apply-result", job.id])
            let o = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            await MainActor.run {
                TeamStore.shared.reload(force: true)
                if o?["ok"] as? Bool != true {
                    let a = NSAlert()
                    a.messageText = L.t("반영하지 못했어요", "Couldn't apply it")
                    a.informativeText = (o?["error"] as? String) ?? ""
                    a.runModal()
                }
            }
        }
    }

    /// 제안된 다음 작업을 이 프로젝트에서 이어서 진행한다 (같은 작업에 새 팀원으로 붙인다 — 다른 프로젝트로 옮기지 않는다)
    func startFollowup(_ job: TeamJob, step: TeamNextStep) { startFollowup(job, stepId: step.id) }

    func startFollowup(_ job: TeamJob, stepId: String) {
        Task.detached {
            guard Self.cli(["followup", job.id, stepId]) != nil else { return }
            await MainActor.run { TeamStore.shared.reload(force: true) }
        }
    }

    /// 특정 팀원(세션)에게 요구사항을 전한다
    func sendRoleNote(_ job: TeamJob, role: String, text: String) {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("buni-team-note-\(UUID().uuidString).txt")
        try? text.write(to: f, atomically: true, encoding: .utf8)
        fire(["role-note", job.id, role, "--text-file", f.path], wait: true)
    }

    /// 그 세션을 터미널에서 `claude --resume` 으로 열어 Claude 에서 이어 본다
    func openSession(_ job: TeamJob, sessionId: String) { fire(["open-session", job.id, sessionId]) }

    // MARK: 진행 상황 읽기 (엔진이 적어 둔 파일)

    nonisolated static func readSessions(jobId: String) -> [TeamSession] {
        let url = jobsDir.appendingPathComponent(jobId).appendingPathComponent("sessions.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var order: [String] = [], map: [String: [String: Any]] = [:]
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let id = o["id"] as? String else { continue }
            if map[id] == nil { order.append(id); map[id] = [:] }
            for (k, v) in o { map[id]?[k] = v }
        }
        return order.compactMap { id in
            guard let m = map[id] else { return nil }
            return TeamSession(id: id, key: m["key"] as? String ?? "", label: m["label"] as? String ?? "",
                               started: m["started"] as? Double ?? 0, finished: m["finished"] as? Double)
        }
    }

    nonisolated static func readActivity(jobId: String, key: String) -> TeamActivity {
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }.prefix(40))
        let url = jobsDir.appendingPathComponent(jobId).appendingPathComponent("activity-\(safe).json")
        guard let data = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .empty }
        let lines = (o["lines"] as? [[String: Any]] ?? []).map { (ts: $0["ts"] as? Double ?? 0, text: $0["text"] as? String ?? "") }
        return TeamActivity(lines: lines, state: o["state"] as? String ?? "")
    }

    /// 질문 답변 중이든 사전요구서가 나온 뒤든 요청을 새로 추가한다 — 팀장이 그에 맞춰 질문을 다시 정리한다.
    /// answers: 답하던 질문에 지금까지 적은 답, requirements: 고치던 요구서 내용
    func addRequest(_ job: TeamJob, text: String, answers: [String: String]? = nil, requirements: String? = nil) {
        let tmpDir = FileManager.default.temporaryDirectory
        let textFile = tmpDir.appendingPathComponent("buni-team-extra-\(UUID().uuidString).txt")
        try? text.write(to: textFile, atomically: true, encoding: .utf8)
        var args = ["interview-add", job.id, "--text-file", textFile.path]
        if let answers, let data = try? JSONSerialization.data(withJSONObject: answers) {
            let f = tmpDir.appendingPathComponent("buni-team-answers-\(UUID().uuidString).json")
            try? data.write(to: f); args += ["--answers", f.path]
        }
        if let requirements, !requirements.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let f = tmpDir.appendingPathComponent("buni-team-req-\(UUID().uuidString).md")
            try? requirements.write(to: f, atomically: true, encoding: .utf8); args += ["--requirements-file", f.path]
        }
        fire(args)
    }

    func approve(_ job: TeamJob, requirements: String, startNow: Bool = false) {
        var args = ["approve", job.id]
        if startNow { args.append("--now") }
        if !requirements.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("buni-team-req-\(UUID().uuidString).md")
            try? requirements.write(to: tmp, atomically: true, encoding: .utf8)
            args += ["--requirements-file", tmp.path]
        }
        fire(args, wait: true)
    }

    func restartInterview(_ job: TeamJob) { fire(["interview-restart", job.id]) }
    func runNow(_ job: TeamJob)  { fire(["run-now", job.id], wait: true) }
    func cancel(_ job: TeamJob)  { fire(["cancel", job.id], wait: true) }
    func retry(_ job: TeamJob)   { fire(["retry", job.id], wait: true) }
    func markDone(_ job: TeamJob) { fire(["mark-done", job.id], wait: true) }
    func delete(_ job: TeamJob)  { fire(["delete", job.id], wait: true) }

    func saveSettings(_ s: TeamSettings) {
        let patch: [String: Any] = ["enabled": s.enabled, "window_start": s.windowStart, "window_end": s.windowEnd,
                                    "concurrency": s.concurrency, "model": s.model, "lead_model": s.leadModel,
                                    "apply_mode": s.applyMode, "run_mode": s.runMode, "schedule_mode": s.scheduleMode, "limit_action": s.limitAction,
                                    "smart_payments": s.smartPayments, "smart_secrets": s.smartSecrets, "smart_build": s.smartBuild,
                                    "smart_deletes": s.smartDeletes, "smart_big": s.smartBig, "smart_big_files": s.smartBigFiles,
                                    "smart_big_lines": s.smartBigLines, "smart_custom": s.smartCustom, "auto_followup": s.autoFollowup]
        if let data = try? JSONSerialization.data(withJSONObject: patch), let json = String(data: data, encoding: .utf8) {
            fire(["settings", "--set", json], wait: true)
        }
    }

    /// 엔진 명령을 뒤에서 실행한다 (질문 정리처럼 오래 걸리는 것도 화면은 job.json 의 busy 로 따라간다)
    private func fire(_ args: [String], wait: Bool = false) {
        Task.detached {
            _ = Self.cli(args)
            if wait { await MainActor.run { TeamStore.shared.reload(force: true) } }
        }
    }

    // MARK: 프로세스 도우미

    nonisolated static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "\(home)/.local/bin", "\(home)/.claude/local"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
        return env
    }

    nonisolated static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    nonisolated static func cli(_ args: [String]) -> Data? {
        guard let script = scriptURL else { return nil }
        let r = run(python, [script.path] + args)
        return r.status == 0 ? r.out : nil
    }
}
