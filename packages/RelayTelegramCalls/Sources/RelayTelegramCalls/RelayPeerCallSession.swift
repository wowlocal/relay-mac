import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import SwiftSignalKit
import TelegramCore
import Postbox
import TGUIKit
import TelegramContext
import TelegramCallsCore
import TelegramMediaUtils
import CallVideoLayer
import TgVoipWebrtc
import SystemPermissions
import Localization
import MattermostSync
import RelayCallsCore
import RelayCalls
import LiveKit

public final class RelayPeerCallSession: PresentationPeerCall {
    public let account: Account
    public let engine: TelegramEngine
    public let sharedContext: (any SharedAccountContextProtocol)
    public let peerId: PeerId
    public let internalId = CallSessionInternalId()
    public let isOutgoing: Bool
    public let isIncomingConference: Bool
    public weak var window: Window?

    private let peerValue = Atomic<Peer?>(value: nil)
    private let isVideoValue: Atomic<Bool>
    fileprivate let relayCallIdValue = Atomic<String?>(value: nil)
    fileprivate let statePromise: ValuePromise<CallState>
    fileprivate let audioLevelPromise = ValuePromise<Float>(0, ignoreRepeated: true)
    fileprivate let canBeRemovedPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let peerDisposable = MetaDisposable()
    private var core: RelayPeerCallCore?

    public var peer: Peer? {
        return self.peerValue.with { $0 }
    }

    public var isVideo: Bool {
        return self.isVideoValue.with { $0 }
    }

    public var relayCallId: String? {
        return self.relayCallIdValue.with { $0 }
    }

    public var accountContext: (any AccountContextProtocol)? {
        return CallsCoreHooks.shared.accountContext(self.account.id)
    }

    public var state: Signal<CallState, NoError> {
        return self.statePromise.get()
    }

    public var audioLevel: Signal<Float, NoError> {
        return self.audioLevelPromise.get()
    }

    public var canBeRemoved: Signal<Bool, NoError> {
        return self.canBeRemovedPromise.get()
    }

    @MainActor
    private init(sharedContext: any SharedAccountContextProtocol, account: Account, peerId: PeerId, isOutgoing: Bool, isVideo: Bool, isIncomingConference: Bool, relayAccount: MattermostRelayCallsAccount, mode: (RelayRoomEngine) -> RelayPeerCallCore.Mode) {
        self.sharedContext = sharedContext
        self.account = account
        self.engine = TelegramEngine(account: account)
        self.peerId = peerId
        self.isOutgoing = isOutgoing
        self.isIncomingConference = isIncomingConference
        self.isVideoValue = Atomic(value: isVideo)
        self.statePromise = ValuePromise(CallState(state: isOutgoing ? .waiting : .ringing, videoState: .inactive(relayIsCameraAvailable && relayHasCamera), remoteVideoState: .inactive, isMuted: false, isOutgoingVideoPaused: true, remoteAspectRatio: 0, remoteAudioState: .active, remoteBatteryLevel: .normal, isScreenCapture: false, participants: [], conferenceReference: nil, supportsConferenceCalls: false), ignoreRepeated: true)

        let media = RelayRoomEngine(options: RelayRoomEngine.Options())
        let core = RelayPeerCallCore(session: self, relayAccount: relayAccount, media: media, mode: mode(media))
        self.core = core

        let peerValue = self.peerValue
        self.peerDisposable.set((account.postbox.loadedPeerWithId(peerId) |> deliverOnMainQueue).start(next: { peer in
            _ = peerValue.swap(peer)
        }))

        core.start()

        DispatchQueue.main.async {
            CallsCoreHooks.shared.showCall(self)
        }
    }

    deinit {
        self.peerDisposable.dispose()
        if let core = self.core {
            relayOnMain {
                core.sessionReleased()
            }
        }
    }

    @MainActor
    public static func outgoing(sharedContext: any SharedAccountContextProtocol, account: Account, peerId: PeerId, isVideo: Bool) -> Signal<RelayPeerCallSession?, NoError> {
        return Signal { subscriber in
            let task = Task { @MainActor in
                guard let relayAccount = MattermostSync.relayCallsAccount(accountId: account.id),
                      let channel = try? await MattermostSync.relayCallChannel(accountId: account.id, peerId: peerId),
                      channel.kind == .direct,
                      let peerUserId = channel.peerUserId else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                let session = RelayPeerCallSession(sharedContext: sharedContext, account: account, peerId: peerId, isOutgoing: true, isVideo: isVideo, isIncomingConference: false, relayAccount: relayAccount, mode: { media in
                    return .direct(RelayDirectCall.outgoing(api: relayAccount.client, engine: media, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, channelId: channel.channelId, peerUserId: peerUserId, video: isVideo))
                })
                subscriber.putNext(session)
                subscriber.putCompletion()
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    @MainActor
    public static func incoming(sharedContext: any SharedAccountContextProtocol, account: Account, call: RelayCall) -> RelayPeerCallSession? {
        guard let relayAccount = MattermostSync.relayCallsAccount(accountId: account.id), call.isRinging(for: relayAccount.ownUserId) else {
            return nil
        }
        guard let callerPeerId = MattermostSync.relayCallPeerId(accountId: account.id, userId: call.startedBy) else {
            return nil
        }
        switch call.kind {
        case .direct:
            return RelayPeerCallSession(sharedContext: sharedContext, account: account, peerId: callerPeerId, isOutgoing: false, isVideo: call.video, isIncomingConference: false, relayAccount: relayAccount, mode: { media in
                return .direct(RelayDirectCall.incoming(api: relayAccount.client, engine: media, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, call: call))
            })
        case .group:
            guard let channel = MattermostSync.relayCallChannel(accountId: account.id, channelId: call.channelId) else {
                return nil
            }
            return RelayPeerCallSession(sharedContext: sharedContext, account: account, peerId: callerPeerId, isOutgoing: false, isVideo: false, isIncomingConference: true, relayAccount: relayAccount, mode: { media in
                return .groupRing(RelayGroupCall.incoming(api: relayAccount.client, engine: media, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, call: call), channelPeerId: channel.peerId)
            })
        case .channel:
            return nil
        }
    }

    fileprivate func setIsVideo(_ value: Bool) {
        _ = self.isVideoValue.swap(value)
    }

    public func acceptCallSession() {
        let window = self.window
        _ = (requestMicrophonePermission() |> deliverOnMainQueue).start(next: { [weak self] access in
            MainActor.assumeIsolated {
                guard let self, let core = self.core else {
                    return
                }
                if access {
                    core.accept()
                } else {
                    if let window {
                        CallsCoreHooks.shared.verifyAlert(window, strings().requestAccesErrorHaveNotAccessCall, strings().modalOK, "", strings().requestAccesErrorConirmSettings, { optionSelected in
                            if optionSelected {
                                openSystemSettings(.microphone)
                            }
                        })
                    }
                    core.hangup()
                }
            }
        })
    }

    public func toggleMute() {
        relayOnMain { [weak self] in
            self?.core?.toggleMute()
        }
    }

    public func requestVideo() {
        relayOnMain { [weak self] in
            self?.core?.requestVideo()
        }
    }

    public func disableVideo() {
        relayOnMain { [weak self] in
            self?.core?.disableVideo()
        }
    }

    public func toggleScreenCapture() -> ScreenCaptureLaunchError? {
        return MainActor.assumeIsolated {
            return self.core?.toggleScreenCapture()
        }
    }

    public func setToRemovableState() {
        relayOnMain { [weak self] in
            self?.core?.setRemovable()
        }
    }

    @discardableResult
    public func hangUpCurrentCall() -> Signal<Bool, NoError> {
        relayOnMain { [weak self] in
            self?.core?.hangup()
        }
        return self.canBeRemovedPromise.get()
    }

    public func makeVideoSource(isIncoming: Bool) -> VideoSource? {
        return MainActor.assumeIsolated {
            return self.core?.makeVideoSource(isIncoming: isIncoming)
        }
    }

    public func makeFallbackVideoView(isIncoming: Bool, completion: @escaping (CallVideoView?) -> Void) {
        relayOnMain { [weak self] in
            guard let source = self?.core?.makeVideoSource(isIncoming: isIncoming) else {
                completion(nil)
                return
            }
            completion(MetalVideoMakeView(videoSource: source))
        }
    }
}

@MainActor
final class RelayPeerCallCore {
    enum Mode {
        case direct(RelayDirectCall)
        case groupRing(RelayGroupCall, channelPeerId: PeerId)
    }

    private weak var session: RelayPeerCallSession?
    private let account: Account
    private let sharedContext: any SharedAccountContextProtocol
    private let isOutgoing: Bool
    private let relayAccount: MattermostRelayCallsAccount
    private let media: RelayRoomEngine
    private let mode: Mode
    private let tones = RelayTonePlayer()
    private let videoSources = RelayVideoSourceRegistry()
    private let peers: RelayPeerResolver
    private let devices: DevicesContext
    private var observation: RelayCancellable?
    private let eventsDisposable = MetaDisposable()
    private let devicesDisposable = MetaDisposable()
    private let removeDisposable = MetaDisposable()
    private var acceptedLocally = false
    private var wasAnswered = false
    private var handedOff = false
    private var terminated = false
    private var removable = false
    private weak var captureSelectWindow: NSWindow?
    private var channelPeer: Peer?
    private let channelPeerDisposable = MetaDisposable()

    init(session: RelayPeerCallSession, relayAccount: MattermostRelayCallsAccount, media: RelayRoomEngine, mode: Mode) {
        self.session = session
        self.account = session.account
        self.sharedContext = session.sharedContext
        self.isOutgoing = session.isOutgoing
        self.relayAccount = relayAccount
        self.media = media
        self.mode = mode
        self.peers = RelayPeerResolver(account: session.account)
        self.devices = CallsCoreHooks.shared.devicesContext(session.sharedContext)
    }

    func start() {
        self.peers.onChange = { [weak self] in
            self?.publish()
        }
        let accountId = self.account.id
        self.eventsDisposable.set((MattermostSync.relayCallEvents(accountId: accountId) |> deliverOnMainQueue).start(next: { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }))
        self.devicesDisposable.set((self.devices.updater() |> deliverOnMainQueue).start(next: { [weak self] update in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                RelayAudioDevices.apply(self.devices)
                if update.camera != nil, case let .direct(call) = self.mode, call.snapshot.isCameraEnabled {
                    let device = relayCameraDevice(self.devices)
                    let media = self.media
                    Task {
                        try? await media.setCameraDevice(device)
                    }
                }
            }
        }))
        RelayAudioDevices.apply(self.devices)
        switch self.mode {
        case let .direct(call):
            if call.isVideo && call.isOutgoing {
                let media = self.media
                let device = relayCameraDevice(self.devices)
                Task {
                    try? await media.setCameraDevice(device)
                }
            }
            self.observation = call.observe { [weak self] _ in
                self?.changed()
            }
            call.start()
        case let .groupRing(call, channelPeerId):
            self.channelPeerDisposable.set((self.account.postbox.loadedPeerWithId(channelPeerId) |> deliverOnMainQueue).start(next: { [weak self] peer in
                MainActor.assumeIsolated {
                    self?.channelPeer = peer
                }
            }))
            self.observation = call.observe { [weak self] _ in
                self?.changed()
            }
            call.start()
        }
        self.changed()
    }

    private func handle(_ event: RelayCallsEvent) {
        switch self.mode {
        case let .direct(call):
            call.handle(event)
        case let .groupRing(call, _):
            if !self.handedOff {
                call.handle(event)
            }
        }
    }

    private func changed() {
        guard !self.handedOff else {
            return
        }
        self.videoSources.refresh()
        self.publish()
    }

    private func publish() {
        guard let session = self.session, !self.handedOff else {
            return
        }
        let cameraAvailable = relayIsCameraAvailable && relayHasCamera
        var participants: [EnginePeer] = []
        var conferenceReference: MessageId?
        let state: CallState.State
        let tone: CallTone?
        var isMuted = false
        var cameraOn = false
        var screenOn = false
        var remoteVideo = false
        var remoteAspect: Float = 0
        var remoteMuted = false
        var level: Float = 0
        var callId: String?
        switch self.mode {
        case let .direct(call):
            let snapshot = call.snapshot
            callId = snapshot.callId
            isMuted = snapshot.isMuted
            cameraOn = snapshot.local?.isCameraEnabled == true
            screenOn = snapshot.local?.isScreenSharing == true
            if let remote = snapshot.remote {
                let track = remote.isScreenSharing ? remote.screenShare : (remote.isCameraEnabled ? remote.camera : nil)
                if let track {
                    remoteVideo = true
                    if let width = track.width, let height = track.height, height > 0 {
                        remoteAspect = Float(width) / Float(height)
                    }
                }
                remoteMuted = !remote.isMicrophoneEnabled
                level = remote.audioLevel
            }
            if snapshot.isCameraEnabled || cameraOn || screenOn {
                session.setIsVideo(true)
            }
            let reception = relayReception(snapshot.local?.connectionQuality)
            switch snapshot.state {
            case let .requesting(ringing):
                state = .requesting(ringing)
                tone = .ringback
            case .ringing:
                state = .ringing
                tone = .ringing
            case .connecting:
                self.wasAnswered = true
                state = .connecting(nil)
                tone = self.isOutgoing ? .ringback : nil
            case let .active(since):
                self.wasAnswered = true
                state = .active(since.timeIntervalSinceReferenceDate, reception, Data())
                tone = nil
            case let .reconnecting(since):
                self.wasAnswered = true
                state = .reconnecting(since.timeIntervalSinceReferenceDate, reception, Data())
                tone = .connecting
            case let .terminated(reason, _):
                let mapped = relayTerminationReason(reason)
                state = .terminated(nil, mapped, false)
                if self.isOutgoing || self.wasAnswered {
                    switch mapped {
                    case .ended(.busy):
                        tone = .busy
                    case .error:
                        tone = .failed
                    default:
                        tone = .ended
                    }
                } else {
                    tone = nil
                }
                self.terminate(mapped)
            }
        case let .groupRing(call, channelPeerId):
            let snapshot = call.snapshot
            callId = snapshot.callId
            conferenceReference = MessageId(peerId: channelPeerId, namespace: Namespaces.Message.Cloud, id: 0)
            let userIds = (snapshot.call?.participantIds ?? []).filter { $0 != self.relayAccount.ownUserId && $0 != snapshot.call?.startedBy }
            self.peers.resolve(userIds)
            participants = userIds.compactMap { self.peers.peer(userId: $0) }
            switch snapshot.state {
            case .ringing:
                state = .ringing
                tone = .ringing
            case let .ended(reason):
                let mapped: CallSessionTerminationReason
                switch reason {
                case .missed:
                    mapped = .ended(.missed)
                case .failed:
                    mapped = .error(.generic)
                default:
                    mapped = .ended(.hungUp)
                }
                state = .terminated(nil, mapped, false)
                tone = nil
                self.terminate(mapped)
            case .connecting, .connected, .reconnecting:
                state = .connecting(nil)
                tone = nil
            }
        }
        _ = session.relayCallIdValue.swap(callId)
        self.tones.play(tone)
        let videoState: CallState.VideoState = (cameraOn || screenOn) ? .active(cameraAvailable) : .inactive(cameraAvailable)
        session.audioLevelPromise.set(level)
        session.statePromise.set(CallState(state: state, videoState: videoState, remoteVideoState: remoteVideo ? .active : .inactive, isMuted: isMuted, isOutgoingVideoPaused: !cameraOn, remoteAspectRatio: remoteAspect, remoteAudioState: remoteMuted ? .muted : .active, remoteBatteryLevel: .normal, isScreenCapture: screenOn && !cameraOn, participants: participants, conferenceReference: conferenceReference, supportsConferenceCalls: false))
    }

    private func terminate(_ reason: CallSessionTerminationReason) {
        if self.terminated {
            return
        }
        self.terminated = true
        self.observation = nil
        self.eventsDisposable.set(nil)
        self.devicesDisposable.set(nil)
        if reason.recall {
            return
        }
        self.sharedContext.dropCrossCall()
        self.removeDisposable.set((Signal<Void, NoError>.single(Void()) |> delay(1.6, queue: Queue.mainQueue())).start(next: { [weak self] in
            MainActor.assumeIsolated {
                self?.setRemovable()
            }
        }))
    }

    func setRemovable() {
        if self.removable {
            return
        }
        self.removable = true
        if !self.handedOff {
            self.sharedContext.dropCrossCall()
        }
        self.session?.canBeRemovedPromise.set(true)
    }

    func accept() {
        switch self.mode {
        case let .direct(call):
            self.acceptedLocally = true
            if call.isVideo && relayIsCameraAvailable && relayHasCamera {
                self.requestVideo()
            }
            call.accept()
        case let .groupRing(call, channelPeerId):
            guard let session = self.session, let accountContext = session.accountContext, let window = session.window, case .ringing = call.state else {
                call.accept()
                return
            }
            self.handedOff = true
            self.tones.stop()
            self.observation = nil
            self.eventsDisposable.set(nil)
            self.devicesDisposable.set(nil)
            let groupCall = RelayPresentationGroupCall(accountContext: accountContext, relayAccount: self.relayAccount, peerId: channelPeerId, peer: self.channelPeer, media: self.media, controller: call, startMuted: false)
            call.accept()
            CallsCoreHooks.shared.presentUpgradedConferenceCall(self.sharedContext, groupCall, accountContext, window)
        }
    }

    func hangup() {
        switch self.mode {
        case let .direct(call):
            let wasLive: Bool
            switch call.state {
            case .active, .reconnecting:
                wasLive = true
            default:
                wasLive = false
            }
            call.hangup()
            if !wasLive {
                self.setRemovable()
            }
        case let .groupRing(call, _):
            if !self.handedOff {
                call.decline()
                self.setRemovable()
            }
        }
    }

    func sessionReleased() {
        if self.handedOff || self.terminated {
            return
        }
        switch self.mode {
        case let .direct(call):
            call.hangup()
        case let .groupRing(call, _):
            call.decline()
        }
        self.tones.stop()
    }

    func toggleMute() {
        if case let .direct(call) = self.mode {
            call.setMuted(!call.snapshot.isMuted)
        }
    }

    func requestVideo() {
        guard case let .direct(call) = self.mode else {
            return
        }
        let media = self.media
        let device = relayCameraDevice(self.devices)
        if call.snapshot.isScreenSharing {
            call.setScreenShare(enabled: false)
        }
        Task { @MainActor in
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    return
                }
            }
            try? await media.setCameraDevice(device)
            call.setCameraEnabled(true)
        }
    }

    func disableVideo() {
        guard case let .direct(call) = self.mode else {
            return
        }
        call.setCameraEnabled(false)
        if call.snapshot.isScreenSharing {
            call.setScreenShare(enabled: false)
        }
    }

    func toggleScreenCapture() -> ScreenCaptureLaunchError? {
        guard case let .direct(call) = self.mode else {
            return nil
        }
        if call.snapshot.local?.isScreenSharing == true {
            call.setScreenShare(enabled: false)
            return nil
        }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            return .permission
        }
        if let window = self.captureSelectWindow {
            window.orderFrontRegardless()
            return nil
        }
        self.captureSelectWindow = CallsCoreHooks.shared.presentScreenCapturePicker(self.devices, call.snapshot.isMuted, { [weak self] source, _ in
            relayOnMain {
                self?.shareScreen(source)
            }
        })
        return nil
    }

    private func shareScreen(_ source: VideoSourceMac) {
        guard case let .direct(call) = self.mode else {
            return
        }
        let media = self.media
        Task { @MainActor in
            guard let target = await relayScreenShareSource(media: media, source: source) else {
                return
            }
            if call.snapshot.isCameraEnabled {
                call.setCameraEnabled(false)
            }
            try? await media.shareScreen(source: target)
        }
    }

    func makeVideoSource(isIncoming: Bool) -> VideoSource? {
        guard case let .direct(call) = self.mode else {
            return nil
        }
        let source = LiveKitVideoSource(engine: self.media, viewSize: CGSize(width: 1280, height: 720), resolveTarget: { [weak call] in
            guard let call else {
                return nil
            }
            let snapshot = call.snapshot
            if isIncoming {
                guard let remote = snapshot.remote else {
                    return nil
                }
                if remote.isScreenSharing, let track = remote.screenShare {
                    return RelayVideoTarget(trackSid: track.sid, mirrored: false)
                }
                if let track = remote.camera {
                    return RelayVideoTarget(trackSid: track.sid, mirrored: false)
                }
                return nil
            } else {
                guard let local = snapshot.local else {
                    return nil
                }
                if local.isScreenSharing, let track = local.screenShare {
                    return RelayVideoTarget(trackSid: track.sid, mirrored: false)
                }
                if let track = local.camera {
                    return RelayVideoTarget(trackSid: track.sid, mirrored: true)
                }
                return nil
            }
        })
        self.videoSources.add(source)
        return source
    }
}

func relayTerminationReason(_ reason: RelayDirectCall.EndReason) -> CallSessionTerminationReason {
    switch reason {
    case .hangup, .remoteHangup, .declinedLocally, .answeredElsewhere, .declinedElsewhere, .ended:
        return .ended(.hungUp)
    case .declined, .busy:
        return .ended(.busy)
    case .missed, .cancelled:
        return .ended(.missed)
    case .failed:
        return .error(.generic)
    }
}

@MainActor
func relayScreenShareSource(media: RelayRoomEngine, source: VideoSourceMac) async -> MacOSScreenCaptureSource? {
    guard let sources = try? await media.screenShareSources() else {
        return nil
    }
    guard let desktop = source as? DesktopCaptureSourceMac else {
        return sources.first(where: { $0 is MacOSDisplay })
    }
    let id = UInt32(truncatingIfNeeded: desktop.uniqueId())
    if desktop.isWindow() {
        return sources.first(where: { ($0 as? MacOSWindow)?.windowID == id })
    }
    return sources.first(where: { ($0 as? MacOSDisplay)?.displayID == id }) ?? sources.first(where: { $0 is MacOSDisplay })
}
