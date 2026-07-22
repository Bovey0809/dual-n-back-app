import AVFoundation

/// Speech (letters) + synthesized feedback tones, mirroring the Web Audio /
/// speechSynthesis code in the Electron renderer.
final class AudioController {
    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    private let voice: AVSpeechSynthesisVoice?

    // Phonetic spellings avoid "capital X" style pronunciations.
    private static let phonetics: [String: String] = [
        "C": "see", "H": "aitch", "K": "kay", "L": "ell",
        "Q": "cue", "R": "are", "S": "ess", "T": "tee",
    ]
    // Fallback tone frequencies when no speech voice is available.
    private static let letterFrequencies: [String: Double] = [
        "C": 200, "H": 280, "K": 360, "L": 440,
        "Q": 520, "R": 600, "S": 680, "T": 760,
    ]

    init() {
        voice = Self.selectBestVoice()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    private static func selectBestVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return english.first { $0.quality == .premium }
            ?? english.first { $0.quality == .enhanced }
            ?? english.first { ["Alex", "Samantha", "Victoria"].contains($0.name) }
            ?? AVSpeechSynthesisVoice(language: "en-US")
            ?? english.first
    }

    // MARK: Letters

    func speakLetter(_ letter: String) {
        guard voice != nil else {
            playFallbackTone(letter)
            return
        }
        let utterance = AVSpeechUtterance(string: Self.phonetics[letter] ?? letter.lowercased())
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.8
        utterance.pitchMultiplier = 0.9
        utterance.volume = 0.8
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    private func playFallbackTone(_ letter: String) {
        let freq = Self.letterFrequencies[letter] ?? 440
        // Triangle wave, 0.8s: ramp to 0.2 over 0.1s, then exponential decay.
        play(makeBuffer(duration: 0.8, wave: .triangle, frequency: { _ in freq }) { t in
            if t < 0.1 { return 0.2 * (t / 0.1) }
            return Self.expDecay(from: 0.2, to: 0.01, progress: (t - 0.1) / 0.7)
        })
    }

    // MARK: Feedback sounds

    func playFeedback(correct: Bool) {
        if correct {
            // High, pleasant chime: sine 800→1000 Hz over 0.1s, 0.15s total.
            play(makeBuffer(duration: 0.15, wave: .sine, frequency: { t in
                800 * pow(1000 / 800, min(t / 0.1, 1))
            }) { t in
                if t < 0.005 { return 0.5 * (t / 0.005) }
                return Self.expDecay(from: 0.5, to: 0.01, progress: (t - 0.005) / 0.145)
            })
        } else {
            // Low, brief buzz: square 200 Hz, 0.08s.
            play(makeBuffer(duration: 0.08, wave: .square, frequency: { _ in 200 }) { t in
                if t < 0.005 { return 0.5 * (t / 0.005) }
                return Self.expDecay(from: 0.5, to: 0.01, progress: (t - 0.005) / 0.075)
            })
        }
    }

    /// Soft, low tone: response made when the game isn't running.
    func playNotReady() {
        play(makeBuffer(duration: 0.12, wave: .sine, frequency: { _ in 300 }) { t in
            if t < 0.005 { return 0.15 * (t / 0.005) }
            return Self.expDecay(from: 0.15, to: 0.01, progress: (t - 0.005) / 0.115)
        })
    }

    /// Double beep: response made before N rounds have elapsed.
    func playTooEarly() {
        play(makeBuffer(duration: 0.15, wave: .sine, frequency: { _ in 400 }) { t in
            Self.piecewiseLinear(t, points: [
                (0, 0), (0.005, 0.2), (0.06, 0), (0.08, 0.2), (0.15, 0),
            ])
        })
    }

    /// Brief error tone for invalid state.
    func playError() {
        play(makeBuffer(duration: 0.08, wave: .sawtooth, frequency: { _ in 150 }) { t in
            if t < 0.005 { return 0.2 * (t / 0.005) }
            return Self.expDecay(from: 0.2, to: 0.01, progress: (t - 0.005) / 0.075)
        })
    }

    // MARK: Synthesis

    private enum Wave { case sine, square, triangle, sawtooth }

    private static func expDecay(from: Double, to: Double, progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return from * pow(to / from, p)
    }

    private static func piecewiseLinear(_ t: Double, points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        for i in 1..<points.count {
            let (x0, y0) = points[i - 1]
            let (x1, y1) = points[i]
            if t <= x1 {
                let f = (t - x0) / (x1 - x0)
                return y0 + (y1 - y0) * f
            }
        }
        return last.1
    }

    private func makeBuffer(
        duration: Double,
        wave: Wave,
        frequency: (Double) -> Double,
        amplitude: (Double) -> Double
    ) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]

        var phase = 0.0
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            phase += 2 * .pi * frequency(t) / sampleRate
            let p = phase.truncatingRemainder(dividingBy: 2 * .pi)
            let raw: Double
            switch wave {
            case .sine: raw = sin(p)
            case .square: raw = sin(p) >= 0 ? 1 : -1
            case .triangle: raw = (2 / .pi) * asin(sin(p))
            case .sawtooth: raw = p / .pi - 1
            }
            data[i] = Float(raw * amplitude(t))
        }
        return buffer
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        player.scheduleBuffer(buffer, at: nil)
        if !player.isPlaying { player.play() }
    }
}
