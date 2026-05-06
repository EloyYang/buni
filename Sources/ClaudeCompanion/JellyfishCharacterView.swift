import SwiftUI

struct JellyfishCharacterView: View {
    @EnvironmentObject var ctrl: CompanionController

    private let p: CGFloat = 6.5

    private let bellColor  = Color(red: 0.48, green: 0.70, blue: 0.94)
    private let lightColor = Color(red: 0.74, green: 0.89, blue: 1.00)
    private let tentColor  = Color(red: 0.32, green: 0.50, blue: 0.78)

    @State private var bodyDY:      CGFloat = 0
    @State private var bodyDX:      CGFloat = 0
    @State private var bellScaleY:  CGFloat = 1.0
    @State private var tentacleDX:  [CGFloat] = [0, 0, 0, 0]
    @State private var tentacleDY:  [CGFloat] = [0, 0, 0, 0]
    @State private var slideTentaclePhase = false
    @State private var blinking  = false
    @State private var wideEyes  = false
    @State private var eyeLookUp = false

    private let tentXs: [CGFloat] = [-2.0, -0.65, 0.65, 2.0]
    private let tentHs: [CGFloat] = [2.4,  2.9,   2.9,  2.4]

    // MARK: – 벨
    private var bellBody: some View {
        ZStack {
            px(w: 4.0, h: 0.8, c: bellColor).offset(y:  p * 2.25)
            px(w: 5.5, h: 1.0, c: bellColor).offset(y:  p * 1.35)
            px(w: 5.5, h: 1.5, c: bellColor).offset(y:  p * 0.10)
            px(w: 4.0, h: 1.0, c: bellColor).offset(y: -p * 1.15)
            px(w: 3.0, h: 0.8, c: lightColor).offset(y: -p * 0.65)

            let eyeY: CGFloat = eyeLookUp ? -p * 0.65 : -p * 0.10
            eyeBlock(x: -p * 1.3, y: eyeY)
            eyeBlock(x:  p * 1.3, y: eyeY)
        }
        .scaleEffect(x: 1.0, y: bellScaleY)
        .animation(.easeInOut(duration: 0.18), value: bellScaleY)
    }

    var body: some View {
        ZStack {
            // ── 촉수 (벨 뒤)
            ForEach(0..<4, id: \.self) { i in
                px(w: 0.6, h: tentHs[i], c: tentColor)
                    .offset(x: p * tentXs[i] + tentacleDX[i],
                            y: p * 2.55 + bodyDY + tentacleDY[i])
                    .animation(.easeInOut(duration: 0.30), value: tentacleDX[i])
                    .animation(.easeInOut(duration: 0.30), value: tentacleDY[i])
            }

            // ── 벨
            bellBody.offset(y: bodyDY)
        }
        .offset(x: bodyDX)
        .animation(.easeInOut(duration: 0.20), value: bodyDX)
        .onChange(of: ctrl.state)     { newState in applyAnimation(newState) }
        .onChange(of: ctrl.isSliding) { sliding in
            sliding ? startSlidePulse() : stopSlidePulse()
        }
        .onAppear {
            applyAnimation(ctrl.state)
            scheduleBlink()
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
        if !ctrl.isSliding {
            withAnimation(.easeOut(duration: 0.2)) {
                bodyDY     = 0
                bodyDX     = 0
                bellScaleY = 1.0
                tentacleDX = [0, 0, 0, 0]
                tentacleDY = [0, 0, 0, 0]
            }
        }

        switch state {
        case .thinking, .toolUse:
            withAnimation(.easeInOut(duration: 0.3)) { eyeLookUp = true }

        case .notification:
            withAnimation(.easeOut(duration: 0.13)) { bodyDY = -p * 2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { bodyDY = 0 }
            }
            withAnimation(.easeInOut(duration: 0.2).delay(0.05)) {
                tentacleDX = [-p * 1.2, p * 0.8, -p * 0.8, p * 1.2]
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.2)) { tentacleDX = [0, 0, 0, 0] }
            }

        case .permission:
            withAnimation(.easeInOut(duration: 0.18)) { wideEyes = true }
            withAnimation(.easeOut(duration: 0.22)) {
                tentacleDY = [0, 0, 0, -p * 3.2]
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
                doSwim()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { scheduleIdleAnimation() }
            } else {
                doTentacleWave()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { scheduleIdleAnimation() }
            }
        }
    }

    private func doSwim() {
        guard case .ready = ctrl.state else { return }
        withAnimation(.easeIn(duration: 0.18)) {
            bellScaleY = 0.48
            bodyDY     = -p * 2.6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            guard case .ready = ctrl.state else {
                withAnimation(.easeOut(duration: 0.3)) { bellScaleY = 1.0; bodyDY = 0 }
                return
            }
            withAnimation(.easeOut(duration: 0.22)) { bellScaleY = 1.0 }
            withAnimation(.spring(response: 0.65, dampingFraction: 0.68)) { bodyDY = 0 }
        }
    }

    private func doTentacleWave() {
        let t = 0.22
        let waves: [[CGFloat]] = [
            [-p*0.9,  p*0.65, -p*0.65,  p*0.9],
            [ p*0.9, -p*0.65,  p*0.65, -p*0.9],
            [-p*0.9,  p*0.65, -p*0.65,  p*0.9],
            [ p*0.9, -p*0.65,  p*0.65, -p*0.9],
            [0, 0, 0, 0],
        ]
        for (idx, offsets) in waves.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + t * Double(idx)) {
                guard case .ready = ctrl.state else {
                    withAnimation(.easeOut(duration: 0.2)) { tentacleDX = [0, 0, 0, 0] }; return
                }
                withAnimation(.easeInOut(duration: t)) { tentacleDX = offsets }
            }
        }
    }

    // MARK: – 슬라이드

    private func startSlidePulse() {
        slideTentaclePhase = false
        stepSlidePulse()
    }

    private func stepSlidePulse() {
        guard ctrl.isSliding else { stopSlidePulse(); return }
        slideTentaclePhase.toggle()
        let s: CGFloat = slideTentaclePhase ? 1 : -1

        withAnimation(.easeIn(duration: 0.12))    { bellScaleY = 0.55 }
        withAnimation(.easeOut(duration: 0.10).delay(0.12)) { bellScaleY = 1.0 }
        withAnimation(.easeInOut(duration: 0.20)) {
            tentacleDX = [-s * p, s * p * 0.7, -s * p * 0.7, s * p]
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { stepSlidePulse() }
    }

    private func stopSlidePulse() {
        withAnimation(.easeOut(duration: 0.2)) {
            tentacleDX = [0, 0, 0, 0]
            bellScaleY = 1.0
        }
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
