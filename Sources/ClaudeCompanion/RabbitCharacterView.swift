import SwiftUI

struct RabbitCharacterView: View {
    @EnvironmentObject var ctrl: CompanionController

    private let p: CGFloat = 6.5

    private let bodyColor = Color(red: 0.91, green: 0.91, blue: 0.94)
    private let earPink   = Color(red: 0.95, green: 0.72, blue: 0.78)
    private let carrotCol = Color(red: 0.96, green: 0.55, blue: 0.18)
    private let leafCol   = Color(red: 0.28, green: 0.70, blue: 0.28)

    @State private var bodyDY:      CGFloat = 0
    @State private var bodyDX:      CGFloat = 0
    @State private var leftArmDY:   CGFloat = 0
    @State private var earFoldScale: CGFloat = 1.0 // 귀 접힘 (1.0 = 펼침, 0 = 완전 접힘)
    @State private var hopPhase:    Bool    = false
    @State private var showCarrot:  Bool    = false
    @State private var blinking:    Bool    = false
    @State private var wideEyes:    Bool    = false
    @State private var eyeLookUp:   Bool    = false

    var body: some View {
        ZStack {
            // ── 귀 (머리 뒤) — 외형·핑크를 ZStack으로 묶어 함께 scaleEffect
            // 왼쪽 귀
            ZStack {
                px(w: 1.6, h: 3.4, c: bodyColor)
                px(w: 0.8, h: 2.7, c: earPink).offset(y: -p * 0.1)
            }
            .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
            .animation(.spring(response: 0.28, dampingFraction: 0.45), value: earFoldScale)
            .offset(x: -p * 1.6, y: -p * 3.5 + bodyDY)

            // 오른쪽 귀
            ZStack {
                px(w: 1.6, h: 3.4, c: bodyColor)
                px(w: 0.8, h: 2.7, c: earPink).offset(y: -p * 0.1)
            }
            .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
            .animation(.spring(response: 0.28, dampingFraction: 0.45), value: earFoldScale)
            .offset(x: p * 1.6, y: -p * 3.5 + bodyDY)

            // ── 몸통
            px(w: 4.5, h: 2.5, c: bodyColor).offset(y: p * 1.5 + bodyDY)

            // ── 왼팔 (권한 요청 시 들어올림)
            px(w: 1.5, h: 0.9, c: bodyColor)
                .offset(x: -p * 2.65, y: p * 1.1 + leftArmDY + bodyDY)
                .animation(.easeOut(duration: 0.28), value: leftArmDY)

            // ── 당근 (권한 요청 시만 표시, 왼쪽)
            if showCarrot {
                carrotView
                    .offset(x: -p * 4.0, y: p * 0.1 + leftArmDY + bodyDY)
                    .animation(.easeOut(duration: 0.28), value: leftArmDY)
                    .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
            }

            // ── 오른팔 (고정)
            px(w: 1.5, h: 0.9, c: bodyColor)
                .offset(x: p * 2.65, y: p * 1.1 + bodyDY)

            // ── 발
            px(w: 1.5, h: 0.9, c: bodyColor).offset(x: -p * 1.2, y: p * 2.9 + bodyDY)
            px(w: 1.5, h: 0.9, c: bodyColor).offset(x:  p * 1.2, y: p * 2.9 + bodyDY)

            // ── 머리 (귀 앞)
            px(w: 5.5, h: 2.5, c: bodyColor).offset(y: -p * 0.8 + bodyDY)

            // ── 눈
            let eyeY = (eyeLookUp ? -p * 1.35 : -p * 0.9) + bodyDY
            eyeBlock(x: -p * 1.4, y: eyeY)
            eyeBlock(x:  p * 1.4, y: eyeY)

            // ── 코 (핑크 작은 사각)
            Rectangle()
                .fill(earPink)
                .frame(width: p * 0.55, height: p * 0.4)
                .offset(y: -p * 0.25 + bodyDY)
        }
        .offset(x: bodyDX)
        .animation(.easeInOut(duration: 0.20), value: bodyDX)
        .onChange(of: ctrl.state)     { newState in applyAnimation(newState) }
        .onChange(of: ctrl.isSliding) { sliding in
            sliding ? startSlideHop() : stopSlideHop()
        }
        .onAppear {
            applyAnimation(ctrl.state)
            scheduleBlink()
        }
    }

    // MARK: – 당근 뷰

    private var carrotView: some View {
        ZStack {
            // 잎 (초록)
            px(w: 1.5, h: 0.6, c: leafCol).offset(y: -p * 1.25)
            px(w: 0.7, h: 0.55, c: leafCol).offset(y: -p * 1.75)
            // 당근 몸통 (주황)
            px(w: 0.7, h: 2.1, c: carrotCol)
        }
    }

    // MARK: – 픽셀 블록 / 눈

    private func px(w: CGFloat, h: CGFloat, c: Color) -> some View {
        Rectangle().fill(c).frame(width: p * w, height: p * h)
    }

    @ViewBuilder
    private func eyeBlock(x: CGFloat, y: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black)
            .frame(width:  p * 0.65,
                   height: blinking ? p * 0.12
                         : wideEyes ? p * 1.1
                         : p * 0.75)
            .offset(x: x, y: y)
            .animation(.easeInOut(duration: 0.08), value: blinking)
            .animation(.easeInOut(duration: 0.12), value: wideEyes)
            .animation(.easeInOut(duration: 0.25), value: eyeLookUp)
    }

    // MARK: – 상태별 애니메이션

    private func applyAnimation(_ state: CompanionState) {
        withAnimation(.easeOut(duration: 0.25)) {
            wideEyes  = false
            eyeLookUp = false
        }
        // 권한 상태가 아니면 팔·당근 내리기
        if case .permission = state { } else {
            withAnimation(.easeOut(duration: 0.25)) {
                leftArmDY = 0
                showCarrot = false
            }
        }
        if !ctrl.isSliding {
            withAnimation(.easeOut(duration: 0.2)) {
                bodyDY       = 0
                bodyDX       = 0
                earFoldScale = 1.0
            }
        }

        switch state {

        case .thinking, .toolUse:
            withAnimation(.easeInOut(duration: 0.3)) { eyeLookUp = true }

        case .notification:
            withAnimation(.easeOut(duration: 0.12)) { bodyDY = -p * 2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { bodyDY = 0 }
            }

        case .permission:
            withAnimation(.easeInOut(duration: 0.18)) { wideEyes = true }
            // 왼팔 번쩍 들기
            withAnimation(.easeOut(duration: 0.28)) { leftArmDY = -p * 2.8 }
            // 잠깐 뒤 당근 등장
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                    showCarrot = true
                }
            }

        case .ready:
            scheduleIdleAnimation()

        case .idle:
            break
        }
    }

    // MARK: – 아이들 애니메이션

    private func scheduleIdleAnimation() {
        let delay = Double.random(in: 6.0...13.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard case .ready = ctrl.state else { return }
            if Double.random(in: 0...1) < 0.5 {
                doIdleHop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { scheduleIdleAnimation() }
            } else {
                doEarPerk()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { scheduleIdleAnimation() }
            }
        }
    }

    private func doIdleHop() {
        guard case .ready = ctrl.state else { return }
        withAnimation(.easeOut(duration: 0.14)) { bodyDY = -p * 2.8 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard case .ready = ctrl.state else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.52)) { bodyDY = 0 }
        }
    }

    private func doEarPerk() {
        guard case .ready = ctrl.state else { return }
        // 귀 끝이 살짝 접혔다 스프링으로 펴지는 모션 (anchor: .bottom 으로 뿌리 고정)
        withAnimation(.easeIn(duration: 0.10)) { earFoldScale = 0.52 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            guard case .ready = ctrl.state else {
                withAnimation(.easeOut(duration: 0.2)) { earFoldScale = 1.0 }
                return
            }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.40)) { earFoldScale = 1.0 }
        }
    }

    // MARK: – 슬라이드 (통통 뛰며 등장·퇴장)

    private func startSlideHop() {
        hopPhase = false
        stepSlideHop()
    }

    private func stepSlideHop() {
        guard ctrl.isSliding else { stopSlideHop(); return }
        hopPhase.toggle()
        withAnimation(hopPhase
            ? .easeOut(duration: 0.11)
            : .spring(response: 0.18, dampingFraction: 0.52)) {
            bodyDY = hopPhase ? -p * 2.2 : 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { stepSlideHop() }
    }

    private func stopSlideHop() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { bodyDY = 0 }
    }

    // MARK: – 헬퍼

    private func scheduleBlink() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 2.5...6.0)) {
            blinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                blinking = false
                scheduleBlink()
            }
        }
    }
}
