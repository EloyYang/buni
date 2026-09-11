import SwiftUI

/// 주니 — 주황 토끼. 발랄하고 장난기 넘침.
/// 특징: 더 높이 튀는 점프, 볼 터치, 오렌지 들기
struct OrangeRabbitCharacterView: View {
    @EnvironmentObject var ctrl: CompanionController
    @Environment(\.colorScheme) private var colorScheme

    private let p: CGFloat = 6.5

    private let bodyColor  = Color(red: 0.95, green: 0.52, blue: 0.12)
    private let earInner   = Color(red: 1.00, green: 0.82, blue: 0.60)
    private let noseColor  = Color(red: 1.00, green: 0.90, blue: 0.80)
    private let cheekColor = Color(red: 1.00, green: 0.70, blue: 0.50).opacity(0.55)
    private let orangeCol  = Color(red: 1.00, green: 0.58, blue: 0.10)
    private let leafCol    = Color(red: 0.22, green: 0.70, blue: 0.22)

    @State private var bodyDY:        CGFloat = 0
    @State private var bodyDX:        CGFloat = 0
    @State private var leftArmDY:     CGFloat = 0
    @State private var rightArmDY:    CGFloat = 0
    @State private var leftArmDX:     CGFloat = 0
    @State private var rightArmDX:    CGFloat = 0
    @State private var earFoldScale:  CGFloat = 1.0
    @State private var hopPhase:      Bool    = false
    @State private var showProp:      Bool    = false
    @State private var showKnitting:  Bool    = false
    @State private var knittingPhase: Bool    = false
    @State private var blinking:      Bool    = false
    @State private var wideEyes:      Bool    = false
    @State private var eyeLookUp:     Bool    = false
    @State private var showReading:   Bool    = false
    @State private var readingPhase:  Bool    = false
    @State private var throwingDoc:  Bool    = false
    @State private var docVisible:   Bool    = true
    @State private var readingStep:  Int     = 0

    var body: some View {
        ZStack {
            // ── 귀 (살짝 벌어진 느낌 — 발랄함)
            ZStack {
                px(w: 1.6, h: 3.3, c: bodyColor)
                px(w: 0.8, h: 2.6, c: earInner).offset(y: -p * 0.1)
            }
            .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
            .animation(.spring(response: 0.26, dampingFraction: 0.42), value: earFoldScale)
            .offset(x: -p * 1.7, y: -p * 3.4 + bodyDY)
            .rotationEffect(.degrees(-5), anchor: .bottom)

            ZStack {
                px(w: 1.6, h: 3.3, c: bodyColor)
                px(w: 0.8, h: 2.6, c: earInner).offset(y: -p * 0.1)
            }
            .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
            .animation(.spring(response: 0.26, dampingFraction: 0.42), value: earFoldScale)
            .offset(x: p * 1.7, y: -p * 3.4 + bodyDY)
            .rotationEffect(.degrees(5), anchor: .bottom)

            // ── 몸통 (통통)
            px(w: 4.7, h: 2.6, c: bodyColor).offset(y: p * 1.5 + bodyDY)

            // ── 왼팔
            armView(outlined: showKnitting)
                .offset(x: -p * 2.70 + leftArmDX, y: p * 1.1 + leftArmDY + bodyDY)
                .animation(.easeInOut(duration: 0.28), value: leftArmDX)
                .animation(.easeInOut(duration: 0.24), value: leftArmDY)

            // ── 오렌지 (권한/완료 시)
            if showProp {
                orangeView
                    .offset(x: -p * 4.0, y: p * 0.0 + leftArmDY + bodyDY)
                    .animation(.easeOut(duration: 0.24), value: leftArmDY)
                    .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
            }

            // ── 오른팔
            armView(outlined: showKnitting)
                .offset(x: p * 2.70 + rightArmDX, y: p * 1.1 + rightArmDY + bodyDY)
                .animation(.easeInOut(duration: 0.28), value: rightArmDX)
                .animation(.easeInOut(duration: 0.24), value: rightArmDY)

            // ── 맥북 타이핑 (생각중 — 팔 위에 그려서 팔이 맥북에 가려짐)
            if showKnitting {
                LaptopView(p: p, bodyDY: bodyDY)
                    .transition(.opacity)
            }

            // ── 발 (동그란 느낌)
            px(w: 1.6, h: 1.0, c: bodyColor).offset(x: -p * 1.2, y: p * 2.9 + bodyDY)
            px(w: 1.6, h: 1.0, c: bodyColor).offset(x:  p * 1.2, y: p * 2.9 + bodyDY)
            // ── 문서 읽기 (툴사용)
            if showReading {
                DocumentView(p: p, bodyDY: bodyDY, throwing: throwingDoc, docVisible: docVisible)
                    .transition(.opacity)
            }

            // ── 머리
            px(w: 5.6, h: 2.6, c: bodyColor).offset(y: -p * 0.8 + bodyDY)

            // ── 볼 터치 (발랄한 포인트)
            Circle()
                .fill(cheekColor)
                .frame(width: p * 1.4, height: p * 1.0)
                .offset(x: -p * 1.8, y: -p * 0.35 + bodyDY)
            Circle()
                .fill(cheekColor)
                .frame(width: p * 1.4, height: p * 1.0)
                .offset(x:  p * 1.8, y: -p * 0.35 + bodyDY)

            // ── 눈
            let eyeY = (eyeLookUp ? -p * 1.32 : -p * 0.88) + bodyDY
            eyeBlock(x: -p * 1.42, y: eyeY)
            eyeBlock(x:  p * 1.42, y: eyeY)

            // ── 코
            Rectangle()
                .fill(noseColor)
                .frame(width: p * 0.58, height: p * 0.40)
                .offset(y: -p * 0.24 + bodyDY)
        }
        .offset(x: bodyDX)
        .animation(.easeInOut(duration: 0.18), value: bodyDX)
        .compositingGroup()
        .shadow(color: colorScheme == .light ? Color.black.opacity(0.30) : .clear,
                radius: 1.5, x: 0, y: 0)
        .onChange(of: ctrl.state)     { newState in applyAnimation(newState) }
        .onChange(of: ctrl.isSliding) { sliding in
            sliding ? startSlideHop() : stopSlideHop()
        }
        .onAppear {
            applyAnimation(ctrl.state)
            scheduleBlink()
        }
    }

    // MARK: - 팔

    @ViewBuilder
    private func armView(outlined: Bool) -> some View {
        ZStack {
            if outlined { px(w: 1.9, h: 1.2, c: Color.black.opacity(0.22)) }
            px(w: 1.5, h: 0.9, c: bodyColor)
        }
    }

    // MARK: - 오렌지

    private var orangeView: some View {
        ZStack {
            // 오렌지 몸통 (둥근 원형)
            Circle()
                .fill(orangeCol)
                .frame(width: p * 1.7, height: p * 1.7)
            // 하이라이트
            Circle()
                .fill(Color.white.opacity(0.32))
                .frame(width: p * 0.45, height: p * 0.45)
                .offset(x: -p * 0.35, y: -p * 0.35)
            // 꼭지
            px(w: 0.22, h: 0.50, c: leafCol).offset(y: -p * 1.1)
            // 잎
            px(w: 0.65, h: 0.35, c: leafCol)
                .rotationEffect(.degrees(-30))
                .offset(x: p * 0.38, y: -p * 0.95)
        }
    }

    // MARK: - 픽셀 / 눈

    private func px(w: CGFloat, h: CGFloat, c: Color) -> some View {
        Rectangle().fill(c).frame(width: p * w, height: p * h)
    }

    @ViewBuilder
    private func eyeBlock(x: CGFloat, y: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black)
            .frame(width:  p * 0.68,
                   height: blinking ? p * 0.10
                         : wideEyes ? p * 1.1
                         : p * 0.78)
            .offset(x: x, y: y)
            .animation(.easeInOut(duration: 0.07), value: blinking)
            .animation(.easeInOut(duration: 0.11), value: wideEyes)
            .animation(.easeInOut(duration: 0.22), value: eyeLookUp)
    }

    // MARK: - 상태 애니메이션

    private func applyAnimation(_ state: CompanionState) {
        withAnimation(.easeOut(duration: 0.22)) { wideEyes = false; eyeLookUp = false }
        if case .permission = state { } else {
            withAnimation(.easeOut(duration: 0.22)) { showProp = false }
        }
        switch state {
        case .thinking, .toolUse, .backgroundWork: break
        default: stopKnitting()
        }
        switch state {
        case .toolRead: break
        default: stopReading()
        }
        if !ctrl.isSliding {
            withAnimation(.easeOut(duration: 0.20)) { bodyDY = 0; bodyDX = 0; earFoldScale = 1.0 }
        }

        switch state {
        case .thinking, .toolUse, .backgroundWork:
            startKnitting()
        case .toolRead:
            startReading()

        case .notification:
            withAnimation(.easeOut(duration: 0.11)) { bodyDY = -p * 3.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.48)) { bodyDY = 0 }
            }

        case .permission:
            // 주니: 눈 크게 + 양팔 빠르게 + 미니 점프
            withAnimation(.easeInOut(duration: 0.16)) { wideEyes = true }
            withAnimation(.easeOut(duration: 0.25)) { leftArmDY  = -p * 3.0 }
            withAnimation(.easeOut(duration: 0.20)) { rightArmDY = -p * 3.0 }
            withAnimation(.easeOut(duration: 0.11)) { bodyDY = -p * 1.8 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.48)) { bodyDY = 0 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { showProp = true }
            }

        case .completed:
            // 주니: 눈 크게 + 양팔 + 3연속 빠른 바운스 (2.5→2.0→1.5)
            withAnimation(.easeInOut(duration: 0.16)) { wideEyes = true }
            withAnimation(.easeOut(duration: 0.25)) { leftArmDY  = -p * 3.0 }
            withAnimation(.easeOut(duration: 0.20)) { rightArmDY = -p * 3.0 }
            // 1st bounce
            withAnimation(.easeOut(duration: 0.11)) { bodyDY = -p * 2.5 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.45)) { bodyDY = 0 }
            }
            // 2nd bounce
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                withAnimation(.easeOut(duration: 0.10)) { bodyDY = -p * 2.0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.48)) { bodyDY = 0 }
                }
            }
            // 3rd bounce
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                withAnimation(.easeOut(duration: 0.10)) { bodyDY = -p * 1.5 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.52)) { bodyDY = 0 }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { showProp = true }
            }

        case .ready:
            scheduleIdleAnimation()
        case .idle:
            break
        }
    }

    // MARK: - 뜨개질 (보통 속도 — 0.30s)

    private func startKnitting() {
        guard !showKnitting else { return }
        withAnimation(.easeOut(duration: 0.28)) {
            leftArmDX  =  p * 1.55; rightArmDX  = -p * 1.55
            leftArmDY =  p * 1.00; rightArmDY =  p * 1.00
            showKnitting = true
        }
        knittingPhase = false
        stepKnitting()
    }

    private func stepKnitting() {
        switch ctrl.state { case .thinking, .toolUse, .backgroundWork: break; default: return }
        knittingPhase.toggle()
        let base: CGFloat = p * 1.00; let swing: CGFloat = p * 0.60
        withAnimation(.easeInOut(duration: 0.30)) {
            leftArmDY  = knittingPhase ? base - swing : base + swing
            rightArmDY = knittingPhase ? base + swing : base - swing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { stepKnitting() }
    }

    private func stopKnitting() {
        withAnimation(.easeOut(duration: 0.22)) {
            showKnitting = false
            if !showReading { rightArmDY = 0; rightArmDX = 0; leftArmDX = 0 }
        }
        // permission 상태가 아닐 때만 왼팔도 내리기
        if !showReading {
            if case .permission = ctrl.state { } else {
                withAnimation(.easeOut(duration: 0.22)) { leftArmDY = 0 }
            }
        }
    }

    // MARK: - 문서 읽기 (빠릿하게 — 0.8s)

    private func startReading() {
        guard !showReading else { return }
        withAnimation(.easeOut(duration: 0.28)) {
            leftArmDX  =  p * 1.55; rightArmDX  = -p * 1.55
            leftArmDY  =  p * 0.25; rightArmDY  =  p * 0.25
            showReading = true
        }
        readingPhase = false
        readingStep  = 0
        stepReading()
    }

    private func stepReading() {
        guard case .toolRead = ctrl.state else { return }
        readingStep += 1
        if readingStep % 3 == 0 {
            throwAndReplaceDoc()
        } else {
            readingPhase.toggle()
            withAnimation(.easeInOut(duration: 0.8)) {
                leftArmDY  = readingPhase ? p * 0.18 : p * 0.30
                rightArmDY = readingPhase ? p * 0.30 : p * 0.18
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.stepReading() }
        }
    }

    private func throwAndReplaceDoc() {
        guard case .toolRead = ctrl.state else { return }
        // 팔을 위로 들며 서류 던지기 + 문서 동시에 fade-out
        withAnimation(.easeOut(duration: 0.18)) {
            leftArmDY  = -p * 0.30
            rightArmDY = -p * 0.30
            leftArmDX  =  p * 1.80
            rightArmDX = -p * 1.80
        }
        throwingDoc = true   // offset만 easeOut으로 날아감
        docVisible  = false  // 동시에 fade-out
        // 날아간 후: offset 즉시 스냅 (throwing=false, animation=nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard case .toolRead = self.ctrl.state else { return }
            self.throwingDoc = false  // 즉시 원위치로 스냅 (애니메이션 없음)
        }
        // 짧은 갭 후 새 문서 fade-in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) {
            guard case .toolRead = self.ctrl.state else { return }
            self.docVisible = true
            withAnimation(.easeOut(duration: 0.28)) {
                self.leftArmDY  =  self.p * 0.25
                self.rightArmDY =  self.p * 0.25
                self.leftArmDX  =  self.p * 1.55
                self.rightArmDX = -self.p * 1.55
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { self.stepReading() }
        }
    }

    private func stopReading() {
        withAnimation(.easeOut(duration: 0.22)) {
            showReading = false
            throwingDoc = false
            docVisible  = true
            if !showKnitting { rightArmDY = 0; rightArmDX = 0; leftArmDX = 0 }
        }
        if !showKnitting {
            if case .permission = ctrl.state { } else {
                withAnimation(.easeOut(duration: 0.22)) { leftArmDY = 0 }
            }
        }
        readingStep  = 0
    }

    // MARK: - 아이들 (높이 점프 — 4~9s)

    private func scheduleIdleAnimation() {
        let delay = Double.random(in: 4.0...9.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard case .ready = ctrl.state else { return }
            let r = Double.random(in: 0...1)
            if r < 0.60 {
                doHighHop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { scheduleIdleAnimation() }
            } else {
                doEarWiggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { scheduleIdleAnimation() }
            }
        }
    }

    private func doHighHop() {
        guard case .ready = ctrl.state else { return }
        withAnimation(.easeOut(duration: 0.14)) { bodyDY = -p * 4.0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard case .ready = ctrl.state else { return }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.45)) { bodyDY = 0 }
        }
    }

    private func doEarWiggle() {
        guard case .ready = ctrl.state else { return }
        withAnimation(.easeInOut(duration: 0.09)) { earFoldScale = 0.60 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.35)) { earFoldScale = 1.1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.45)) { earFoldScale = 1.0 }
        }
    }

    // MARK: - 슬라이드 (통통 튀는)

    private func startSlideHop() { hopPhase = false; stepSlideHop() }

    private func stepSlideHop() {
        guard ctrl.isSliding else { stopSlideHop(); return }
        hopPhase.toggle()
        withAnimation(hopPhase ? .easeOut(duration: 0.10) : .spring(response: 0.20, dampingFraction: 0.45)) {
            bodyDY = hopPhase ? -p * 2.8 : 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.21) { stepSlideHop() }
    }

    private func stopSlideHop() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { bodyDY = 0 }
    }

    // MARK: - 눈 깜빡임

    private func scheduleBlink() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 2.2...5.5)) {
            blinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                blinking = false
                scheduleBlink()
            }
        }
    }
}

