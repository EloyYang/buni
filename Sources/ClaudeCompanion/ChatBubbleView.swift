import SwiftUI

struct ChatBubbleView: View {
    let message: String
    /// 캐릭터가 화면 왼쪽에 있으면 true — 이때는 꼬리가 왼쪽(캐릭터 쪽)을 향한다
    var flipped: Bool = false

    var body: some View {
        SpeechBubbleShell(flipped: flipped) {
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
        }
    }
}

/// 말풍선 공통 틀 — 내용 + 캐릭터를 가리키는 꼬리를 붙여준다.
/// flipped == true(캐릭터가 화면 왼쪽에 있을 때)면 꼬리와 정렬을 반대쪽(왼쪽)으로 뒤집는다.
struct SpeechBubbleShell<Content: View>: View {
    var flipped: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: flipped ? .leading : .trailing) {
            content()

            // 캐릭터가 있는 쪽을 향하는 꼬리 (버블 왼쪽/오른쪽 중앙)
            SpeechTail()
                .fill(Color.white)
                .frame(width: 16, height: 13)
                .scaleEffect(x: flipped ? -1 : 1, y: 1)
                .offset(x: flipped ? -14 : 14, y: 0)
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
