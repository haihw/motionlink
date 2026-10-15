import Observation
import simd
import SwiftUI

@MainActor @Observable
final class LaserMazeState {
    @ObservationIgnored private var game: LaserMazeEngine
    @ObservationIgnored private var demo = LaserMazeEngine()
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var demoFrame: UInt64 = 0
    @ObservationIgnored private var waypoint = 1
    private(set) var revision: UInt64 = 0
    private(set) var phoneAvailable = false
    private(set) var isPreview = false
    let leaderboard: MazeLeaderboard
    private(set) var pendingFinish: MazeFinish?
    private(set) var scoreError: String?
    @ObservationIgnored private var submittedRunID: UUID?
    var playerName = ""
    var canSubmitCurrentRun: Bool {
        _ = revision
        return !isPreview && game.phase == .escaped && submittedRunID != game.runID && !leaderboard.contains(game.runID)
    }
    init(leaderboard: MazeLeaderboard? = nil, game: LaserMazeEngine = LaserMazeEngine()) {
        self.leaderboard = leaderboard ?? MazeLeaderboard(); self.game = game
    }
    func requestScore() {
        guard canSubmitCurrentRun, let finish = MazeFinish(game: game) else { return }
        pendingFinish = finish; playerName = leaderboard.lastPlayerName; scoreError = nil
    }
    func skipScore() { pendingFinish = nil; scoreError = nil }
    func saveScore() {
        guard let finish = pendingFinish else { return }
        do {
            try leaderboard.save(finish: finish, name: playerName)
            submittedRunID = finish.id; pendingFinish = nil; scoreError = nil; revision &+= 1
        } catch {
            scoreError = leaderboard.loadFailed ? "Saved times could not be loaded. Try saving again after checking storage access."
                : "Your time could not be saved. Please try again."
        }
    }
    var snapshot: LaserMazeEngine { _ = revision; return isPreview ? demo : game }
    var sensitivity: Double {
        get { Double(snapshot.sensitivity) }
        set { game.sensitivity = Float(newValue); demo.sensitivity = Float(newValue); revision &+= 1 }
    }
    func canSetPose(_ session: MacSession) -> Bool {
        !isPreview && session.deviceName != nil && !session.isPaused && !session.isStale && !session.isDemo
            && session.sample.map(TiltPose.canCapture) == true
    }
    func calibrate(_ session: MacSession) {
        guard canSetPose(session), let sample = session.sample else { return }
        if game.calibrate(sample) { session.haptics.play(.impact(intensity: 0.3)); revision &+= 1 }
    }
    func restart(newMaze: Bool = false) {
        let seed: UInt64? = newMaze ? UInt64.random(in: 1...UInt64.max) : nil
        if isPreview { demo.restart(seed: seed); waypoint = 1 }
        else { game.restart(seed: seed); submittedRunID = nil; skipScore() }
        revision &+= 1
    }
    func suspend() { game.suspend(); isPreview = false; phoneAvailable = false; lastSequence = nil; revision &+= 1 }
    func togglePreview() {
        if isPreview { isPreview = false; game.suspend(); lastSequence = nil }
        else {
            game.suspend(); demo = LaserMazeEngine(seed: game.layout.seed); demo.sensitivity = game.sensitivity
            demoFrame = 0; waypoint = 1; demo.calibrate(Self.sample(frame: 0, rotation: .identity)); isPreview = true
        }
        revision &+= 1
    }
    func tick(_ session: MacSession) {
        if isPreview { tickPreview(); revision &+= 1; return }
        let available = session.deviceName != nil && !session.isPaused && !session.isStale && !session.isDemo
        if available != phoneAvailable {
            phoneAvailable = available
            if !available { game.suspend(); lastSequence = nil }
            revision &+= 1
        }
        guard available, let sample = session.sample, sample.sequence != lastSequence else { return }
        lastSequence = sample.sequence
        if let event = game.update(sample) {
            switch event {
            case .calibrated: session.haptics.play(.impact(intensity: 0.3, sharpness: 0.4))
            case .burned: session.haptics.play(.failure)
            case .respawned: session.haptics.play(.impact(intensity: 0.35, sharpness: 0.2))
            case .escaped: session.haptics.play(.success); requestScore()
            }
        }
        revision &+= 1
    }
    private func tickPreview() {
        demoFrame &+= 1
        var rotation = MotionQuaternion.identity
        if demo.phase == .playing {
            let target: SIMD2<Float>
            if demo.deaths == 0 { target = [-100, demo.layout.start.y] }
            else {
                if waypoint < demo.layout.route.count - 1 && simd_distance(demo.position, demo.layout.route[waypoint]) < 8 { waypoint += 1 }
                target = demo.layout.route[min(waypoint, demo.layout.route.count - 1)]
            }
            let delta = target - demo.position, distance = simd_length(delta)
            let desired = distance > 0.1 ? delta / distance * min(140, distance * 3) : .zero
            let terminal = desired + (desired - demo.velocity) * 0.6
            var planar = terminal / (640 * demo.sensitivity)
            let magnitude = simd_length(planar)
            if magnitude > 0.65 { planar *= 0.65 / magnitude }
            if magnitude > 0.001 { planar *= (simd_length(planar) * (1 - sin(Float.pi / 120)) + sin(Float.pi / 120)) / simd_length(planar) }
            let gravity = SIMD3<Float>(planar.x, -planar.y, -sqrt(max(0.01, 1 - simd_length_squared(planar))))
            rotation = MotionQuaternion(simd_quatf(from: simd_normalize(gravity), to: SIMD3<Float>(0, 0, -1)))
        }
        demo.update(Self.sample(frame: demoFrame, rotation: rotation))
    }
    private static func sample(frame: UInt64, rotation: MotionQuaternion) -> MotionSample {
        MotionSample(sequence: frame, timestamp: Double(frame) / 60, attitude: rotation,
                     rotationRate: .zero, acceleration: .zero, gravity: MotionVector(x: 0, y: 0, z: -1))
    }
}

struct LaserMazeView: View {
    let session: MacSession
    let maze: LaserMazeState
    var body: some View {
        HStack(spacing: 0) {
            LaserMazeControls(session: session, maze: maze).frame(width: 300)
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            VStack(spacing: 18) {
                LaserMazeReadout(maze: maze)
                LaserMazeBoard(game: maze.snapshot).aspectRatio(4 / 3, contentMode: .fit).frame(maxWidth: 1100, maxHeight: .infinity)
                HStack {
                    Button { maze.restart() } label: { Label("Restart run", systemImage: "arrow.counterclockwise") }
                    Button { maze.restart(newMaze: true) } label: { Label("New maze", systemImage: "square.grid.3x3") }
                    if maze.canSubmitCurrentRun {
                        Button { maze.requestScore() } label: { Label("Save time", systemImage: "trophy") }
                    }
                    Spacer()
                    Button { maze.togglePreview() } label: { Label(maze.isPreview ? "Stop demo" : "Watch demo", systemImage: maze.isPreview ? "stop.fill" : "play.fill") }
                }.buttonStyle(.bordered).controlSize(.large)
                Text(maze.isPreview ? "Preview · one laser hit, then a guided escape · your run is preserved" : "Tilt to move  ·  Hold your natural pose to stop  ·  Touch a laser and return to START")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LinearGradient(colors: [Color(red: 0.08, green: 0.06, blue: 0.14), MotionTheme.background], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .task {
            while !Task.isCancelled {
                maze.tick(session)
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
        }
        .onDisappear { maze.suspend() }
        .sheet(item: Binding(get: { maze.pendingFinish }, set: { if $0 == nil { maze.skipScore() } })) { finish in
            MazeNameSheet(maze: maze, finish: finish)
        }
    }
}

private struct LaserMazeControls: View {
    let session: MacSession
    @Bindable var maze: LaserMazeState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Small bug.\nSteady hands.").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("The laser maze").foregroundStyle(.secondary)
                }
                MacPairingCard(session: session, neutralInstruction: "Hold the phone in a comfortable grip, then Set natural pose. Tilt gently to guide the ladybug.")
                VStack(alignment: .leading, spacing: 9) {
                    Button { maze.calibrate(session) } label: { Label("Set natural pose", systemImage: "viewfinder") }
                        .buttonStyle(.borderedProminent).disabled(!maze.canSetPose(session))
                    Text("Flat, tilted, or upright. Hold still and click to set your neutral grip. Screen-up holds also calibrate automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Movement sensitivity"); Spacer(); Text(maze.sensitivity, format: .number.precision(.fractionLength(1))) + Text("×") }.font(.caption)
                    Slider(value: $maze.sensitivity, in: 0.4...1.5) { Text("Movement sensitivity") }.labelsHidden()
                    Text("Start gently. Larger tilts move faster, with the same momentum and braking as Drawing Demo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                MazeLeaderboardPanel(leaderboard: maze.leaderboard, seed: maze.snapshot.layout.seed)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Label("Find the green exit", systemImage: "flag.checkered").font(.callout.bold()).foregroundStyle(MotionTheme.accent)
                    Text("Guide the whole ladybug through the corridors. Every red laser is dangerous, including the outer border.")
                    Label("A touch sends you back", systemImage: "flame.fill").font(.callout.bold()).foregroundStyle(.orange)
                    Text("Touch a laser and the bug burns, then returns to START. Hold your natural pose briefly before moving again.")
                    Label("Tilt to steer", systemImage: "move.3d").font(.callout.bold())
                    Text("Left / right → left / right\nForward / backward → up / down\nCombine tilts for diagonals.\nReturn to your natural pose to stop.")
                }.font(.caption).foregroundStyle(.secondary)
                Text("No drawing trigger is needed here. The ladybug follows your tilt as soon as you hold neutral to start.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
    }
}

private struct MazeNameSheet: View {
    @Bindable var maze: LaserMazeState
    let finish: MazeFinish
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "trophy.fill").font(.system(size: 36)).foregroundStyle(.yellow)
            Text("You escaped!").font(.largeTitle.bold())
            Text(MazeFinish.time(finish.elapsed)).font(.system(size: 38, weight: .bold, design: .monospaced)).foregroundStyle(MotionTheme.accent)
            Text("\(finish.deaths) laser \(finish.deaths == 1 ? "hit" : "hits") · \(finish.deaths + 1) \(finish.deaths == 0 ? "attempt" : "attempts")").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter your name for the leaderboard").font(.headline)
                TextField("Player name", text: $maze.playerName).textFieldStyle(.roundedBorder).focused($nameFocused)
                    .onChange(of: maze.playerName) { _, name in
                        if name.count > 24 { maze.playerName = String(name.prefix(24)) }
                    }
                    .onSubmit { if !MazeScore.normalizedName(maze.playerName).isEmpty { maze.saveScore() } }
                Text("Up to 24 characters. Saved on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = maze.scoreError { Text(error).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("Skip") { maze.skipScore() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save time") { maze.saveScore() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(MazeScore.normalizedName(maze.playerName).isEmpty)
            }
        }.padding(32).frame(width: 400).onAppear { nameFocused = true }
    }
}

private struct MazeLeaderboardPanel: View {
    let leaderboard: MazeLeaderboard
    let seed: UInt64
    @State private var allMazes = false
    var body: some View {
        let entries = allMazes ? leaderboard.scores : leaderboard.entries(for: seed)
        VStack(alignment: .leading, spacing: 12) {
            Label("LEADERBOARD", systemImage: "trophy.fill").font(.caption.bold()).tracking(1).foregroundStyle(.yellow)
            Picker("Leaderboard scope", selection: $allMazes) {
                Text("This maze").tag(false); Text("All mazes").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            Text(allMazes ? "Fastest first · maze layouts vary" : "Same maze · fastest first").font(.caption).foregroundStyle(.secondary)
            if leaderboard.loadFailed {
                Text("Saved times could not be loaded.").font(.caption).foregroundStyle(.orange)
                Button("Retry loading") { leaderboard.reload() }.font(.caption)
            } else if entries.isEmpty {
                Text("No times yet. Reach EXIT to add your name.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries.prefix(10).enumerated()), id: \.element.id) { rank, entry in
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(rank + 1)").font(.system(.caption, design: .monospaced).bold())
                            .foregroundStyle(rank == 0 ? .yellow : .secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name).font(.callout.weight(.semibold)).lineLimit(1)
                            Text("\(entry.finish.deaths) laser \(entry.finish.deaths == 1 ? "hit" : "hits")").font(.caption2).foregroundStyle(.secondary)
                            if allMazes && entry.finish.mazeSeed != seed { Text("Other maze").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 4)
                        Text(MazeFinish.time(entry.finish.elapsed)).font(.system(.caption, design: .monospaced).bold()).monospacedDigit()
                    }
                }
                if entries.count > 10 { Text("Fastest 10 of \(entries.count) saved times").font(.caption2).foregroundStyle(.secondary) }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct LaserMazeReadout: View {
    let maze: LaserMazeState
    var body: some View {
        let game = maze.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LADYBUG / LASER RUN").font(.caption.bold()).tracking(2).foregroundStyle(.orange)
                Spacer()
                StatusPill(text: game.phase == .escaped ? "Safe!" : game.phase == .burning ? "Burned!" : maze.isPreview ? "Preview" : "Attempt \(game.attempt)", active: game.phase == .escaped)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title(game)).font(.title2.bold())
                    Text(subtitle(game)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(Self.time(game.elapsed)).font(.system(.title3, design: .monospaced).bold()).monospacedDigit()
                    Text("\(game.deaths) laser \(game.deaths == 1 ? "hit" : "hits") · \(Int(game.speed)) pt/s")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if game.phase == .ready && (maze.phoneAvailable || maze.isPreview) {
                ProgressView(value: game.isCalibrated ? game.neutralProgress : game.calibrationProgress).tint(MotionTheme.accent)
            }
        }
    }
    private func title(_ game: LaserMazeEngine) -> String {
        if game.phase == .escaped { return "Tiny bug. Great escape." }
        if game.phase == .burning { return "Ouch! Back to the beginning." }
        if !maze.phoneAvailable && !maze.isPreview { return "A delicate little escape." }
        if !game.isCalibrated { return "Choose your natural pose." }
        if !game.isTracking { return "Return toward your natural pose." }
        return game.phase == .ready ? "Hold your neutral grip to begin." : "Easy does it. Follow the gaps."
    }
    private func subtitle(_ game: LaserMazeEngine) -> String {
        if game.phase == .escaped { return "Escaped in \(Self.time(game.elapsed)) across \(game.attempt) \(game.attempt == 1 ? "attempt" : "attempts")." }
        if game.phase == .burning { return "The laser caught the bug. Get ready at START." }
        if !maze.phoneAvailable && !maze.isPreview { return "Pair your iPhone or watch the guided demo." }
        if !game.isCalibrated { return "Use Set natural pose, or hold the screen upward for automatic setup." }
        if game.phase == .ready { return "Hold comfortably neutral for a moment. Then tilt to move." }
        return "Reach the green exit. Keep the entire bug clear of the lasers."
    }
    private static func time(_ seconds: Double) -> String { String(format: "%02d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60)) }
}

private struct LaserMazeBoard: View {
    let game: LaserMazeEngine
    var body: some View {
        Canvas { context, size in
            let scale = size.width / CGFloat(LaserMazeLayout.size.x)
            context.scaleBy(x: scale, y: scale)
            context.fill(Path(CGRect(x: 0, y: 0, width: 960, height: 720)), with: .color(Color(red: 0.025, green: 0.035, blue: 0.07)))
            var grid = Path()
            for x in stride(from: 0, through: 960, by: 30) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: 720)) }
            for y in stride(from: 0, through: 720, by: 30) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: 960, y: y)) }
            context.stroke(grid, with: .color(.white.opacity(0.035)), lineWidth: 0.8)
            pad(game.layout.start, text: "START", color: .cyan, context: &context)
            pad(game.layout.goal, text: "EXIT", color: MotionTheme.accent, context: &context)
            if game.trail.count > 1 {
                var trail = Path(); trail.move(to: game.trail[0].point)
                for point in game.trail.dropFirst() { trail.addLine(to: point.point) }
                context.stroke(trail, with: .color(.cyan.opacity(0.2)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 7]))
            }
            var lasers = Path(), nodes = Path()
            for wall in game.layout.walls {
                lasers.move(to: wall.a.point); lasers.addLine(to: wall.b.point)
                for point in [wall.a, wall.b] { nodes.addEllipse(in: CGRect(x: CGFloat(point.x) - 4, y: CGFloat(point.y) - 4, width: 8, height: 8)) }
            }
            context.stroke(lasers, with: .color(.red.opacity(0.09)), style: StrokeStyle(lineWidth: 24, lineCap: .round))
            context.stroke(lasers, with: .color(.red.opacity(0.20)), style: StrokeStyle(lineWidth: 13, lineCap: .round))
            context.stroke(lasers, with: .color(Color(red: 1, green: 0.15, blue: 0.30)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            context.stroke(lasers, with: .color(Color(red: 1, green: 0.75, blue: 0.78)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            context.fill(nodes, with: .color(Color(red: 1, green: 0.35, blue: 0.43)))
            ladybug(context: &context)
            if game.phase == .burning { burn(context: &context) }
            if game.phase == .escaped { celebrate(context: &context) }
        }.clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 16)
            .accessibilityLabel("Laser maze. Ladybug at \(Int(game.position.x)), \(Int(game.position.y)). \(game.deaths) laser hits. \(game.phase == .escaped ? "Escaped" : game.phase == .burning ? "Burning" : "Find the green exit").")
    }
    private func pad(_ position: SIMD2<Float>, text: String, color: Color, context: inout GraphicsContext) {
        let p = position.point
        context.fill(Path(ellipseIn: CGRect(x: p.x - 36, y: p.y - 36, width: 72, height: 72)), with: .color(color.opacity(0.1)))
        context.stroke(Path(ellipseIn: CGRect(x: p.x - 28, y: p.y - 28, width: 56, height: 56)), with: .color(color.opacity(0.65)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        context.draw(Text(text).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(color), at: CGPoint(x: p.x, y: p.y + 44))
    }
    private func ladybug(context: inout GraphicsContext) {
        var bug = context
        bug.translateBy(x: CGFloat(game.position.x), y: CGFloat(game.position.y)); bug.rotate(by: .radians(Double(game.heading)))
        let burning = game.phase == .burning
        let body = Path(ellipseIn: CGRect(x: -11, y: -13, width: 22, height: 28))
        bug.fill(Path(ellipseIn: CGRect(x: -13, y: -7, width: 28, height: 26)), with: .color(.black.opacity(0.4)))
        var legs = Path()
        for side in [-1.0, 1.0] {
            for index in 0..<3 {
                let y = Double(index * 8 - 7)
                let wobble = game.phase == .playing && game.speed > 2 ? sin(game.elapsed * 35 + Double(index) * 2) * 2 : 0
                legs.move(to: CGPoint(x: side * 8, y: y)); legs.addLine(to: CGPoint(x: side * 16, y: y + wobble + 3))
            }
        }
        bug.stroke(legs, with: .color(.gray), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        bug.fill(body, with: .linearGradient(Gradient(colors: burning ? [.black, .gray] : [Color(red: 1, green: 0.30, blue: 0.25), Color(red: 0.65, green: 0.03, blue: 0.10)]), startPoint: CGPoint(x: -10, y: -10), endPoint: CGPoint(x: 10, y: 10)))
        bug.fill(Path(ellipseIn: CGRect(x: -7, y: -19, width: 14, height: 12)), with: .color(.black))
        var seam = Path(); seam.move(to: CGPoint(x: 0, y: -10)); seam.addLine(to: CGPoint(x: 0, y: 14))
        bug.stroke(seam, with: .color(.black.opacity(0.8)), lineWidth: 1.5)
        for side in [-1.0, 1.0] {
            for y in [-5.0, 5.0] { bug.fill(Path(ellipseIn: CGRect(x: side * 5 - 2.5, y: y - 2.5, width: 5, height: 5)), with: .color(.black)) }
            bug.fill(Path(ellipseIn: CGRect(x: side * 3.5 - 1, y: -17, width: 2, height: 2)), with: .color(.white))
            var antenna = Path(); antenna.move(to: CGPoint(x: side * 4, y: -17)); antenna.addQuadCurve(to: CGPoint(x: side * 9, y: -24), control: CGPoint(x: side * 4, y: -24))
            bug.stroke(antenna, with: .color(.gray), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }
        if !burning { bug.fill(Path(ellipseIn: CGRect(x: -7, y: -9, width: 4, height: 7)), with: .color(.white.opacity(0.25))) }
    }
    private func burn(context: inout GraphicsContext) {
        let t = min(1, game.phaseAge / 0.85), center = game.position.point
        for index in 0..<20 {
            let angle = Double(index) * 2.39996
            let distance = CGFloat(12 + t * Double(25 + index % 5 * 8))
            let p = CGPoint(x: center.x + CGFloat(cos(angle)) * distance, y: center.y + CGFloat(sin(angle)) * distance - CGFloat(t * 30))
            let radius = CGFloat((1 - t) * 4 + 1)
            context.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)), with: .color((index.isMultiple(of: 3) ? Color.yellow : .orange).opacity(1 - t)))
        }
        context.stroke(Path(ellipseIn: CGRect(x: center.x - CGFloat(t * 55), y: center.y - CGFloat(t * 55), width: CGFloat(t * 110), height: CGFloat(t * 110))), with: .color(.orange.opacity(1 - t)), lineWidth: 3)
    }
    private func celebrate(context: inout GraphicsContext) {
        let t = min(1, game.phaseAge / 2)
        for index in 0..<28 {
            let a = Double(index) * 2.39996
            let radius = 35 + t * Double(30 + index % 7 * 12)
            let x = Double(game.position.x) + cos(a) * radius, y = Double(game.position.y) + sin(a) * radius + t * t * 45
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 4, height: 4)), with: .color((index.isMultiple(of: 2) ? MotionTheme.accent : .yellow).opacity(1 - t)))
        }
    }
}

private extension SIMD2 where Scalar == Float { var point: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) } }

#Preview { LaserMazeView(session: MacSession(), maze: LaserMazeState()).frame(width: 1160, height: 700).preferredColorScheme(.dark) }
