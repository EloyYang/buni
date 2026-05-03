import SwiftUI
import AppKit

// MARK: - Key Recorder Field

/// 클릭 후 다음 키 입력을 단축키로 기록하는 컨트롤
struct KeyRecorderField: View {
    let label: String
    @Binding var shortcut: KeyShortcut?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 80, alignment: .leading)
                .foregroundColor(.white.opacity(0.85))

            Button(action: toggleRecording) {
                HStack(spacing: 6) {
                    if isRecording {
                        Text("키 입력 대기...")
                            .foregroundColor(.yellow)
                    } else if let sc = shortcut {
                        Text(sc.displayString)
                            .foregroundColor(.white)
                    } else {
                        Text("없음")
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Spacer()
                    if !isRecording {
                        Image(systemName: "pencil")
                            .foregroundColor(.white.opacity(0.5))
                            .font(.system(size: 10))
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.yellow.opacity(0.7))
                            .font(.system(size: 10))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 160)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isRecording
                              ? Color.yellow.opacity(0.15)
                              : Color.white.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isRecording
                                        ? Color.yellow.opacity(0.6)
                                        : Color.white.opacity(0.25),
                                        lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            if shortcut != nil && !isRecording {
                Button(action: { shortcut = nil }) {
                    Image(systemName: "minus.circle")
                        .foregroundColor(.red.opacity(0.7))
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ESC 누르면 취소
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let relevant = event.modifierFlags
                .intersection([.command, .option, .control, .shift])
            shortcut = KeyShortcut(keyCode: event.keyCode,
                                   modifiers: relevant.rawValue)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

// MARK: - Settings View

struct ShortcutSettingsView: View {
    @ObservedObject private var store = ShortcutStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("단축키 설정")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)

            Divider()
                .background(Color.white.opacity(0.2))

            VStack(alignment: .leading, spacing: 12) {
                KeyRecorderField(label: "권한 허락",  shortcut: $store.approve)
                KeyRecorderField(label: "권한 거부",  shortcut: $store.deny)
                KeyRecorderField(label: "캐릭터 숨기기", shortcut: $store.hide)
            }

            Divider()
                .background(Color.white.opacity(0.2))

            HStack {
                Text("단축키는 전역으로 동작합니다.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
                Button("저장") {
                    store.save()
                    // 창 닫기
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(PillButtonStyle(color: .accentColor))
            }
        }
        .padding(20)
        .frame(width: 310)
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
        .onChange(of: store.approve) { _ in store.save() }
        .onChange(of: store.deny)    { _ in store.save() }
        .onChange(of: store.hide)    { _ in store.save() }
    }
}

// MARK: - Button Style

private struct PillButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(configuration.isPressed ? 0.7 : 1.0))
            )
    }
}
