import Foundation
import SwiftUI
import Combine

enum CompanionState: Equatable {
    case idle           // Claude 프로세스 없음 — 패널 숨김
    case ready          // 응답 완료, 입력 대기 중 — 버블 없음
    case thinking
    case toolUse(String)
    case notification(String)
    case permission(String)
}

class CompanionController: ObservableObject {
    @Published var state: CompanionState = .idle
    @Published var usagePercent: Double = 0      // 컨텍스트 창 사용률 (내부용)
    @Published var planUsagePercent: Double = 0  // 플랜 일일 한도 대비 사용률
    @Published var planTokensToday: Int = 0       // 오늘 사용한 토큰 수
    @Published var sessionStart: Date? = nil
    @Published var isSliding: Bool = false
    @Published var alwaysApprove: Bool = false
    var pendingPermissionId: String? = nil

    var planTokenLabel: String {
        guard planTokensToday > 0 else { return "" }
        return String(format: "%.0f%%", planUsagePercent)
    }

    // AppDelegate가 주입하는 액션 콜백
    var onHideRequest: (() -> Void)?
    var onShowRequest: (() -> Void)?
    var onOpenClaudeRequest: (() -> Void)?
    var onPanelDragStart: (() -> Void)?
    var onPanelDrag: ((CGSize) -> Void)?
    var onPanelDragEnd: (() -> Void)?
    var onResetPositionRequest: (() -> Void)?

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

    var onOpenSettingsRequest: (() -> Void)?

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
