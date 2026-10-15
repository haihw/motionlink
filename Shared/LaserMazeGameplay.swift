import Foundation
import simd

struct LaserWall: Identifiable, Sendable {
    let id: Int
    let a: SIMD2<Float>
    let b: SIMD2<Float>
    static let coreRadius: Float = 3

    /// Swept circle against a laser capsule, including its rounded endpoints.
    func firstContact(from start: SIMD2<Float>, to end: SIMD2<Float>, radius: Float) -> Float? {
        let r = radius + Self.coreRadius
        let lo = simd_min(a, b), hi = simd_max(a, b)
        let padding: SIMD2<Float> = abs(a.x - b.x) < 0.001 ? [r, 0] : [0, r]
        var enter: Float = 0, leave: Float = 1
        let delta = end - start
        for axis in 0..<2 {
            if abs(delta[axis]) < 0.000001 {
                if start[axis] < lo[axis] - padding[axis] || start[axis] > hi[axis] + padding[axis] { enter = 2; break }
            } else {
                let t1 = (lo[axis] - padding[axis] - start[axis]) / delta[axis]
                let t2 = (hi[axis] + padding[axis] - start[axis]) / delta[axis]
                enter = max(enter, min(t1, t2)); leave = min(leave, max(t1, t2))
            }
        }
        let strip: Float? = enter <= leave && enter <= 1 && leave >= 0 ? enter : nil
        return [strip, Self.circleContact(from: start, to: end, center: a, radius: r),
                Self.circleContact(from: start, to: end, center: b, radius: r)].compactMap { $0 }.min()
    }

    static func circleContact(from start: SIMD2<Float>, to end: SIMD2<Float>, center: SIMD2<Float>, radius: Float) -> Float? {
        let offset = start - center, delta = end - start
        let c = simd_dot(offset, offset) - radius * radius
        if c <= 0 { return 0 }
        let a = simd_dot(delta, delta)
        guard a > 0.000001 else { return nil }
        let b = 2 * simd_dot(offset, delta), discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return nil }
        let t = (-b - sqrt(discriminant)) / (2 * a)
        return (0...1).contains(t) ? t : nil
    }
}

struct LaserMazeLayout: Sendable {
    static let columns = 8, rows = 6
    static let cellSize: Float = 120
    static let size = SIMD2<Float>(960, 720)
    let seed: UInt64
    let walls: [LaserWall]
    let route: [SIMD2<Float>]
    var start: SIMD2<Float> { Self.center(Self.columns * (Self.rows - 1)) }
    var goal: SIMD2<Float> { Self.center(Self.columns - 1) }
    static func center(_ cell: Int) -> SIMD2<Float> {
        SIMD2(Float(cell % columns) + 0.5, Float(cell / columns) + 0.5) * cellSize
    }
    init(seed: UInt64 = 42) {
        self.seed = seed
        let count = Self.columns * Self.rows, root = Self.columns * (Self.rows - 1)
        var visited: Set<Int> = [root], stack = [root], parents: [Int: Int] = [:], openings: Set<Int> = []
        var random = seed == 0 ? UInt64(0xA51CE) : seed
        func edge(_ a: Int, _ b: Int) -> Int { min(a, b) * count + max(a, b) }
        while let cell = stack.last {
            let x = cell % Self.columns, y = cell / Self.columns
            var neighbors: [Int] = []
            if x > 0 { neighbors.append(cell - 1) }; if x + 1 < Self.columns { neighbors.append(cell + 1) }
            if y > 0 { neighbors.append(cell - Self.columns) }; if y + 1 < Self.rows { neighbors.append(cell + Self.columns) }
            neighbors.removeAll { visited.contains($0) }
            guard !neighbors.isEmpty else { stack.removeLast(); continue }
            random ^= random << 13; random ^= random >> 7; random ^= random << 17
            let next = neighbors[Int(random % UInt64(neighbors.count))]
            openings.insert(edge(cell, next)); parents[next] = cell; visited.insert(next); stack.append(next)
        }
        var walls: [LaserWall] = []
        for y in 0...Self.rows {
            for x in 0..<Self.columns {
                if y > 0 && y < Self.rows && openings.contains(edge((y - 1) * Self.columns + x, y * Self.columns + x)) { continue }
                walls.append(LaserWall(id: walls.count, a: SIMD2(Float(x), Float(y)) * Self.cellSize,
                                       b: SIMD2(Float(x + 1), Float(y)) * Self.cellSize))
            }
        }
        for x in 0...Self.columns {
            for y in 0..<Self.rows {
                if x > 0 && x < Self.columns && openings.contains(edge(y * Self.columns + x - 1, y * Self.columns + x)) { continue }
                walls.append(LaserWall(id: walls.count, a: SIMD2(Float(x), Float(y)) * Self.cellSize,
                                       b: SIMD2(Float(x), Float(y + 1)) * Self.cellSize))
            }
        }
        self.walls = walls
        var cells = [Self.columns - 1]
        while let previous = parents[cells.last!] { cells.append(previous) }
        route = cells.reversed().map(Self.center)
    }
    func firstContact(from start: SIMD2<Float>, to end: SIMD2<Float>, radius: Float) -> Float? {
        walls.compactMap { $0.firstContact(from: start, to: end, radius: radius) }.min()
    }
}

enum LaserMazePhase: Sendable { case ready, playing, burning, escaped }
enum LaserMazeEvent: Sendable { case calibrated, burned, respawned, escaped }

struct LaserMazeEngine: Sendable {
    static let bugRadius: Float = 24
    let runID = UUID()
    private(set) var layout: LaserMazeLayout
    private(set) var phase = LaserMazePhase.ready
    private(set) var position: SIMD2<Float>
    private(set) var velocity = SIMD2<Float>.zero
    private(set) var tiltDegrees = SIMD2<Float>.zero
    private(set) var heading: Float = 0
    private(set) var phaseAge = 0.0
    private(set) var elapsed = 0.0
    private(set) var deaths = 0
    private(set) var attempt = 1
    private(set) var neutralProgress = 0.0
    private(set) var calibrationProgress = 0.0
    private(set) var isTracking = false
    private(set) var trail: [SIMD2<Float>] = []
    var sensitivity: Float = 0.6
    var isCalibrated: Bool { pose != nil }
    var speed: Float { simd_length(velocity) }
    private var pose: TiltPose?
    private var previousTime: Double?
    private var previousSequence: UInt64?

    init(seed: UInt64 = 42) { let layout = LaserMazeLayout(seed: seed); self.layout = layout; position = layout.start }
    mutating func restart(seed: UInt64? = nil) {
        let oldPose = pose, oldTime = previousTime, oldSequence = previousSequence, gain = sensitivity
        self = Self(seed: seed ?? layout.seed)
        pose = oldPose; previousTime = oldTime; previousSequence = oldSequence; sensitivity = gain
        isTracking = oldPose != nil
    }
    mutating func suspend() {
        pose = nil; previousTime = nil; previousSequence = nil; velocity = .zero; tiltDegrees = .zero
        isTracking = false; calibrationProgress = 0; neutralProgress = 0
        if phase == .playing { phase = .ready; phaseAge = 0 }
    }
    @discardableResult mutating func calibrate(_ sample: MotionSample) -> Bool {
        guard TiltPose.canCapture(sample) else { return false }
        pose = TiltPose(sample); previousTime = sample.timestamp; previousSequence = sample.sequence
        velocity = .zero; tiltDegrees = .zero; neutralProgress = 0; calibrationProgress = 1; isTracking = true
        if phase == .playing { phase = .ready; phaseAge = 0 }
        return true
    }
    @discardableResult mutating func update(_ sample: MotionSample) -> LaserMazeEvent? {
        guard sample.isValid else { suspend(); return nil }
        if let previousSequence, sample.sequence <= previousSequence { return nil }
        let dt = previousTime.map { sample.timestamp - $0 } ?? 0
        previousTime = sample.timestamp; previousSequence = sample.sequence
        guard dt > 0 && dt <= 0.2 else {
            velocity = .zero; neutralProgress = 0; calibrationProgress = 0
            if phase == .playing { phase = .ready; phaseAge = 0 }
            return nil
        }
        guard let pose else {
            let steady = TiltPose.canCapture(sample) && sample.gravity.z < -0.35
                && sample.rotationRate.magnitude < 0.4 && sample.acceleration.magnitude < 0.12
            calibrationProgress = steady ? min(1, calibrationProgress + dt / 0.7) : 0
            if calibrationProgress >= 1 && calibrate(sample) { return .calibrated }
            return nil
        }
        let gravity = pose.gravity(sample)
        tiltDegrees = TiltPose.angles(gravity); isTracking = gravity.z < -0.087
        phaseAge += dt
        if phase == .escaped { return nil }
        if phase == .burning {
            elapsed += dt
            if phaseAge >= 0.85 {
                phase = .ready; phaseAge = 0; position = layout.start; heading = 0; velocity = .zero
                trail.removeAll(); neutralProgress = 0; attempt += 1
                return .respawned
            }
            return nil
        }
        guard isTracking else { velocity = .zero; neutralProgress = 0; phase = .ready; return nil }
        if phase == .ready {
            neutralProgress = simd_length(tiltDegrees) <= 4 ? min(1, neutralProgress + dt / 0.25) : 0
            if neutralProgress >= 1 { phase = .playing; phaseAge = 0 }
            return nil
        }
        elapsed += dt
        let travel = TiltPhysics.travel(gravity: gravity, velocity: &velocity, dt: dt, sensitivity: sensitivity)
        return move(by: travel)
    }

    /// Same swept collision path for sensor movement, deterministic replay, and tests.
    @discardableResult mutating func move(by travel: SIMD2<Float>) -> LaserMazeEvent? {
        guard phase == .playing, travel.x.isFinite, travel.y.isFinite else { return nil }
        let next = position + travel
        let collision = layout.firstContact(from: position, to: next, radius: Self.bugRadius)
        let exit = LaserWall.circleContact(from: position, to: next, center: layout.goal, radius: 26)
        if let collision, exit == nil || collision <= exit! {
            position += travel * collision; velocity = .zero; phase = .burning; phaseAge = 0; deaths += 1
            return .burned
        }
        if let exit {
            position += travel * exit; velocity = .zero; phase = .escaped; phaseAge = 0
            return .escaped
        }
        position = next
        if speed > 2 { heading = atan2(velocity.y, velocity.x) + .pi / 2 }
        if trail.last.map({ simd_distance($0, position) > 6 }) ?? true {
            trail.append(position); if trail.count > 100 { trail.removeFirst() }
        }
        return nil
    }
}
