import SwiftUI

struct ChatBubbleView: View {
    let message: String

    var body: some View {
        ZStack(alignment: .trailing) {
            // Main bubble — 내용에 맞게 줄어들고 최대 너비 제한
            Text(message)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(.black)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .lineLimit(6)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 210, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.18), radius: 8, x: -2, y: 3)
                )

            // Tail pointing right toward character (버블 오른쪽 중앙)
            SpeechTail()
                .fill(Color.white)
                .frame(width: 16, height: 13)
                .offset(x: 14, y: 0)
        }
        // 핵심: 부모가 제안하는 너비를 무시하고 내용물의 이상적 크기 사용
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct SpeechTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: 0, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
