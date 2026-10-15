import Observation
import SwiftUI

@MainActor @Observable
final class PaperFlightState {
    @ObservationIgnored private var game = PaperFlightEngine()
    @ObservationIgnored private var demo = PaperFlightPreview()
    @ObservationIgnored private var lastSequence: UInt64?
    private(set) var revision: UInt64 = 0
    private(set) var phoneAvailable = false
    private(set) var isPreview = false
    var snapshot: PaperFlightEngine { _ = revision; return isPreview ? demo.engine : game }
    var sensitivity: Double {
        get { Double(game.sensitivity) }
        set { game.sensitivity = Float(newValue); revision &+= 1 }
    }
    func canSetPose(_ session: MacSession) -> Bool {
        !isPreview && session.deviceName != nil && !session.isPaused && !session.isStale && !session.isDemo
            && session.sample.map(TiltPose.canCapture) == true
    }
    func calibrate(_ session: MacSession) {
        guard canSetPose(session), let sample = session.sample else { return }
        if game.calibrate(sample) { session.haptics.play(.impact(intensity: 0.3)); revision &+= 1 }
    }
    var canLaunch: Bool { _ = revision; return !isPreview && phoneAvailable && game.isCalibrated }
    func launch() { guard canLaunch else { return }; game.launch(); revision &+= 1 }
    func togglePreview() {
        if isPreview { isPreview = false; game.suspend(); lastSequence = nil }
        else { game.suspend(); demo = PaperFlightPreview(sensitivity: game.sensitivity); isPreview = true }
        revision &+= 1
    }
    func suspend() { game.suspend(); isPreview = false; phoneAvailable = false; lastSequence = nil; revision &+= 1 }
    func tick(_ session: MacSession) {
        if isPreview { demo.tick(); revision &+= 1; return }
        let available = session.deviceName != nil && !session.isPaused && !session.isStale && !session.isDemo
        if available != phoneAvailable {
            phoneAvailable = available
            if !available { game.suspend(); lastSequence = nil }
            revision &+= 1
        }
        guard available, let sample = session.sample, sample.sequence != lastSequence else { return }
        lastSequence = sample.sequence
        let events = game.update(sample)
        for event in events {
            switch event {
            case .calibrated: session.haptics.play(.impact(intensity: 0.3))
            case .launched: session.haptics.play(.impact(intensity: 0.6, sharpness: 0.4))
            case .boost: session.haptics.play(.rumble(duration: 0.18, intensity: 0.65))
            case .turbulence: session.haptics.play(.rumble(duration: 0.22, intensity: 0.18))
            case .ringPassed(_, let perfect):
                if !events.contains(.finished) { session.haptics.play(perfect ? .success : .impact(intensity: 0.5)) }
            case .ringMissed: session.haptics.play(.impact(intensity: 0.18, sharpness: 0.2))
            case .crashed: session.haptics.play(.failure)
            case .finished: session.haptics.play(.success)
            }
        }
        revision &+= 1
    }
}

struct PaperFlightView: View {
    let session: MacSession
    let flight: PaperFlightState
    var body: some View {
        HStack(spacing: 0) {
            PaperFlightControls(session: session, flight: flight).frame(width: 290)
            Divider()
            VStack(spacing: 16) {
                FlightReadout(game: flight.snapshot)
                ZStack {
                    PaperFlightArenaView(flight: flight)
                    VStack {
                        HStack {
                            Label(flight.isPreview ? "GUIDED PREVIEW" : "PAPER PLANE FLIGHT", systemImage: "paperplane.fill")
                                .font(.caption.bold()).tracking(1)
                            Spacer()
                            Text(flight.snapshot.inTurbulence ? "CROSSWIND" : flight.snapshot.boostRemaining > 0 ? "BOOST" : "GLIDING")
                                .font(.caption.bold()).foregroundStyle(flight.snapshot.inTurbulence ? .orange : .cyan)
                        }.padding(18).background(.black.opacity(0.25))
                        Spacer()
                        flightOverlay
                        Spacer()
                        HStack(spacing: 5) {
                            ForEach(Array(flight.snapshot.results.enumerated()), id: \.offset) { index, result in
                                Image(systemName: result == .perfect ? "sparkle" : result == .passed ? "checkmark.circle.fill" : result == .missed ? "xmark.circle" : "circle")
                                    .foregroundStyle(result == .perfect ? .yellow : result == .passed ? .green : result == .missed ? .gray : .white)
                                    .accessibilityLabel("Ring \(index + 1): \(String(describing: result))")
                            }
                        }.font(.title3).padding(14).background(.black.opacity(0.35), in: Capsule()).padding(18)
                    }.allowsHitTesting(false)
                }.clipShape(RoundedRectangle(cornerRadius: 22)).frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Button { flight.launch() } label: { Label(flight.snapshot.phase == .ready ? "Launch flight" : "Fly again", systemImage: "paperplane") }
                        .buttonStyle(.borderedProminent).disabled(!flight.canLaunch)
                    Spacer()
                    Button { flight.togglePreview() } label: { Label(flight.isPreview ? "Stop preview" : "Watch demo", systemImage: flight.isPreview ? "stop.fill" : "play.fill") }
                        .buttonStyle(.bordered)
                }.controlSize(.large)
                Text(flight.isPreview ? "Simulated controller · eight-ring course · your flight is preserved" : "Bank to turn  ·  Tip forward to dive, back to climb  ·  Push forward quickly to boost")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            while !Task.isCancelled {
                flight.tick(session)
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
        }
        .onDisappear { flight.suspend() }
    }
    @ViewBuilder private var flightOverlay: some View {
        let game = flight.snapshot
        if game.phase == .countdown {
            overlay(title: "\(game.countdownNumber)", detail: "Hold your natural pose to launch", symbol: "paperplane.fill")
        } else if game.phase == .crashed {
            overlay(title: "Paper down!", detail: "\(game.crashReason?.rawValue ?? "Flight ended")\n\(game.ringsPassed) / 8 rings · \(game.score) points", symbol: "wind")
        } else if game.phase == .finished {
            overlay(title: "Beautiful flight!", detail: "\(game.ringsPassed) / 8 rings · \(game.perfectPasses) perfect\n\(game.score) points · \(String(format: "%.1f", game.elapsed)) seconds", symbol: "sparkles")
        } else if !flight.isPreview && (!flight.phoneAvailable || !game.isCalibrated) {
            overlay(title: flight.phoneAvailable ? "Find your grip" : "Ready for takeoff", detail: flight.phoneAvailable ? "Hold still with the screen up, or click Set natural pose.\nYour flight is paused while you calibrate." : "Connect your iPhone, or watch the guided demo.", symbol: "iphone")
        } else if game.phase == .ready {
            overlay(title: "Cleared for takeoff", detail: "Click Launch flight, then hold neutral for 3 seconds.", symbol: "paperplane")
        } else if !game.isTracking || game.neutralProgress < 1 {
            overlay(title: "Hold neutral", detail: "Return to your natural pose to resume flying.", symbol: "viewfinder")
        }
    }
    private func overlay(title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.cyan)
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(detail).font(.callout).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
        }.padding(26).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 22)).padding(24)
    }
}

private struct PaperFlightControls: View {
    let session: MacSession
    @Bindable var flight: PaperFlightState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fold. Tilt.\nTake flight.").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("A little paper. A wide open sky.").font(.callout).foregroundStyle(.secondary)
                }
                MacPairingCard(session: session, neutralInstruction: "Hold the phone like your plane. Set your natural pose, then bank and pitch to fly.")
                VStack(alignment: .leading, spacing: 9) {
                    Button { flight.calibrate(session) } label: { Label("Set natural pose", systemImage: "viewfinder") }
                        .buttonStyle(.borderedProminent).disabled(!flight.canSetPose(session))
                    Text("Flat or upright: hold still and set your comfortable grip. A steady screen-up hold calibrates automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Steering response"); Spacer(); Text(flight.sensitivity, format: .number.precision(.fractionLength(1))) + Text("×") }.font(.caption)
                    Slider(value: $flight.sensitivity, in: 0.5...1.5) { Text("Steering response") }.labelsHidden().disabled(flight.isPreview)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Label("Bank into the turn", systemImage: "arrow.triangle.turn.up.right.diamond").font(.callout.bold()).foregroundStyle(.cyan)
                    Text("Lean left or right to bank. Hold the lean to turn; return to neutral to fly straight.")
                    Label("Climb and dive", systemImage: "arrow.up.and.down").font(.callout.bold()).foregroundStyle(.cyan)
                    Text("Tip the top of the phone forward to dive. Pull it back to climb. The camera keeps the horizon level.")
                    Label("A forward flick = boost", systemImage: "wind").font(.callout.bold()).foregroundStyle(.orange)
                    Text("Push the phone forward quickly, then relax. Boost lasts 1.6 seconds, with a short recharge.")
                    Label("Thread eight rings", systemImage: "circle.circle").font(.callout.bold()).foregroundStyle(.yellow)
                    Text("100 points per ring. Fly through the center for 150. Avoid the rims, storm clouds, and water. Blue wind pockets gently buffet the plane.")
                }.font(.caption).foregroundStyle(.secondary)
                Text("A gliding game with assisted airspeed. Speed and altitude describe the virtual plane.").font(.caption2).foregroundStyle(.tertiary)
            }.padding(22)
        }
    }
}

private struct FlightReadout: View {
    let game: PaperFlightEngine
    var body: some View {
        HStack(spacing: 0) {
            metric("AIRSPEED", String(format: "%.1f m/s", game.speed))
            metric("ALTITUDE", String(format: "%.1f m", game.position.y))
            metric("RINGS", "\(game.ringsPassed) / 8")
            metric("SCORE", "\(game.score)")
        }.padding(.vertical, 12).background(MotionTheme.panel, in: RoundedRectangle(cornerRadius: 16))
    }
    private func metric(_ name: String, _ value: String) -> some View {
        VStack(spacing: 5) {
            Text(name).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .monospaced).bold()).monospacedDigit()
        }.frame(maxWidth: .infinity)
    }
}
