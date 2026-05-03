import SwiftUI

struct PermissionBubbleView: View {
    let command: String
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                // 제목
                HStack(spacing: 5) {
                    Text("🔐")
                    Text("실행 허용?")
                        .font(.system(.callout, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.black)
                }

                // 명령어 미리보기
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(red: 0.25, green: 0.25, blue: 0.25))
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.94, green: 0.94, blue: 0.94))
                    )

                // 버튼 행
                HStack(spacing: 8) {
                    Button(action: onDeny) {
                        Text("거부")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(red: 0.85, green: 0.25, blue: 0.20))
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: onApprove) {
                        Text("허용")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(red: 0.20, green: 0.70, blue: 0.35))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 230, alignment: .leading)
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
}
