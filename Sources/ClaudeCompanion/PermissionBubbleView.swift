import SwiftUI

struct PermissionBubbleView: View {
    let command: String
    let onApprove: () -> Void
    let onApproveAll: () -> Void
    let onDeny: () -> Void

    @State private var isExpanded = false

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                // 제목 + 펼치기 토글
                HStack(spacing: 5) {
                    Text("🔐")
                    Text("실행 허용?")
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(red: 0.5, green: 0.5, blue: 0.5))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }

                // 명령어 미리보기 (펼쳐지면 전체 표시)
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(red: 0.25, green: 0.25, blue: 0.25))
                    .lineLimit(isExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.94, green: 0.94, blue: 0.94))
                    )

                // 버튼 행
                HStack(spacing: 6) {
                    permissionButton("거부",   color: Color(red: 0.85, green: 0.25, blue: 0.20), action: onDeny)
                    permissionButton("허용",   color: Color(red: 0.20, green: 0.70, blue: 0.35), action: onApprove)
                    permissionButton("전체 허용", color: Color(red: 0.25, green: 0.50, blue: 0.90), action: onApproveAll)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 250, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.20), radius: 8, x: -2, y: 3)
            )

            // 말풍선 꼬리
            SpeechTail()
                .fill(Color.white)
                .frame(width: 16, height: 13)
                .offset(x: 14, y: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func permissionButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(color))
        }
        .buttonStyle(.plain)
    }
}
