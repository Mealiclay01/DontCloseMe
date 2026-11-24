import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

final class SystemVolumeOverride {
    private var savedVolume: Float32?
    private var savedMuted: UInt32?
    private var savedDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    func captureAndForceMax() {
        let device = defaultOutputDeviceID()
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }

        if savedDeviceID == AudioObjectID(kAudioObjectUnknown) {
            savedDeviceID = device
            savedVolume = getVolume(device: device)
            savedMuted = getMuted(device: device)
        }

        setMuted(device: device, muted: 0)
        setVolume(device: device, volume: 1.0)
    }

    func enforceMaxIfActive() {
        let device = defaultOutputDeviceID()
        guard device != AudioObjectID(kAudioObjectUnknown) else { return }
        if getMuted(device: device) != 0 {
            setMuted(device: device, muted: 0)
        }
        if let v = getVolume(device: device), v < 0.96 {
            setVolume(device: device, volume: 1.0)
        }
    }

    func restore() {
        let device = savedDeviceID != AudioObjectID(kAudioObjectUnknown)
            ? savedDeviceID
            : defaultOutputDeviceID()
        guard device != AudioObjectID(kAudioObjectUnknown) else {
            clearSaved()
            return
        }

        if let vol = savedVolume {
            setVolume(device: device, volume: vol)
        }
        if let muted = savedMuted {
            setMuted(device: device, muted: muted)
        }
        clearSaved()
    }

    private func clearSaved() {
        savedVolume = nil
        savedMuted = nil
        savedDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func defaultOutputDeviceID() -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : AudioObjectID(kAudioObjectUnknown)
    }

    private func getVolume(device: AudioObjectID) -> Float32? {
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol)
        return status == noErr ? vol : nil
    }

    private func setVolume(device: AudioObjectID, volume: Float32) {
        var vol = max(0.0, min(1.0, volume))
        let size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(device, &addr, 0, nil, size, &vol)
    }

    private func getMuted(device: AudioObjectID) -> UInt32? {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted)
        return status == noErr ? muted : nil
    }

    private func setMuted(device: AudioObjectID, muted: UInt32) {
        var m = muted
        let size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(device, &addr, 0, nil, size, &m)
    }
}

@MainActor
final class VoiceAlarmPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false

    private let synthesizer = AVSpeechSynthesizer()
    private let volumeOverride = SystemVolumeOverride()
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var klaxonBuffer: AVAudioPCMBuffer?

    private var sirenTimer: Timer?
    private var speechTimer: Timer?
    private var volumeLockTimer: Timer?
    private var phraseIndex = 0
    private var forceSystemMax = false

    override init() {
        super.init()
    }

    func startAlarm(
        agents: [DetectedAgent],
        angle: Double?,
        playSiren: Bool,
        speakJoke: Bool,
        overrideVolume: Bool,
        customPhrase: String
    ) {
        stop()
        isPlaying = true
        forceSystemMax = overrideVolume

        if overrideVolume {
            volumeOverride.captureAndForceMax()
            volumeLockTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isPlaying, self.forceSystemMax else { return }
                    self.volumeOverride.enforceMaxIfActive()
                }
            }
            if let volumeLockTimer {
                RunLoop.main.add(volumeLockTimer, forMode: .common)
            }
        }

        if playSiren {
            playSirenPulse()
            sirenTimer = Timer.scheduledTimer(withTimeInterval: 1.35, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.playSirenPulse()
                }
            }
            if let sirenTimer {
                RunLoop.main.add(sirenTimer, forMode: .common)
            }
        }

        if speakJoke {
            // Brief offset so first klaxon punch lands right before speech
            let delay = playSiren ? 0.35 : 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isPlaying else { return }
                self.speakNextLine(agents: agents, angle: angle, customPhrase: customPhrase)
            }
            speechTimer = Timer.scheduledTimer(withTimeInterval: 4.4, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.speakNextLine(agents: agents, angle: angle, customPhrase: customPhrase)
                }
            }
            if let speechTimer {
                RunLoop.main.add(speechTimer, forMode: .common)
            }
        }
    }

    func stop() {
        isPlaying = false
        sirenTimer?.invalidate()
        sirenTimer = nil
        speechTimer?.invalidate()
        speechTimer = nil
        volumeLockTimer?.invalidate()
        volumeLockTimer = nil

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        playerNode?.stop()
        audioEngine?.stop()

        if forceSystemMax {
            volumeOverride.restore()
            forceSystemMax = false
        }
    }

    func playTaskCompleteChime() {
        let utterance = AVSpeechUtterance(string: "Tasks finished. Safe to sleep now.")
        utterance.rate = 0.50
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.8
        synthesizer.speak(utterance)
    }

    private func speakNextLine(agents: [DetectedAgent], angle: Double?, customPhrase: String) {
        guard isPlaying, !synthesizer.isSpeaking else { return }

        let line: String
        let trimmedCustom = customPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if phraseIndex == 0 && !trimmedCustom.isEmpty {
            line = JokePhraseBank.format(trimmedCustom, agents: agents, angle: angle)
        } else {
            let template = JokePhraseBank.spokenLines[phraseIndex % JokePhraseBank.spokenLines.count]
            line = JokePhraseBank.format(template, agents: agents, angle: angle)
        }
        phraseIndex += 1

        let utterance = AVAudioUtteranceCompat.make(line: line)
        synthesizer.speak(utterance)
    }

    private func prepareAudioEngine() {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        // High-presence multi-harmonic klaxon tailored for MacBook speakers (880-2200 Hz band)
        let duration = 1.1
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        if let samples = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                let t = Double(i) / sampleRate
                // 4 fast pulses inside 1.1s: High-Low-High-Low
                let phase = Int((t / duration) * 4.0)
                let baseFreq = (phase % 2 == 0) ? 960.0 : 720.0
                let secondFreq = (phase % 2 == 0) ? 1440.0 : 1080.0

                let segLen = duration / 4.0
                let localT = t.truncatingRemainder(dividingBy: segLen)
                let attack = min(1.0, localT / 0.008)
                let release = min(1.0, max(0.0, (segLen - localT) / 0.02))
                let env = attack * release

                // Rich sawtooth/harmonic stack passed through tanh saturation for maximum perceived loudness
                let h1 = sin(2.0 * .pi * baseFreq * t)
                let h2 = 0.65 * sin(2.0 * .pi * secondFreq * t)
                let h3 = 0.40 * sin(2.0 * .pi * (baseFreq * 2.0) * t)
                let h4 = 0.25 * sin(2.0 * .pi * (baseFreq * 3.0) * t)
                let raw = (h1 + h2 + h3 + h4) * 1.4
                let saturated = tanh(raw)
                samples[i] = Float(saturated * env * 0.96)
            }
        }

        self.audioEngine = engine
        self.playerNode = node
        self.klaxonBuffer = buffer
    }

    private func playSirenPulse() {
        if audioEngine == nil {
            prepareAudioEngine()
        }
        guard let engine = audioEngine, let node = playerNode, let buffer = klaxonBuffer else { return }
        engine.mainMixerNode.outputVolume = 1.0
        if !engine.isRunning {
            try? engine.start()
        }
        node.volume = 1.0
        if !node.isPlaying {
            node.play()
        }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }
}

private enum AVAudioUtteranceCompat {
    static func make(line: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: line)
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.12
        utterance.volume = 1.0
        if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        return utterance
    }
}
