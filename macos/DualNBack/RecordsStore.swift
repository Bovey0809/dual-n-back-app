import Foundation

enum FileLocations {
    /// ~/Library/Application Support/DualNBack — training records + lock state.
    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("DualNBack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

struct TrainingRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: String
    let nLevel: Int
    let plannedTime: Int
    let actualTime: Int
    let rounds: Int
    let positionAccuracy: Int
    let audioAccuracy: Int
    let totalAccuracy: Int
    let speed: Int
    let autoLevel: Bool
}

/// JSON persistence for training records (replaces renderer localStorage).
final class RecordsStore {
    private var url: URL {
        FileLocations.appSupportDir.appendingPathComponent("records.json")
    }

    func load() -> [TrainingRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TrainingRecord].self, from: data)) ?? []
    }

    func save(_ records: [TrainingRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
