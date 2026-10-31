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
for (name, pane) in [("업무 보드", SquadPane.overview), ("단체방", SquadPane.channel)] {
    snap(NSHostingView(rootView: TeamRootView(initialSelection: jobId, initialPane: pane).environment(\.colorScheme, .dark)),
         NSSize(width: 1180, height: 800), out + "/" + name + ".png")
}
snap(NSHostingView(rootView: SquadBoardView(onGoto: { _, _ in }).environment(\.colorScheme, .dark)), NSSize(width: 1180, height: 760), out + "/업무 현황.png")
print("done")
