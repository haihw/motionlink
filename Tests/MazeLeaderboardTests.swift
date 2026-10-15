import Foundation
import Testing
@testable import MotionLinkCore

private func scoreLocation() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("MotionLinkScores-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("scores.json")
}

@MainActor @Test("Leaderboard survives reopening and ranks fastest times separately for each maze")
func mazeLeaderboardPersistence() throws {
    let url = scoreLocation(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let board = MazeLeaderboard(fileURL: url)
    let slow = MazeFinish(mazeSeed: 42, elapsed: 35.123, deaths: 2)
    let fast = MazeFinish(mazeSeed: 42, elapsed: 18.765)
    try board.save(finish: slow, name: "Hai")
    try board.save(finish: fast, name: "Linh")
    try board.save(finish: MazeFinish(mazeSeed: 7, elapsed: 1.1), name: "An")
    let reopened = MazeLeaderboard(fileURL: url)
    #expect(!reopened.loadFailed && reopened.scores.count == 3)
    #expect(reopened.entries(for: 42).map(\.id) == [fast.id, slow.id])
    #expect(reopened.entries(for: 7).map(\.name) == ["An"])
}

@MainActor @Test("A completed run can only be saved once, even if name submission repeats")
func mazeLeaderboardDeduplication() throws {
    let url = scoreLocation(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let board = MazeLeaderboard(fileURL: url), finish = MazeFinish(mazeSeed: 42, elapsed: 25)
    let first = try board.save(finish: finish, name: "Hai")
    let second = try board.save(finish: finish, name: "Other name")
    #expect(first && !second && board.scores.count == 1 && board.scores[0].name == "Hai")
    let reopened = MazeLeaderboard(fileURL: url)
    let third = try reopened.save(finish: finish, name: "Duplicate")
    #expect(!third && reopened.scores.count == 1)
}

@MainActor @Test("Blank names and invalid times are rejected without changing saved scores")
func mazeLeaderboardValidation() throws {
    let url = scoreLocation(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let board = MazeLeaderboard(fileURL: url)
    let finish = MazeFinish(mazeSeed: 42, elapsed: 25)
    #expect(throws: (any Error).self) { try board.save(finish: finish, name: " \n\t ") }
    for time in [Double.nan, -Double.infinity, 0, -10, 604_800] {
        #expect(throws: (any Error).self) { try board.save(finish: MazeFinish(mazeSeed: 42, elapsed: time), name: "Hai") }
    }
    #expect(board.scores.isEmpty && !FileManager.default.fileExists(atPath: url.path))
    #expect(MazeScore.normalizedName("  Hải   Nguyễn\n ") == "Hải Nguyễn")
    #expect(MazeScore.normalizedName(String(repeating: "🐞", count: 30)).count == 24)
    #expect(MazeScore.normalizedName("A\u{0000}B") == "AB")
}

@MainActor @Test("Corrupt archives are preserved and cannot be silently overwritten")
func mazeLeaderboardCorruptArchive() throws {
    let url = scoreLocation(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let corrupt = Data("not leaderboard JSON".utf8); try corrupt.write(to: url)
    let board = MazeLeaderboard(fileURL: url)
    #expect(board.loadFailed)
    #expect(throws: (any Error).self) { try board.save(finish: MazeFinish(mazeSeed: 42, elapsed: 25), name: "Hai") }
    #expect(try Data(contentsOf: url) == corrupt)
    #expect(board.scores.isEmpty)
}

@MainActor @Test("A failed disk write never creates an in-memory success")
func mazeLeaderboardWriteFailure() throws {
    let url = scoreLocation(), parent = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: parent) }
    try Data("a file, not a folder".utf8).write(to: parent)
    let board = MazeLeaderboard(fileURL: url)
    #expect(throws: (any Error).self) { try board.save(finish: MazeFinish(mazeSeed: 42, elapsed: 25), name: "Hai") }
    #expect(board.scores.isEmpty)
}

@Test("Leaderboard time formatting rounds across minute boundaries and keeps hundredths")
func mazeLeaderboardTimeFormatting() {
    #expect(MazeFinish.time(12.345) == "00:12.35")
    #expect(MazeFinish.time(59.999) == "01:00.00")
    #expect(MazeFinish.time(125.7) == "02:05.70")
    #expect(MazeFinish.time(.nan) == "—")
}

@Test("Only escaped runs can produce a score; restart creates a fresh run ID")
func mazeFinishEligibility() {
    var game = LaserMazeEngine(); let oldID = game.runID
    #expect(MazeFinish(game: game) == nil)
    let sample = MotionSample(sequence: 0, timestamp: 0, attitude: .identity, rotationRate: .zero, acceleration: .zero, gravity: MotionVector(x: 0, y: 0, z: -1))
    game.calibrate(sample)
    for tick in 1...20 {
        var next = sample; next.sequence = UInt64(tick); next.timestamp = Double(tick) / 60; game.update(next)
    }
    for target in game.layout.route.dropFirst() { game.move(by: target - game.position) }
    #expect(MazeFinish(game: game)?.id == oldID)
    game.restart()
    #expect(game.runID != oldID && MazeFinish(game: game) == nil)
}
