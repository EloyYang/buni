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
    @Published var isSliding: Bool = false
    @Published var alwaysApprove: Bool = false
    @Published var memo: String = ""
    var pendingPermissionId: String? = nil

    var planTokenLabel: String {
        if let u = serverUtilization {
            return String(format: "%.0f%%", u)
        }
        return "동기화중"   // 서버 값 미수신 시
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
    /// 완료 버블 확인 버튼 클릭 시 세션 제거 요청
    var onDismissCompleted: (() -> Void)?

    private var autoHideTask: DispatchWorkItem?

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
