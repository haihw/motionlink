import simd
import Testing
@testable import MotionLinkCore

private func mazeSample(_ tick: Int, rotation: MotionQuaternion = .identity) -> MotionSample {
    MotionSample(sequence: UInt64(tick), timestamp: Double(tick) / 60, attitude: rotation,
                 rotationRate: .zero, acceleration: .zero, gravity: MotionVector(x: 0, y: 0, z: -1))
}
private func playingMaze() -> LaserMazeEngine {
    var game = LaserMazeEngine(); game.calibrate(mazeSample(0))
    for tick in 1...20 { game.update(mazeSample(tick)) }
    return game
}

@Test("Every generated maze has a contiguous safe route from START to EXIT", arguments: [UInt64(0), 1, 7, 42, 999, UInt64.max])
func laserMazeRoutes(seed: UInt64) {
    let maze = LaserMazeLayout(seed: seed)
    #expect(maze.route.first == maze.start && maze.route.last == maze.goal)
    #expect(maze.route.count >= 13 && Set(maze.walls.map(\.id)).count == maze.walls.count)
    for (start, end) in zip(maze.route, maze.route.dropFirst()) {
        #expect(abs(simd_distance(start, end) - LaserMazeLayout.cellSize) < 0.001)
        #expect(maze.firstContact(from: start, to: end, radius: LaserMazeEngine.bugRadius) == nil)
    }
    #expect(maze.walls.map(\.a) == LaserMazeLayout(seed: seed).walls.map(\.a))
    #expect(maze.route == LaserMazeLayout(seed: seed).route)
}

@Test("Laser sweeps catch fast crossings, body contact, and endpoints while allowing near misses")
func laserSweptCollision() {
    let wall = LaserWall(id: 0, a: [100, 100], b: [100, 200])
    let crossing = wall.firstContact(from: [0, 150], to: [300, 150], radius: 10)
    #expect(crossing != nil && abs(crossing! - 87.0 / 300) < 0.001)
    #expect(wall.firstContact(from: [88, 120], to: [88, 180], radius: 10) == 0)
    #expect(wall.firstContact(from: [86, 120], to: [86, 180], radius: 10) == nil)
    #expect(wall.firstContact(from: [0, 90], to: [200, 90], radius: 10) != nil)
    #expect(wall.firstContact(from: [0, 86], to: [200, 86], radius: 10) == nil)
    #expect(wall.firstContact(from: [80, 150], to: [80, 150], radius: 10) == nil)
    let horizontal = LaserWall(id: 1, a: [200, 100], b: [100, 100])
    #expect(horizontal.firstContact(from: [150, 0], to: [150, 300], radius: 10) != nil)
}

@Test("The first laser hit burns once, then respawns at START and waits for neutral")
func laserBurnAndRespawn() {
    var game = playingMaze()
    #expect(game.phase == .playing)
    let event = game.move(by: [-300, 0])
    #expect(event == .burned && game.phase == .burning && game.deaths == 1)
    #expect(abs(game.position.x - (LaserMazeEngine.bugRadius + LaserWall.coreRadius)) < 0.001)
    let secondHit = game.move(by: [-300, 0])
    #expect(secondHit == nil && game.deaths == 1)
    var respawns = 0
    let heldTilt = MotionQuaternion(simd_quatf(angle: -0.4, axis: SIMD3<Float>(0, 1, 0)))
    for tick in 21..<100 { if game.update(mazeSample(tick, rotation: heldTilt)) == .respawned { respawns += 1 } }
    #expect(respawns == 1 && game.position == game.layout.start && game.attempt == 2)
    #expect(game.phase == .ready && game.speed == 0 && game.deaths == 1)
    for tick in 100..<120 { game.update(mazeSample(tick)) }
    #expect(game.phase == .playing)
}

@Test("Following the safe route reaches EXIT and freezes the completed run")
func laserMazeEscape() {
    var game = playingMaze()
    for target in game.layout.route.dropFirst() { game.move(by: target - game.position) }
    #expect(game.phase == .escaped && game.deaths == 0 && game.attempt == 1)
    let position = game.position, time = game.elapsed
    for tick in 21..<100 { game.update(mazeSample(tick)) }
    game.move(by: [-900, 0])
    #expect(game.phase == .escaped && game.position == position && game.elapsed == time)
}

@Test("Fast movement cannot tunnel through a laser on its way toward the exit")
func laserNoTunneling() {
    var game = playingMaze()
    let event = game.move(by: [0, -2000])
    #expect(event == .burned && game.deaths == 1 && game.phase == .burning)
    #expect(game.position.y > 0)
}

@Test("Maze steering shares drawing physics but does not run the drawing trigger")
func laserDrawingControlParity() {
    var game = playingMaze(), pen = DrawingEngine()
    pen.configureTrigger(.init(angle: 45)); pen.calibrate(mazeSample(20))
    let mazeOrigin = game.position, penOrigin = pen.position
    let tilt = MotionQuaternion(simd_quatf(angle: -0.12, axis: SIMD3<Float>(0, 1, 0)))
    pen.sensitivity = game.sensitivity
    for tick in 21...26 { game.update(mazeSample(tick, rotation: tilt)); pen.update(mazeSample(tick, rotation: tilt)) }
    #expect(simd_distance(game.position - mazeOrigin, pen.position - penOrigin) < 0.001)
    #expect(simd_distance(game.velocity, pen.velocity) < 0.001)
    #expect(game.position.x < mazeOrigin.x && game.phase == .playing)
}

@Test("Natural pose, gaps, duplicate samples, and reconnect do not teleport or kill the bug")
func laserInputLifecycle() {
    var game = playingMaze()
    let start = game.position
    let rotation = MotionQuaternion(simd_quatf(angle: 0.08, axis: SIMD3<Float>(0, 1, 0)))
    game.update(mazeSample(21, rotation: rotation))
    let position = game.position
    for _ in 0..<10 { game.update(mazeSample(21, rotation: rotation)) }
    #expect(game.position == position)
    game.update(mazeSample(60, rotation: rotation))
    #expect(game.phase == .ready && game.position == position && game.speed == 0 && game.deaths == 0)
    game.suspend()
    #expect(!game.isCalibrated && game.position == position)
    var upright = mazeSample(61)
    upright.attitude = MotionQuaternion(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0)))
    upright.gravity = MotionVector(x: 0, y: -1, z: 0)
    let captured = game.calibrate(upright)
    #expect(captured && game.position == position && game.tiltDegrees == .zero)
    #expect(game.position != start)
}

@Test("Restart clears a run and new mazes retain the calibrated grip and sensitivity")
func laserRestart() {
    var game = playingMaze(); game.sensitivity = 0.8
    game.move(by: [-300, 0]); game.restart()
    #expect(game.position == game.layout.start && game.phase == .ready && game.deaths == 0 && game.attempt == 1)
    #expect(game.isCalibrated && game.sensitivity == 0.8 && game.elapsed == 0)
    let route = game.layout.route
    game.restart(seed: 7)
    #expect(game.layout.seed == 7 && game.layout.route != route && game.isCalibrated)
}
