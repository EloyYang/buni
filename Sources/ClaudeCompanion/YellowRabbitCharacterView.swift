import SwiftUI

/// 누니 — 노란 토끼. 밝고 여유롭고 낙천적.
/// 특징: 느린 뜨개질, 드문 idle 애니메이션, 별 들기
struct YellowRabbitCharacterView: View {
    @EnvironmentObject var ctrl: CompanionController
    @Environment(\.colorScheme) private var colorScheme

    private let p: CGFloat = 6.5

    private let bodyColor  = Color(red: 0.96, green: 0.86, blue: 0.22)
    private let earInner   = Color(red: 1.00, green: 0.96, blue: 0.72)
    private let noseColor  = Color(red: 1.00, green: 0.95, blue: 0.75)
    private let starCol    = Color(red: 1.00, green: 0.88, blue: 0.10)
    private let blushColor = Color(red: 1.00, green: 0.68, blue: 0.45).opacity(0.42)

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
            // ── 귀 (길고 여유로운)
            ZStack {
                px(w: 1.6, h: 3.8, c: bodyColor)
                px(w: 0.8, h: 3.1, c: earInner).offset(y: -p * 0.1)
            }
            .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
            .animation(.spring(response: 0.35, dampingFraction: 0.50), value: earFoldScale)
            .offset(x: -p * 1.5, y: -p * 3.8 + bodyDY)

            ZStack {
                px(w: 1.6, h: 3.8, c: bodyColor)
                px(w: 0.8, h: 3.1, c: earInner).offset(y: -p * 0.1)
            }
            .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
            .animation(.spring(response: 0.35, dampingFraction: 0.50), value: earFoldScale)
            .offset(x: p * 1.5, y: -p * 3.8 + bodyDY)

            // ── 몸통
            px(w: 4.5, h: 2.5, c: bodyColor).offset(y: p * 1.5 + bodyDY)

            // ── 왼팔
            armView(outlined: showKnitting)
                .offset(x: -p * 2.65 + leftArmDX, y: p * 1.1 + leftArmDY + bodyDY)
                .animation(.easeInOut(duration: 0.38), value: leftArmDX)
                .animation(.easeInOut(duration: 0.35), value: leftArmDY)

            // ── 별 (권한/완료 시)
            if showProp {
                starView
                    .offset(x: -p * 3.8, y: p * 0.0 + leftArmDY + bodyDY)
                    .animation(.easeOut(duration: 0.35), value: leftArmDY)
                    .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
            }

            // ── 오른팔
            armView(outlined: showKnitting)
                .offset(x: p * 2.65 + rightArmDX, y: p * 1.1 + rightArmDY + bodyDY)
                .animation(.easeInOut(duration: 0.38), value: rightArmDX)
                .animation(.easeInOut(duration: 0.35), value: rightArmDY)

            // ── 맥북 타이핑 (생각중 — 팔 위에 그려서 팔이 맥북에 가려짐)
            if showKnitting {
                LaptopView(p: p, bodyDY: bodyDY)
                    .transition(.opacity)
            }

            // ── 발
            px(w: 1.5, h: 0.9, c: bodyColor).offset(x: -p * 1.2, y: p * 2.9 + bodyDY)
            px(w: 1.5, h: 0.9, c: bodyColor).offset(x:  p * 1.2, y: p * 2.9 + bodyDY)
            // ── 문서 읽기 (툴사용)
            if showReading {
                DocumentView(p: p, bodyDY: bodyDY, throwing: throwingDoc, docVisible: docVisible)
                    .transition(.opacity)
            }

            // ── 머리
            px(w: 5.5, h: 2.5, c: bodyColor).offset(y: -p * 0.8 + bodyDY)

            // ── 볼 홍조 (따뜻하고 낙천적인 특징)
            Ellipse()
                .fill(blushColor)
                .frame(width: p * 0.68, height: p * 0.28)
                .offset(x: -p * 1.55, y: -p * 0.42 + bodyDY)
            Ellipse()
                .fill(blushColor)
                .frame(width: p * 0.68, height: p * 0.28)
                .offset(x:  p * 1.55, y: -p * 0.42 + bodyDY)

            // ── 눈 (크고 밝음)
            let eyeY = (eyeLookUp ? -p * 1.35 : -p * 0.90) + bodyDY
            eyeBlock(x: -p * 1.4, y: eyeY)
            eyeBlock(x:  p * 1.4, y: eyeY)

            // ── 눈 하이라이트 (반짝이는 효과)
            if !blinking {
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: p * 0.22, height: p * 0.22)
                    .offset(x: -p * 1.54, y: eyeY - p * 0.22)
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: p * 0.22, height: p * 0.22)
                    .offset(x:  p * 1.26, y: eyeY - p * 0.22)
            }

            // ── 코
            Rectangle()
                .fill(noseColor)
                .frame(width: p * 0.58, height: p * 0.40)
                .offset(y: -p * 0.24 + bodyDY)
        }
        .offset(x: bodyDX)
        .animation(.easeInOut(duration: 0.25), value: bodyDX)
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

    // MARK: - 별 (픽셀아트 — 십자 + 대각 사각형)

    private var starView: some View {
        ZStack {
            // 중앙
            px(w: 0.85, h: 0.85, c: starCol)
            // 상하좌우 돌출
            px(w: 0.50, h: 0.90, c: starCol).offset(y: -p * 0.65)
            px(w: 0.50, h: 0.90, c: starCol).offset(y:  p * 0.65)
            px(w: 0.90, h: 0.50, c: starCol).offset(x: -p * 0.65)
            px(w: 0.90, h: 0.50, c: starCol).offset(x:  p * 0.65)
            // 대각 꼭짓점 (45도 회전 사각형)
            px(w: 0.48, h: 0.48, c: starCol).rotationEffect(.degrees(45)).offset(x: -p * 0.52, y: -p * 0.52)
            px(w: 0.48, h: 0.48, c: starCol).rotationEffect(.degrees(45)).offset(x:  p * 0.52, y: -p * 0.52)
            px(w: 0.48, h: 0.48, c: starCol).rotationEffect(.degrees(45)).offset(x: -p * 0.52, y:  p * 0.52)
            px(w: 0.48, h: 0.48, c: starCol).rotationEffect(.degrees(45)).offset(x:  p * 0.52, y:  p * 0.52)
            // 하이라이트
            px(w: 0.28, h: 0.28, c: Color.white.opacity(0.50)).offset(x: -p * 0.20, y: -p * 0.20)
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
                   height: blinking ? p * 0.11
                         : wideEyes ? p * 1.15
                         : p * 0.82)
            .offset(x: x, y: y)
            .animation(.easeInOut(duration: 0.09), value: blinking)
            .animation(.easeInOut(duration: 0.14), value: wideEyes)
            .animation(.easeInOut(duration: 0.28), value: eyeLookUp)
    }

    // MARK: - 상태 애니메이션

    private func applyAnimation(_ state: CompanionState) {
        withAnimation(.easeOut(duration: 0.30)) { wideEyes = false; eyeLookUp = false }
        if case .permission = state { } else {
            withAnimation(.easeOut(duration: 0.30)) { showProp = false }
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
            withAnimation(.easeOut(duration: 0.28)) { bodyDY = 0; bodyDX = 0; earFoldScale = 1.0 }
        }

        switch state {
        case .thinking, .toolUse, .backgroundWork:
            startKnitting()
        case .toolRead:
            startReading()

        case .notification:
            withAnimation(.easeOut(duration: 0.15)) { bodyDY = -p * 2.2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.58)) { bodyDY = 0 }
            }

        case .permission:
            // 누니: 천천히 놀라며 느긋하게 팔 올리기
            withAnimation(.easeInOut(duration: 0.35)) { wideEyes = true }
            withAnimation(.easeOut(duration: 0.55)) { leftArmDY = -p * 2.8 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.70)) { showProp = true }
            }

        case .completed:
            // 누니: 여유롭게 놀라며 작고 느린 점프 + 별
            withAnimation(.easeInOut(duration: 0.35)) { wideEyes = true }
            withAnimation(.easeOut(duration: 0.55)) { leftArmDY = -p * 2.8 }
            withAnimation(.easeOut(duration: 0.28)) { bodyDY = -p * 1.8 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                withAnimation(.spring(response: 0.40, dampingFraction: 0.65)) { bodyDY = 0 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.70)) { showProp = true }
            }

        case .ready:
            scheduleIdleAnimation()
        case .idle:
            break
        }
    }

    // MARK: - 뜨개질 (느림 — 0.46s)

    private func startKnitting() {
        guard !showKnitting else { return }
        withAnimation(.easeOut(duration: 0.40)) {
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
        withAnimation(.easeInOut(duration: 0.46)) {
            leftArmDY  = knittingPhase ? base - swing : base + swing
            rightArmDY = knittingPhase ? base + swing : base - swing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) { stepKnitting() }
    }

    private func stopKnitting() {
        withAnimation(.easeOut(duration: 0.32)) {
            showKnitting = false
            if !showReading { rightArmDY = 0; rightArmDX = 0; leftArmDX = 0 }
        }
        // permission 상태가 아닐 때만 왼팔도 내리기
        if !showReading {
            if case .permission = ctrl.state { } else {
                withAnimation(.easeOut(duration: 0.32)) { leftArmDY = 0 }
            }
        }
    }

    // MARK: - 문서 읽기 (여유롭게 — 1.5s)

    private func startReading() {
        guard !showReading else { return }
        withAnimation(.easeOut(duration: 0.40)) {
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
            withAnimation(.easeInOut(duration: 1.5)) {
                leftArmDY  = readingPhase ? p * 0.18 : p * 0.30
                rightArmDY = readingPhase ? p * 0.30 : p * 0.18
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.stepReading() }
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
        withAnimation(.easeOut(duration: 0.32)) {
            showReading = false
            throwingDoc = false
            docVisible  = true
            if !showKnitting { rightArmDY = 0; rightArmDX = 0; leftArmDX = 0 }
        }
        if !showKnitting {
            if case .permission = ctrl.state { } else {
                withAnimation(.easeOut(duration: 0.32)) { leftArmDY = 0 }
            }
        }
        readingStep  = 0
    }

    // MARK: - 아이들 (여유로운 — 10~18s)

    private func scheduleIdleAnimation() {
        let delay = Double.random(in: 10.0...18.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard case .ready = ctrl.state else { return }
            let r = Double.random(in: 0...1)
            if r < 0.45 {
                doIdleHop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { scheduleIdleAnimation() }
            } else {
                doEarPerk()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { scheduleIdleAnimation() }
            }
        }
    }

    private func doIdleHop() {
        guard case .ready = ctrl.state else { return }
        withAnimation(.easeOut(duration: 0.18)) { bodyDY = -p * 2.5 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            guard case .ready = ctrl.state else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.58)) { bodyDY = 0 }
        }
    }

    private func doEarPerk() {
        guard case .ready = ctrl.state else { return }
        withAnimation(.easeIn(duration: 0.14)) { earFoldScale = 0.55 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            guard case .ready = ctrl.state else {
                withAnimation(.easeOut(duration: 0.28)) { earFoldScale = 1.0 }; return
            }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.48)) { earFoldScale = 1.0 }
        }
    }

    // MARK: - 슬라이드 (부드럽게)

    private func startSlideHop() { hopPhase = false; stepSlideHop() }

    private func stepSlideHop() {
        guard ctrl.isSliding else { stopSlideHop(); return }
        hopPhase.toggle()
        withAnimation(hopPhase ? .easeOut(duration: 0.13) : .spring(response: 0.22, dampingFraction: 0.55)) {
            bodyDY = hopPhase ? -p * 2.0 : 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { stepSlideHop() }
    }

    private func stopSlideHop() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.65)) { bodyDY = 0 }
    }

    // MARK: - 눈 깜빡임 (느림)

    private func scheduleBlink() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 3.5...7.5)) {
            blinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                blinking = false
                scheduleBlink()
            }
        }
    }
}

