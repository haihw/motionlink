import Foundation
import simd

enum DrawingTool: String, CaseIterable, Identifiable, Sendable {
    case pen = "Pen", pencil = "Pencil", brush = "Brush"
    var id: Self { self }
    var symbol: String { switch self { case .pen: "pencil.tip"; case .pencil: "pencil"; case .brush: "paintbrush.pointed.fill" } }
    var width: Float { switch self { case .pen: 3.5; case .pencil: 2.5; case .brush: 16 } }
    var description: String {
        switch self {
        case .pen: "Clean, even ink."
        case .pencil: "Soft graphite with a grainy edge."
        case .brush: "Full strokes that narrow as you move faster."
        }
    }
}

enum DrawingInk: String, CaseIterable, Identifiable, Sendable {
    case midnight = "Midnight", ocean = "Ocean", coral = "Coral", moss = "Moss", ochre = "Ochre", plum = "Plum"
    var id: Self { self }
    var rgb: SIMD3<Double> {
        switch self {
        case .midnight: [0.10, 0.15, 0.21]; case .ocean: [0.12, 0.39, 0.69]
        case .coral: [0.82, 0.28, 0.23]; case .moss: [0.20, 0.45, 0.34]
        case .ochre: [0.73, 0.47, 0.12]; case .plum: [0.49, 0.26, 0.55]
        }
    }
}

struct DrawingPoint: Sendable {
    var position: SIMD2<Float>
    var width: Float
}

struct DrawingStroke: Identifiable, Sendable {
    let id = UUID()
    let tool: DrawingTool
    let ink: DrawingInk
    var points: [DrawingPoint]
}

struct DrawingTriggerSettings: Sendable, Equatable {
    var angle: Float = 18
    var window: Double = 0.45
    var bounded: Self {
        Self(angle: angle.isFinite ? min(45, max(8, angle)) : 18,
             window: window.isFinite ? min(1, max(0.15, window)) : 0.45)
    }
}

/// Level → left threshold → right threshold, within one sensor-clock window.
/// A completed gesture must return to level before it can toggle again.
struct DrawingTiltTrigger: Sendable {
    enum Phase: Sendable { case ready, waitingForRight, returnToLevel }
    private(set) var phase = Phase.ready
    private var neutralAt: Double?
    private var startedAt: Double?
    private var leftAt: Double?
    private var neutralSince: Double?
    private var blockedUntil = 0.0
    private var previousRoll: Float = 0

    mutating func reset(time: Double? = nil, requireNeutral: Bool = false) {
        self = Self(); neutralAt = time
        if requireNeutral { phase = .returnToLevel }
    }
    mutating func update(roll: Float, time: Double, settings: DrawingTriggerSettings) -> Bool {
        defer { previousRoll = roll }
        let settings = settings.bounded
        let nearLevel = abs(roll) <= min(4, settings.angle * 0.25)
        if nearLevel {
            if neutralSince == nil { neutralSince = time }
            if phase == .returnToLevel && time >= blockedUntil && time - (neutralSince ?? time) >= 0.12 { phase = .ready }
            if phase == .ready { neutralAt = time }
        } else { neutralSince = nil }
        guard phase != .returnToLevel else { return false }
        if phase == .waitingForRight {
            guard let startedAt, time - startedAt <= settings.window else {
                phase = .ready; self.startedAt = nil; leftAt = nil; neutralAt = nil
                return false
            }
            if roll >= settings.angle && time - (leftAt ?? time) >= 0.04 {
                phase = .returnToLevel; blockedUntil = time + 0.25
                neutralAt = nil; self.startedAt = nil; leftAt = nil; neutralSince = nil
                return true
            }
        } else if roll <= -settings.angle && previousRoll > -settings.angle,
                  let neutralAt, time - neutralAt <= settings.window {
            startedAt = neutralAt; leftAt = time; phase = .waitingForRight
        }
        return false
    }
}

enum DrawingEvent: Sendable { case calibrated, penDown, penUp }

/// A virtual, damped pen sliding under g·sin(tilt), with paper-space units.
/// The comfortable reference pose is the virtual level; yaw alone adds no force.
struct DrawingEngine: Sendable {
    static let paperSize = SIMD2<Float>(1000, 750)
    static let pointLimit = 160_000
    private(set) var position = paperSize / 2
    private(set) var velocity = SIMD2<Float>.zero
    private(set) var tiltDegrees = SIMD2<Float>.zero // right / forward
    private(set) var isPenDown = false
    private(set) var isTracking = false
    private(set) var isCalibrated = false
    private(set) var isSettling = false
    private(set) var calibrationProgress = 0.0
    private(set) var strokes: [DrawingStroke] = []
    private(set) var pointCount = 0
    private(set) var tool = DrawingTool.pen
    private(set) var ink = DrawingInk.midnight
    var sensitivity: Float = 1
    private(set) var triggerSettings = DrawingTriggerSettings()
    var triggerPhase: DrawingTiltTrigger.Phase { trigger.phase }
    var speed: Float { simd_length(velocity) }
    var isFull: Bool { pointCount >= Self.pointLimit }
    private var pose: TiltPose?
    private var previousTime: Double?
    private var previousSequence: UInt64?
    private var trigger = DrawingTiltTrigger()
    private var activeStroke: Int?

    mutating func select(tool: DrawingTool) { activeStroke = nil; self.tool = tool }
    mutating func select(ink: DrawingInk) { activeStroke = nil; self.ink = ink }
    mutating func configureTrigger(_ settings: DrawingTriggerSettings) {
        let settings = settings.bounded
        guard settings != triggerSettings else { return }
        triggerSettings = settings
        trigger.reset(time: previousTime, requireNeutral: true)
        velocity = .zero; activeStroke = nil; isSettling = true
    }
    mutating func lift() { isPenDown = false; activeStroke = nil }
    mutating func center() { lift(); velocity = .zero; position = Self.paperSize / 2 }
    mutating func clear() { lift(); strokes.removeAll(); pointCount = 0 }
    mutating func undo() {
        lift()
        if let last = strokes.popLast() { pointCount -= last.points.count }
    }
    mutating func suspend() {
        lift(); velocity = .zero; tiltDegrees = .zero
        pose = nil; isCalibrated = false; isTracking = false; isSettling = false
        previousTime = nil; previousSequence = nil; calibrationProgress = 0; trigger.reset()
    }
    static func canCalibrate(_ sample: MotionSample) -> Bool {
        TiltPose.canCapture(sample)
    }
    @discardableResult mutating func calibrate(_ sample: MotionSample) -> Bool {
        guard Self.canCalibrate(sample) else { return false }
        lift(); velocity = .zero; tiltDegrees = .zero; trigger.reset(time: sample.timestamp)
        pose = TiltPose(sample); isCalibrated = true; isTracking = true; isSettling = false
        calibrationProgress = 1; previousTime = sample.timestamp; previousSequence = sample.sequence
        return true
    }

    @discardableResult mutating func update(_ sample: MotionSample) -> DrawingEvent? {
        guard sample.isValid else { suspend(); return nil }
        if let previousSequence, sample.sequence <= previousSequence { return nil }
        let dt = previousTime.map { sample.timestamp - $0 } ?? 0
        previousTime = sample.timestamp; previousSequence = sample.sequence
        guard dt > 0 && dt <= 0.2 else {
            lift(); velocity = .zero; activeStroke = nil; calibrationProgress = 0; trigger.reset(time: sample.timestamp, requireNeutral: true); isSettling = false
            return nil
        }
        guard let pose else {
            let steady = sample.gravity.z < -0.35 && sample.rotationRate.magnitude < 0.4 && sample.acceleration.magnitude < 0.12
            calibrationProgress = steady ? min(1, calibrationProgress + dt / 0.7) : 0
            if calibrationProgress >= 1 && calibrate(sample) { return .calibrated }
            return nil
        }
        let gravity = pose.gravity(sample)
        tiltDegrees = TiltPose.angles(gravity)
        isTracking = gravity.z < -0.087 // Keep the virtual paper within 85° of level.
        guard isTracking else { lift(); velocity = .zero; trigger.reset(requireNeutral: true); return nil }
        let toggled = trigger.update(roll: tiltDegrees.x, time: sample.timestamp, settings: triggerSettings)
        if toggled {
            if isPenDown { lift() } else if !isFull { isPenDown = true }
            activeStroke = nil
        }
        isSettling = trigger.phase != .ready
        if isSettling { velocity = .zero; activeStroke = nil }
        else {
            position += TiltPhysics.travel(gravity: gravity, velocity: &velocity, dt: dt, sensitivity: sensitivity)
            for axis in 0..<2 {
                let bounded = min(Self.paperSize[axis] - 18, max(18, position[axis]))
                if bounded != position[axis] { velocity[axis] = 0 }
                position[axis] = bounded
            }
            if isPenDown { appendInk() }
        }
        return toggled ? (isPenDown ? .penDown : .penUp) : nil
    }

    private mutating func appendInk() {
        guard !isFull else { lift(); return }
        let width = tool.width * (tool == .brush ? max(0.4, 1.3 - speed / 650) : 1)
        let point = DrawingPoint(position: position, width: width)
        if let activeStroke {
            guard let previous = strokes[activeStroke].points.last, simd_distance(previous.position, position) >= 0.7 else { return }
            strokes[activeStroke].points.append(point)
        } else {
            strokes.append(DrawingStroke(tool: tool, ink: ink, points: [point]))
            activeStroke = strokes.count - 1
        }
        pointCount += 1
    }
}
