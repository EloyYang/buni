import Cocoa
import SwiftUI

/// macOS의 자동 위치 제약(constrainFrameRect)을 무효화한 NSPanel.
/// 기본 NSPanel은 setFrameOrigin 호출 시 가시 영역 밖으로 나가지 못하도록
/// 내부적으로 위치를 보정하는데, 이를 우회해 메뉴바까지 자유롭게 이동할 수 있게 한다.
final class UnconstrainedPanel: NSPanel {
    // 채팅 입력이 활성화됐을 때 키보드 입력 허용
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

/// ignoresMouseEvents 동적 제어와 함께 사용하는 NSHostingView 서브클래스.
/// hitTest는 기본 동작 그대로 유지 — 클릭 통과는 AppDelegate의 ignoresMouseEvents로 제어한다.
final class ClickThroughHostingView<T: View>: NSHostingView<T> {
    // 기본값(false)이면 패널이 비활성 상태일 때 첫 클릭은 앱을 activate만 시키고
    // 실제 mouseDown/드래그 제스처로는 전달되지 않아, "한 번 클릭해선 안 움직이고
    // 두 번째 클릭+드래그부터 움직이는" 문제가 생긴다. 첫 클릭부터 바로 실제
    // 이벤트로 처리되도록 true로 강제한다.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
