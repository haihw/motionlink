import Observation
import simd
import SwiftUI

@MainActor @Observable
final class WokDemoState {
    var engine = WokGameEngine()
    var target = EggDoneness.medium
    var practiceMode = false
    var isPhoneLevel = false
    var isAutoplay = false
    var steadyDuration = 0.0
    var hasNeutral = false
    var phoneAvailable = false
    var round = 0
    var input = WokInput(active: false)
    @ObservationIgnored private var reference: MotionQuaternion?
    @ObservationIgnored private var motion = LinearMotionTracker()
    @ObservationIgnored private var translation = WokTranslationTracker()
    @ObservationIgnored private var motionFrame = WokMotionFrame(gravity: MotionVector(x: 0, y: -1, z: 0))
    @ObservationIgnored private var recenterRevision: UInt64 = 0
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var lastTimestamp: Double?
    @ObservationIgnored private var demoSequence: UInt64 = 0

    var canStart: Bool { phoneAvailable && steadyDuration >= 0.6 }
    var playing: Bool { engine.phase != .ready && !engine.finished }

    func receive(_ session: MacSession) {
        phoneAvailable = session.deviceName != nil && !session.isPaused && !session.isStale && !session.isDemo
        guard phoneAvailable, let sample = session.sample else {
            if !isAutoplay { input.active = false }
            steadyDuration = 0; isPhoneLevel = false; lastTimestamp = nil; lastSequence = nil
            hasNeutral = false; reference = nil; motion.reset(); translation.reset()
            return
        }
        guard lastSequence != sample.sequence else { return }
        let dt = lastTimestamp.map { sample.timestamp - $0 } ?? 0
        let steady = sample.rotationRate.magnitude < 0.16
            && sample.acceleration.magnitude * Double(LinearMotionTracker.standardGravity) < 0.22
        isPhoneLevel = sample.gravity.magnitude > 0.8 && -sample.gravity.z / sample.gravity.magnitude > cos(35 * .pi / 180)
        steadyDuration = steady && isPhoneLevel && dt > 0 && dt <= 0.2 ? min(0.6, steadyDuration + dt) : 0
        lastTimestamp = sample.timestamp; lastSequence = sample.sequence
        guard !isAutoplay, let reference else { return }
        let q = sample.attitude.relative(to: reference)
        let worldDevice = motionFrame.deviceRotation(q)
        let estimate = motion.update(sample, orientation: worldDevice)
        let displacement = translation.update(estimate, timestamp: sample.timestamp)
        input = WokInput(rotation: motionFrame.wokRotation(q), translation: displacement,
                         velocity: estimate.velocity.simdValue,
                         acceleration: worldDevice.rotation.act(sample.acceleration.simdValue * LinearMotionTracker.standardGravity),
                         gyro: worldDevice.rotation.act(sample.rotationRate.simdValue), sampleID: sample.sequence, active: true, recenterID: recenterRevision)
    }

    func start(session: MacSession) {
        guard canStart, let sample = session.sample else { return }
        isAutoplay = false; reference = sample.attitude; hasNeutral = true
        motion.reset(); translation.reset(); recenterRevision = 0
        motionFrame = WokMotionFrame(gravity: sample.gravity)
        input = WokInput(rotation: motionFrame.wokRotation(.identity), sampleID: sample.sequence)
        engine.start(target: target, practice: practiceMode); round += 1
    }

    func preview() {
        isAutoplay = true; engine.start(target: target, practice: practiceMode); round += 1
    }

    func stopPreview() {
        isAutoplay = false; engine = WokGameEngine()
        hasNeutral = false; reference = nil; input.active = false
    }

    func recenter() {
        translation.reset(); motion.reset(); input.translation = .zero; input.velocity = .zero
        recenterRevision += 1; input.recenterID = recenterRevision
    }

    func tick(_ dt: Double, session: MacSession) {
        receive(session)
        if isAutoplay {
            demoSequence += 1
            input = .autoplay(engine: engine, sampleID: demoSequence)
        }
        engine.step(deltaTime: dt, input: input)
        if isAutoplay && !engine.practiceMode && engine.readyToServe && engine.phase == .cooking { engine.serve() }
    }
}

struct WokDemoView: View {
    let session: MacSession
    @State private var game = WokDemoState()
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("One egg.\nPerfect timing.").font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Wok tossing & searing").foregroundStyle(.secondary)
                    }
                    MacPairingCard(session: session, neutralInstruction: "Hold the phone screen facing up, roughly level and still. The screen is the wok’s opening.")
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Practice · heat off", isOn: $game.practiceMode)
                            .toggleStyle(.switch).disabled(game.playing)
                        if !game.practiceMode {
                            Text("TARGET DONENESS").font(.caption.bold()).tracking(1).foregroundStyle(.secondary)
                            Picker("Doneness", selection: $game.target) {
                                ForEach(EggDoneness.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented).disabled(game.playing)
                            Text(game.target.description).font(.callout).foregroundStyle(.orange)
                        }
                        Text("A cooking game: the meter represents doneness in the simulation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(18).background(MotionTheme.panel, in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 14) {
                        if !game.practiceMode {
                            meter("FIRST SIDE", value: game.engine.sear[0], band: 0.50...0.72)
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
                        instruction("1", "Hold the phone screen facing up. The wok follows its actual tilt, rotation, and movement.")
                        instruction("2", "Circle to stir, tilt to slide, rotate to turn the bowl. Push forward, then lift upward quickly to toss. A faster gesture adds a second spin.")
                        instruction("3", "A flip returns to the opposite side. Relax the motion between tosses. In Cook mode, use the green timing bands.")
                        HStack(spacing: 12) {
                            Label("Push away", systemImage: "arrow.up.forward")
                            Image(systemName: "chevron.right")
                            Label("Lift up", systemImage: "arrow.up")
                        }.font(.caption.bold()).foregroundStyle(MotionTheme.accent)
                    }
                    Text("The turquoise rim mark follows the phone’s top edge. Translation is a short-motion estimate; use Recenter wok if it drifts.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(24)
            }.frame(width: 340)
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            ZStack {
                WokArenaView(session: session, game: game)
                VStack(spacing: 12) {
                    HStack {
                        Label("WOK TOSSING & SEARING", systemImage: "flame.fill")
                            .font(.caption.bold()).tracking(1).foregroundStyle(.orange)
                        Spacer()
                        StatusPill(text: game.isAutoplay ? "Chef demo" : game.phoneAvailable && game.hasNeutral ? "Phone control live" : "Heat paused", active: game.isAutoplay || game.input.active)
                    }.padding(24)
                    if game.engine.phase == .cooking {
                        VStack(spacing: 6) {
                            Text(game.engine.phaseLabel).font(.title2.bold())
                            Text(game.engine.feedback).font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }.padding(16).background(MotionTheme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 24)
                    }
                    Spacer()
                    if game.engine.phase == .ready || game.engine.finished || (!game.isAutoplay && !game.hasNeutral) {
                        startCard
                    }
                    Spacer()
                    if game.engine.phase != .ready && !game.engine.practiceMode {
                        HStack(spacing: 22) {
                            meter("FIRST SIDE", value: game.engine.sear[0], band: 0.50...0.72)
                            meter("SECOND SIDE", value: game.engine.sear[1], band: game.engine.target.target)
                        }.padding(16).frame(maxWidth: 480)
                            .background(MotionTheme.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
                            .padding(.horizontal, 20)
                    }
                    HStack(spacing: 12) {
                        Button { game.recenter() } label: { Label("Recenter wok", systemImage: "scope") }
                            .disabled(!game.hasNeutral || game.isAutoplay || game.engine.phase == .airborne)
                        Button { game.engine.serve() } label: { Label("Serve egg", systemImage: "checkmark.circle") }
                            .disabled(game.engine.phase != .cooking || !game.input.active || game.engine.practiceMode)
                            .tint(game.engine.readyToServe ? MotionTheme.accent : .orange)
                        Button {
                            if game.isAutoplay { game.stopPreview() } else { game.preview() }
                        } label: { Label(game.isAutoplay ? "Stop demo" : "Watch demo", systemImage: game.isAutoplay ? "stop.fill" : "play.fill") }
                    }.buttonStyle(.bordered).controlSize(.large).padding(.horizontal, 12)
                    if game.engine.phase == .airborne {
                        Label(game.engine.lastFlipTurns == 2 ? "2 full spins + a half-turn" : "1 full spin + a half-turn", systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout.bold()).foregroundStyle(MotionTheme.accent)
                    }
                    Text("Phone screen = wok opening · push forward + lift to toss · faster = double spin")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 24)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var startCard: some View {
        VStack(spacing: 14) {
            Image(systemName: game.engine.finished ? "star.circle.fill" : "flame.fill")
                .font(.system(size: 36)).foregroundStyle(.orange)
            Text(game.engine.finished ? game.engine.phaseLabel : "Your phone. Your wok.").font(.title2.bold())
            if game.engine.phase == .served {
                HStack { ForEach(0..<3, id: \.self) { index in Image(systemName: index < game.engine.rating ? "star.fill" : "star").foregroundStyle(.orange) } }
            }
            Text(game.engine.finished ? game.engine.feedback : "The screen is the wok’s opening. Hold it facing up and roughly level. Start captures position and heading; your tilt stays real.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !game.isAutoplay {
                ProgressView(value: game.steadyDuration, total: 0.6).tint(MotionTheme.accent)
                Button(game.engine.phase == .ready ? "Start · crack an egg" : "Cook another egg") { game.start(session: session) }
                    .buttonStyle(.borderedProminent).tint(.orange).disabled(!game.canStart)
                Text(game.phoneAvailable ? game.canStart ? "Steady grip detected. Ready to cook." : game.isPhoneLevel ? "Hold still to set your wok position." : "Face the screen upward and hold it roughly level." : "Pair your phone, or use Watch demo.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Cook another demo egg") { game.preview() }.buttonStyle(.borderedProminent).tint(.orange)
            }
        }.padding(24).frame(maxWidth: 350)
            .background(MotionTheme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 22)).padding(.horizontal, 20)
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
            Text(label == "FIRST SIDE" ? "Flip window: 50–72%" : "Serve window: \(Int(band.lowerBound * 100))–\(Int(band.upperBound * 100))%")
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
