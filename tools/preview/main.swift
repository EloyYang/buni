import Cocoa
import SwiftUI

// 화면 비교용 — 같은 예시 데이터로 팀 현황 화면 몇 개를 PNG 로 저장한다 (tools/preview-shots.sh 가 부른다)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated { TeamStore.shared.reload(force: true) }
let jobId = MainActor.assumeIsolated { TeamStore.shared.jobs.first?.id ?? "" }

func snap(_ view: NSView, _ size: NSSize, _ path: String) {
    view.frame = NSRect(origin: .zero, size: size)
    let win = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: .darkAqua)
    win.contentView = view
    win.orderFront(nil)
    for _ in 0..<12 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// BUNI_PREVIEW_OPEN=1 — 업무 카드의 상세 팝업을 연 채로 그린다 (화면이 그 환경변수를 모르는 옛 소스에서는 그냥 무시된다)
func withDetailOpen(_ body: () -> Void) {
    setenv("BUNI_PREVIEW_OPEN", "1", 1); body(); unsetenv("BUNI_PREVIEW_OPEN")
}
func project(_ pane: SquadPane) -> NSHostingView<some View> {
    NSHostingView(rootView: TeamRootView(initialSelection: jobId, initialPane: pane).environment(\.colorScheme, .dark))
}
func overview() -> NSHostingView<some View> {
    NSHostingView(rootView: SquadBoardView(onGoto: { _, _ in }).environment(\.colorScheme, .dark))
}

if ProcessInfo.processInfo.environment["BUNI_PREVIEW_LIVE"] != nil {
    // 직접 써 보기 — 같은 예시 데이터로 팀 창을 진짜 창으로 띄운다 (이 소스 트리 그대로 컴파일한 프로그램)
    app.setActivationPolicy(.regular)
    let host = project(.overview)
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    win.title = "Buni 미리보기 — " + (ProcessInfo.processInfo.environment["BUNI_SHOT_SIDE"] ?? "")
    win.contentView = host
    win.center()
    win.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
} else {
    snap(project(.overview), NSSize(width: 1180, height: 800), out + "/프로젝트 현황.png")
    snap(project(.channel), NSSize(width: 1180, height: 800), out + "/단체방.png")
    snap(overview(), NSSize(width: 1180, height: 760), out + "/전체 현황.png")
    withDetailOpen { snap(overview(), NSSize(width: 1180, height: 760), out + "/전체 현황 · 업무 상세.png") }
    withDetailOpen { snap(project(.overview), NSSize(width: 1180, height: 800), out + "/프로젝트 현황 · 업무 상세.png") }
    print("done")
}
