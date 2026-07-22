import AppKit
import Combine

/// State machine + timing authority — port of src/main/lock-manager.js.
/// Publishes UI state directly (replaces Electron IPC push).
final class LockManager: ObservableObject {
    enum Mode {
        case idle, locked, degraded
    }

    enum SkipError: Error {
        case notLocked, skipPending, quotaExhausted, wrongPhrase, dayBoundary

        var message: String {
            switch self {
            case .wrongPhrase: return "句子不一致,请一字不差地输入"
            case .quotaExhausted: return "本周跳过次数已用完"
            case .notLocked: return "当前未锁定"
            case .skipPending: return "跳过正在等待中"
            case .dayBoundary: return "临近午夜,新的一天即将开始,请明天再试"
            }
        }
    }

    private static let degradedInterval: TimeInterval = 60 * 60 // no kiosk retry for 1 hour
    private static let persistInterval: TimeInterval = 5        // flush progress every 5s
    private static let dateCheckInterval: TimeInterval = 60     // day-rollover check every 60s

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var skipsRemaining = 0
    @Published private(set) var pausedForIdle = false
    @Published private(set) var unlocked = false

    private(set) var state: LockState
    let config: LockConfig
    weak var game: GameEngine?

    private let stateDir: URL
    private let isLockEnabled: () -> Bool
    private let onUnlocked: () -> Void
    private let kiosk: KioskController

    private var degradedUntil: Date?
    private var lastHeartbeatAt: Date?
    private var dirty = false
    private var skipWork: DispatchWorkItem?
    private var timers: [Timer] = []

    var isLocked: Bool { mode == .locked }

    init(stateDir: URL,
         configOverrides: [String: Double]?,
         isLockEnabled: @escaping () -> Bool,
         onUnlocked: @escaping () -> Void,
         kiosk: KioskController) {
        self.stateDir = stateDir
        self.isLockEnabled = isLockEnabled
        self.onUnlocked = onUnlocked
        self.kiosk = kiosk

        self.state = LockStateStore.load(dir: stateDir)
        var cfg = state.config
        if let overrides = configOverrides { cfg.apply(overrides: overrides) }
        self.config = cfg
    }

    func initialize() {
        state.recordLaunch()
        let wouldLock = isLockEnabled() && !state.isCompletedToday()
        if wouldLock && state.isCrashLooping() {
            degradedUntil = Date().addingTimeInterval(Self.degradedInterval) // fail-open
        }
        LockStateStore.save(dir: stateDir, state)

        timers.append(Timer.scheduledTimer(withTimeInterval: Self.dateCheckInterval, repeats: true) { [weak self] _ in
            self?.evaluateLock()
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: Self.persistInterval, repeats: true) { [weak self] _ in
            self?.flushState()
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.heartbeatTick()
        })

        // Re-evaluate on wake / screen unlock (parity with powerMonitor).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.evaluateLock() }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.evaluateLock() }

        evaluateLock()
        publishState()
    }

    // MARK: State machine

    func evaluateLock() {
        state.ensureToday()
        if let until = degradedUntil, Date() < until {
            if mode != .degraded {
                mode = .degraded
                kiosk.destroy()
                onUnlocked() // surface a normal window so the banner is visible
            }
            return
        }
        if !isLockEnabled() || state.isCompletedToday() {
            if mode == .locked { kiosk.destroy() }
            mode = .idle
            return
        }
        if mode != .locked {
            mode = .locked
            kiosk.create()
        }
    }

    // MARK: Heartbeat (1s)

    private func heartbeatTick() {
        let now = Date()
        let delta = LockState.clampHeartbeatDelta(last: lastHeartbeatAt, now: now)
        lastHeartbeatAt = now

        guard let game else {
            publishState()
            return
        }

        let idleFor = now.timeIntervalSince(game.lastInputAt)
        let activelyTraining = game.isRunning && !game.idlePaused && idleFor < config.idleThresholdSeconds

        if activelyTraining {
            let done = state.accumulate(delta, now: now, config: config)
            dirty = true
            if done && !state.isCompletedToday() {
                complete()
            }
        }

        // Anti-AFK: pause the game clock when locked and idle past threshold.
        if mode == .locked, game.isRunning, !game.idlePaused, idleFor >= config.idleThresholdSeconds {
            game.pauseForIdle()
        }

        publishState()
    }

    private func publishState() {
        state.ensureToday()
        remainingSeconds = Int(ceil(state.remainingSeconds(config: config)))
        skipsRemaining = state.skipsRemaining(now: Date(), config: config)
        if let game {
            pausedForIdle = game.isRunning &&
                Date().timeIntervalSince(game.lastInputAt) >= config.idleThresholdSeconds
        } else {
            pausedForIdle = false
        }
        unlocked = state.isCompletedToday()
    }

    // MARK: Completion

    private func complete() {
        skipWork?.cancel()
        skipWork = nil
        state.recordCompletion()
        LockStateStore.save(dir: stateDir, state)
        publishState()
        // Let the "完成" banner breathe for 3s, then hand back the machine.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.kiosk.destroy()
            self.mode = .idle
            self.onUnlocked()
        }
    }

    // MARK: Emergency skip

    func requestSkip(phrase: String) -> Result<Double, SkipError> {
        guard mode == .locked else { return .failure(.notLocked) }
        guard skipWork == nil else { return .failure(.skipPending) }
        guard state.skipsRemaining(now: Date(), config: config) > 0 else {
            return .failure(.quotaExhausted)
        }
        guard phrase == config.skipPhrase else { return .failure(.wrongPhrase) }
        let now = Date()
        if LockState.localDateString(now) !=
            LockState.localDateString(now.addingTimeInterval(config.skipWaitSeconds)) {
            return .failure(.dayBoundary)
        }
        // Skip is recorded only when the mandatory wait completes (kill+relaunch
        // during the wait keeps the lock and does not burn quota).
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.skipWork = nil
            self.state.recordSkip()
            LockStateStore.save(dir: self.stateDir, self.state)
            self.publishState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.kiosk.destroy()
                self.mode = .idle
                self.onUnlocked()
            }
        }
        skipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.skipWaitSeconds, execute: work)
        return .success(config.skipWaitSeconds)
    }

    // MARK: Agent toggle

    /// Returns the new installed state. Refuses while locked: disabling the
    /// agent would tear down the kiosk (lock escape).
    func setAgentEnabled(_ enabled: Bool) -> Bool {
        if isLocked { return LaunchAgentInstaller.isInstalled }
        if enabled {
            LaunchAgentInstaller.install()
        } else {
            LaunchAgentInstaller.uninstall()
        }
        evaluateLock()
        return LaunchAgentInstaller.isInstalled
    }

    // MARK: Persistence

    func flushState() {
        guard dirty else { return }
        dirty = false
        LockStateStore.save(dir: stateDir, state)
    }
}
