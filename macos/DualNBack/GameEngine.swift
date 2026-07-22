import Foundation
import Combine

enum ResponseType { case visual, audio }

struct AccuracySummary: Equatable {
    var visual = 0
    var audio = 0
    var total = 0
}

struct LevelNote: Equatable {
    let message: String
    let isDown: Bool
}

/// Direct port of the DualNBack class from the Electron renderer.
/// All state updates happen on the main thread (timers on the main run loop).
final class GameEngine: ObservableObject {
    static let audioLetters = ["C", "H", "K", "L", "Q", "R", "S", "T"]

    // MARK: Settings (persisted like localStorage lastNLevel/lastSpeed/…)

    @Published var nLevel: Int { didSet { saveSettings() } }
    @Published var speedMs: Int { didSet { saveSettings() } }
    @Published var sessionMinutes: Int { didSet { saveSettings() } }
    @Published var autoLevel: Bool { didSet { saveSettings() } }

    // MARK: Live state

    @Published private(set) var isRunning = false
    @Published private(set) var idlePaused = false
    @Published private(set) var round = 0
    @Published private(set) var activeSquare: Int?
    @Published private(set) var accuracy = AccuracySummary()
    @Published private(set) var timerText = "Ready to start"
    @Published private(set) var progress: Double = 0
    @Published private(set) var instructions =
        "Press Start to begin training. Match visual positions and audio letters from N steps back."
    @Published private(set) var levelNotification: LevelNote?
    @Published private(set) var records: [TrainingRecord]

    let audio = AudioController()

    // MARK: Internals

    private struct Stimulus {
        let visual: Int
        let audio: String
    }

    private var sequence: [Stimulus] = []
    private var visualResponses: [Bool] = []
    private var audioResponses: [Bool] = []

    private let levelUpThreshold = 80       // % accuracy needed to level up
    private let levelDownThreshold = 60     // % accuracy needed to level down
    private let minTrialsForLevelChange = 15

    private var sessionStartTime: Date?
    private var sessionDuration: TimeInterval = 0
    private var idlePausedAt: Date?

    private var roundTimer: Timer?
    private var sessionTimer: Timer?
    private var stimulusClearTimer: Timer?
    private var notificationTimer: Timer?
    private var resetTimer: Timer?

    /// Timestamp of the last "valid input" (A/L/Space/buttons) — feeds both
    /// the anti-AFK pause and the LockManager heartbeat.
    private(set) var lastInputAt = Date()

    private let store = RecordsStore()

    init() {
        let d = UserDefaults.standard
        nLevel = d.object(forKey: "lastNLevel") as? Int ?? 2
        speedMs = d.object(forKey: "lastSpeed") as? Int ?? 2500
        sessionMinutes = d.object(forKey: "lastSessionTime") as? Int ?? 20
        autoLevel = d.object(forKey: "lastAutoLevel") as? Bool ?? true
        records = store.load()
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(nLevel, forKey: "lastNLevel")
        d.set(speedMs, forKey: "lastSpeed")
        d.set(sessionMinutes, forKey: "lastSessionTime")
        d.set(autoLevel, forKey: "lastAutoLevel")
    }

    var secondsSinceLastInput: TimeInterval {
        Date().timeIntervalSince(lastInputAt)
    }

    func markInput() {
        lastInputAt = Date()
        if idlePaused { resumeFromIdle() }
    }

    // MARK: Game control

    func toggleGame() {
        if isRunning { stopGame() } else { startGame() }
    }

    func startGame() {
        isRunning = true
        round = 0
        sequence = []
        visualResponses = []
        audioResponses = []
        accuracy = AccuracySummary()
        resetTimer?.invalidate()

        sessionDuration = TimeInterval(sessionMinutes * 60)
        sessionStartTime = Date()

        instructions = "\(nLevel)-Back Training in Progress..."
        startSessionTimer()
        nextRound()
    }

    func stopGame() {
        guard isRunning else { return }
        isRunning = false
        invalidateGameTimers()

        // Save a record if we've completed at least a few rounds.
        if round >= nLevel {
            saveTrainingRecord(calculateAccuracy())
        }

        instructions = "Game stopped. Press Start to begin training."
        timerText = "Ready to start"
        progress = 0
        activeSquare = nil
        accuracy = calculateAccuracy()
    }

    private func endSession() {
        isRunning = false
        invalidateGameTimers()

        timerText = "Session Complete!"
        let acc = calculateAccuracy()
        accuracy = acc
        instructions = "Training Session Complete! \(round) rounds completed. Total Score: \(acc.total)%"
        activeSquare = nil

        saveTrainingRecord(acc)

        resetTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self, !self.isRunning else { return }
            self.timerText = "Ready to start"
            self.progress = 0
        }
    }

    private func invalidateGameTimers() {
        roundTimer?.invalidate()
        sessionTimer?.invalidate()
        stimulusClearTimer?.invalidate()
        roundTimer = nil
        sessionTimer = nil
        stimulusClearTimer = nil
    }

    // MARK: Session timer

    private func startSessionTimer() {
        updateTimer()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateTimer()
        }
    }

    private func updateTimer() {
        guard let start = sessionStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = max(0, sessionDuration - elapsed)

        if remaining == 0 {
            endSession()
            return
        }

        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        timerText = String(format: "%d:%02d remaining", minutes, seconds)
        progress = (sessionDuration - remaining) / sessionDuration
    }

    // MARK: Rounds

    private func nextRound() {
        guard isRunning else { return }

        round += 1

        let visualPos = Int.random(in: 0..<9)
        let letter = Self.audioLetters.randomElement()!
        sequence.append(Stimulus(visual: visualPos, audio: letter))
        visualResponses.append(false)
        audioResponses.append(false)

        showStimuli(visualPos: visualPos, letter: letter)

        roundTimer?.invalidate()
        roundTimer = Timer.scheduledTimer(withTimeInterval: Double(speedMs) / 1000, repeats: false) { [weak self] _ in
            self?.nextRound()
        }
    }

    private func showStimuli(visualPos: Int, letter: String) {
        activeSquare = visualPos
        audio.speakLetter(letter)

        stimulusClearTimer?.invalidate()
        stimulusClearTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.activeSquare = nil
        }
    }

    // MARK: Responses

    func recordResponse(_ type: ResponseType) {
        guard isRunning else {
            audio.playNotReady()
            return
        }
        guard round >= nLevel else {
            audio.playTooEarly()
            return
        }

        let current = round - 1
        let target = current - nLevel
        guard current >= 0, target >= 0, current < sequence.count, target < sequence.count else {
            audio.playError()
            return
        }

        let isCorrect: Bool
        switch type {
        case .visual:
            isCorrect = sequence[current].visual == sequence[target].visual
            visualResponses[current] = true
        case .audio:
            isCorrect = sequence[current].audio == sequence[target].audio
            audioResponses[current] = true
        }

        // Immediate feedback + real-time stats.
        audio.playFeedback(correct: isCorrect)
        accuracy = calculateAccuracy()

        if autoLevel && round >= nLevel + minTrialsForLevelChange {
            checkAutoLevel()
        }
    }

    // MARK: Auto level

    private func checkAutoLevel() {
        let total = calculateAccuracy().total
        if total >= levelUpThreshold && nLevel < 12 {
            changeLevel(by: 1)
        } else if total < levelDownThreshold && nLevel > 1 {
            changeLevel(by: -1)
        }
    }

    private func changeLevel(by delta: Int) {
        nLevel += delta
        let isDown = delta < 0
        let message = isDown
            ? "Level Down: Now playing \(nLevel)-Back"
            : "Level Up! Now playing \(nLevel)-Back"
        levelNotification = LevelNote(message: message, isDown: isDown)

        notificationTimer?.invalidate()
        notificationTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.levelNotification = nil
        }
    }

    // MARK: Accuracy
    // Every round from nLevel onward counts: correct means "responded exactly
    // when there was a match" (non-response on non-match is also correct).

    func calculateAccuracy() -> AccuracySummary {
        var visualCorrect = 0, audioCorrect = 0
        var visualTotal = 0, audioTotal = 0

        guard sequence.count > nLevel else { return AccuracySummary() }
        for i in nLevel..<sequence.count {
            let target = i - nLevel

            let visualMatch = sequence[i].visual == sequence[target].visual
            visualTotal += 1
            if visualMatch == visualResponses[i] { visualCorrect += 1 }

            let audioMatch = sequence[i].audio == sequence[target].audio
            audioTotal += 1
            if audioMatch == audioResponses[i] { audioCorrect += 1 }
        }

        func pct(_ correct: Int, _ total: Int) -> Int {
            total > 0 ? Int((Double(correct) / Double(total) * 100).rounded()) : 0
        }
        return AccuracySummary(
            visual: pct(visualCorrect, visualTotal),
            audio: pct(audioCorrect, audioTotal),
            total: pct(visualCorrect + audioCorrect, visualTotal + audioTotal)
        )
    }

    // MARK: Idle pause (lock anti-AFK)

    func pauseForIdle() {
        guard isRunning, !idlePaused else { return }
        idlePaused = true
        idlePausedAt = Date()
        roundTimer?.invalidate()
        sessionTimer?.invalidate()
    }

    func resumeFromIdle() {
        guard idlePaused else { return }
        idlePaused = false
        // Shift the free-play session clock so paused time doesn't count against it.
        if let pausedAt = idlePausedAt, let start = sessionStartTime {
            sessionStartTime = start.addingTimeInterval(Date().timeIntervalSince(pausedAt))
        }
        idlePausedAt = nil
        startSessionTimer()
        nextRound()
    }

    // MARK: Records

    private func saveTrainingRecord(_ acc: AccuracySummary) {
        let actualMinutes: Int
        if let start = sessionStartTime {
            actualMinutes = Int((Date().timeIntervalSince(start) / 60).rounded())
        } else {
            actualMinutes = 0
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium

        let record = TrainingRecord(
            date: formatter.string(from: Date()),
            nLevel: nLevel,
            plannedTime: sessionMinutes,
            actualTime: actualMinutes,
            rounds: round,
            positionAccuracy: acc.visual,
            audioAccuracy: acc.audio,
            totalAccuracy: acc.total,
            speed: speedMs,
            autoLevel: autoLevel
        )

        records.insert(record, at: 0)
        if records.count > 50 { records = Array(records.prefix(50)) }
        store.save(records)
    }

    func clearRecords() {
        records = []
        store.save(records)
    }

    // MARK: Test audio

    func testAudio() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.audio.playFeedback(correct: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.audio.playFeedback(correct: false)
        }
        for (index, letter) in ["C", "H", "K", "L"].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(index) * 0.8) { [weak self] in
                self?.audio.speakLetter(letter)
            }
        }
    }

    deinit {
        invalidateGameTimers()
        notificationTimer?.invalidate()
        resetTimer?.invalidate()
    }
}
