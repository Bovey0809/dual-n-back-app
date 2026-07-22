import SwiftUI

/// SwiftUI port of src/renderer/index.html. One view serves both the normal
/// window (lockMode == false) and the kiosk window (lockMode == true).
struct ContentView: View {
    let lockMode: Bool

    @EnvironmentObject var game: GameEngine
    @EnvironmentObject var lock: LockManager

    // Emergency skip modal
    @State private var showSkipModal = false
    @State private var skipInput = ""
    @State private var skipError = ""
    @State private var skipInfo = ""
    @State private var skipCountdown: Int?

    // Confirmations
    @State private var showClearConfirm = false
    @State private var pendingAgentChange: Bool?
    @State private var agentInstalled = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.40, green: 0.49, blue: 0.92),
                    Color(red: 0.46, green: 0.29, blue: 0.64),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                Text("Dual N-Back Training")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.3), radius: 5, y: 2)

                if lockMode { lockBanner }
                if lock.mode == .degraded { degradedBanner }

                controls
                progressBar

                Text(game.timerText)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))

                gameArea

                statsRow

                if !lockMode { recordsSection }
            }
            .padding(24)
            .frame(maxWidth: 1500, maxHeight: .infinity)

            if game.idlePaused { idleOverlay }
            if showSkipModal { skipModal }

            if let note = game.levelNotification {
                levelToast(note)
            }
        }
        .frame(minWidth: 900, minHeight: 700)
        .onAppear { agentInstalled = LaunchAgentInstaller.isInstalled }
        .alert("清除记录", isPresented: $showClearConfirm) {
            Button("清除", role: .destructive) { game.clearRecords() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Are you sure you want to clear all training records? This cannot be undone.")
        }
        .alert(
            pendingAgentChange == true ? "启用开机锁?" : "关闭开机锁?",
            isPresented: Binding(
                get: { pendingAgentChange != nil },
                set: { if !$0 { pendingAgentChange = nil } }
            )
        ) {
            Button("确定") {
                if let enable = pendingAgentChange {
                    agentInstalled = lock.setAgentEnabled(enable)
                }
                pendingAgentChange = nil
            }
            Button("取消", role: .cancel) { pendingAgentChange = nil }
        } message: {
            Text(pendingAgentChange == true
                 ? "启用后:每天首次使用电脑将全屏锁定,完成 20 分钟训练才能解锁;强退会被自动拉起。确定启用?"
                 : "确定关闭开机锁?")
        }
    }

    // MARK: Banners

    private var lockBanner: some View {
        HStack(spacing: 12) {
            Text(lockBannerText)
                .font(.system(size: 20, weight: .bold))
            if !lock.unlocked {
                Button("紧急跳过") { openSkipModal() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Color(red: 0.96, green: 0.26, blue: 0.21).opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(red: 0.96, green: 0.26, blue: 0.21).opacity(0.5)))
                    .cornerRadius(6)
            }
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(lock.unlocked
                    ? Color(red: 0.3, green: 0.69, blue: 0.31).opacity(0.35)
                    : Color(red: 1.0, green: 0.34, blue: 0.13).opacity(0.25))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(
            lock.unlocked
            ? Color(red: 0.3, green: 0.69, blue: 0.31)
            : Color(red: 1.0, green: 0.34, blue: 0.13).opacity(0.55)))
        .cornerRadius(12)
    }

    private var lockBannerText: String {
        if lock.unlocked {
            return "✅ 今日训练完成!电脑已解锁"
        }
        if lock.pausedForIdle {
            return "⏸ 已暂停(\(Int(lock.config.idleThresholdSeconds)) 秒无操作)· 今日剩余 \(formatMMSS(lock.remainingSeconds))"
        }
        return "🔒 完成训练解锁电脑 · 今日剩余 \(formatMMSS(lock.remainingSeconds))"
    }

    private var degradedBanner: some View {
        Text("⚠️ 锁屏因连续异常暂停一小时,请自觉完成今日训练")
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(Color(red: 1.0, green: 0.76, blue: 0.03).opacity(0.25))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(Color(red: 1.0, green: 0.76, blue: 0.03).opacity(0.55)))
            .cornerRadius(12)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("N-Level:", selection: $game.nLevel) {
                ForEach(1...12, id: \.self) { Text("\($0)-Back").tag($0) }
            }
            .fixedSize()

            Picker("Speed:", selection: $game.speedMs) {
                Text("Slow (3s)").tag(3000)
                Text("Normal (2.5s)").tag(2500)
                Text("Fast (2s)").tag(2000)
                Text("Very Fast (1.5s)").tag(1500)
            }
            .fixedSize()

            if !lockMode {
                Picker("Session:", selection: $game.sessionMinutes) {
                    ForEach([5, 10, 15, 20, 25, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                .fixedSize()
            }

            Picker("Auto Level:", selection: $game.autoLevel) {
                Text("On").tag(true)
                Text("Off").tag(false)
            }
            .fixedSize()

            if !lockMode {
                HStack(spacing: 5) {
                    Toggle("开机锁:", isOn: Binding(
                        get: { agentInstalled },
                        set: { pendingAgentChange = $0 }
                    ))
                    .toggleStyle(.switch)
                    Text(agentInstalled ? "●" : "○")
                        .foregroundColor(agentInstalled ? Color(red: 0.3, green: 0.69, blue: 0.31) : .white.opacity(0.85))
                        .help(agentInstalled ? "开机锁已启用" : "开机锁未启用")
                }
                .fixedSize()
            }

            Button("Test Audio") {
                game.testAudio()
            }

            Button(game.isRunning ? "Stop Game" : "Start Game") {
                game.markInput()
                game.toggleGame()
            }
            .keyboardShortcut(.defaultAction)
        }
        .foregroundColor(.white)
    }

    // MARK: Progress + game area

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.3, green: 0.69, blue: 0.31),
                                 Color(red: 0.27, green: 0.63, blue: 0.28)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * game.progress)
                    .animation(.easeInOut(duration: 0.3), value: game.progress)
            }
        }
        .frame(height: 6)
    }

    private var gameArea: some View {
        VStack(spacing: 16) {
            Text(game.instructions)
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)

            grid

            HStack(spacing: 15) {
                responseButton(
                    title: "Position Match (A)",
                    colors: [Color(red: 1.0, green: 0.42, blue: 0.42),
                             Color(red: 1.0, green: 0.56, blue: 0.56)]
                ) {
                    game.markInput()
                    game.recordResponse(.visual)
                }
                responseButton(
                    title: "Audio Match (L)",
                    colors: [Color(red: 0.31, green: 0.8, blue: 0.77),
                             Color(red: 0.27, green: 0.63, blue: 0.55)]
                ) {
                    game.markInput()
                    game.recordResponse(.audio)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .background(Color.black.opacity(0.3))
        .cornerRadius(15)
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.fixed(130), spacing: 15), count: 3)
        return LazyVGrid(columns: columns, spacing: 15) {
            ForEach(0..<9, id: \.self) { pos in
                RoundedRectangle(cornerRadius: 12)
                    .fill(game.activeSquare == pos
                          ? Color(red: 0.3, green: 0.69, blue: 0.31)
                          : Color.white.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(game.activeSquare == pos
                                ? Color(red: 0.3, green: 0.69, blue: 0.31)
                                : Color.white.opacity(0.3),
                                lineWidth: 3))
                    .shadow(color: game.activeSquare == pos
                            ? Color(red: 0.3, green: 0.69, blue: 0.31).opacity(0.8)
                            : .clear,
                            radius: 15)
                    .frame(width: 130, height: 130)
                    .scaleEffect(game.activeSquare == pos ? 1.05 : 1)
                    .animation(.easeInOut(duration: 0.15), value: game.activeSquare)
            }
        }
        .opacity(game.isRunning ? 1 : 0.35)
        .animation(.easeInOut(duration: 0.3), value: game.isRunning)
    }

    private func responseButton(title: String, colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .frame(minWidth: 160)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
        .opacity(game.isRunning ? 1 : 0.5)
    }

    // MARK: Stats

    private var statsRow: some View {
        HStack(spacing: 15) {
            statBox(value: "\(game.round)", label: "Rounds Completed")
            statBox(value: "\(game.accuracy.visual)%", label: "Position Accuracy")
            statBox(value: "\(game.accuracy.audio)%", label: "Audio Accuracy")
            statBox(value: "\(game.accuracy.total)%", label: "Total Accuracy")
        }
    }

    private func statBox(value: String, label: String) -> some View {
        VStack(spacing: 5) {
            Text(value).font(.system(size: 26, weight: .bold))
            Text(label).font(.system(size: 12)).opacity(0.8)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(15)
        .background(Color.white.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.2)))
        .cornerRadius(10)
    }

    // MARK: Records

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Training Records").font(.system(size: 17, weight: .bold))
                Spacer()
                Button("Clear All") { showClearConfirm = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color(red: 0.96, green: 0.26, blue: 0.21).opacity(0.2))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(red: 0.96, green: 0.26, blue: 0.21).opacity(0.4)))
                    .cornerRadius(8)
            }

            if game.records.isEmpty {
                Text("No training sessions recorded yet. Complete a session to see your progress!")
                    .italic()
                    .opacity(0.6)
                    .frame(maxWidth: .infinity)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(game.records) { record in
                            recordRow(record)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .foregroundColor(.white)
        .padding(16)
        .background(Color.white.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.2)))
        .cornerRadius(15)
    }

    private func recordRow(_ record: TrainingRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(record.date)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Color(red: 0.3, green: 0.69, blue: 0.31))
            HStack(spacing: 14) {
                Text("\(record.nLevel)-Back").bold()
                Text("\(record.actualTime)min")
                Text("\(record.rounds) rounds")
                Text("Pos: \(record.positionAccuracy)%")
                Text("Audio: \(record.audioAccuracy)%")
                Text("Total: \(record.totalAccuracy)%").bold()
                Text(record.autoLevel ? "Auto" : "Manual")
                    .foregroundColor(record.autoLevel
                                     ? Color(red: 0.3, green: 0.69, blue: 0.31)
                                     : Color(red: 1.0, green: 0.65, blue: 0.15))
            }
            .font(.system(size: 12))
            .opacity(0.9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.05))
        .overlay(Rectangle().fill(Color(red: 0.3, green: 0.69, blue: 0.31)).frame(width: 3),
                 alignment: .leading)
        .cornerRadius(8)
    }

    // MARK: Idle overlay

    private var idleOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 15) {
                Text("⏸ 还在吗?").font(.system(size: 24))
                Text("超过 \(Int(lock.config.idleThresholdSeconds)) 秒没有操作,计时已暂停。")
                Text("按 A / L / 空格 继续训练")
            }
            .foregroundColor(.white)
            .padding(30)
            .frame(maxWidth: 520)
            .background(Color(red: 0.12, green: 0.12, blue: 0.16).opacity(0.95))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.25)))
            .cornerRadius(16)
        }
    }

    // MARK: Emergency skip modal

    private func openSkipModal() {
        skipInfo = "本周剩余 \(lock.skipsRemaining) 次。如需跳过今日训练,请一字不差输入以下句子:"
        skipError = ""
        skipInput = ""
        skipCountdown = nil
        showSkipModal = true
    }

    private var skipModal: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()
            VStack(spacing: 12) {
                Text("紧急跳过").font(.system(size: 24))
                Text(skipInfo)
                Text(lock.config.skipPhrase)
                    .font(.system(size: 13))
                    .opacity(0.75)
                    .textSelection(.enabled)

                TextEditor(text: $skipInput)
                    .font(.system(size: 14))
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.3)))

                Text(skipError)
                    .foregroundColor(Color(red: 1.0, green: 0.54, blue: 0.5))
                    .frame(minHeight: 18)

                HStack(spacing: 12) {
                    Button("取消") {
                        showSkipModal = false
                    }
                    Button("确认跳过") { confirmSkip() }
                        .disabled(skipCountdown != nil)
                }
            }
            .foregroundColor(.white)
            .padding(30)
            .frame(maxWidth: 520)
            .background(Color(red: 0.12, green: 0.12, blue: 0.16).opacity(0.95))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.25)))
            .cornerRadius(16)
        }
    }

    private func confirmSkip() {
        let phrase = skipInput.trimmingCharacters(in: .whitespacesAndNewlines)
        switch lock.requestSkip(phrase: phrase) {
        case .failure(let error):
            skipError = error.message
        case .success(let waitSeconds):
            skipError = ""
            skipCountdown = Int(waitSeconds)
            tickSkipCountdown()
        }
    }

    private func tickSkipCountdown() {
        guard let left = skipCountdown else { return }
        skipInfo = "强制等待中… \(left) 秒后解锁"
        guard left > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let current = skipCountdown, current > 0 {
                skipCountdown = current - 1
                tickSkipCountdown()
            }
        }
    }

    // MARK: Level toast

    private func levelToast(_ note: LevelNote) -> some View {
        VStack {
            HStack {
                Spacer()
                Text(note.message)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 15)
                    .background(LinearGradient(
                        colors: note.isDown
                        ? [Color(red: 1.0, green: 0.6, blue: 0.0), Color(red: 0.96, green: 0.49, blue: 0.0)]
                        : [Color(red: 0.3, green: 0.69, blue: 0.31), Color(red: 0.27, green: 0.63, blue: 0.28)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.3), lineWidth: 2))
                    .cornerRadius(10)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            }
            Spacer()
        }
        .padding(20)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.5), value: game.levelNotification)
    }

    // MARK: Helpers

    private func formatMMSS(_ totalSeconds: Int) -> String {
        let s = max(0, totalSeconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
