import Foundation

// Persistent lock state — direct port of src/main/lock-state.js.
// The JSON shape (camelCase keys) matches the Electron version.

struct LockConfig: Codable, Equatable {
    var dailyMinutes: Double = 20
    var idleThresholdSeconds: Double = 90
    var skipsPerWeek: Double = 2
    var skipWaitSeconds: Double = 60
    var skipPhrase: String = "我承认我今天没有完成训练,我欠自己20分钟"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = LockConfig()
        dailyMinutes = try c.decodeIfPresent(Double.self, forKey: .dailyMinutes) ?? def.dailyMinutes
        idleThresholdSeconds = try c.decodeIfPresent(Double.self, forKey: .idleThresholdSeconds) ?? def.idleThresholdSeconds
        skipsPerWeek = try c.decodeIfPresent(Double.self, forKey: .skipsPerWeek) ?? def.skipsPerWeek
        skipWaitSeconds = try c.decodeIfPresent(Double.self, forKey: .skipWaitSeconds) ?? def.skipWaitSeconds
        skipPhrase = try c.decodeIfPresent(String.self, forKey: .skipPhrase) ?? def.skipPhrase
    }

    /// Numeric overrides from `--test-lock key=value,...` (in-memory only).
    mutating func apply(overrides: [String: Double]) {
        for (key, value) in overrides {
            switch key {
            case "dailyMinutes": dailyMinutes = value
            case "idleThresholdSeconds": idleThresholdSeconds = value
            case "skipsPerWeek": skipsPerWeek = value
            case "skipWaitSeconds": skipWaitSeconds = value
            default: break
            }
        }
    }
}

struct LockState: Codable {
    var progressDate: String
    var progressSecondsToday: Double
    var lastCompletedDate: String?
    var skips: [String]
    var recentLaunches: [String]
    var config: LockConfig

    // MARK: Date helpers

    static func localDateString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseISO(_ s: String) -> Date? {
        isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
    }

    static func isoString(_ d: Date) -> String {
        isoWithFraction.string(from: d)
    }

    // MARK: Construction / decoding

    static func makeDefault(now: Date = Date()) -> LockState {
        LockState(
            progressDate: localDateString(now),
            progressSecondsToday: 0,
            lastCompletedDate: nil,
            skips: [],
            recentLaunches: [],
            config: LockConfig()
        )
    }

    init(progressDate: String, progressSecondsToday: Double, lastCompletedDate: String?,
         skips: [String], recentLaunches: [String], config: LockConfig) {
        self.progressDate = progressDate
        self.progressSecondsToday = progressSecondsToday
        self.lastCompletedDate = lastCompletedDate
        self.skips = skips
        self.recentLaunches = recentLaunches
        self.config = config
    }

    // Tolerant decoding (parity with normalize() in lock-state.js).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = LockState.makeDefault()
        progressDate = try c.decodeIfPresent(String.self, forKey: .progressDate) ?? def.progressDate
        progressSecondsToday = try c.decodeIfPresent(Double.self, forKey: .progressSecondsToday) ?? 0
        lastCompletedDate = try c.decodeIfPresent(String.self, forKey: .lastCompletedDate) ?? nil
        skips = try c.decodeIfPresent([String].self, forKey: .skips) ?? []
        recentLaunches = try c.decodeIfPresent([String].self, forKey: .recentLaunches) ?? []
        config = try c.decodeIfPresent(LockConfig.self, forKey: .config) ?? LockConfig()
    }

    // MARK: Progress

    mutating func ensureToday(now: Date = Date()) {
        let today = Self.localDateString(now)
        if progressDate != today {
            progressDate = today
            progressSecondsToday = 0
        }
    }

    func isCompletedToday(now: Date = Date()) -> Bool {
        lastCompletedDate == Self.localDateString(now)
    }

    func remainingSeconds(config: LockConfig) -> Double {
        max(0, config.dailyMinutes * 60 - progressSecondsToday)
    }

    /// Returns true when the daily quota is fully accumulated.
    mutating func accumulate(_ deltaSeconds: Double, now: Date = Date(), config: LockConfig) -> Bool {
        ensureToday(now: now)
        progressSecondsToday += deltaSeconds
        return remainingSeconds(config: config) == 0
    }

    // MARK: Skips (rolling 7-day window)

    private static let weekSeconds: TimeInterval = 7 * 24 * 60 * 60

    func skipsRemaining(now: Date = Date(), config: LockConfig) -> Int {
        let used = skips
            .compactMap(Self.parseISO)
            .filter { now.timeIntervalSince($0) < Self.weekSeconds }
            .count
        return max(0, Int(config.skipsPerWeek) - used)
    }

    mutating func recordSkip(now: Date = Date()) {
        skips.append(Self.isoString(now))
        lastCompletedDate = Self.localDateString(now)
    }

    mutating func recordCompletion(now: Date = Date()) {
        lastCompletedDate = Self.localDateString(now)
    }

    // MARK: Crash-loop detection (spec §6 fail-open)

    private static let crashWindowSeconds: TimeInterval = 5 * 60
    private static let crashThreshold = 5

    mutating func recordLaunch(now: Date = Date()) {
        recentLaunches.append(Self.isoString(now))
        recentLaunches = Array(recentLaunches.suffix(10))
    }

    func isCrashLooping(now: Date = Date()) -> Bool {
        let recent = recentLaunches
            .compactMap(Self.parseISO)
            .filter { now.timeIntervalSince($0) < Self.crashWindowSeconds }
        return recent.count >= Self.crashThreshold
    }

    /// Heartbeat deltas are clamped to [0, 1] seconds so sleep/suspend gaps
    /// never count as training time.
    static func clampHeartbeatDelta(last: Date?, now: Date) -> Double {
        guard let last else { return 1 }
        return min(1, max(0, now.timeIntervalSince(last)))
    }
}

enum LockStateStore {
    static let filename = "lock-state.json"

    static func load(dir: URL, now: Date = Date()) -> LockState {
        let file = dir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .makeDefault(now: now)
        }
        do {
            let data = try Data(contentsOf: file)
            return try JSONDecoder().decode(LockState.self, from: data)
        } catch {
            // Corrupted file → keep .corrupt backup, rebuild "today incomplete, zero progress".
            let backup = dir.appendingPathComponent(filename + ".corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: file, to: backup)
            return .makeDefault(now: now)
        }
    }

    static func save(dir: URL, _ state: LockState) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: dir.appendingPathComponent(filename), options: .atomic)
    }
}
