import Foundation
import AVFoundation
import CoreAudio
import RelayCallsCore
import LiveKit
import os

private let relayCallsOSLog = OSLog(subsystem: "org.relaychat.RelayMac", category: "calls")

func relayLog(_ message: String) {
    os_log("RelayCalls: %{public}@", log: relayCallsOSLog, type: .default, message)
}

enum RelayCallAudio {
    private static var isPrepared = false

    static func install() {
        RelayCallsLog.handler = { message in
            relayLog(message)
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["RELAY_DEBUG_RTC_LOG"] == "1" {
            LiveKitSDK.setLogger(OSLogger(minLevel: .info, rtc: true))
        }
        #endif
    }

    static private(set) var usesVoiceProcessingEngine = false

    static func selectAudioDeviceModule() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["RELAY_DEBUG_AUDIO_ENGINE_ADM"] == "1" {
            self.usesVoiceProcessingEngine = true
            relayLog("audio: LiveKit's AVAudioEngine device module (Apple voice processing)")
            return
        }
        #endif
        do {
            try AudioManager.set(audioDeviceModuleType: .platformDefault)
            relayLog("audio: WebRTC's platform device module (Core Audio, WebRTC echo cancellation)")
        } catch {
            self.usesVoiceProcessingEngine = true
            relayLog("audio: platform device module not set: \(error)")
        }
    }

    static func prepareOnAudioQueue() {
        if self.isPrepared {
            return
        }
        self.isPrepared = true
        let manager = AudioManager.shared
        #if DEBUG
        RelayAudioProbe.shared.install(manager)
        #endif
        guard self.usesVoiceProcessingEngine else {
            return
        }
        manager.isAdvancedDuckingEnabled = false
        if #available(macOS 14.0, *) {
            manager.duckingLevel = .min
        }
        manager.set(engineObservers: RelayAudioEngineLog.chain(manager))
    }

    static func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let value = name?.takeRetainedValue() else {
            return "device \(id)"
        }
        return value as String
    }
}

final class RelayAudioEngineLog: AudioEngineObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var nextObserver: (any AudioEngineObserver)?
    private(set) var starts = 0
    private(set) var stops = 0

    static let shared = RelayAudioEngineLog()

    static func chain(_ manager: AudioManager) -> [any AudioEngineObserver] {
        var observers: [any AudioEngineObserver] = [manager.mixer, self.shared]
        #if DEBUG
        observers.append(RelayAudioProbe.shared)
        #endif
        return observers
    }

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

    var counts: (starts: Int, stops: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        return (self.starts, self.stops)
    }

    func engineWillEnable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        relayLog("audio engine: enable (playout \(isPlayoutEnabled), recording \(isRecordingEnabled))")
        return self.next?.engineWillEnable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    func engineWillStart(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        self.lock.lock()
        self.starts += 1
        let count = self.starts
        self.lock.unlock()
        relayLog("audio engine: start #\(count) (playout \(isPlayoutEnabled), recording \(isRecordingEnabled)) \(Self.describe(engine, isRecordingEnabled: isRecordingEnabled))")
        return self.next?.engineWillStart(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    func engineDidStop(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        self.lock.lock()
        self.stops += 1
        let count = self.stops
        self.lock.unlock()
        relayLog("audio engine: stop #\(count) (playout \(isPlayoutEnabled), recording \(isRecordingEnabled))")
        return self.next?.engineDidStop(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    func engineDidDisable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        relayLog("audio engine: disable (playout \(isPlayoutEnabled), recording \(isRecordingEnabled))")
        return self.next?.engineDidDisable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }

    static func describe(_ engine: AVAudioEngine, isRecordingEnabled: Bool) -> String {
        var parts: [String] = []
        parts.append("output=\(RelayCallAudio.deviceName(engine.outputNode.auAudioUnit.deviceID))")
        if isRecordingEnabled {
            let input = engine.inputNode
            parts.append("input=\(RelayCallAudio.deviceName(input.auAudioUnit.deviceID))")
            parts.append("voiceProcessing=\(input.isVoiceProcessingEnabled)")
            if #available(macOS 14.0, *), input.isVoiceProcessingEnabled {
                let ducking = input.voiceProcessingOtherAudioDuckingConfiguration
                parts.append("ducking(advanced \(ducking.enableAdvancedDucking.boolValue), level \(ducking.duckingLevel.rawValue))")
            }
        }
        return parts.joined(separator: " ")
    }
}
