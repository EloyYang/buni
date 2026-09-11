import SwiftUI

/// 우니 — 연두 토끼. 차분하고 침착하며 느긋함.
/// 특징: 아주 느린 동작, 드문 idle 애니메이션, 잎 들기
struct GreenRabbitCharacterView: View {
    @EnvironmentObject var ctrl: CompanionController
    @Environment(\.colorScheme) private var colorScheme

    private let p: CGFloat = 6.5

    private let bodyColor = Color(red: 0.45, green: 0.80, blue: 0.38)
    private let earInner  = Color(red: 0.78, green: 0.95, blue: 0.68)
    private let noseColor = Color(red: 0.82, green: 0.95, blue: 0.78)
    private let leafCol   = Color(red: 0.28, green: 0.68, blue: 0.22)
    private let leafLight = Color(red: 0.62, green: 0.88, blue: 0.50)

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
            // ── 귀 (넓고 둥근 — 침착한 인상)
            ZStack {
                px(w: 1.8, h: 3.2, c: bodyColor)
                px(w: 1.0, h: 2.5, c: earInner).offset(y: -p * 0.1)
            }
            .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
            .animation(.spring(response: 0.45, dampingFraction: 0.60), value: earFoldScale)
            .offset(x: -p * 1.5, y: -p * 3.3 + bodyDY)

            ZStack {
                px(w: 1.8, h: 3.2, c: bodyColor)
                px(w: 1.0, h: 2.5, c: earInner).offset(y: -p * 0.1)
            }
            .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
            .animation(.spring(response: 0.45, dampingFraction: 0.60), value: earFoldScale)
            .offset(x: p * 1.5, y: -p * 3.3 + bodyDY)

            // ── 몸통
            px(w: 4.6, h: 2.6, c: bodyColor).offset(y: p * 1.5 + bodyDY)

            // ── 왼팔
            armView(outlined: showKnitting)
                .offset(x: -p * 2.68 + leftArmDX, y: p * 1.1 + leftArmDY + bodyDY)
                .animation(.easeInOut(duration: 0.45), value: leftArmDX)
                .animation(.easeInOut(duration: 0.42), value: leftArmDY)

            // ── 잎 (권한/완료 시)
            if showProp {
                leafView
                    .offset(x: -p * 4.0, y: p * 0.0 + leftArmDY + bodyDY)
                    .animation(.easeOut(duration: 0.42), value: leftArmDY)
                    .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
            }

            // ── 오른팔
            armView(outlined: showKnitting)
                .offset(x: p * 2.68 + rightArmDX, y: p * 1.1 + rightArmDY + bodyDY)
                .animation(.easeInOut(duration: 0.45), value: rightArmDX)
                .animation(.easeInOut(duration: 0.42), value: rightArmDY)

            // ── 맥북 타이핑 (생각중 — 팔 위에 그려서 팔이 맥북에 가려짐)
            if showKnitting {
                LaptopView(p: p, bodyDY: bodyDY)
                    .transition(.opacity)
            }

            // ── 발
            px(w: 1.6, h: 1.0, c: bodyColor).offset(x: -p * 1.2, y: p * 2.9 + bodyDY)
            px(w: 1.6, h: 1.0, c: bodyColor).offset(x:  p * 1.2, y: p * 2.9 + bodyDY)
            // ── 문서 읽기 (툴사용)
            if showReading {
                DocumentView(p: p, bodyDY: bodyDY, throwing: throwingDoc, docVisible: docVisible)
                    .transition(.opacity)
            }

            // ── 머리
            px(w: 5.6, h: 2.6, c: bodyColor).offset(y: -p * 0.8 + bodyDY)

            // ── 눈 (반쯤 감긴 여유로운 눈)
            let eyeY = (eyeLookUp ? -p * 1.35 : -p * 0.90) + bodyDY
            eyeBlock(x: -p * 1.42, y: eyeY)
            eyeBlock(x:  p * 1.42, y: eyeY)

            // ── 코
            Rectangle()
                .fill(noseColor)
                .frame(width: p * 0.60, height: p * 0.40)
                .offset(y: -p * 0.24 + bodyDY)
        }
        .offset(x: bodyDX)
        .animation(.easeInOut(duration: 0.30), value: bodyDX)
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

    // MARK: - 잎 (클로버 느낌)

    private var leafView: some View {
        ZStack {
            // 줄기
            px(w: 0.22, h: 1.10, c: leafCol).offset(y: p * 0.5)
            // 왼쪽 잎
            px(w: 0.90, h: 1.30, c: leafCol)
                .rotationEffect(.degrees(-28))
                .offset(x: -p * 0.55, y: -p * 0.30)
            // 오른쪽 잎
            px(w: 0.90, h: 1.30, c: leafCol)
                .rotationEffect(.degrees(28))
                .offset(x:  p * 0.55, y: -p * 0.30)
            // 잎맥 (왼)
            px(w: 0.14, h: 0.90, c: leafLight.opacity(0.70))
                .rotationEffect(.degrees(-28))
                .offset(x: -p * 0.55, y: -p * 0.30)
            // 잎맥 (오)
            px(w: 0.14, h: 0.90, c: leafLight.opacity(0.70))
                .rotationEffect(.degrees(28))
                .offset(x:  p * 0.55, y: -p * 0.30)
        }
    }

    // MARK: - 픽셀 / 눈 (반쯤 게슴츠레)

    private func px(w: CGFloat, h: CGFloat, c: Color) -> some View {
        Rectangle().fill(c).frame(width: p * w, height: p * h)
    }

    @ViewBuilder
    private func eyeBlock(x: CGFloat, y: CGFloat) -> some View {
        // 기본은 가로로 살짝 납작한 눈 — 여유로운 표정
        Rectangle()
            .fill(Color.black)
            .frame(width:  p * 0.72,
                   height: blinking ? p * 0.10
                         : wideEyes ? p * 1.05
                         : p * 0.60)
            .offset(x: x, y: y)
            .animation(.easeInOut(duration: 0.12), value: blinking)
            .animation(.easeInOut(duration: 0.18), value: wideEyes)
            .animation(.easeInOut(duration: 0.35), value: eyeLookUp)
    }

    // MARK: - 상태 애니메이션

    private func applyAnimation(_ state: CompanionState) {
        withAnimation(.easeOut(duration: 0.35)) { wideEyes = false; eyeLookUp = false }
        if case .permission = state { } else {
            withAnimation(.easeOut(duration: 0.35)) { showProp = false }
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
            withAnimation(.easeOut(duration: 0.32)) { bodyDY = 0; bodyDX = 0; earFoldScale = 1.0 }
        }

        switch state {
        case .thinking, .toolUse, .backgroundWork:
            startKnitting()
        case .toolRead:
            startReading()

        case .notification:
            // 차분하게 가볍게 한 번만
            withAnimation(.easeOut(duration: 0.18)) { bodyDY = -p * 1.8 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                withAnimation(.spring(response: 0.40, dampingFraction: 0.65)) { bodyDY = 0 }
            }

        case .permission:
            // 우니: 아주 천천히 놀라며 한 팔만 느긋하게 올리기
            withAnimation(.easeInOut(duration: 0.40)) { wideEyes = true }
            withAnimation(.easeOut(duration: 0.65)) { leftArmDY = -p * 2.6 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                withAnimation(.spring(response: 0.48, dampingFraction: 0.75)) { showProp = true }
            }

        case .completed:
            // 우니: 양팔 천천히 들고 아래로 가볍게 고개 끄덕
            withAnimation(.easeInOut(duration: 0.40)) { wideEyes = true }
            withAnimation(.easeOut(duration: 0.65)) {
                leftArmDY  = -p * 2.6
                rightArmDY = -p * 2.6
            }
            withAnimation(.easeOut(duration: 0.22)) { bodyDY = p * 0.8 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) { bodyDY = 0 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                withAnimation(.spring(response: 0.48, dampingFraction: 0.75)) { showProp = true }
            }

        case .ready:
            scheduleIdleAnimation()
        case .idle:
            break
        }
    }

    // MARK: - 타이핑 (아주 느림 — 0.58s)

    private func startKnitting() {
        guard !showKnitting else { return }
        withAnimation(.easeOut(duration: 0.48)) {
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
        withAnimation(.easeInOut(duration: 0.58)) {
            leftArmDY  = knittingPhase ? base - swing : base + swing
            rightArmDY = knittingPhase ? base + swing : base - swing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { stepKnitting() }
    }

    private func stopKnitting() {
        withAnimation(.easeOut(duration: 0.38)) {
            showKnitting = false
            if !showReading { rightArmDY = 0; rightArmDX = 0; leftArmDX = 0 }
        }
        // permission 상태가 아닐 때만 왼팔도 내리기
        if !showReading {
            if case .permission = ctrl.state { } else {
                withAnimation(.easeOut(duration: 0.38)) { leftArmDY = 0 }
            }
        }
    }

    // MARK: - 문서 읽기 (아주 천천히 — 2.0s)

    private func startReading() {
        guard !showReading else { return }
        withAnimation(.easeOut(duration: 0.48)) {
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
            withAnimation(.easeInOut(duration: 2.0)) {
                leftArmDY  = readingPhase ? p * 0.18 : p * 0.30
                rightArmDY = readingPhase ? p * 0.30 : p * 0.18
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { self.stepReading() }
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
        withAnimation(.easeOut(duration: 0.38)) {
            showReading = false
            throwingDoc = false
            docVisible  = true
            if !showKnitting { rightArmDY = 0; rightArmDX = 0; leftArmDX = 0 }
        }
        if !showKnitting {
            if case .permission = ctrl.state { } else {
                withAnimation(.easeOut(duration: 0.38)) { leftArmDY = 0 }
            }
        }
        readingStep  = 0
    }

    // MARK: - 아이들 (매우 드물게 — 15~25s)

    private func scheduleIdleAnimation() {
        let delay = Double.random(in: 15.0...25.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard case .ready = ctrl.state else { return }
            let r = Double.random(in: 0...1)
            if r < 0.40 {
                doGentleHop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { scheduleIdleAnimation() }
            } else {
                doSlowEarPerk()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { scheduleIdleAnimation() }
            }
        }
    }

    private func doGentleHop() {
        guard case .ready = ctrl.state else { return }
        withAnimation(.easeOut(duration: 0.22)) { bodyDY = -p * 2.0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard case .ready = ctrl.state else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) { bodyDY = 0 }
        }
    }

    private func doSlowEarPerk() {
        guard case .ready = ctrl.state else { return }
        withAnimation(.easeIn(duration: 0.20)) { earFoldScale = 0.58 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard case .ready = ctrl.state else {
                withAnimation(.easeOut(duration: 0.35)) { earFoldScale = 1.0 }; return
            }
            withAnimation(.spring(response: 0.48, dampingFraction: 0.55)) { earFoldScale = 1.0 }
        }
    }

    // MARK: - 슬라이드 (느긋하게)

    private func startSlideHop() { hopPhase = false; stepSlideHop() }

    private func stepSlideHop() {
        guard ctrl.isSliding else { stopSlideHop(); return }
        hopPhase.toggle()
        withAnimation(hopPhase ? .easeOut(duration: 0.15) : .spring(response: 0.26, dampingFraction: 0.62)) {
            bodyDY = hopPhase ? -p * 1.8 : 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { stepSlideHop() }
    }

    private func stopSlideHop() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.70)) { bodyDY = 0 }
    }

    // MARK: - 눈 깜빡임 (아주 느림)

    private func scheduleBlink() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 4.5...10.0)) {
            blinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                blinking = false
                scheduleBlink()
            }
        }
    }
}
