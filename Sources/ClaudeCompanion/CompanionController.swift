import Foundation
import SwiftUI
import Combine

enum CompanionState: Equatable {
    case idle           // Claude 프로세스 없음 — 패널 숨김
    case ready          // 응답 완료, 입력 대기 중 — 버블 없음
    case thinking
    case toolUse(String)   // 쓰기/실행 도구 (Write, Edit, Bash 등) — 맥북 타이핑
    case toolRead(String)  // 읽기/검색 도구 (Read, Grep, WebFetch 등) — 문서 읽기
    case notification(String)
    case permission(String)
    case completed      // 응답 완료 알림 (잠깐 표시 후 ready로)
    case backgroundWork(String)  // Stop 이후에도 계속 도는 백그라운드 작업 — 완료 아님
}

extension CompanionState {
    /// 세션이 실제로 "돌고 있는" 상태인지 — 프롬프트를 넣어 Claude가 일하는 동안.
    /// 비진행 → 진행으로 바뀌는 순간이 곧 "세션 시작"이고, 사용자가 숨긴 부니는
    /// 그 시점에만 다시 나타난다(SessionWindow 참고).
    var isRunning: Bool {
        switch self {
        case .thinking, .toolUse, .toolRead, .permission, .backgroundWork:
            return true
        case .idle, .ready, .completed, .notification:
            return false
        }
    }
}

/// 부니를 클릭했을 때 만진 부위 — 부위마다 반응이 다르다
enum TouchRegion {
    case ear    // 귀 — 쫑긋 세운다
    case body   // 몸·얼굴 — 간지러워 몸을 비튼다
}

/// 우클릭 메뉴 "다른 세션으로 전환"에 나열되는 항목 — id는 Claude 세션 UUID
struct SessionSwitchTarget: Identifiable {
    let id: String
    let label: String
}

class CompanionController: ObservableObject {
    @Published var state: CompanionState = .idle
    @Published var usagePercent: Double = 0      // 컨텍스트 창 사용률 (내부용)
    @Published var sessionStart: Date? = nil

    /// 이 세션만의 캐릭터 — 기본값은 마지막으로 저장된 캐릭터
    @Published var character: CharacterType = {
        if let raw  = UserDefaults.standard.string(forKey: "character.selected"),
           let type = CharacterType(rawValue: raw) { return type }
        return .rabbit
    }()

    // 서버에서 가져온 실제 플랜 사용량
    @Published var serverUtilization: Double? = nil  // five_hour.utilization (%)
    @Published var serverResetsAt: Date? = nil        // five_hour.resets_at
    @Published var monthlyTokens: Int = 0             // 이번 달 누적 토큰 (JSONL 집계)
    /// 대기 중에 무기를 꺼내 보여주는 중 — 캐릭터 뷰는 이 값에 맞춰 오른팔을 들어 올리고,
    /// 무기 레이어는 들어 올린 손 위치에 무기를 그린다.
    @Published var isShowingWeapon: Bool = false
    @Published var isSliding: Bool = false {
        didSet { if isSliding, !oldValue { slidingSince = Date() } }
    }
    /// isSliding이 참이 된 시각 — 애니메이션 완료 콜백이 끊겨 플래그가 굳는 경우를
    /// 감지해 풀어주기 위해 둔다(굳으면 부니를 영영 클릭할 수 없게 된다).
    private(set) var slidingSince = Date()
    /// 쓰다듬을 때마다 1씩 올라간다 — 캐릭터 뷰가 이 값의 변화를 보고 반응한다.
    /// (같은 부위를 연달아 만져도 매번 반응하도록 Bool이 아니라 카운터를 쓴다)
    @Published private(set) var touchTick: Int = 0
    /// 마지막으로 만진 부위
    private(set) var lastTouchRegion: TouchRegion = .body
    @Published var alwaysApprove: Bool = false
    @Published var memo: String = ""
    /// 메모가 세션 이름에서 자동으로 채워진 값인지 (사용자가 직접 지정/삭제하면 false).
    /// true인 동안에만 세션 이름 변경을 따라가고, UserDefaults에도 저장하지 않는다.
    @Published var memoIsAuto: Bool = true
    /// 한도 안내 버블을 사용자가 직접 숨김 — 앱 전체가 공유(LimitNoticeStore)하며,
    /// 이번 한도 창이 리셋될 때까지 유지된다. 직접 쓰지 말고 dismissLimitNotice()를 쓸 것.
    @Published private(set) var limitNoticeDismissed: Bool = LimitNoticeStore.shared.isDismissed
    /// 캐릭터가 화면 왼쪽 절반에 있는지 — true면 말풍선을 캐릭터 오른쪽에,
    /// false(기본, 오른쪽)면 캐릭터 왼쪽에 그린다. SessionWindow가 패널 위치를
    /// 계산할 때마다 갱신한다.
    @Published var isNearLeftEdge: Bool = false
    var pendingPermissionId: String? = nil

    // MARK: - 플랜 한도

    /// 5시간 플랜 한도 도달 여부 (서버 사용률 100% 이상)
    var isLimitReached: Bool { (serverUtilization ?? 0) >= 100 }

    /// 한도 안내 버블을 실제로 띄울지 여부
    var isLimitNoticeVisible: Bool { isLimitReached && !limitNoticeDismissed }

    /// 한도 재설정 시각 — 서버 값 우선, 없으면 세션 시작 + 5시간
    var limitResetAt: Date? {
        serverResetsAt ?? sessionStart?.addingTimeInterval(5 * 3600)
    }

    var planTokenLabel: String {
        if let u = serverUtilization {
            return String(format: "%.0f%%", u)
        }
        return L.t("동기화중", "syncing")   // 서버 값 미수신 시
    }

    /// 게이지바 표시용 실제 사용률 (0-100)
    var displayUsagePercent: Double {
        serverUtilization ?? 0   // 동기화 전엔 빈 바
    }

    // AppDelegate가 주입하는 액션 콜백
    var onHideRequest: (() -> Void)?
    var onShowRequest: (() -> Void)?
    var onOpenClaudeRequest: (() -> Void)?
    var onPanelDragStart: (() -> Void)?
    var onPanelDrag: ((CGSize) -> Void)?
    var onPanelDragEnd: (() -> Void)?
    var onResetPositionRequest: (() -> Void)?
    var onOpenSettingsRequest: (() -> Void)?
    var onShowStatusBarRequest: (() -> Void)?
    var onEditMemoRequest: (() -> Void)?
    /// 메모를 비우는 요청 — 메모를 지우면 "빈 메모"가 아니라 기본값(세션 이름)으로 되돌린다
    var onClearMemoRequest: (() -> Void)?
    /// 다른 세션으로 전환 요청 — 대상 세션 id
    var onSwitchSessionRequest: ((String) -> Void)?
    /// 전환 가능한 다른 세션 목록. AppDelegate가 세션 추가/제거/전환마다 갱신한다.
    /// 우클릭 메뉴 closure 안에서 직접 함수를 호출하는 방식은 SwiftUI가 의존성으로
    /// 추적하지 못해, 세션이 새로 생겨도 먼저 열어본 적 있는 메뉴는 안 갱신되는
    /// 문제가 있었음 — @Published로 바꿔 항상 최신 상태가 반영되게 한다.
    @Published var switchTargets: [SessionSwitchTarget] = []
    /// 완료 버블 확인 버튼 클릭 시 세션 제거 요청
    var onDismissCompleted: (() -> Void)?

    private var autoHideTask: DispatchWorkItem?
    private var limitNoticeCancellable: AnyCancellable?

    init() {
        // 한 부니에서 "숨기기"를 누르면 모든 세션의 부니가 같이 숨긴다
        limitNoticeCancellable = LimitNoticeStore.shared.$dismissedUntil
            .receive(on: DispatchQueue.main)
            .sink { [weak self] until in
                self?.limitNoticeDismissed = until.map { Date() < $0 } ?? false
            }
    }

    /// 확인 요청(ask_user·확인 대기 추정) 버블 닫기.
    /// 이 버블은 승인 버튼이 없어 사용자가 터미널에서 답하는데, 그 뒤에 후속 훅
    /// 이벤트가 안 오는 경우가 있어 버블이 영영 남았다. 클로드를 열었거나 이미
    /// 답한 상황이면 여기서 정리한다. (승인 버튼이 있는 실제 권한 요청은 제외)
    func dismissAskUser() {
        guard case .permission = state, pendingPermissionId == nil else { return }
        update(to: .ready)
    }

    /// 부니를 쓰다듬었을 때 — 부위를 기록하고 캐릭터 뷰에 신호를 보낸다
    func touch(_ region: TouchRegion) {
        lastTouchRegion = region
        touchTick += 1
    }

    /// 한도 안내 버블의 "숨기기" — 이번 한도 창 동안은 모든 부니에서 다시 뜨지 않는다
    func dismissLimitNotice() {
        LimitNoticeStore.shared.dismiss(until: limitResetAt)
    }

    /// 한도 창이 새로 시작돼 다시 작업할 수 있게 됐을 때 알려준다
    func announceLimitReset() {
        update(to: .notification(L.t("🎉 한도가 초기화됐어요! 다시 작업할 수 있어요",
                                    "🎉 Usage limit reset — you can work again!")),
               autohideAfter: 8)
    }

    /// 숨김 상태를 현재 시각 기준으로 다시 계산 (리셋 시각이 지나면 저절로 풀리도록)
    func refreshLimitNoticeDismissal() {
        let dismissed = LimitNoticeStore.shared.isDismissed
        if limitNoticeDismissed != dismissed { limitNoticeDismissed = dismissed }
    }

    /// 단축키 등으로 외부에서 권한 승인
    func approvePermission() {
        guard let reqId = pendingPermissionId else { return }
        let file = "/tmp/claude-companion-decision-\(reqId)"
        try? "approve".write(toFile: file, atomically: true, encoding: .utf8)
        pendingPermissionId = nil
        update(to: .thinking)
    }

    /// 단축키 등으로 외부에서 권한 거부
    func denyPermission() {
        guard let reqId = pendingPermissionId else { return }
        let file = "/tmp/claude-companion-decision-\(reqId)"
        try? "deny".write(toFile: file, atomically: true, encoding: .utf8)
        pendingPermissionId = nil
        update(to: .ready)
    }

    /// 현재 요청 승인 + 이후 모든 권한 요청 자동 승인
    func approveAllPermissions() {
        alwaysApprove = true
        approvePermission()
    }

    func dismissCompleted() {
        guard case .completed = state else { return }
        update(to: .ready)
        onDismissCompleted?()
    }

    func update(to newState: CompanionState, autohideAfter seconds: Double? = nil) {
        DispatchQueue.main.async {
            self.autoHideTask?.cancel()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                self.state = newState
            }

            if let delay = seconds {
                let task = DispatchWorkItem { [weak self] in
                    self?.update(to: .idle)
                }
                self.autoHideTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
            }
        }
    }
}
