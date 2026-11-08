import Foundation
import AVFoundation
import SwiftSignalKit
import TelegramCore
import Postbox
import TelegramCallsCore
import TelegramContext
import TelegramMediaUtils
import MattermostSync
import RelayCallsCore
import RelayCalls
import LiveKit

func relayOnMain(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            body()
        }
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                body()
            }
        }
    }
}

final class RelayTonePlayer {
    private final class Output {
        var player: CallAudioPlayer?
    }
    private static let queue = DispatchQueue(label: "org.relaychat.RelayTonePlayer", qos: .userInitiated)
    private let output = Output()
    private(set) var current: CallTone?

    func play(_ tone: CallTone?) {
        if tone == self.current {
            return
        }
        self.current = tone
        let output = self.output
        let url = tone.flatMap { RelayTonePlayer.url(for: $0) }
        let loops = tone.map { RelayTonePlayer.loops(for: $0) } ?? 0
        RelayTonePlayer.queue.async {
            output.player?.stop()
            output.player = url.map { CallAudioPlayer($0, loops: loops) }
            output.player?.play()
        }
    }

    deinit {
        let output = self.output
        RelayTonePlayer.queue.async {
            output.player?.stop()
            output.player = nil
        }
    }

    func stop() {
        self.play(nil)
    }

    private static func url(for tone: CallTone) -> URL? {
        let path: String?
        switch tone {
        case .busy:
            path = Bundle.main.path(forResource: "voip_busy", ofType: "caf")
        case .ringback:
            path = Bundle.main.path(forResource: "voip_ringback", ofType: "caf")
        case .connecting:
            path = Bundle.main.path(forResource: "voip_connecting", ofType: "mp3")
        case .failed:
            path = Bundle.main.path(forResource: "voip_fail", ofType: "caf")
        case .ended:
            path = Bundle.main.path(forResource: "voip_end", ofType: "caf")
        case .ringing:
            path = Bundle.main.path(forResource: "opening", ofType: "m4a")
        case .undefined:
            path = nil
        }
        return path.map { URL(fileURLWithPath: $0) }
    }

    private static func loops(for tone: CallTone) -> Int {
        switch tone {
        case .busy:
            return 3
        case .ringback, .connecting, .ringing:
            return -1
        case .failed, .ended:
            return 1
        case .undefined:
            return 0
        }
    }
}

@MainActor
final class RelayPeerResolver {
    private let account: Account
    private var peers: [String: EnginePeer] = [:]
    private var pending = Set<String>()
    private var attempts: [String: Date] = [:]
    var onChange: (() -> Void)?

    init(account: Account) {
        self.account = account
    }

    func peer(userId: String) -> EnginePeer? {
        return self.peers[userId]
    }

    func peerId(userId: String) -> PeerId? {
        return self.peers[userId]?.id ?? MattermostSync.relayCallPeerId(accountId: self.account.id, userId: userId)
    }

    func resolve(_ userIds: [String]) {
        let now = Date()
        let missing = Array(Set(userIds).subtracting(self.peers.keys).subtracting(self.pending).filter { userId in
            guard let attempt = self.attempts[userId] else {
                return true
            }
            return now.timeIntervalSince(attempt) > 30
        })
        if missing.isEmpty {
            return
        }
        for userId in missing {
            self.attempts[userId] = now
        }
        self.pending.formUnion(missing)
        let account = self.account
        Task { @MainActor [weak self] in
            await MattermostSync.ensureRelayCallUsers(accountId: account.id, userIds: missing)
            let peerIds = missing.compactMap { userId -> (String, PeerId)? in
                guard let peerId = MattermostSync.relayCallPeerId(accountId: account.id, userId: userId) else {
                    return nil
                }
                return (userId, peerId)
            }
            let signal = account.postbox.transaction { transaction -> [(String, EnginePeer)] in
                return peerIds.compactMap { userId, peerId in
                    return transaction.getPeer(peerId).map { (userId, EnginePeer($0)) }
                }
            } |> deliverOnMainQueue
            _ = signal.start(next: { loaded in
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.pending.subtract(missing)
                    for (userId, peer) in loaded {
                        self.peers[userId] = peer
                    }
                    if !loaded.isEmpty {
                        self.onChange?()
                    }
                }
            })
        }
    }
}

enum RelayAudioDevices {
    private static let queue = DispatchQueue(label: "org.relaychat.RelayAudioDevices", qos: .userInitiated)

    static func apply(_ devices: DevicesContext) {
        let microId = devices.currentMicroId
        let outputId = devices.currentOutputId
        self.queue.async {
            let manager = AudioManager.shared
            if let id = microId, let device = manager.inputDevices.first(where: { $0.deviceId == id }) {
                manager.inputDevice = device
            }
            if let id = outputId, let device = manager.outputDevices.first(where: { $0.deviceId == id }) {
                manager.outputDevice = device
            }
        }
    }
}

func relayReception(_ quality: RelayConnectionQuality?) -> Int32? {
    switch quality {
    case .excellent?:
        return 4
    case .good?:
        return 3
    case .poor?:
        return 1
    case .lost?:
        return 0
    case .unknown?, nil:
        return nil
    }
}

func relayCameraDevice(_ devices: DevicesContext) -> AVCaptureDevice? {
    if let id = devices.currentCameraId, let device = AVCaptureDevice(uniqueID: id) {
        return device
    }
    return AVCaptureDevice.default(for: .video)
}

var relayIsCameraAvailable: Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized, .notDetermined:
        return true
    default:
        return false
    }
}

var relayHasCamera: Bool {
    return !AVCaptureDevice.devices(for: .video).filter({ $0.isConnected && !$0.isSuspended }).isEmpty
}
