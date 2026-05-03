import SwiftUI

// MARK: - Pixel art Claw'd character

struct ClaudeCharacterView: View {
    @EnvironmentObject var ctrl: CompanionController

    private let p: CGFloat = 6.5

    @State private var leftClawDY:  CGFloat = 0
    @State private var rightClawDY: CGFloat = 0
    @State private var bodyDY:      CGFloat = 0
    @State private var bodyDX:      CGFloat = 0
    @State private var isWalking:   Bool    = false // 걷는 중일 때만 true
    @State private var legPhase:    Bool    = false // 다리 교차 단계 (isWalking=true일 때만 적용)
    @State private var blinking:    Bool    = false
    @State private var wideEyes:    Bool    = false
    @State private var eyeLookUp:   Bool    = false

    private let bodyColor = Color(red: 0.76, green: 0.52, blue: 0.37)

    var body: some View {
        ZStack {
            // ── 4 legs — legPhase에 따라 짝/홀 다리 교차
            ForEach(0..<4, id: \.self) { idx in
                let xUnit = ([-2.5, -0.8, 0.8, 2.5] as [CGFloat])[idx]
                // 걷는 중일 때만 짝/홀 교차, 아닐 때는 모두 동일 높이
                let raised = isWalking && (legPhase ? (idx % 2 == 0) : (idx % 2 == 1))
                pxRect(w: 1, h: 1.5)
                    .offset(x: p * xUnit,
                            y: p * 2.75 + bodyDY - (raised ? p * 0.55 : 0))
                    .animation(.easeInOut(duration: 0.16), value: raised)
            }

            // ── Body (7×4p)
            pxRect(w: 7, h: 4)
                .offset(y: bodyDY)

            // ── Left claw
            pxRect(w: 1, h: 1.2)
                .offset(x: -p * 4, y: leftClawDY + bodyDY)
                .animation(.easeInOut(duration: 0.18), value: leftClawDY)

            // ── Right claw
            pxRect(w: 1, h: 1.2)
                .offset(x:  p * 4, y: rightClawDY + bodyDY)
                .animation(.easeInOut(duration: 0.18), value: rightClawDY)

            let eyeY: CGFloat = eyeLookUp ? -p * 1.1 : -p * 0.5

            // ── Left eye
            Rectangle()
                .fill(Color.black)
                .frame(width: p * 0.7,
                       height: blinking ? p * 0.15
                             : wideEyes ? p * 1.4
                             : p * 1.0)
                .offset(x: -p * 2.0, y: eyeY + bodyDY)
                .animation(.easeInOut(duration: 0.08), value: blinking)
                .animation(.easeInOut(duration: 0.25), value: eyeLookUp)
                .animation(.easeInOut(duration: 0.12), value: wideEyes)

            // ── Right eye
            Rectangle()
                .fill(Color.black)
                .frame(width: p * 0.7,
                       height: blinking ? p * 0.15
                             : wideEyes ? p * 1.4
                             : p * 1.0)
                .offset(x:  p * 2.0, y: eyeY + bodyDY)
                .animation(.easeInOut(duration: 0.08), value: blinking)
                .animation(.easeInOut(duration: 0.25), value: eyeLookUp)
                .animation(.easeInOut(duration: 0.12), value: wideEyes)
        }
        // 전체 좌우 이동
        .offset(x: bodyDX)
        .animation(.easeInOut(duration: 0.20), value: bodyDX)
        .onChange(of: ctrl.state) { newState in
            applyAnimation(newState)
        }
        .onChange(of: ctrl.isSliding) { sliding in
            if sliding {
                startSlideWalk()
            } else {
                stopSlideWalk()
            }
        }
        .onAppear {
            applyAnimation(ctrl.state)
            scheduleBlink()
        }
    }

    private func pxRect(w: CGFloat, h: CGFloat) -> some View {
        Rectangle().fill(bodyColor).frame(width: p * w, height: p * h)
    }

    // MARK: – State animations

    private func applyAnimation(_ state: CompanionState) {
        withAnimation(.easeOut(duration: 0.25)) {
            leftClawDY  = 0
            rightClawDY = 0
            wideEyes    = false
            eyeLookUp   = false
        }
        // 슬라이드 등장·퇴장 중에는 다리/위치 리셋 생략 — slide walk가 관리
        if !ctrl.isSliding {
            withAnimation(.easeOut(duration: 0.2)) {
                bodyDY    = 0
                bodyDX    = 0
                isWalking = false
                legPhase  = false
            }
        }

        switch state {

        case .thinking, .toolUse:
            withAnimation(.easeInOut(duration: 0.3)) { eyeLookUp = true }

        case .notification:
            withAnimation(.easeOut(duration: 0.12)) { bodyDY = -p * 2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.easeIn(duration: 0.12)) { bodyDY = 0 }
            }
            withAnimation(.easeInOut(duration: 0.2).delay(0.1)) {
                rightClawDY = -p * 2.5
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                withAnimation(.easeInOut(duration: 0.2)) { rightClawDY = 0 }
            }

        case .permission:
            withAnimation(.easeInOut(duration: 0.18)) {
                leftClawDY  = -p * 2.5
                rightClawDY = -p * 2.5
                wideEyes    = true
            }
            shakeBody()

        case .ready:
            scheduleIdleAnimation()

        case .idle:
            break
        }
    }

    // MARK: – Idle animations (대기 중 랜덤 동작)

    private func scheduleIdleAnimation() {
        let delay = Double.random(in: 6.0...14.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard case .ready = ctrl.state else { return }
            // 40% 점프, 60% 걷기
            if Double.random(in: 0...1) < 0.4 {
                doIdleJump()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    scheduleIdleAnimation()
                }
            } else {
                doIdleWalk()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    scheduleIdleAnimation()
                }
            }
        }
    }

    /// 좌우로 한 번씩 워들 (4 스텝)
    private func doIdleWalk() {
        let dir: CGFloat = Bool.random() ? 1 : -1
        let step = p * 1.2
        let t = 0.20

        // 걷기 시작 — 다리 교차 활성화
        isWalking = true
        legPhase  = false

        // 1
        DispatchQueue.main.asyncAfter(deadline: .now() + t * 1) {
            guard case .ready = ctrl.state else { isWalking = false; legPhase = false; return }
            withAnimation(.easeInOut(duration: t)) { bodyDX = dir * step;     legPhase = true  }
        }
        // 2
        DispatchQueue.main.asyncAfter(deadline: .now() + t * 2) {
            guard case .ready = ctrl.state else { isWalking = false; legPhase = false; return }
            withAnimation(.easeInOut(duration: t)) { bodyDX = dir * step * 2; legPhase = false }
        }
        // 3
        DispatchQueue.main.asyncAfter(deadline: .now() + t * 3) {
            guard case .ready = ctrl.state else { isWalking = false; legPhase = false; return }
            withAnimation(.easeInOut(duration: t)) { bodyDX = dir * step;     legPhase = true  }
        }
        // 4: 원위치 복귀 후 다리 원상태
        DispatchQueue.main.asyncAfter(deadline: .now() + t * 4) {
            guard case .ready = ctrl.state else { isWalking = false; legPhase = false; return }
            withAnimation(.easeInOut(duration: t)) { bodyDX = 0; legPhase = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t * 4 + t) {
            // 걷기 완전 종료 — 다리 평평하게
            isWalking = false
            legPhase  = false
        }
    }

    /// 점프 (위로 튀어 올랐다 내려옴)
    private func doIdleJump() {
        guard case .ready = ctrl.state else { return }
        withAnimation(.easeOut(duration: 0.14)) { bodyDY = -p * 3 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard case .ready = ctrl.state else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { bodyDY = 0 }
        }
    }

    // MARK: – Shared helpers

    private func startClawSnap() {
        var up = true
        Timer.scheduledTimer(withTimeInterval: 0.38, repeats: true) { t in
            guard case .toolUse = ctrl.state else { t.invalidate(); return }
            withAnimation(.easeInOut(duration: 0.18)) {
                leftClawDY  = up ? -p * 1.8 :  0
                rightClawDY = up ? 0         : -p * 1.8
            }
            up.toggle()
        }
    }

    private func shakeBody() {
        let steps: [CGFloat] = [0, -p, p, -p, p, -p * 0.5, p * 0.5, 0]
        for (i, dy) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.07) {
                bodyDY = dy
            }
        }
    }

    // MARK: – Slide walk (등장·퇴장 시 다리 연속 교차)

    private func startSlideWalk() {
        isWalking = true
        legPhase  = false
        stepSlideWalk()
    }

    private func stepSlideWalk() {
        guard ctrl.isSliding else {
            withAnimation(.easeOut(duration: 0.2)) {
                isWalking = false
                legPhase  = false
            }
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) { legPhase.toggle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            stepSlideWalk()
        }
    }

    private func stopSlideWalk() {
        withAnimation(.easeOut(duration: 0.2)) {
            isWalking = false
            legPhase  = false
        }
    }

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
