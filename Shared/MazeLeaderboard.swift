import Foundation
import Observation

struct MazeFinish: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let mazeSeed: UInt64
    let elapsed: Double
    let deaths: Int
    let completedAt: Date
    var isValid: Bool {
        elapsed.isFinite && elapsed > 0 && elapsed < 604_800 && (0..<1_000_000).contains(deaths)
            && completedAt.timeIntervalSince1970.isFinite && completedAt.timeIntervalSince1970 >= 0
    }
    init?(game: LaserMazeEngine, date: Date = Date()) {
        guard game.phase == .escaped else { return nil }
        self.init(id: game.runID, mazeSeed: game.layout.seed, elapsed: game.elapsed, deaths: game.deaths, completedAt: date)
        guard isValid else { return nil }
    }
    init(id: UUID = UUID(), mazeSeed: UInt64, elapsed: Double, deaths: Int = 0, completedAt: Date = Date()) {
        self.id = id; self.mazeSeed = mazeSeed; self.elapsed = elapsed; self.deaths = deaths; self.completedAt = completedAt
    }
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite && (0..<604_800).contains(seconds) else { return "—" }
        let hundredths = Int((seconds * 100).rounded())
        return String(format: "%02d:%02d.%02d", hundredths / 6000, (hundredths % 6000) / 100, hundredths % 100)
    }
}

struct MazeScore: Codable, Sendable, Identifiable, Equatable {
    let finish: MazeFinish
    let name: String
    var id: UUID { finish.id }
    var isValid: Bool { finish.isValid && !name.isEmpty && name == Self.normalizedName(name) }
    static func normalizedName(_ raw: String) -> String {
        let line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let scalars = line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String(String.UnicodeScalarView(scalars)).prefix(24)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func faster(_ a: Self, _ b: Self) -> Bool {
        if a.finish.elapsed != b.finish.elapsed { return a.finish.elapsed < b.finish.elapsed }
        if a.finish.completedAt != b.finish.completedAt { return a.finish.completedAt < b.finish.completedAt }
        return a.id.uuidString < b.id.uuidString
    }
}

/// Small local JSON store. Commit in memory only after the atomic disk write succeeds.
@MainActor @Observable
final class MazeLeaderboard {
    private struct Archive: Codable { var version = 1; var scores: [MazeScore] }
    enum StoreError: Error { case invalidScore, unreadableArchive }
    private(set) var scores: [MazeScore] = []
    private(set) var loadFailed = false
    @ObservationIgnored let fileURL: URL
    var lastPlayerName: String { scores.max(by: { $0.finish.completedAt < $1.finish.completedAt })?.name ?? "" }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MotionLink", isDirectory: true).appendingPathComponent("maze-leaderboard.json")
        reload()
    }
    func reload() {
        do {
            if !FileManager.default.fileExists(atPath: fileURL.path) { scores = []; loadFailed = false; return }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
            guard archive.version == 1, archive.scores.count <= 2000, archive.scores.allSatisfy(\.isValid),
                  Set(archive.scores.map(\.id)).count == archive.scores.count else { throw StoreError.unreadableArchive }
            scores = archive.scores.sorted(by: MazeScore.faster); loadFailed = false
        } catch { loadFailed = true }
    }
    func entries(for mazeSeed: UInt64) -> [MazeScore] { scores.filter { $0.finish.mazeSeed == mazeSeed } }
    func contains(_ id: UUID) -> Bool { scores.contains { $0.id == id } }

    @discardableResult func save(finish: MazeFinish, name: String) throws -> Bool {
        if loadFailed { reload(); if loadFailed { throw StoreError.unreadableArchive } }
        let score = MazeScore(finish: finish, name: MazeScore.normalizedName(name))
        guard score.isValid else { throw StoreError.invalidScore }
        guard !contains(score.id) else { return false }
        var updated = scores + [score]
        // Retain the fastest 100 per course, then the fastest 2,000 overall.
        var perMaze: [UInt64: Int] = [:]
        updated = updated.sorted(by: MazeScore.faster).filter {
            let count = perMaze[$0.finish.mazeSeed, default: 0]; perMaze[$0.finish.mazeSeed] = count + 1
            return count < 100
        }
        updated = Array(updated.prefix(2000))
        let data = try JSONEncoder().encode(Archive(scores: updated))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        scores = updated
        return true
    }
}
