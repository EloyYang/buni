import SwiftUI

/// 부드러운 곡선 위주의 "말랑토끼" — 각진 픽셀아트 대신 둥근 블롭 실루엣과
/// 점 눈 + 작은 w자 입으로 그린 미니멀 스타일 캐릭터.
/// 상태 머신(생각중/툴사용/권한요청/완료 등) 로직은 RabbitCharacterView와 동일하게
/// 맞춰 다른 캐릭터와 동작 차이 없이 스킨만 다르게 보이도록 했다.
struct SoftRabbitCharacterView: View {
    @EnvironmentObject var ctrl: CompanionController
    @Environment(\.colorScheme) private var colorScheme

    private let p: CGFloat = 6.5

    private let bodyColor = Color(red: 0.83, green: 0.92, blue: 0.98)
    private let earAccent = Color(red: 0.68, green: 0.84, blue: 0.95)
    private let noseCol   = Color(red: 0.96, green: 0.74, blue: 0.80)
    private let mouthCol  = Color.black.opacity(0.55)
    private let carrotCol = Color(red: 0.96, green: 0.55, blue: 0.18)
    private let leafCol   = Color(red: 0.28, green: 0.70, blue: 0.28)

    @State private var bodyDY:        CGFloat = 0
    @State private var bodyDX:        CGFloat = 0
    @State private var leftArmDY:     CGFloat = 0
    @State private var rightArmDY:    CGFloat = 0
    @State private var leftArmDX:     CGFloat = 0   // 뜨개질 시 팔을 안쪽으로
    @State private var rightArmDX:    CGFloat = 0
    @State private var earFoldScale:  CGFloat = 1.0
    @State private var hopPhase:      Bool    = false
    @State private var showCarrot:    Bool    = false
    @State private var showKnitting:  Bool    = false
    @State private var knittingPhase: Bool    = false
    @State private var blinking:      Bool    = false
    @State private var wideEyes:      Bool    = false
    @State private var eyeLookUp:     Bool    = false
    @State private var showReading:   Bool    = false
    @State private var readingPhase:  Bool    = false
    @State private var throwingDoc:   Bool    = false
    @State private var docVisible:    Bool    = true
    @State private var readingStep:   Int     = 0

    var body: some View {
        ZStack {
            // ── 귀 (동글동글, 머리 뒤)
            ear.offset(x: -p * 1.6, y: -p * 3.5 + bodyDY)
            ear.offset(x:  p * 1.6, y: -p * 3.5 + bodyDY)

            // ── 몸통 (둥근 블롭)
            blob(w: 4.5, h: 2.5, c: bodyColor).offset(y: p * 1.5 + bodyDY)

            // ── 왼팔 (뜨개질 시: 외곽선 표시 + 안쪽으로 이동)
            armView(outlined: showKnitting)
                .offset(x: -p * 2.65 + leftArmDX, y: p * 1.1 + leftArmDY + bodyDY)
                .animation(.easeInOut(duration: 0.32), value: leftArmDX)
                .animation(.easeInOut(duration: 0.28), value: leftArmDY)

            // ── 권한 요청 당근
            if showCarrot {
                carrotView
                    .offset(x: -p * 4.0, y: p * 0.1 + leftArmDY + bodyDY)
                    .animation(.easeOut(duration: 0.28), value: leftArmDY)
                    .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
            }

            // ── 오른팔 (뜨개질 시: 외곽선 표시 + 안쪽으로 이동)
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
            capsule(w: 1.5, h: 0.9, c: bodyColor).offset(x: -p * 1.2, y: p * 2.9 + bodyDY)
            capsule(w: 1.5, h: 0.9, c: bodyColor).offset(x:  p * 1.2, y: p * 2.9 + bodyDY)

            // ── 문서 읽기 (툴사용)
            if showReading {
                DocumentView(p: p, bodyDY: bodyDY, throwing: throwingDoc, docVisible: docVisible)
                    .transition(.opacity)
            }

            // ── 머리 (둥근 블롭, 귀 앞)
            blob(w: 5.5, h: 2.9, c: bodyColor).offset(y: -p * 0.7 + bodyDY)

            // ── 눈 (동그란 점)
            let eyeY = (eyeLookUp ? -p * 1.35 : -p * 0.9) + bodyDY
            eyeDot(x: -p * 1.4, y: eyeY)
            eyeDot(x:  p * 1.4, y: eyeY)

            // ── 코
            Circle()
                .fill(noseCol)
                .frame(width: p * 0.5, height: p * 0.5)
                .offset(y: -p * 0.15 + bodyDY)

            // ── 입 (부드러운 w자 미소)
            WMouthShape()
                .stroke(mouthCol, style: StrokeStyle(lineWidth: p * 0.11, lineCap: .round, lineJoin: .round))
                .frame(width: p * 1.1, height: p * 0.35)
                .offset(y: p * 0.32 + bodyDY)
        }
        .offset(x: bodyDX)
        .animation(.easeInOut(duration: 0.20), value: bodyDX)
        .compositingGroup()
        .shadow(color: colorScheme == .light ? Color.black.opacity(0.25) : .clear,
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

    // MARK: – 귀

    private var ear: some View {
        ZStack {
            Capsule().fill(bodyColor).frame(width: p * 1.6, height: p * 3.4)
            Capsule().fill(earAccent).frame(width: p * 0.8, height: p * 2.5).offset(y: p * 0.1)
        }
        .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
        .animation(.spring(response: 0.28, dampingFraction: 0.45), value: earFoldScale)
    }

    // MARK: – 팔 뷰 (뜨개질 중 외곽선으로 몸통과 구분)

    @ViewBuilder
    private func armView(outlined: Bool) -> some View {
        ZStack {
            if outlined {
                capsule(w: 1.9, h: 1.2, c: Color.black.opacity(0.18))
            }
            capsule(w: 1.5, h: 0.9, c: bodyColor)
        }
    }

    // MARK: – 권한 요청 당근 뷰

    private var carrotView: some View {
        ZStack {
            Capsule().fill(leafCol).frame(width: p * 1.5, height: p * 0.6).offset(y: -p * 1.25)
            Capsule().fill(leafCol).frame(width: p * 0.7, height: p * 0.55).offset(y: -p * 1.75)
            RoundedRectangle(cornerRadius: p * 0.35, style: .continuous)
                .fill(carrotCol)
                .frame(width: p * 0.7, height: p * 2.1)
        }
    }

    // MARK: – 도형 헬퍼 (둥근 블롭 / 캡슐 / 점 눈)

    private func blob(w: CGFloat, h: CGFloat, c: Color) -> some View {
        RoundedRectangle(cornerRadius: p * h / 2, style: .continuous)
            .fill(c)
            .frame(width: p * w, height: p * h)
    }

    private func capsule(w: CGFloat, h: CGFloat, c: Color) -> some View {
        Capsule().fill(c).frame(width: p * w, height: p * h)
    }

    @ViewBuilder
    private func eyeDot(x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(Color.black)
            .frame(width:  p * 0.62,
                   height: blinking ? p * 0.10
                         : wideEyes ? p * 1.05
                         : p * 0.62)
            .offset(x: x, y: y)
            .animation(.easeInOut(duration: 0.08), value: blinking)
            .animation(.easeInOut(duration: 0.12), value: wideEyes)
            .animation(.easeInOut(duration: 0.25), value: eyeLookUp)
    }

    // MARK: – 상태별 애니메이션 (RabbitCharacterView와 동일한 상태 머신)

    private func applyAnimation(_ state: CompanionState) {
        withAnimation(.easeOut(duration: 0.25)) {
            wideEyes  = false
            eyeLookUp = false
        }

        // 권한 상태가 아니면 팔·당근 내리기
        if case .permission = state { } else {
            withAnimation(.easeOut(duration: 0.25)) {
                showCarrot = false
            }
        }

        // 타이핑/읽기 중지
        switch state {
        case .thinking, .toolUse, .backgroundWork: break
        default: stopKnitting()
        }
        switch state {
        case .toolRead: break
        default: stopReading()
        }

        if !ctrl.isSliding {
            withAnimation(.easeOut(duration: 0.2)) {
                bodyDY       = 0
                bodyDX       = 0
                earFoldScale = 1.0
            }
        }

        switch state {

        case .thinking, .toolUse, .backgroundWork:
            startKnitting()
        case .toolRead:
            startReading()

        case .notification:
            withAnimation(.easeOut(duration: 0.12)) { bodyDY = -p * 2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { bodyDY = 0 }
            }

        case .permission:
            withAnimation(.easeInOut(duration: 0.18)) { wideEyes = true }
            withAnimation(.easeOut(duration: 0.28)) { leftArmDY = -p * 2.8 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                    showCarrot = true
                }
            }

        case .completed:
            // 완료: 권한 요청과 동일한 모션 (눈 크게 + 팔 올리기 + 작은 점프)
            withAnimation(.easeInOut(duration: 0.18)) { wideEyes = true }
            withAnimation(.easeOut(duration: 0.28)) { leftArmDY = -p * 2.8 }
            withAnimation(.easeOut(duration: 0.12)) { bodyDY = -p * 2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { bodyDY = 0 }
            }
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

    // MARK: – 뜨개질 애니메이션

    private func startKnitting() {
        guard !showKnitting else { return }
        withAnimation(.easeOut(duration: 0.32)) {
            leftArmDX    =  p * 1.55
            rightArmDX   = -p * 1.55
            leftArmDY    =  p * 1.00
            rightArmDY   =  p * 1.00
            showKnitting = true
        }
        knittingPhase = false
        stepKnitting()
    }

    private func stepKnitting() {
        switch ctrl.state { case .thinking, .toolUse, .backgroundWork: break; default: return }
        knittingPhase.toggle()
        let base:  CGFloat = p * 1.00
        let swing: CGFloat = p * 0.60
        withAnimation(.easeInOut(duration: 0.32)) {
            leftArmDY  = knittingPhase ? base - swing : base + swing
            rightArmDY = knittingPhase ? base + swing : base - swing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { stepKnitting() }
    }

    private func stopKnitting() {
        withAnimation(.easeOut(duration: 0.25)) {
            showKnitting = false
            if !showReading { rightArmDY = 0; rightArmDX = 0; leftArmDX = 0 }
        }
        // permission 상태가 아닐 때만 왼팔도 내리기
        if !showReading {
            if case .permission = ctrl.state { } else {
                withAnimation(.easeOut(duration: 0.25)) { leftArmDY = 0 }
            }
        }
    }

    // MARK: – 문서 읽기

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
            withAnimation(.easeInOut(duration: 1.2)) {
                leftArmDY  = readingPhase ? p * 0.18 : p * 0.30
                rightArmDY = readingPhase ? p * 0.30 : p * 0.18
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { self.stepReading() }
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
        withAnimation(.easeOut(duration: 0.25)) {
            showReading = false
            throwingDoc = false
            docVisible  = true
            if !showKnitting { rightArmDY = 0; rightArmDX = 0; leftArmDX = 0 }
        }
        if !showKnitting {
            if case .permission = ctrl.state { } else {
                withAnimation(.easeOut(duration: 0.25)) { leftArmDY = 0 }
            }
        }
        readingStep  = 0
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
        withAnimation(.easeIn(duration: 0.10)) { earFoldScale = 0.52 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            guard case .ready = ctrl.state else {
                withAnimation(.easeOut(duration: 0.2)) { earFoldScale = 1.0 }
                return
            }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.40)) { earFoldScale = 1.0 }
        }
    }

    // MARK: – 슬라이드

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

    // MARK: – 눈 깜빡임

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

/// 작고 부드러운 "w"자 미소 — 두 개의 완만한 물결로 표현.
private struct WMouthShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: w * 0.25, y: 0), control: CGPoint(x: w * 0.125, y: h))
        path.addQuadCurve(to: CGPoint(x: w * 0.5,  y: 0), control: CGPoint(x: w * 0.375, y: -h * 0.4))
        path.addQuadCurve(to: CGPoint(x: w * 0.75, y: 0), control: CGPoint(x: w * 0.625, y: h))
        path.addQuadCurve(to: CGPoint(x: w,        y: 0), control: CGPoint(x: w * 0.875, y: -h * 0.4))
        return path
    }
}
