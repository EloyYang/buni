import Cocoa

/// macOS의 자동 위치 제약(constrainFrameRect)을 무효화한 NSPanel.
/// 기본 NSPanel은 setFrameOrigin 호출 시 가시 영역 밖으로 나가지 못하도록
/// 내부적으로 위치를 보정하는데, 이를 우회해 메뉴바까지 자유롭게 이동할 수 있게 한다.
final class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}
