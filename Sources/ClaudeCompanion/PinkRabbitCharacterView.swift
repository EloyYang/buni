import SwiftUI

/// 푸니 — 핑크 토끼. 사랑스럽고 달콤한 성격.
/// 특징: 크고 반짝이는 눈, 하트 코, 볼 홍조, 하트 들기
struct PinkRabbitCharacterView: View {
    @EnvironmentObject var ctrl: CompanionController
    @Environment(\.colorScheme) private var colorScheme

    private let p: CGFloat = 6.5

    private let bodyColor  = Color(red: 0.98, green: 0.78, blue: 0.88)
    private let earInner   = Color(red: 1.00, green: 0.92, blue: 0.96)
    private let blushColor = Color(red: 0.98, green: 0.62, blue: 0.75).opacity(0.55)
    private let noseColor  = Color(red: 0.95, green: 0.35, blue: 0.60)
    private let heartCol   = Color(red: 0.95, green: 0.28, blue: 0.52)
    private let heartLight = Color(red: 1.00, green: 0.65, blue: 0.80)
    private let sparkleCol = Color(red: 1.00, green: 0.90, blue: 0.95)

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
    @State private var swayPhase:     Bool    = false   // 아이들 스웨이
    @State private var showReading:   Bool    = false
    @State private var readingPhase:  Bool    = false
    @State private var throwingDoc:  Bool    = false
    @State private var docVisible:   Bool    = true
    @State private var readingStep:  Int     = 0

    var body: some View {
        ZStack {
            // ── 귀 (부드럽고 둥근)
            ZStack {
                px(w: 1.65, h: 3.4, c: bodyColor)
                px(w: 0.85, h: 2.7, c: earInner).offset(y: -p * 0.1)
            }
            .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
            .animation(.spring(response: 0.32, dampingFraction: 0.48), value: earFoldScale)
            .offset(x: -p * 1.55, y: -p * 3.5 + bodyDY)

            ZStack {
                px(w: 1.65, h: 3.4, c: bodyColor)
                px(w: 0.85, h: 2.7, c: earInner).offset(y: -p * 0.1)
            }
            .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
            .animation(.spring(response: 0.32, dampingFraction: 0.48), value: earFoldScale)
            .offset(x: p * 1.55, y: -p * 3.5 + bodyDY)

            // ── 몸통
            px(w: 4.6, h: 2.5, c: bodyColor).offset(y: p * 1.5 + bodyDY)

            // ── 왼팔
            armView(outlined: showKnitting)
                .offset(x: -p * 2.65 + leftArmDX, y: p * 1.1 + leftArmDY + bodyDY)
                .animation(.easeInOut(duration: 0.32), value: leftArmDX)
                .animation(.easeInOut(duration: 0.28), value: leftArmDY)

            // ── 하트 (권한/완료 시)
            if showProp {
                heartPropView
                    .offset(x: -p * 4.1, y: p * 0.1 + leftArmDY + bodyDY)
                    .animation(.easeOut(duration: 0.28), value: leftArmDY)
                    .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
            }

            // ── 오른팔
            armView(outlined: showKnitting)
                .offset(x: p * 2.65 + rightArmDX, y: p * 1.1 + rightArmDY + bodyDY)
                .animation(.easeInOut(duration: 0.32), value: rightArmDX)
                .animation(.easeInOut(duration: 0.28), value: rightArmDY)

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

            // ── 머리 (넓고 둥글게)
            px(w: 5.6, h: 2.6, c: bodyColor).offset(y: -p * 0.8 + bodyDY)

            // ── 볼 홍조 (사랑스러운 핵심 포인트)
            Ellipse()
                .fill(blushColor)
                .frame(width: p * 1.6, height: p * 1.0)
                .offset(x: -p * 1.9, y: -p * 0.30 + bodyDY)
            Ellipse()
                .fill(blushColor)
                .frame(width: p * 1.6, height: p * 1.0)
                .offset(x:  p * 1.9, y: -p * 0.30 + bodyDY)

            // ── 눈 (크고 반짝임 — 사랑스러운 핵심)
            let eyeY = (eyeLookUp ? -p * 1.38 : -p * 0.92) + bodyDY
            eyeBlock(x: -p * 1.45, y: eyeY)
            eyeBlock(x:  p * 1.45, y: eyeY)

            // ── 눈 하이라이트 (반짝이는 효과)
            if !blinking {
                // 작은 하이라이트 점
                Rectangle()
                    .fill(sparkleCol)
                    .frame(width: p * 0.22, height: p * 0.22)
                    .offset(x: -p * 1.60, y: eyeY - p * 0.28)
                Rectangle()
                    .fill(sparkleCol)
                    .frame(width: p * 0.22, height: p * 0.22)
                    .offset(x:  p * 1.30, y: eyeY - p * 0.28)
                // wideEyes일 때 추가 하이라이트
                if wideEyes {
                    Rectangle()
                        .fill(sparkleCol.opacity(0.70))
                        .frame(width: p * 0.16, height: p * 0.16)
                        .offset(x: -p * 1.25, y: eyeY + p * 0.18)
                    Rectangle()
                        .fill(sparkleCol.opacity(0.70))
                        .frame(width: p * 0.16, height: p * 0.16)
                        .offset(x:  p * 1.65, y: eyeY + p * 0.18)
                }
            }

            // ── 코 (하트 모양 — 픽셀아트)
            heartNoseView
                .offset(y: -p * 0.22 + bodyDY)
        }
        .offset(x: bodyDX)
        .animation(.easeInOut(duration: 0.22), value: bodyDX)
        .compositingGroup()
        .shadow(color: colorScheme == .light ? Color.black.opacity(0.28) : .clear,
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
            if outlined { px(w: 1.9, h: 1.2, c: Color.black.opacity(0.18)) }
            px(w: 1.5, h: 0.9, c: bodyColor)
        }
    }

    // MARK: - 하트 코 (픽셀아트 미니 하트)

    private var heartNoseView: some View {
        ZStack {
            // 왼쪽 윗 볼록
            px(w: 0.30, h: 0.30, c: noseColor).offset(x: -p * 0.17, y: -p * 0.17)
            // 오른쪽 윗 볼록
            px(w: 0.30, h: 0.30, c: noseColor).offset(x:  p * 0.17, y: -p * 0.17)
            // 중앙 몸통
            px(w: 0.52, h: 0.28, c: noseColor)
            // 아래 중앙
            px(w: 0.30, h: 0.24, c: noseColor).offset(y: p * 0.22)
            // 뾰족 끝
            px(w: 0.16, h: 0.18, c: noseColor).offset(y: p * 0.40)
        }
    }

    // MARK: - 하트 프롭 (권한/완료 시 들기)

    private var heartPropView: some View {
        ZStack {
            // 픽셀아트 하트 — 크게
            // 윗 두 볼록
            px(w: 0.85, h: 0.85, c: heartCol).offset(x: -p * 0.52, y: -p * 0.50)
            px(w: 0.85, h: 0.85, c: heartCol).offset(x:  p * 0.52, y: -p * 0.50)
            // 중간 가득 채움
            px(w: 1.85, h: 0.85, c: heartCol).offset(y: p * 0.02)
            // 아래로 좁아지는 형태
            px(w: 1.40, h: 0.65, c: heartCol).offset(y: p * 0.68)
            px(w: 0.90, h: 0.55, c: heartCol).offset(y: p * 1.22)
            px(w: 0.45, h: 0.40, c: heartCol).offset(y: p * 1.68)
            // 하이라이트
            px(w: 0.30, h: 0.55, c: heartLight.opacity(0.55)).offset(x: -p * 0.50, y: -p * 0.40)
        }
    }

    // MARK: - 픽셀 / 눈 (크고 동그란)

    private func px(w: CGFloat, h: CGFloat, c: Color) -> some View {
        Rectangle().fill(c).frame(width: p * w, height: p * h)
    }

    @ViewBuilder
    private func eyeBlock(x: CGFloat, y: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black)
            .frame(width:  p * 0.75,
                   height: blinking ? p * 0.10
                         : wideEyes ? p * 1.20
                         : p * 0.90)   // 기본 눈도 크게
            .offset(x: x, y: y)
            .animation(.easeInOut(duration: 0.09), value: blinking)
            .animation(.easeInOut(duration: 0.14), value: wideEyes)
            .animation(.easeInOut(duration: 0.26), value: eyeLookUp)
    }

    // MARK: - 상태 애니메이션

    private func applyAnimation(_ state: CompanionState) {
        withAnimation(.easeOut(duration: 0.26)) { wideEyes = false; eyeLookUp = false }
        if case .permission = state { } else {
            withAnimation(.easeOut(duration: 0.26)) { showProp = false }
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
            withAnimation(.easeOut(duration: 0.24)) { bodyDY = 0; bodyDX = 0; earFoldScale = 1.0 }
        }

        switch state {
        case .thinking, .toolUse, .backgroundWork:
            startKnitting()
        case .toolRead:
            startReading()

        case .notification:
            withAnimation(.easeOut(duration: 0.13)) { bodyDY = -p * 2.2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.52)) { bodyDY = 0 }
            }

        case .permission:
            // 푸니: 눈 크게 + 왼팔 + 오른팔 살짝 들기
            withAnimation(.easeInOut(duration: 0.16)) { wideEyes = true }
            withAnimation(.easeOut(duration: 0.28)) { leftArmDY = -p * 2.8 }
            withAnimation(.easeOut(duration: 0.22)) { rightArmDY = -p * 1.8 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) { showProp = true }
            }

        case .completed:
            // 푸니: 눈 크게 + 양팔 + 두 번 통통 튀기
            withAnimation(.easeInOut(duration: 0.16)) { wideEyes = true }
            withAnimation(.easeOut(duration: 0.28)) { leftArmDY = -p * 2.8 }
            withAnimation(.easeOut(duration: 0.22)) { rightArmDY = -p * 2.8 }
            // 첫 번째 바운스
            withAnimation(.easeOut(duration: 0.13)) { bodyDY = -p * 2.2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.52)) { bodyDY = 0 }
            }
            // 두 번째 바운스
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                withAnimation(.easeOut(duration: 0.12)) { bodyDY = -p * 1.8 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.55)) { bodyDY = 0 }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.62)) { showProp = true }
            }

        case .ready:
            scheduleIdleAnimation()
        case .idle:
            break
        }
    }

    // MARK: - 뜨개질 (중간 속도 — 0.34s)

    private func startKnitting() {
        guard !showKnitting else { return }
        withAnimation(.easeOut(duration: 0.30)) {
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
        withAnimation(.easeInOut(duration: 0.34)) {
            leftArmDY  = knittingPhase ? base - swing : base + swing
            rightArmDY = knittingPhase ? base + swing : base - swing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { stepKnitting() }
    }

    private func stopKnitting() {
        withAnimation(.easeOut(duration: 0.26)) {
            showKnitting = false
            if !showReading { rightArmDY = 0; rightArmDX = 0; leftArmDX = 0 }
        }
        // permission 상태가 아닐 때만 왼팔도 내리기
        if !showReading {
            if case .permission = ctrl.state { } else {
                withAnimation(.easeOut(duration: 0.26)) { leftArmDY = 0 }
            }
        }
    }

    // MARK: - 문서 읽기 (부드럽게 — 1.5s)

    private func startReading() {
        guard !showReading else { return }
        withAnimation(.easeOut(duration: 0.38)) {
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
        withAnimation(.easeOut(duration: 0.26)) {
            showReading = false
            throwingDoc = false
            docVisible  = true
            if !showKnitting { rightArmDY = 0; rightArmDX = 0; leftArmDX = 0 }
        }
        if !showKnitting {
            if case .permission = ctrl.state { } else {
                withAnimation(.easeOut(duration: 0.26)) { leftArmDY = 0 }
            }
        }
        readingStep  = 0
    }

    // MARK: - 아이들 (스웨이 + 점프 — 5~11s)

    private func scheduleIdleAnimation() {
        let delay = Double.random(in: 5.0...11.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard case .ready = ctrl.state else { return }
            let r = Double.random(in: 0...1)
            if r < 0.35 {
                doIdleHop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { scheduleIdleAnimation() }
            } else if r < 0.70 {
                doGentleSway()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { scheduleIdleAnimation() }
            } else {
                doHeartEarPerk()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { scheduleIdleAnimation() }
            }
        }
    }

    private func doIdleHop() {
        guard case .ready = ctrl.state else { return }
        withAnimation(.easeOut(duration: 0.15)) { bodyDY = -p * 2.6 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            guard case .ready = ctrl.state else { return }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.52)) { bodyDY = 0 }
        }
    }

    // 살랑살랑 좌우로 흔들기 (사랑스러운 특징)
    private func doGentleSway() {
        guard case .ready = ctrl.state else { return }
        withAnimation(.easeInOut(duration: 0.22)) { bodyDX = -p * 1.2 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard case .ready = ctrl.state else {
                withAnimation(.easeOut(duration: 0.20)) { bodyDX = 0 }; return
            }
            withAnimation(.easeInOut(duration: 0.22)) { bodyDX = p * 1.2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                guard case .ready = ctrl.state else {
                    withAnimation(.easeOut(duration: 0.20)) { bodyDX = 0 }; return
                }
                withAnimation(.spring(response: 0.30, dampingFraction: 0.55)) { bodyDX = 0 }
            }
        }
    }

    // 귀 살짝 접었다 활짝 — 수줍음 표현
    private func doHeartEarPerk() {
        guard case .ready = ctrl.state else { return }
        withAnimation(.easeIn(duration: 0.12)) { earFoldScale = 0.45 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            guard case .ready = ctrl.state else {
                withAnimation(.easeOut(duration: 0.22)) { earFoldScale = 1.0 }; return
            }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.36)) { earFoldScale = 1.0 }
        }
    }

    // MARK: - 슬라이드

    private func startSlideHop() { hopPhase = false; stepSlideHop() }

    private func stepSlideHop() {
        guard ctrl.isSliding else { stopSlideHop(); return }
        hopPhase.toggle()
        withAnimation(hopPhase ? .easeOut(duration: 0.11) : .spring(response: 0.20, dampingFraction: 0.50)) {
            bodyDY = hopPhase ? -p * 2.2 : 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { stepSlideHop() }
    }

    private func stopSlideHop() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.60)) { bodyDY = 0 }
    }

    // MARK: - 눈 깜빡임 (보통 속도)

    private func scheduleBlink() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 2.8...6.0)) {
            blinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                blinking = false
                scheduleBlink()
            }
        }
    }
}

