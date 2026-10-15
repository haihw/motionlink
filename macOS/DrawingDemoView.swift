import Observation
import simd
import SwiftUI

@MainActor @Observable
final class DrawingDemoState {
    @ObservationIgnored private var drawing = DrawingEngine()
    @ObservationIgnored private var previewDrawing = DrawingEngine()
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var previewFrame: UInt64 = 0
    private(set) var revision: UInt64 = 0
    private(set) var isPreview = false
    private(set) var phoneAvailable = false
    var showGrid = true
    var snapshot: DrawingEngine { _ = revision; return isPreview ? previewDrawing : drawing }
    var tool: DrawingTool { snapshot.tool }
    var ink: DrawingInk { snapshot.ink }
    var sensitivity: Double {
        get { Double(snapshot.sensitivity) }
        set { if isPreview { previewDrawing.sensitivity = Float(newValue) } else { drawing.sensitivity = Float(newValue) }; revision &+= 1 }
    }
    var triggerAngle: Double {
        get { Double(snapshot.triggerSettings.angle) }
        set { var settings = drawing.triggerSettings; settings.angle = Float(newValue); configureTrigger(settings) }
    }
    var triggerWindow: Double {
        get { snapshot.triggerSettings.window }
        set { var settings = drawing.triggerSettings; settings.window = newValue; configureTrigger(settings) }
    }
    private func configureTrigger(_ settings: DrawingTriggerSettings) {
        drawing.configureTrigger(settings); previewDrawing.configureTrigger(settings); revision &+= 1
    }
    func select(_ tool: DrawingTool) {
        if isPreview { previewDrawing.select(tool: tool) } else { drawing.select(tool: tool) }; revision &+= 1
    }
    func select(_ ink: DrawingInk) {
        if isPreview { previewDrawing.select(ink: ink) } else { drawing.select(ink: ink) }; revision &+= 1
    }
    func center() { if isPreview { previewDrawing.center() } else { drawing.center() }; revision &+= 1 }
    func undo() { if isPreview { previewDrawing.undo() } else { drawing.undo() }; revision &+= 1 }
    func clear() { if isPreview { previewDrawing.clear() } else { drawing.clear() }; revision &+= 1 }
    func lift() { if isPreview { previewDrawing.lift() } else { drawing.lift() }; revision &+= 1 }
    func canSetNaturalPose(_ session: MacSession) -> Bool {
        !isPreview && session.deviceName != nil && !session.isPaused && !session.isStale && !session.isDemo
            && session.sample.map(DrawingEngine.canCalibrate) == true
    }
    func calibrate(_ session: MacSession) {
        guard canSetNaturalPose(session), let sample = session.sample else { return }
        if drawing.calibrate(sample) { session.haptics.play(.impact(intensity: 0.3, sharpness: 0.4)); revision &+= 1 }
    }
    func suspend() {
        drawing.suspend(); isPreview = false; phoneAvailable = false; lastSequence = nil; revision &+= 1
    }
    func togglePreview() {
        if isPreview { isPreview = false; drawing.suspend(); lastSequence = nil }
        else {
            drawing.suspend(); previewDrawing = DrawingEngine(); previewFrame = 0
            previewDrawing.configureTrigger(drawing.triggerSettings)
            previewDrawing.select(tool: .brush); previewDrawing.select(ink: .ocean)
            previewDrawing.calibrate(Self.previewSample(frame: 0, settings: drawing.triggerSettings)); isPreview = true
        }
        revision &+= 1
    }
    func tick(_ session: MacSession) {
        if isPreview {
            previewFrame &+= 1
            previewDrawing.update(Self.previewSample(frame: previewFrame, settings: drawing.triggerSettings)); revision &+= 1
            return
        }
        let available = session.deviceName != nil && !session.isPaused && !session.isStale && !session.isDemo
        if available != phoneAvailable {
            phoneAvailable = available
            if !available { drawing.suspend(); lastSequence = nil }
            revision &+= 1
        }
        guard available, let sample = session.sample, lastSequence != sample.sequence else { return }
        lastSequence = sample.sequence
        if let event = drawing.update(sample) {
            switch event {
            case .calibrated: session.haptics.play(.impact(intensity: 0.3, sharpness: 0.4))
            case .penDown: session.haptics.play(.impact(intensity: 0.65, sharpness: 0.65))
            case .penUp: session.haptics.play(.impact(intensity: 0.35, sharpness: 0.2))
            }
        }
        revision &+= 1
    }
    private static func previewSample(frame: UInt64, settings: DrawingTriggerSettings) -> MotionSample {
        let time = Double(frame) / 60
        let cycle = Double(frame % 600) / 60
        let phase = Float(max(0, time - 0.8))
        let threshold = (settings.angle + 5) * .pi / 180
        let rightTime = 0.05 + min(0.1, settings.window * 0.4)
        let rotation: simd_quatf
        if cycle < 0.05 || cycle >= rightTime + 0.1 && cycle < rightTime + 0.45 { rotation = MotionQuaternion.identity.rotation }
        else if cycle < rightTime { rotation = simd_quatf(angle: -threshold, axis: SIMD3<Float>(0, 1, 0)) }
        else if cycle < rightTime + 0.1 { rotation = simd_quatf(angle: threshold, axis: SIMD3<Float>(0, 1, 0)) }
        else {
            let amplitude = min(0.36, settings.angle * 0.6 * .pi / 180)
            rotation = simd_quatf(angle: amplitude * cos(phase * 0.85), axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: 0.30 * sin(phase * 1.1), axis: SIMD3<Float>(1, 0, 0))
        }
        return MotionSample(sequence: frame, timestamp: time, attitude: MotionQuaternion(rotation),
                            rotationRate: .zero, acceleration: .zero, gravity: MotionVector(x: 0, y: 0, z: -1))
    }
}

struct DrawingDemoView: View {
    let session: MacSession
    let drawing: DrawingDemoState
    var body: some View {
        HStack(spacing: 0) {
            DrawingControls(session: session, drawing: drawing).frame(width: 300)
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
            DrawingWorkspace(drawing: drawing)
        }
        .task {
            while !Task.isCancelled {
                drawing.tick(session)
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
        }
        .onDisappear { drawing.suspend() }
    }
}

private struct DrawingControls: View {
    let session: MacSession
    @Bindable var drawing: DrawingDemoState
    @State private var confirmClear = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A little tilt.\nA fresh mark.").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Motion drawing studio").foregroundStyle(.secondary)
                }
                MacPairingCard(session: session, neutralInstruction: "Hold the phone in your comfortable grip, then click Set natural pose. Screen-up holds also set a default pose automatically.")
                VStack(alignment: .leading, spacing: 8) {
                    Button { drawing.calibrate(session) } label: { Label("Set natural pose", systemImage: "viewfinder") }
                        .buttonStyle(.borderedProminent).disabled(!drawing.canSetNaturalPose(session))
                    Text("Flat, tilted, or upright: hold comfortably still, then click. Your grip becomes neutral for steering and the trigger. Existing marks stay on the paper.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("PEN TRIGGER · LEFT → RIGHT").font(.caption.bold()).tracking(1).foregroundStyle(.secondary)
                    HStack { Text("Angle each side"); Spacer(); Text("\(Int(drawing.triggerAngle))°").monospacedDigit() }.font(.caption)
                    Slider(value: $drawing.triggerAngle, in: 8...45, step: 1) { Text("Trigger tilt angle") }.labelsHidden()
                    HStack { Text("Gesture time"); Spacer(); Text(drawing.triggerWindow, format: .number.precision(.fractionLength(2))) + Text(" s") }.font(.caption).monospacedDigit()
                    Slider(value: $drawing.triggerWindow, in: 0.15...1, step: 0.05) { Text("Trigger timing window") }.labelsHidden()
                    Text("From your natural pose, quickly tilt left then right past the selected angle within this time. Return to your natural pose to rearm. Repeat to lift or lower the tip.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("YOUR TOOL").font(.caption.bold()).tracking(1).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(DrawingTool.allCases) { tool in
                            Button { drawing.select(tool) } label: {
                                VStack(spacing: 7) {
                                    Image(systemName: tool.symbol).font(.title3)
                                    Text(tool.rawValue).font(.caption)
                                }.frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .foregroundStyle(drawing.tool == tool ? MotionTheme.accent : .secondary)
                                    .background(drawing.tool == tool ? MotionTheme.accent.opacity(0.12) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(drawing.tool == tool ? MotionTheme.accent.opacity(0.5) : .clear))
                            }.buttonStyle(.plain).accessibilityLabel(tool.rawValue).accessibilityAddTraits(drawing.tool == tool ? .isSelected : [])
                        }
                    }
                    Text(drawing.tool.description).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("INK").font(.caption.bold()).tracking(1); Spacer(); Text(drawing.ink.rawValue).font(.caption) }.foregroundStyle(.secondary)
                    HStack(spacing: 9) {
                        ForEach(DrawingInk.allCases) { ink in
                            Button { drawing.select(ink) } label: {
                                Circle().fill(ink.color).frame(width: 28, height: 28)
                                    .overlay(Circle().stroke(.white.opacity(drawing.ink == ink ? 0.9 : 0.15), lineWidth: drawing.ink == ink ? 3 : 1))
                                    .padding(2)
                            }.buttonStyle(.plain).accessibilityLabel(ink.rawValue).accessibilityAddTraits(drawing.ink == ink ? .isSelected : [])
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Tilt sensitivity"); Spacer(); Text(drawing.sensitivity, format: .number.precision(.fractionLength(1))) + Text("×") }.font(.caption)
                    Slider(value: $drawing.sensitivity, in: 0.4...2) { Text("Tilt sensitivity") }.labelsHidden()
                    Toggle("Dot grid", isOn: $drawing.showGrid).font(.callout).toggleStyle(.switch)
                }
                HStack {
                    Button { drawing.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.disabled(drawing.snapshot.strokes.isEmpty)
                    Spacer()
                    Button { confirmClear = true } label: { Label("Clear paper", systemImage: "trash") }.disabled(drawing.snapshot.strokes.isEmpty)
                }.buttonStyle(.bordered)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("Tilt to travel", systemImage: "move.3d").font(.callout.bold())
                    Text("Left / right → left / right\nForward / backward → up / down\nCombine tilts to move diagonally.\nLarger tilt → faster movement.")
                    Label("Tilt left, then right to toggle", systemImage: "arrow.left.arrow.right").font(.callout.bold()).padding(.top, 4)
                    Text("A quick left-then-right tilt puts the tip down. Repeat to lift it. Return to your natural pose after each trigger to stop and rearm.")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
        .confirmationDialog("Clear this paper?", isPresented: $confirmClear) {
            Button("Clear paper", role: .destructive) { drawing.clear() }
        } message: { Text("This removes all strokes from the current paper.") }
    }
}

private struct DrawingWorkspace: View {
    let drawing: DrawingDemoState
    var body: some View {
        VStack(spacing: 18) {
            DrawingLiveReadout(drawing: drawing)
            DrawingPaper(drawing: drawing)
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: 1100, maxHeight: .infinity)
            HStack(spacing: 10) {
                Button { drawing.center() } label: { Label("Center tip", systemImage: "scope") }
                if drawing.snapshot.isPenDown {
                    Button { drawing.lift() } label: { Label("Lift tip", systemImage: "pencil.tip.crop.circle") }
                }
                Spacer()
                Button { drawing.togglePreview() } label: {
                    Label(drawing.isPreview ? "Stop demo" : "Try demo", systemImage: drawing.isPreview ? "stop.fill" : "play.fill")
                }
            }.buttonStyle(.bordered).controlSize(.large)
            Text(drawing.isPreview ? "Simulated tilt · your own paper is preserved" : "Quick left → right: tip down / up     ·     Tilt to move     ·     Natural pose to stop")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(26).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(colors: [Color(red: 0.10, green: 0.14, blue: 0.18), MotionTheme.background], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

private struct DrawingLiveReadout: View {
    let drawing: DrawingDemoState
    var body: some View {
        let engine = drawing.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TILT & INK").font(.caption.bold()).tracking(2).foregroundStyle(MotionTheme.accent)
                Spacer()
                StatusPill(text: engine.isPenDown ? "Tip down · drawing" : "Tip lifted", active: engine.isPenDown)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title(engine)).font(.title2.bold())
                    Text(subtitle(engine)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Int(engine.speed)) pt/s").font(.system(.body, design: .monospaced).bold()).monospacedDigit()
                    Text("↔ \(Int(engine.tiltDegrees.x))°  ↕ \(Int(engine.tiltDegrees.y))°").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).monospacedDigit()
                }.accessibilityLabel("Speed \(Int(engine.speed)) paper points per second. Horizontal tilt \(Int(engine.tiltDegrees.x)) degrees, forward tilt \(Int(engine.tiltDegrees.y)) degrees.")
            }
            if !engine.isCalibrated && drawing.phoneAvailable && !drawing.isPreview {
                ProgressView(value: engine.calibrationProgress).tint(MotionTheme.accent)
            }
        }
    }
    private func title(_ engine: DrawingEngine) -> String {
        if drawing.isPreview { return "A line in motion." }
        if !drawing.phoneAvailable { return "Your phone is the guide." }
        if !engine.isCalibrated { return "Choose your natural pose." }
        if engine.isFull { return "This paper is full." }
        if !engine.isTracking { return "Return toward your natural pose." }
        if engine.isSettling { return engine.triggerPhase == .waitingForRight ? "Now tilt right." : "Return to your natural pose." }
        return engine.isPenDown ? "Follow your imagination." : "Find your next starting point."
    }
    private func subtitle(_ engine: DrawingEngine) -> String {
        if drawing.isPreview { return "A preview of tilt, momentum, and brush strokes." }
        if !drawing.phoneAvailable { return "Connect your iPhone to begin, or try the demo." }
        if !engine.isCalibrated { return "Hold any comfortable grip and click Set natural pose, or hold screen-up for automatic setup." }
        if engine.isFull { return "Undo a stroke or clear the paper to keep drawing." }
        if !engine.isTracking { return "The tip is lifted while the phone is turned too far from your chosen pose." }
        if engine.isSettling { return engine.triggerPhase == .waitingForRight ? "Reach the right trigger angle before the timing window ends." : "Hold your chosen neutral grip briefly to resume moving and rearm the trigger." }
        return engine.isPenDown ? "Quickly tilt left then right again to lift the tip." : "Tilt to move. A quick left-then-right tilt starts drawing."
    }
}

private struct DrawingPaper: View {
    let drawing: DrawingDemoState
    var body: some View {
        let engine = drawing.snapshot
        let showGrid = drawing.showGrid
        Canvas { context, size in
            let scale = size.width / CGFloat(DrawingEngine.paperSize.x)
            context.scaleBy(x: scale, y: scale)
            let paperRect = CGRect(x: 0, y: 0, width: 1000, height: 750)
            context.fill(Path(paperRect), with: .color(Color(red: 0.975, green: 0.964, blue: 0.929)))
            if showGrid {
                var dots = Path()
                for x in stride(from: 25, to: 1000, by: 25) {
                    for y in stride(from: 25, to: 750, by: 25) { dots.addEllipse(in: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1.5, height: 1.5)) }
                }
                context.fill(dots, with: .color(.black.opacity(0.10)))
            }
            context.stroke(Path(CGRect(x: 17, y: 17, width: 966, height: 716)), with: .color(.black.opacity(0.06)), lineWidth: 1)
            for stroke in engine.strokes { Self.render(stroke, context: &context) }
            Self.cursor(engine, context: &context)
            context.draw(Text("MOTIONLINK  /  \(engine.tool.rawValue.uppercased())").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.black.opacity(0.25)), at: CGPoint(x: 35, y: 727), anchor: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 16)
        .accessibilityLabel("Drawing paper. \(engine.strokes.count) \(engine.strokes.count == 1 ? "stroke" : "strokes"). \(engine.isPenDown ? "Tip down" : "Tip lifted").")
    }

    private static func render(_ stroke: DrawingStroke, context: inout GraphicsContext) {
        guard let first = stroke.points.first else { return }
        let opacity = stroke.tool == .pencil ? 0.55 : 0.94
        let shading = GraphicsContext.Shading.color(stroke.ink.color.opacity(opacity))
        if stroke.tool == .brush {
            for index in stroke.points.indices {
                let point = stroke.points[index]
                if index == 0 {
                    context.fill(Path(ellipseIn: CGRect(x: CGFloat(point.position.x - point.width / 2), y: CGFloat(point.position.y - point.width / 2), width: CGFloat(point.width), height: CGFloat(point.width))), with: shading)
                } else {
                    let previous = stroke.points[index - 1]
                    var path = Path(); path.move(to: previous.position.cgPoint); path.addLine(to: point.position.cgPoint)
                    context.stroke(path, with: shading, style: StrokeStyle(lineWidth: CGFloat((previous.width + point.width) / 2), lineCap: .round, lineJoin: .round))
                }
            }
        } else {
            var path = Path(); path.move(to: first.position.cgPoint)
            for point in stroke.points.dropFirst() { path.addLine(to: point.position.cgPoint) }
            if stroke.points.count == 1 {
                context.fill(Path(ellipseIn: CGRect(x: CGFloat(first.position.x - first.width / 2), y: CGFloat(first.position.y - first.width / 2), width: CGFloat(first.width), height: CGFloat(first.width))), with: shading)
            } else {
                context.stroke(path, with: shading, style: StrokeStyle(lineWidth: CGFloat(stroke.tool.width), lineCap: .round, lineJoin: .round))
            }
            if stroke.tool == .pencil {
                var grain = Path()
                for (index, point) in stroke.points.enumerated() where index.isMultiple(of: 3) {
                    let offset = Float((index * 17) % 7 - 3) * 0.3
                    grain.addEllipse(in: CGRect(x: CGFloat(point.position.x + offset), y: CGFloat(point.position.y), width: 0.8, height: 0.8))
                }
                context.fill(grain, with: .color(stroke.ink.color.opacity(0.25)))
            }
        }
    }

    private static func cursor(_ engine: DrawingEngine, context: inout GraphicsContext) {
        let p = engine.position.cgPoint
        let radius: CGFloat = engine.tool == .brush ? 11 : 7
        context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y + 5, width: 24, height: 8)), with: .color(.black.opacity(engine.isPenDown ? 0.08 : 0.16)))
        context.stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)), with: .color(engine.isPenDown ? engine.ink.color : Color.black.opacity(0.45)), style: StrokeStyle(lineWidth: 1.4, dash: engine.isPenDown ? [] : [3, 3]))
        var pen = context
        pen.translateBy(x: p.x, y: p.y - (engine.isPenDown ? 0 : 10))
        pen.rotate(by: .degrees(32 + Double(engine.tiltDegrees.x) * 0.3))
        let barrel = CGRect(x: -5, y: -70, width: 10, height: 51)
        pen.fill(Path(roundedRect: barrel, cornerRadius: 3), with: .linearGradient(Gradient(colors: [engine.ink.color, engine.ink.color.opacity(0.65)]), startPoint: CGPoint(x: -5, y: -40), endPoint: CGPoint(x: 5, y: -40)))
        var nib = Path(); nib.move(to: CGPoint(x: -5, y: -19)); nib.addLine(to: .zero); nib.addLine(to: CGPoint(x: 5, y: -19)); nib.closeSubpath()
        pen.fill(nib, with: .color(engine.tool == .pencil ? Color(red: 0.77, green: 0.62, blue: 0.41) : engine.ink.color))
        pen.fill(Path(ellipseIn: CGRect(x: -1.5, y: -2, width: 3, height: 3)), with: .color(engine.ink.color))
    }
}

private extension DrawingInk {
    var color: Color { let rgb = rgb; return Color(red: rgb.x, green: rgb.y, blue: rgb.z) }
}
private extension SIMD2 where Scalar == Float {
    var cgPoint: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
}

#Preview { DrawingDemoView(session: MacSession(), drawing: DrawingDemoState()).frame(width: 1160, height: 700).preferredColorScheme(.dark) }
