import SwiftUI

struct PermissionBubbleView: View {
    let command: String
    let onApprove: () -> Void
    let onApproveAll: () -> Void
    let onDeny: () -> Void
    /// 캐릭터가 화면 왼쪽에 있으면 true — 이때는 꼬리가 왼쪽(캐릭터 쪽)을 향한다
    var flipped: Bool = false

    @ObservedObject private var lang = LanguageStore.shared
    @State private var isExpanded = false

    var body: some View {
        SpeechBubbleShell(flipped: flipped) {
            VStack(alignment: .leading, spacing: 8) {
                // 제목 + 펼치기 토글
                HStack(spacing: 5) {
                    Text("🔐")
                    Text(L.t("실행 허용?", "Run this?"))
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

                // 명령어 미리보기 (펼쳐지면 스크롤 가능한 전체 표시)
                Group {
                    if isExpanded {
                        ScrollView(.vertical, showsIndicators: true) {
                            Text(command)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(red: 0.25, green: 0.25, blue: 0.25))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                        .frame(maxHeight: 110)
                    } else {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(red: 0.25, green: 0.25, blue: 0.25))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 0.94, green: 0.94, blue: 0.94))
                )

                // 버튼 행
                HStack(spacing: 6) {
                    permissionButton(L.t("거부", "Deny"),   color: Color(red: 0.85, green: 0.25, blue: 0.20), action: onDeny)
                    permissionButton(L.t("허용", "Allow"),   color: Color(red: 0.20, green: 0.70, blue: 0.35), action: onApprove)
                    permissionButton(L.t("전체 허용", "Allow all"), color: Color(red: 0.25, green: 0.50, blue: 0.90), action: onApproveAll)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 210, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.20), radius: 8, x: -2, y: 3)
            )
        }
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
