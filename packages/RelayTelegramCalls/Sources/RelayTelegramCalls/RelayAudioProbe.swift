#if DEBUG
import Foundation
import AVFoundation
import CoreAudio
import LiveKit

final class RelayAudioMeter: NSObject, AudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var windowFrames = 0
    private var windowSquares = 0.0
    private var windowPeak: Float = 0
    private var windowCrossings = 0
    private var windowRate = 48000.0
    private var lastSign = false
    private var last: (rms: Double, peak: Double, frequency: Double)?
    private var lastAt: Date?

    func render(pcmBuffer: AVAudioPCMBuffer) {
        self.add(pcmBuffer)
    }

    func add(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        guard count > 0 else {
            return
        }
        var squares = 0.0
        var peak: Float = 0
        var crossings = 0
        var sign = self.lastSign
        if let data = buffer.floatChannelData {
            let samples = data[0]
            for index in 0 ..< count {
                let value = samples[index]
                squares += Double(value * value)
                peak = max(peak, abs(value))
                let positive = value >= 0
                if positive != sign {
                    crossings += 1
                    sign = positive
                }
            }
        } else if let data = buffer.int16ChannelData {
            let samples = data[0]
            for index in 0 ..< count {
                let value = Float(samples[index]) / 32768
                squares += Double(value * value)
                peak = max(peak, abs(value))
                let positive = value >= 0
                if positive != sign {
                    crossings += 1
                    sign = positive
                }
            }
        } else {
            return
        }
        self.lock.lock()
        self.lastSign = sign
        self.frames += count
        self.windowFrames += count
        self.windowSquares += squares
        self.windowPeak = max(self.windowPeak, peak)
        self.windowCrossings += crossings
        self.windowRate = buffer.format.sampleRate
        if Double(self.windowFrames) >= self.windowRate {
            let rms = (self.windowSquares / Double(self.windowFrames)).squareRoot()
            let seconds = Double(self.windowFrames) / self.windowRate
            self.last = (Self.dB(rms), Self.dB(Double(self.windowPeak)), Double(self.windowCrossings) / 2 / seconds)
            self.lastAt = Date()
            self.windowFrames = 0
            self.windowSquares = 0
            self.windowPeak = 0
            self.windowCrossings = 0
        }
        self.lock.unlock()
    }

    var info: [String: Any] {
        self.lock.lock()
        defer { self.lock.unlock() }
        var result: [String: Any] = ["frames": self.frames]
        if let last = self.last, let at = self.lastAt {
            result["rmsDb"] = (last.rms * 10).rounded() / 10
            result["peakDb"] = (last.peak * 10).rounded() / 10
            result["frequency"] = last.frequency.rounded()
            result["age"] = (Date().timeIntervalSince(at) * 10).rounded() / 10
        }
        return result
    }

    private static func dB(_ value: Double) -> Double {
        return value > 0 ? 20 * log10(value) : -200
    }
}

final class RelayAudioProbe: AudioEngineObserver, @unchecked Sendable {
    static let shared = RelayAudioProbe()

    let microphone = RelayAudioMeter()
    let remote = RelayAudioMeter()
    let output = RelayAudioMeter()
    private let lock = NSLock()
    private var nextObserver: (any AudioEngineObserver)?
    private weak var outputSource: AVAudioNode?
    private weak var tappedNode: AVAudioNode?
    private var engineInfo: [String: Any] = [:]

    var next: (any AudioEngineObserver)? {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.nextObserver
        }
        set {
            self.lock.lock()
            self.nextObserver = newValue
            self.lock.unlock()
        }
    }

    func install(_ manager: AudioManager) {
        manager.add(localAudioRenderer: self.microphone)
        manager.add(remoteAudioRenderer: self.remote)
    }

    func engineWillConnectOutput(_ engine: AVAudioEngine, src: AVAudioNode, dst: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        self.lock.lock()
        self.outputSource = src
        self.lock.unlock()
        return self.next?.engineWillConnectOutput(engine, src: src, dst: dst, format: format, context: context) ?? 0
    }

    func engineWillStart(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        let result = self.next?.engineWillStart(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
        self.lock.lock()
        let source = self.outputSource
        let tapped = self.tappedNode
        self.engineInfo = ["playout": isPlayoutEnabled, "recording": isRecordingEnabled, "description": RelayAudioEngineLog.describe(engine, isRecordingEnabled: isRecordingEnabled), "at": Date().description]
        self.lock.unlock()
        if isPlayoutEnabled, let source, source.engine === engine {
            if let tapped, tapped.engine != nil {
                tapped.removeTap(onBus: 0)
            }
            let meter = self.output
            source.installTap(onBus: 0, bufferSize: 4800, format: nil) { buffer, _ in
                meter.add(buffer)
            }
            self.lock.lock()
            self.tappedNode = source
            self.lock.unlock()
        }
        return result
    }

    func engineDidStop(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        self.lock.lock()
        let tapped = self.tappedNode
        self.tappedNode = nil
        self.engineInfo["stoppedAt"] = Date().description
        self.lock.unlock()
        if let tapped, tapped.engine != nil {
            tapped.removeTap(onBus: 0)
        }
        return self.next?.engineDidStop(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    func engineWillRelease(_ engine: AVAudioEngine) -> Int {
        self.lock.lock()
        let tapped = self.tappedNode
        self.tappedNode = nil
        self.outputSource = nil
        self.lock.unlock()
        if let tapped, tapped.engine != nil {
            tapped.removeTap(onBus: 0)
        }
        return self.next?.engineWillRelease(engine) ?? 0
    }

    var info: [String: Any] {
        self.lock.lock()
        let engineInfo = self.engineInfo
        self.lock.unlock()
        let counts = RelayAudioEngineLog.shared.counts
        return ["microphoneSent": self.microphone.info, "remoteMixed": self.remote.info, "engineOutput": self.output.info, "lastEngineStart": engineInfo, "engineStarts": counts.starts, "engineStops": counts.stops]
    }
}

enum RelayAudioDebug {
    static func info() -> [String: Any] {
        let manager = AudioManager.shared
        var result: [String: Any] = RelayAudioProbe.shared.info
        result["engineRunning"] = manager.isEngineRunning
        result["engineAvailability"] = "\(manager.engineAvailability)"
        result["microphoneMuted"] = manager.isMicrophoneMuted
        result["inputDevice"] = "\(manager.inputDevice.name) default=\(manager.inputDevice.isDefault)"
        result["outputDevice"] = "\(manager.outputDevice.name) default=\(manager.outputDevice.isDefault)"
        result["advancedDucking"] = manager.isAdvancedDuckingEnabled
        if #available(macOS 14.0, *) {
            result["duckingLevel"] = "\(manager.duckingLevel)"
        }
        result["voiceProcessingBypassed"] = manager.isVoiceProcessingBypassed
        result["recordingAlwaysPrepared"] = manager.isRecordingAlwaysPreparedMode
        let platform = manager.platformVoiceProcessingState
        result["platformVoiceProcessing"] = "\(platform)"
        result["lastAppliedDevices"] = RelayAudioDevices.lastApplied
        return result
    }
}
#endif
