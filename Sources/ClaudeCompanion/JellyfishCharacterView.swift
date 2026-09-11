import SwiftUI

struct BrownRabbitCharacterView: View {
    @EnvironmentObject var ctrl: CompanionController
    @Environment(\.colorScheme) private var colorScheme

    private let p: CGFloat = 6.5

    private let bodyColor = Color(red: 0.60, green: 0.40, blue: 0.22)
    private let earInner  = Color(red: 0.78, green: 0.54, blue: 0.40)
    private let browColor = Color(red: 0.22, green: 0.12, blue: 0.05)
    private let noseColor = Color(red: 0.85, green: 0.58, blue: 0.50)
    private let carrotCol = Color(red: 0.96, green: 0.55, blue: 0.18)
    private let leafCol   = Color(red: 0.28, green: 0.70, blue: 0.28)

    @State private var bodyDY:        CGFloat = 0
    @State private var bodyDX:        CGFloat = 0
    @State private var leftArmDY:     CGFloat = 0
    @State private var rightArmDY:    CGFloat = 0
    @State private var leftArmDX:     CGFloat = 0
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
    @State private var throwingDoc:  Bool    = false
    @State private var docVisible:   Bool    = true
    @State private var readingStep:  Int     = 0
    @State private var browFurrow:   CGFloat = 0

    var body: some View {
        ZStack {
            // ── 귀 (머리 뒤) — 짧고 두꺼운 수컷 귀
            ZStack {
                px(w: 1.7, h: 3.0, c: bodyColor)
                px(w: 0.9, h: 2.3, c: earInner).offset(y: -p * 0.1)
            }
            .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
            .animation(.spring(response: 0.28, dampingFraction: 0.45), value: earFoldScale)
            .offset(x: -p * 1.5, y: -p * 3.2 + bodyDY)

            ZStack {
                px(w: 1.7, h: 3.0, c: bodyColor)
                px(w: 0.9, h: 2.3, c: earInner).offset(y: -p * 0.1)
            }
            .scaleEffect(x: 1, y: earFoldScale, anchor: .bottom)
            .animation(.spring(response: 0.28, dampingFraction: 0.45), value: earFoldScale)
            .offset(x: p * 1.5, y: -p * 3.2 + bodyDY)

            // ── 몸통 (약간 더 넓음)
            px(w: 4.8, h: 2.6, c: bodyColor).offset(y: p * 1.5 + bodyDY)

            // ── 왼팔
            armView(outlined: showKnitting)
                .offset(x: -p * 2.75 + leftArmDX, y: p * 1.1 + leftArmDY + bodyDY)
                .animation(.easeInOut(duration: 0.32), value: leftArmDX)
                .animation(.easeInOut(duration: 0.28), value: leftArmDY)

            // ── 권한 요청 당근
            if showCarrot {
                carrotView
                    .offset(x: -p * 4.0, y: p * 0.1 + leftArmDY + bodyDY)
                    .animation(.easeOut(duration: 0.28), value: leftArmDY)
                    .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
            }

            // ── 오른팔
            armView(outlined: showKnitting)
                .offset(x: p * 2.75 + rightArmDX, y: p * 1.1 + rightArmDY + bodyDY)
                .animation(.easeInOut(duration: 0.32), value: rightArmDX)
                .animation(.easeInOut(duration: 0.28), value: rightArmDY)

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

            // ── 머리 (더 넓고 각진 느낌)
            px(w: 5.8, h: 2.6, c: bodyColor).offset(y: -p * 0.8 + bodyDY)

            // ── 눈썹 (browFurrow로 표정 변화 — 인상 쓰기/흡족)
            let browY = -p * 1.35 + bodyDY
            Rectangle()
                .fill(browColor)
                .frame(width: p * 0.95, height: p * 0.24)
                .rotationEffect(.degrees(-10 - browFurrow))
                .animation(.easeInOut(duration: 0.22), value: browFurrow)
                .offset(x: -p * 1.45, y: browY)
            Rectangle()
                .fill(browColor)
                .frame(width: p * 0.95, height: p * 0.24)
                .rotationEffect(.degrees(10 + browFurrow))
                .animation(.easeInOut(duration: 0.22), value: browFurrow)
                .offset(x:  p * 1.45, y: browY)

            // ── 눈
            let eyeY = (eyeLookUp ? -p * 1.1 : -p * 0.85) + bodyDY
            eyeBlock(x: -p * 1.45, y: eyeY)
            eyeBlock(x:  p * 1.45, y: eyeY)

            // ── 코 (약간 넓음)
            Rectangle()
                .fill(noseColor)
                .frame(width: p * 0.70, height: p * 0.42)
                .offset(y: -p * 0.22 + bodyDY)

            // ── 수염 자국 (양쪽 볼 점)
            Rectangle()
                .fill(browColor.opacity(0.35))
                .frame(width: p * 0.18, height: p * 0.18)
                .offset(x: -p * 0.85, y: -p * 0.10 + bodyDY)
            Rectangle()
                .fill(browColor.opacity(0.35))
                .frame(width: p * 0.18, height: p * 0.18)
                .offset(x:  p * 0.85, y: -p * 0.10 + bodyDY)
        }
        .offset(x: bodyDX)
        .animation(.easeInOut(duration: 0.20), value: bodyDX)
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

    // MARK: - 팔 뷰

    @ViewBuilder
    private func armView(outlined: Bool) -> some View {
        ZStack {
            if outlined { px(w: 1.9, h: 1.2, c: Color.black.opacity(0.22)) }
            px(w: 1.5, h: 0.9, c: bodyColor)
        }
    }

    // MARK: - 권한 요청 당근

    private var carrotView: some View {
        ZStack {
            px(w: 1.5, h: 0.6, c: leafCol).offset(y: -p * 1.25)
            px(w: 0.7, h: 0.55, c: leafCol).offset(y: -p * 1.75)
            px(w: 0.7, h: 2.1, c: carrotCol)
        }
    }

    // MARK: - 픽셀 블록 / 눈

    private func px(w: CGFloat, h: CGFloat, c: Color) -> some View {
        Rectangle().fill(c).frame(width: p * w, height: p * h)
    }

    @ViewBuilder
    private func eyeBlock(x: CGFloat, y: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black)
            .frame(width:  p * 0.70,
                   height: blinking ? p * 0.12
                         : wideEyes ? p * 1.1
                         : p * 0.75)
            .offset(x: x, y: y)
            .animation(.easeInOut(duration: 0.08), value: blinking)
            .animation(.easeInOut(duration: 0.12), value: wideEyes)
            .animation(.easeInOut(duration: 0.25), value: eyeLookUp)
    }

    // MARK: - 상태별 애니메이션

    private func applyAnimation(_ state: CompanionState) {
        withAnimation(.easeOut(duration: 0.25)) {
            wideEyes   = false
            eyeLookUp  = false
            browFurrow = 0
        }
        if case .permission = state { } else {
            withAnimation(.easeOut(duration: 0.25)) { showCarrot = false }
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
            withAnimation(.easeOut(duration: 0.2)) {
                bodyDY = 0; bodyDX = 0; earFoldScale = 1.0
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
            // 두니: 인상 쓰며 천천히 팔 올리기 — 단호한 표정
            withAnimation(.easeInOut(duration: 0.22)) { browFurrow = 16 }
            withAnimation(.easeOut(duration: 0.45)) { leftArmDY = -p * 2.8 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) { showCarrot = true }
            }

        case .completed:
            // 두니: 흡족한 표정 + 양팔 들기 + 아래로 고개 끄덕
            withAnimation(.easeInOut(duration: 0.22)) { browFurrow = -8 }
            withAnimation(.easeOut(duration: 0.45)) {
                leftArmDY  = -p * 2.8
                rightArmDY = -p * 2.8
            }
            withAnimation(.easeOut(duration: 0.30)) { bodyDY = p * 1.2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) { bodyDY = 0 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) { showCarrot = true }
            }

        case .ready:
            scheduleIdleAnimation()

        case .idle:
            break
        }
    }

    // MARK: - 뜨개질

    private func startKnitting() {
        guard !showKnitting else { return }
        withAnimation(.easeOut(duration: 0.32)) {
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

    // MARK: - 문서 읽기

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
            withAnimation(.easeInOut(duration: 1.0)) {
                leftArmDY  = readingPhase ? p * 0.18 : p * 0.30
                rightArmDY = readingPhase ? p * 0.30 : p * 0.18
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { self.stepReading() }
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

    // MARK: - 아이들

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
                withAnimation(.easeOut(duration: 0.2)) { earFoldScale = 1.0 }; return
            }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.40)) { earFoldScale = 1.0 }
        }
    }

    // MARK: - 슬라이드

    private func startSlideHop() { hopPhase = false; stepSlideHop() }

    private func stepSlideHop() {
        guard ctrl.isSliding else { stopSlideHop(); return }
        hopPhase.toggle()
        withAnimation(hopPhase ? .easeOut(duration: 0.11) : .spring(response: 0.18, dampingFraction: 0.52)) {
            bodyDY = hopPhase ? -p * 2.2 : 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { stepSlideHop() }
    }

    private func stopSlideHop() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { bodyDY = 0 }
    }

    // MARK: - 눈 깜빡임

    private func scheduleBlink() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 2.5...6.0)) {
            blinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                blinking = false; scheduleBlink()
            }
        }
    }
}
