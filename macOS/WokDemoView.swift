import Observation
import simd
import SwiftUI

@MainActor @Observable
final class WokDemoState {
    var engine = WokGameEngine()
    @ObservationIgnored private var sessionState = WokCookingSession()
    private var sessionRevision: UInt64 = 0
    var cookingSession: WokCookingSession { _ = sessionRevision; return sessionState }
    var practiceMode = false
    var isAutoplay = false
    var countdown = WokStartCountdown()
    var autoStartEnabled = true
    var resultElapsed = 0.0
    var hasNeutral = false
    var phoneAvailable = false
    var input = WokInput(active: false)
    var celebrationRemaining = 0.0
    var celebrationPosition = SIMD3<Float>.zero
    var endGesture = WokEndSessionGesture()
    @ObservationIgnored private var reference: MotionQuaternion?
    @ObservationIgnored private var motion = LinearMotionTracker()
    @ObservationIgnored private var translation = WokTranslationTracker()
    @ObservationIgnored private var motionFrame = WokMotionFrame(gravity: MotionVector(x: 0, y: -1, z: 0))
    @ObservationIgnored private var recenterRevision: UInt64 = 0
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var demoSequence: UInt64 = 0

    var waitingForEgg: Bool { engine.phase == .ready || sessionState.currentRecorded || !hasNeutral }
    var playing: Bool { sessionState.phase == .active }
    var countdownNumber: Int? {
        if isAutoplay && sessionState.currentRecorded && resultElapsed >= 4 && resultElapsed < 7 {
            return max(1, 3 - Int(resultElapsed - 4))
        }
        return countdown.number
    }

    func startCookingSession(autoplay: Bool = false) {
        sessionState.start(); sessionRevision &+= 1; engine = WokGameEngine(); isAutoplay = autoplay
        hasNeutral = false; reference = nil; input = WokInput(active: false)
        motion.reset(); translation.reset(); lastSequence = nil; recenterRevision = 0
        countdown.reset(); endGesture.reset(); resultElapsed = 0; celebrationRemaining = 0
        if autoplay { beginEgg() }
    }

    func receive(_ session: MacSession) {
        phoneAvailable = session.deviceName != nil && !session.isPaused && !session.isStale && !session.isDemo
        guard phoneAvailable, let sample = session.sample else {
            if !isAutoplay { input.active = false }
            countdown.reset(); endGesture.reset(); lastSequence = nil
            hasNeutral = false; reference = nil; motion.reset(); translation.reset()
            return
        }
        guard lastSequence != sample.sequence else { return }
        lastSequence = sample.sequence
        guard playing else { return }
        if endGesture.update(sample, allowed: sessionState.canEnd) {
            session.haptics.stopAll()
            endCookingSession(); return
        }
        guard !isAutoplay else { return }
        if (autoStartEnabled || engine.phase == .ready || !hasNeutral && !engine.finished)
            && waitingForEgg && (!engine.finished || resultElapsed >= 4) {
            countdown.update(sample)
            if countdown.isReady { captureAndBeginEgg(sample) }
        } else { countdown.reset() }
        guard let reference else { return }
        let q = sample.attitude.relative(to: reference)
        let worldDevice = motionFrame.deviceRotation(q)
        let estimate = motion.update(sample, orientation: worldDevice)
        let displacement = translation.update(estimate, timestamp: sample.timestamp)
        input = WokInput(rotation: motionFrame.wokRotation(q), translation: displacement,
                         velocity: estimate.velocity.simdValue,
                         acceleration: worldDevice.rotation.act(sample.acceleration.simdValue * LinearMotionTracker.standardGravity),
                         gyro: worldDevice.rotation.act(sample.rotationRate.simdValue), sampleID: sample.sequence, active: true, recenterID: recenterRevision)
    }

    private func captureAndBeginEgg(_ sample: MotionSample) {
        reference = sample.attitude; hasNeutral = true
        motion.reset(); translation.reset()
        motionFrame = WokMotionFrame(gravity: sample.gravity)
        recenterRevision &+= 1
        input = WokInput(rotation: motionFrame.wokRotation(.identity), sampleID: sample.sequence, recenterID: recenterRevision)
        // Reconnecting during a paused egg resumes it after setup. A completed
        // egg or the first countdown starts a fresh randomly requested egg.
        if engine.phase == .ready || sessionState.currentRecorded { beginEgg() }
        countdown.reset(); endGesture.reset()
    }

    private func beginEgg() {
        guard let target = sessionState.beginEgg() else { return }
        sessionRevision &+= 1
        engine.start(target: target, practice: practiceMode, catchPosition: sessionState.pile.nextCatchPosition)
        resultElapsed = 0
    }

    func preview() { startCookingSession(autoplay: true) }
    func stopPreview() { endCookingSession() }
    func endCookingSession() {
        sessionState.record(engine)
        guard sessionState.end() else { return }
        sessionRevision &+= 1
        isAutoplay = false; input.active = false; countdown.reset(); endGesture.reset()
        if !engine.finished { engine = WokGameEngine() }
    }

    func recenter() {
        translation.reset(); motion.reset(); input.translation = .zero; input.velocity = .zero
        recenterRevision &+= 1; input.recenterID = recenterRevision
    }

    func tick(_ dt: Double, session: MacSession) {
        guard dt.isFinite, dt > 0, dt <= 0.1 else { return }
        sessionState.pile.step(dt)
        celebrationRemaining = max(0, celebrationRemaining - dt)
        if engine.finished && playing { resultElapsed += dt }
        receive(session)
        guard playing else { return }
        if isAutoplay {
            if sessionState.currentRecorded && resultElapsed >= 7 { beginEgg() }
            demoSequence &+= 1
            input = .autoplay(engine: engine, sampleID: demoSequence)
        }
        let previousAttempts = engine.attempts
        let previousFlips = engine.flips
        let previousPhase = engine.phase
        engine.step(deltaTime: dt, input: input)
        if !isAutoplay && engine.attempts > previousAttempts {
            let bigToss = engine.phase == .serving || engine.lastFlipTurns == 2
            let strength: Float = engine.phase == .serving ? 1 : bigToss ? 0.95 : 0.8
            var events = [
                HapticEvent(kind: .transient, intensity: strength, sharpness: 0.7),
                HapticEvent(kind: .continuous, duration: 0.07, intensity: strength * 0.55, sharpness: 0.2)
            ]
            if bigToss {
                events.append(HapticEvent(kind: .transient, time: 0.1, intensity: strength * 0.85, sharpness: 0.6))
            }
            session.haptics.play(HapticPattern(events: events))
        }
        if !isAutoplay && (engine.flips > previousFlips || previousPhase == .cracking && engine.phase == .cooking) {
            let strength: Float = previousPhase == .cracking ? 0.45 : engine.lastFlipTurns == 2 ? 0.7 : 0.6
            session.haptics.play(.impact(intensity: strength, sharpness: 0.25))
        }
        if let result = sessionState.record(engine) {
            if !isAutoplay { session.haptics.play(result.stars == 3 ? .success : result.served ? .impact() : .failure) }
            sessionRevision &+= 1
            resultElapsed = 0
            if result.stars == 3 {
                celebrationRemaining = 2.8; celebrationPosition = engine.eggPosition
            }
        }
    }
}

struct WokDemoView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: MacSession
    @State private var game = WokDemoState()
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Egg after egg.\nPerfect timing.").font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Wok tossing & searing").foregroundStyle(.secondary)
                    }
                    MacPairingCard(session: session, neutralInstruction: "Face the screen upward and hold comfortably. Start a cooking session, then hold comfortably for the 3-second countdown.")
                    VStack(alignment: .leading, spacing: 12) {
                        Button { game.startCookingSession() } label: {
                            Label(game.playing ? "Restart cooking session" : game.practiceMode ? "Start practice" : "Start cooking session", systemImage: "flame.fill")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
                        Toggle("Auto next egg · 3-second countdown", isOn: $game.autoStartEnabled).toggleStyle(.switch)
                        Toggle("Practice · heat off", isOn: $game.practiceMode)
                            .toggleStyle(.switch).disabled(game.playing)
                        if !game.practiceMode {
                            Text(game.engine.phase == .ready ? "RANDOM REQUEST PER EGG" : "EGG \(game.cookingSession.eggNumber) · REQUESTED DONENESS")
                                .font(.caption.bold()).tracking(1).foregroundStyle(.secondary)
                            Text(game.engine.phase == .ready ? "Soft, Medium, or Firm" : game.engine.target.rawValue)
                                .font(.title2.bold()).foregroundStyle(.orange)
                            if game.engine.phase != .ready { Text(game.engine.target.description).font(.callout).foregroundStyle(.secondary) }
                        }
                        Divider()
                        HStack {
                            Label("\(game.cookingSession.servedCount) served", systemImage: "checkmark.circle")
                            Spacer()
                            Text("\(game.cookingSession.perfectCount) perfect").foregroundStyle(MotionTheme.accent)
                        }.font(.caption.bold())
                        if !game.cookingSession.results.isEmpty {
                            Text("Average: \(game.cookingSession.averageStars, format: .number.precision(.fractionLength(2))) / 3 stars")
                                .font(.callout.bold()).foregroundStyle(.orange)
                        }
                        Text("The plate holds 3 eggs. Extras tumble onto the table. Fold the phone downward at any time to end the session. An unfinished egg scores 0 stars.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(18).background(MotionTheme.panel, in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 14) {
                        if !game.practiceMode {
                            meter("FIRST SIDE", value: game.engine.sear[0], band: game.engine.firstSideTarget)
                            meter("SECOND SIDE", value: game.engine.sear[1], band: game.engine.target.target)
                        } else {
                            Label("Free play · no cooking timer", systemImage: "hand.draw.fill").foregroundStyle(MotionTheme.accent)
                            Text("Explore circular movement, tilt, and spins.").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Label("\(game.engine.flips) flips", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            Text(game.engine.practiceMode ? "\(game.engine.totalTurns) spins" : "\(game.engine.perfectFlips) perfect").foregroundStyle(MotionTheme.accent)
                        }.font(.caption)
                        if game.engine.lastFlipTurns > 0 {
                            Text("Last toss: \(game.engine.lastFlipTurns) full \(game.engine.lastFlipTurns == 1 ? "spin" : "spins") + half-turn")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }.padding(18).background(MotionTheme.panel, in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 12) {
                        instruction("1", "Start a session, then face the screen up and hold comfortably for 3–2–1. Each egg gets a random doneness request.")
                        instruction("2", "Circle to stir, tilt to slide, rotate to turn the bowl. Push forward, then lift upward quickly to toss. A faster gesture adds a second spin.")
                        instruction("3", "A flip returns to the opposite side. In Cook mode, reach both green bands, then make a big push-and-lift toss. The plate catches the egg. Fold the phone downward any time to end the session; an unfinished egg scores 0. An egg resting in the wok heats twice as fast.")
                        HStack(spacing: 12) {
                            Label("Push away", systemImage: "arrow.up.forward")
                            Image(systemName: "chevron.right")
                            Label("Lift up", systemImage: "arrow.up")
                        }.font(.caption.bold()).foregroundStyle(MotionTheme.accent)
                    }
                    Text("The wok stays over the burner with a small circular range and slight lift. The turquoise mark follows the phone’s top edge. Recenter if the movement estimate drifts.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(24)
            }.frame(width: 340)
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            ZStack {
                WokArenaView(session: session, game: game, reduceMotion: reduceMotion)
                VStack(spacing: 12) {
                    HStack {
                        Label("WOK TOSSING & SEARING", systemImage: "flame.fill")
                            .font(.caption.bold()).tracking(1).foregroundStyle(.orange)
                        Spacer()
                        StatusPill(text: game.isAutoplay ? "Chef demo" : game.playing && game.phoneAvailable && game.hasNeutral ? "Phone control live" : "Heat paused", active: game.isAutoplay || game.input.active)
                    }.padding(24)
                    if game.celebrationRemaining > 0 {
                        Label("Perfect egg! ★★★", systemImage: "sparkles")
                            .font(.title2.bold()).foregroundStyle(.yellow).padding(14)
                            .background(MotionTheme.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Perfect egg. Three stars!")
                    }
                    if game.playing && (game.engine.phase == .cooking || game.engine.phase == .serving) {
                        VStack(spacing: 6) {
                            Text("\(game.engine.target.rawValue) egg · \(game.engine.phaseLabel)").font(.title2.bold())
                            if game.engine.phase == .cooking && game.input.active && game.engine.heatingMultiplier == 2 {
                                Label("Egg resting · heat ×2", systemImage: "flame.fill")
                                    .font(.callout.bold()).foregroundStyle(.orange)
                            }
                            Text(game.engine.phase == .cooking && game.engine.readyToServe
                                 ? "Both sides are cooked. Push forward and lift strongly to toss onto the plate."
                                 : game.engine.feedback).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }.padding(16).background(MotionTheme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 24)
                    }
                    Spacer()
                    if !game.playing || game.engine.phase == .ready || game.engine.finished || (!game.isAutoplay && !game.hasNeutral) {
                        WokSessionCard(game: game)
                            .frame(maxWidth: .infinity, alignment: game.cookingSession.servedCount > 0 ? .leading : .center)
                    }
                    Spacer()
                    if game.playing && game.engine.phase != .ready && !game.engine.practiceMode {
                        HStack(spacing: 22) {
                            meter("FIRST SIDE", value: game.engine.sear[0], band: game.engine.firstSideTarget)
                            meter("SECOND SIDE", value: game.engine.sear[1], band: game.engine.target.target)
                        }.padding(16).frame(maxWidth: 360)
                            .background(MotionTheme.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                    }
                    HStack(spacing: 12) {
                        Button { game.recenter() } label: { Label("Recenter wok", systemImage: "scope") }
                            .disabled(!game.playing || !game.hasNeutral || game.isAutoplay || game.engine.phase == .airborne || game.engine.phase == .serving)
                        if game.cookingSession.canEnd {
                            Button { session.haptics.stopAll(); game.endCookingSession() } label: { Label("End session", systemImage: "checkmark.flag") }
                        }
                        Button {
                            if game.isAutoplay { game.stopPreview() } else { game.preview() }
                        } label: { Label(game.isAutoplay ? "Stop demo" : "Watch demo", systemImage: game.isAutoplay ? "stop.fill" : "play.fill") }
                    }.buttonStyle(.bordered).controlSize(.large).padding(.horizontal, 12)
                    if game.engine.phase == .airborne {
                        Label(game.engine.lastFlipTurns == 2 ? "2 full spins + a half-turn" : "1 full spin + a half-turn", systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout.bold()).foregroundStyle(MotionTheme.accent)
                    } else if game.engine.phase == .serving {
                        Label("Big toss · plate catch", systemImage: "checkmark.circle")
                            .font(.callout.bold()).foregroundStyle(MotionTheme.accent)
                    }
                    Text("Push forward + lift to flip · both sides done + big toss to serve")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func meter(_ label: String, value: Double, band: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(label).font(.caption2.bold()).tracking(1); Spacer(); Text("\(Int(value * 100))%").monospacedDigit().font(.caption) }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(MotionTheme.accent.opacity(0.3))
                        .frame(width: geometry.size.width * (band.upperBound - band.lowerBound))
                        .offset(x: geometry.size.width * band.lowerBound)
                    Capsule().fill(band.contains(value) ? MotionTheme.accent : .orange)
                        .frame(width: max(3, geometry.size.width * min(1, value)), height: 4)
                }
            }.frame(height: 12)
            Text(label == "FIRST SIDE" ? "Flip window: \(Int(band.lowerBound * 100))–\(Int(band.upperBound * 100))%" : "Serve window: \(Int(band.lowerBound * 100))–\(Int(band.upperBound * 100))%")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.caption.bold()).foregroundStyle(.orange).frame(width: 22, height: 22)
                .background(.orange.opacity(0.12), in: Circle())
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}


private struct WokSessionCard: View {
    let game: WokDemoState
    var body: some View {
        VStack(spacing: 14) {
            if game.cookingSession.phase == .ended {
                Image(systemName: "trophy.fill").font(.system(size: 36)).foregroundStyle(.orange)
                Text("Cooking session complete").font(.title2.bold())
                Text("\(game.cookingSession.averageStars, format: .number.precision(.fractionLength(2))) / 3 stars")
                    .font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.orange)
                Text("Average across \(game.cookingSession.results.count) eggs")
                    .font(.callout).foregroundStyle(.secondary)
                Text("\(game.cookingSession.servedCount) served · \(game.cookingSession.perfectCount) perfect · \(game.cookingSession.results.count - game.cookingSession.servedCount) missed")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Start a new session to clear the plate and scores.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let number = game.countdownNumber {
                Text("\(number)").font(.system(size: 76, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.orange)
                Text("Next egg incoming…").font(.title2.bold())
                Text("Hold comfortably, or fold the phone downward to end now. An unfinished egg scores 0 stars.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !game.playing {
                Image(systemName: "flame.fill").font(.system(size: 36)).foregroundStyle(.orange)
                Text("Your phone. Your kitchen.").font(.title2.bold())
                Text("Start a cooking session. Each egg has a surprise doneness request. Build your plate and aim for three stars.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Image(systemName: game.engine.finished ? "star.circle.fill" : "flame.fill")
                    .font(.system(size: 36)).foregroundStyle(.orange)
                Text(game.engine.finished ? game.engine.phaseLabel : "Hold comfortably to begin").font(.title2.bold())
                if game.engine.phase == .served {
                    HStack { ForEach(0..<3, id: \.self) { index in Image(systemName: index < game.engine.rating ? "star.fill" : "star").foregroundStyle(.orange) } }
                }
                Text(game.engine.finished ? game.engine.feedback : "Face the screen up and roughly level for the 3–2–1 countdown.")
                    .font(.callout).foregroundStyle(.secondary)
                if game.cookingSession.canEnd {
                    Label("Fold phone downward to end any time", systemImage: "iphone.gen3.radiowaves.left.and.right")
                        .font(.callout.bold()).foregroundStyle(MotionTheme.accent)
                    if game.endGesture.held > 0 {
                        ProgressView(value: game.endGesture.held, total: WokEndSessionGesture.holdDuration).tint(MotionTheme.accent)
                    }
                }
                if !game.isAutoplay {
                    ProgressView(value: game.countdown.steadyDuration, total: WokStartCountdown.holdDuration).tint(MotionTheme.accent)
                    Text(!game.autoStartEnabled ? "Auto next egg paused. Enable it to continue."
                         : !game.phoneAvailable ? "Pair your phone, or use Watch demo."
                         : game.engine.finished && game.resultElapsed < 4 ? "Next egg after a short break. Fold down to end."
                         : "Stay roughly level for the next egg.")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("Chef demo continues with a new random egg.").font(.caption).foregroundStyle(.secondary) }
            }
        }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            .padding(24).frame(maxWidth: 330)
            .background(MotionTheme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 22)).padding(.horizontal, 20)
    }
}
