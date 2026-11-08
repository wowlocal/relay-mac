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
import TelegramVoip
import CallVideoLayer
import TgVoipWebrtc
import MattermostSync
import RelayCallsCore
import RelayCalls
import LiveKit

public final class RelayPresentationGroupCall: PresentationGroupCall {
    public let account: Account
    public let engine: TelegramEngine
    public let accountContext: (any AccountContextProtocol)
    public let sharedContext: (any SharedAccountContextProtocol)
    public let internalId = CallSessionInternalId()
    public let peerId: PeerId?
    public let isStream: Bool = false
    public let isConference: Bool = false
    public var mustStopSharing: (() -> Void)?
    public var mustStopVideo: (() -> Void)?
    public var permissions: (PresentationGroupCallMuteAction, @escaping (Bool) -> Void) -> Void = { _, f in f(true) }

    private let peerValue: Atomic<Peer?>
    private let callIdValue = Atomic<Int64?>(value: nil)
    private let relayCallIdValue = Atomic<String?>(value: nil)
    private let peerDisposable = MetaDisposable()
    fileprivate let canBeRemovedPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    fileprivate let statePromise: ValuePromise<PresentationGroupCallState>
    fileprivate let membersPromise = ValuePromise<PresentationGroupCallMembers?>(nil, ignoreRepeated: true)
    fileprivate let audioLevelsPromise = Promise<[(PeerId, UInt32, Float, Bool)]>([])
    fileprivate let myAudioLevelPromise = ValuePromise<Float>(0, ignoreRepeated: true)
    fileprivate let invitedPeersPromise = ValuePromise<[PresentationGroupCallInvitedPeer]>([], ignoreRepeated: true)
    fileprivate let isMutedPromise: ValuePromise<Bool>
    fileprivate let summaryStatePromise = ValuePromise<PresentationGroupCallSummaryState?>(nil, ignoreRepeated: true)
    fileprivate let callInfoPromise = ValuePromise<GroupCallInfo?>(nil, ignoreRepeated: true)
    fileprivate let stateVersionPromise = ValuePromise<Int>(0, ignoreRepeated: true)
    fileprivate let isSpeakingPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private var core: RelayGroupCallCore?

    public var peer: Peer? {
        return self.peerValue.with { $0 }
    }

    public var joinAsPeerId: PeerId {
        return self.account.peerId
    }

    public var joinAsPeerIdValue: Signal<PeerId, NoError> {
        return .single(self.account.peerId)
    }

    public var callId: Int64? {
        return self.callIdValue.with { $0 }
    }

    public var relayCallId: String? {
        return self.relayCallIdValue.with { $0 }
    }

    public var canBeRemoved: Signal<Bool, NoError> { self.canBeRemovedPromise.get() }
    public var state: Signal<PresentationGroupCallState, NoError> { self.statePromise.get() }
    public var members: Signal<PresentationGroupCallMembers?, NoError> { self.membersPromise.get() }
    public var audioLevels: Signal<[(PeerId, UInt32, Float, Bool)], NoError> { self.audioLevelsPromise.get() }
    public var myAudioLevel: Signal<Float, NoError> { self.myAudioLevelPromise.get() }
    public var invitedPeers: Signal<[PresentationGroupCallInvitedPeer], NoError> { self.invitedPeersPromise.get() }
    public var isMuted: Signal<Bool, NoError> { self.isMutedPromise.get() }
    public var summaryState: Signal<PresentationGroupCallSummaryState?, NoError> { self.summaryStatePromise.get() }
    public var callInfo: Signal<GroupCallInfo?, NoError> { self.callInfoPromise.get() }
    public var stateVersion: Signal<Int, NoError> { self.stateVersionPromise.get() }
    public var isSpeaking: Signal<Bool, NoError> { self.isSpeakingPromise.get() }
    public var e2eEncryptionKeyHash: Signal<Data?, NoError> { .single(nil) }
    public var messagesState: Signal<GroupCallMessagesContext.State, NoError> {
        return .single(GroupCallMessagesContext.State(messages: [], pinnedMessages: [], topStars: [], totalStars: 0, pendingMyStars: 0))
    }
    public var inviteLinks: Signal<GroupCallInviteLinks?, NoError> { .single(nil) }
    public var displayAsPeers: Signal<[FoundPeer]?, NoError> { .single(nil) }

    @MainActor
    init(accountContext: any AccountContextProtocol, relayAccount: MattermostRelayCallsAccount, peerId: PeerId, peer: Peer?, media: RelayRoomEngine, controller: RelayGroupCall, startMuted: Bool) {
        self.accountContext = accountContext
        self.account = accountContext.account
        self.engine = accountContext.engine
        self.sharedContext = accountContext.sharedContext
        self.peerId = peerId
        self.peerValue = Atomic(value: peer)
        self.isMutedPromise = ValuePromise(startMuted, ignoreRepeated: true)
        self.statePromise = ValuePromise(RelayGroupCallCore.callState(myPeerId: accountContext.account.peerId, isConnected: false, isMuted: startMuted, sources: VideoSources(), presentationEndpointId: nil), ignoreRepeated: true)

        if peer == nil {
            let peerValue = self.peerValue
            self.peerDisposable.set((accountContext.account.postbox.loadedPeerWithId(peerId) |> deliverOnMainQueue).start(next: { peer in
                _ = peerValue.swap(peer)
            }))
        }

        let core = RelayGroupCallCore(call: self, relayAccount: relayAccount, media: media, controller: controller, startMuted: startMuted)
        self.core = core
        core.start()
    }

    deinit {
        self.peerDisposable.dispose()
    }

    fileprivate func setCallId(_ relayCallId: String) {
        _ = self.relayCallIdValue.swap(relayCallId)
        _ = self.callIdValue.swap(MattermostSync.relayGroupCallId(callId: relayCallId))
    }

    @MainActor
    public static func start(accountContext: any AccountContextProtocol, peerId: PeerId, activeCall: CachedChannelData.ActiveCall?) -> Signal<RelayPresentationGroupCall?, NoError> {
        let account = accountContext.account
        return Signal { subscriber in
            let task = Task { @MainActor in
                guard let relayAccount = MattermostSync.relayCallsAccount(accountId: account.id),
                      let channel = try? await MattermostSync.relayCallChannel(accountId: account.id, peerId: peerId),
                      channel.kind != .direct else {
                    subscriber.putNext(nil)
                    subscriber.putCompletion()
                    return
                }
                var callId: String?
                var kind = channel.kind
                if let activeCall, let reference = MattermostSync.relayCall(groupCallId: activeCall.id), reference.accountId == account.id, reference.channelId == channel.channelId {
                    callId = reference.callId
                    kind = reference.kind
                } else if let live = MattermostSync.relayLiveCall(accountId: account.id, peerId: peerId), live.kind != .direct, live.isLive {
                    callId = live.id
                    kind = live.kind
                }
                let peer = await withCheckedContinuation { (continuation: CheckedContinuation<Peer?, Never>) in
                    _ = (account.postbox.transaction { $0.getPeer(peerId) }).start(next: { peer in
                        continuation.resume(returning: peer)
                    })
                }
                let media = RelayRoomEngine(options: RelayRoomEngine.Options())
                let controller: RelayGroupCall
                if let callId {
                    controller = RelayGroupCall.join(api: relayAccount.client, engine: media, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, channelId: channel.channelId, callId: callId, kind: kind)
                } else if kind == .group {
                    controller = RelayGroupCall.ring(api: relayAccount.client, engine: media, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, channelId: channel.channelId, video: false)
                } else {
                    controller = RelayGroupCall.join(api: relayAccount.client, engine: media, ownUserId: relayAccount.ownUserId, deviceId: relayAccount.deviceId, channelId: channel.channelId, callId: nil, kind: .channel)
                }
                let call = RelayPresentationGroupCall(accountContext: accountContext, relayAccount: relayAccount, peerId: peerId, peer: peer, media: media, controller: controller, startMuted: kind == .channel)
                controller.start()
                subscriber.putNext(call)
                subscriber.putCompletion()
            }
            return ActionDisposable {
                task.cancel()
            }
        }
    }

    private func onMain(_ body: @escaping @MainActor (RelayGroupCallCore) -> Void) {
        relayOnMain { [weak self] in
            if let core = self?.core {
                body(core)
            }
        }
    }

    public func raiseHand() {
    }

    public func lowerHand() {
    }

    public func resetListenerLink() {
    }

    public func leave(terminateIfPossible: Bool) -> Signal<Bool, NoError> {
        self.onMain { core in
            core.leave(terminate: terminateIfPossible)
        }
        return .single(true)
    }

    public func toggleIsMuted() {
        self.onMain { core in
            self.setIsMuted(action: core.isMutedAction.isEffectivelyMuted ? .unmuted : .muted(isPushToTalkActive: false))
        }
    }

    public func setVolume(peerId: PeerId, volume: Int32, sync: Bool) {
        self.onMain { core in
            core.setVolume(peerId: peerId, volume: volume)
        }
    }

    public func setIsMuted(action: PresentationGroupCallMuteAction) {
        self.permissions(action, { [weak self] granted in
            guard granted else {
                return
            }
            self?.onMain { core in
                core.setMuted(action)
            }
        })
    }

    public func updateMuteState(peerId: PeerId, isMuted: Bool) -> GroupCallParticipantsContext.Participant.MuteState? {
        return nil
    }

    public func invitePeer(_ peerId: PeerId, isVideo: Bool) -> Bool {
        return false
    }

    public func kickPeer(id: EnginePeer.Id) {
    }

    public func removedPeer(_ peerId: PeerId) {
    }

    public func updateDefaultParticipantsAreMuted(isMuted: Bool) {
    }

    public func setRequestedVideoList(items: [PresentationGroupCallRequestedVideo]) {
        self.onMain { core in
            core.setRequestedVideoList(items)
        }
    }

    public func setSuspendVideoChannelRequests(_ value: Bool) {
        self.onMain { core in
            core.setSuspended(value)
        }
    }

    public func makeVideoView(endpointId: String, videoMode: GroupCallVideoMode, completion: @escaping (PresentationCallVideoView?) -> Void) {
        self.onMain { core in
            guard let source = core.makeVideoSource(endpointId: endpointId) else {
                completion(nil)
                return
            }
            let videoView = MetalVideoMakeView(videoSource: source)
            completion(PresentationCallVideoView(holder: videoView, view: videoView, setOnFirstFrameReceived: { [weak videoView] f in
                videoView?.firstFrameRendered = {
                    f?(0)
                }
            }, getOrientation: {
                return .rotation0
            }, getAspect: {
                return 0
            }, setVideoContentMode: { [weak videoView] gravity in
                videoView?.setGravity(gravity)
            }, setOnOrientationUpdated: { _ in
            }, setOnIsMirroredUpdated: { _ in
            }, setIsPaused: { [weak videoView] paused in
                videoView?.isPaused = paused
            }, renderToSize: { [weak videoView] size, animated in
                videoView?.updateLayout(size: size, transition: animated ? .animated(duration: 0.3, curve: .easeOut) : .immediate)
            }))
        }
    }

    public func requestVideo(deviceId: OngoingCallVideoCapturer, source: VideoSourceMac) {
        self.requestVideo(deviceId: source.deviceIdKey(), source: source)
    }

    public func requestVideo(deviceId: String, source: VideoSourceMac) {
        self.onMain { core in
            core.requestVideo(deviceId: deviceId, source: source)
        }
    }

    public func disableVideo() {
        self.onMain { core in
            core.disableVideo()
        }
    }

    public func requestScreencast(deviceId: OngoingCallVideoCapturer, source: VideoSourceMac) {
        self.requestScreencast(deviceId: source.deviceIdKey(), source: source)
    }

    public func requestScreencast(deviceId: String, source: VideoSourceMac) {
        self.onMain { core in
            core.requestScreencast(source: source)
        }
    }

    public func disableScreencast() {
        self.onMain { core in
            core.disableScreencast()
        }
    }

    public func toggleVideoFailed(failed: Bool) {
        self.onMain { core in
            core.setVideoFailed(failed)
        }
    }

    public func loadMore() {
    }

    public func joinAsSpeakerIfNeeded(_ joinHash: String) {
    }

    public func reconnect(as peerId: PeerId) {
    }

    public func updateTitle(_ title: String, force: Bool) {
    }

    public func setShouldBeRecording(_ shouldBeRecording: Bool, title: String?, videoOrientation: Bool?) {
    }

    public func startScheduled() {
    }

    public func toggleScheduledSubscription(_ subscribe: Bool) {
    }

    public func sendMessage(text: String, entities: [MessageTextEntity], paidStars: Int64?) {
    }

    public func sendStars(amount: Int64) {
    }

    public func deleteMessage(id: GroupCallMessagesContext.Message.Id, authorId: EnginePeer.Id, reportSpam: Bool, deleteAll: Bool) {
    }

    public func updateMessagesEnabled(isEnabled: Bool) {
    }

    public func setDefaultSendAs(_ peerId: PeerId?) {
    }
}

@MainActor
final class RelayGroupCallCore {
    private enum VideoKind: String {
        case camera
        case screen
    }

    private weak var call: RelayPresentationGroupCall?
    private let account: Account
    private let relayAccount: MattermostRelayCallsAccount
    private let media: RelayRoomEngine
    private let controller: RelayGroupCall
    private let peers: RelayPeerResolver
    private let devices: DevicesContext
    private let videoSources = RelayVideoSourceRegistry()
    private var sourcesByEndpoint: [String: [WeakVideoSource]] = [:]
    private var requestedQuality: [String: PresentationGroupCallRequestedVideo.Quality] = [:]
    private var suspended = false
    private var observation: RelayCancellable?
    private let eventsDisposable = MetaDisposable()
    private let devicesDisposable = MetaDisposable()
    private let ownPeerDisposable = MetaDisposable()
    private var ownPeer: EnginePeer?
    private var sources = VideoSources()
    private var cameraRequested = false
    private var screenPending = false
    private var screenWasLive = false
    private var activity: [String: Double] = [:]
    private var volumes: [PeerId: Int32] = [:]
    private var version = 0
    private(set) var isMutedAction: PresentationGroupCallMuteAction
    private var ended = false

    private final class WeakVideoSource {
        weak var value: LiveKitVideoSource?
        init(_ value: LiveKitVideoSource) {
            self.value = value
        }
    }

    init(call: RelayPresentationGroupCall, relayAccount: MattermostRelayCallsAccount, media: RelayRoomEngine, controller: RelayGroupCall, startMuted: Bool) {
        self.call = call
        self.account = call.account
        self.relayAccount = relayAccount
        self.media = media
        self.controller = controller
        self.peers = RelayPeerResolver(account: call.account)
        self.devices = CallsCoreHooks.shared.devicesContext(call.sharedContext)
        self.isMutedAction = startMuted ? .muted(isPushToTalkActive: false) : .unmuted
    }

    func start() {
        self.peers.onChange = { [weak self] in
            self?.publish()
        }
        self.controller.setMuted(self.isMutedAction.isEffectivelyMuted)
        self.ownPeerDisposable.set((self.account.postbox.loadedPeerWithId(self.account.peerId) |> deliverOnMainQueue).start(next: { [weak self] peer in
            MainActor.assumeIsolated {
                self?.ownPeer = EnginePeer(peer)
                self?.publish()
            }
        }))
        self.eventsDisposable.set((MattermostSync.relayCallEvents(accountId: self.account.id) |> deliverOnMainQueue).start(next: { [weak self] event in
            MainActor.assumeIsolated {
                self?.controller.handle(event)
            }
        }))
        self.devicesDisposable.set((self.devices.updater() |> deliverOnMainQueue).start(next: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                RelayAudioDevices.apply(self.devices)
            }
        }))
        RelayAudioDevices.apply(self.devices)
        self.observation = self.controller.observe { [weak self] _ in
            self?.changed()
        }
        self.changed()
    }

    private func changed() {
        self.videoSources.refresh()
        self.publish()
    }

    static func callState(myPeerId: PeerId, isConnected: Bool, isMuted: Bool, sources: VideoSources, presentationEndpointId: String?) -> PresentationGroupCallState {
        var state = PresentationGroupCallState(myPeerId: myPeerId, networkState: isConnected ? .connected : .connecting, canManageCall: false, adminIds: Set(), muteState: isMuted ? GroupCallParticipantsContext.Participant.MuteState(canUnmute: true, mutedByYou: false) : nil, defaultParticipantMuteState: nil, messagesEnabled: nil, recordingStartTimestamp: nil, title: nil, raisedHand: false, scheduleTimestamp: nil, subscribedToScheduled: false, isVideoEnabled: true, isStream: false, isChannel: false, isConference: false, sendAs: [], defaultSendAs: nil, sendPaidMessageStars: nil)
        state.sources = sources
        state.presentationEndpointId = presentationEndpointId
        return state
    }

    private static func ssrc(_ userId: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in userId.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        return hash == 0 ? 1 : hash
    }

    private static func endpointId(_ identity: String, _ kind: VideoKind) -> String {
        return "\(identity)|\(kind.rawValue)"
    }

    private func publish() {
        guard let call = self.call else {
            return
        }
        let snapshot = self.controller.snapshot
        let now = Date().timeIntervalSince1970
        let isMuted = self.isMutedAction.isEffectivelyMuted

        if let callId = snapshot.callId {
            call.setCallId(callId)
        }

        if self.cameraRequested && !snapshot.isCameraEnabled {
            self.cameraRequested = false
            if self.sources.video != nil {
                self.sources.video = nil
                call.mustStopVideo?()
            }
        }
        if snapshot.isScreenSharing {
            self.screenWasLive = true
        } else if self.screenWasLive && !self.screenPending {
            self.screenWasLive = false
            self.sources.screencast = nil
        }

        self.peers.resolve(snapshot.participants.filter { !$0.isSelf }.map(\.userId) + snapshot.invitees.keys)

        var participants: [GroupCallParticipantsContext.Participant] = []
        var speaking = Set<PeerId>()
        var levels: [(PeerId, UInt32, Float, Bool)] = []
        var myLevel: Float = 0
        var mySpeaking = false
        var connectedUsers = Set<String>()
        var presentationEndpointId: String?
        for participant in snapshot.participants {
            connectedUsers.insert(participant.userId)
            let peerId: PeerId
            let peer: EnginePeer?
            if participant.isSelf {
                peerId = self.account.peerId
                peer = self.ownPeer
            } else {
                guard let resolvedId = self.peers.peerId(userId: participant.userId) else {
                    continue
                }
                peerId = resolvedId
                peer = self.peers.peer(userId: participant.userId)
            }
            guard let peer else {
                continue
            }
            let ssrc = RelayGroupCallCore.ssrc(participant.userId)
            let speaks = participant.isSpeaking && !(participant.isSelf && isMuted)
            if speaks {
                self.activity[participant.userId] = now
                speaking.insert(peerId)
            }
            let level = participant.isSelf && isMuted ? 0 : participant.audioLevel
            levels.append((peerId, ssrc, level, speaks))
            if participant.isSelf {
                myLevel = level
                mySpeaking = speaks
            }
            var video: GroupCallParticipantsContext.Participant.VideoDescription?
            if let camera = participant.camera, camera.track.isLive {
                video = .init(endpointId: RelayGroupCallCore.endpointId(camera.identity, .camera), ssrcGroups: [], audioSsrc: ssrc, isPaused: false)
            }
            var presentation: GroupCallParticipantsContext.Participant.VideoDescription?
            if let screen = participant.screenShare, screen.track.isLive {
                let endpoint = RelayGroupCallCore.endpointId(screen.identity, .screen)
                presentation = .init(endpointId: endpoint, ssrcGroups: [], audioSsrc: ssrc, isPaused: false)
                if participant.isSelf && screen.isLocal {
                    presentationEndpointId = endpoint
                }
            }
            let micOn = participant.isSelf ? !isMuted : participant.isMicrophoneEnabled
            let joined = participant.joinedAt?.timeIntervalSince1970 ?? now
            participants.append(GroupCallParticipantsContext.Participant(
                id: .peer(peerId),
                peer: peer,
                ssrc: ssrc,
                videoDescription: video,
                presentationDescription: presentation,
                joinTimestamp: Int32(joined),
                raiseHandRating: nil,
                hasRaiseHand: false,
                activityTimestamp: self.activity[participant.userId],
                activityRank: nil,
                muteState: micOn ? nil : GroupCallParticipantsContext.Participant.MuteState(canUnmute: true, mutedByYou: false),
                volume: self.volumes[peerId],
                about: nil,
                joinedVideo: true,
                paidStarsTotal: nil
            ))
        }

        var invited: [PresentationGroupCallInvitedPeer] = []
        for (userId, inviteeState) in snapshot.invitees.sorted(by: { $0.key < $1.key }) where inviteeState.isRinging && !connectedUsers.contains(userId) && userId != self.relayAccount.ownUserId {
            if let peerId = self.peers.peerId(userId: userId) {
                invited.append(PresentationGroupCallInvitedPeer(id: peerId, state: .ringing))
            }
        }

        let isConnected = snapshot.state == .connected
        let state = RelayGroupCallCore.callState(myPeerId: self.account.peerId, isConnected: isConnected, isMuted: self.isMutedVisually, sources: self.sources, presentationEndpointId: presentationEndpointId)
        let members = PresentationGroupCallMembers(participants: participants, speakingParticipants: speaking, totalCount: participants.count, loadMoreToken: nil)

        var info: GroupCallInfo?
        if let callId = snapshot.callId {
            let count = max(participants.count, snapshot.call?.participantIds.count ?? 0)
            info = GroupCallInfo(id: MattermostSync.relayGroupCallId(callId: callId), accessHash: MattermostSync.relayGroupCallId(callId: snapshot.channelId), participantCount: count, streamDcId: nil, title: nil, scheduleTimestamp: nil, subscribedToScheduled: false, recordingStartTimestamp: nil, sortAscending: true, defaultParticipantsAreMuted: nil, messagesAreEnabled: nil, isVideoEnabled: true, unmutedVideoLimit: 100, isStream: false, isCreator: false, defaultSendAs: nil)
        }

        call.statePromise.set(state)
        call.callInfoPromise.set(info)
        call.invitedPeersPromise.set(invited)
        call.membersPromise.set(members)
        self.version += 1
        call.stateVersionPromise.set(self.version)
        call.audioLevelsPromise.set(.single(levels))
        call.myAudioLevelPromise.set(myLevel)
        call.isSpeakingPromise.set(mySpeaking)
        call.summaryStatePromise.set(PresentationGroupCallSummaryState(info: info, participantCount: info?.participantCount ?? participants.count, callState: state, topParticipants: Array(participants.prefix(3)), activeSpeakers: speaking))

        if snapshot.state.isEnded && !self.ended {
            self.ended = true
            self.observation = nil
            self.eventsDisposable.set(nil)
            self.devicesDisposable.set(nil)
            call.canBeRemovedPromise.set(true)
        }
    }

    private var isMutedVisually: Bool {
        switch self.isMutedAction {
        case .muted:
            return true
        case .unmuted:
            return false
        }
    }

    func setMuted(_ action: PresentationGroupCallMuteAction) {
        self.isMutedAction = action
        self.controller.setMuted(action.isEffectivelyMuted)
        self.call?.isMutedPromise.set(action.isEffectivelyMuted)
        self.publish()
    }

    func leave(terminate: Bool) {
        if terminate && self.controller.snapshot.canEnd {
            let controller = self.controller
            Task { @MainActor in
                do {
                    try await controller.endForEveryone()
                } catch {
                    controller.leave()
                }
            }
        } else {
            self.controller.leave()
        }
    }

    func setVolume(peerId: PeerId, volume: Int32) {
        self.volumes[peerId] = volume
        guard let userId = MattermostSync.relayCallUserId(accountId: self.account.id, peerId: peerId) else {
            return
        }
        let value = Double(volume) / 10000.0
        for participant in self.media.room.remoteParticipants.values where RelayParticipantIdentity(participant.identity?.stringValue ?? "")?.userId == userId {
            for publication in participant.audioTracks {
                (publication.track as? RemoteAudioTrack)?.volume = value
            }
        }
        self.publish()
    }

    func setRequestedVideoList(_ items: [PresentationGroupCallRequestedVideo]) {
        self.requestedQuality = Dictionary(items.map { ($0.endpointId, $0.maxQuality) }, uniquingKeysWith: { lhs, _ in lhs })
        self.applyVideoSizes()
    }

    func setSuspended(_ value: Bool) {
        self.suspended = value
        self.applyVideoSizes()
    }

    private func applyVideoSizes() {
        for (endpointId, entries) in self.sourcesByEndpoint {
            let size: CGSize
            switch self.requestedQuality[endpointId] {
            case .thumbnail?:
                size = CGSize(width: 320, height: 180)
            case .medium?:
                size = CGSize(width: 640, height: 360)
            case .full?, nil:
                size = CGSize(width: 1280, height: 720)
            }
            for entry in entries {
                entry.value?.setViewSize(size)
                entry.value?.setVisible(!self.suspended)
            }
        }
    }

    func makeVideoSource(endpointId: String) -> LiveKitVideoSource? {
        let parts = endpointId.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = VideoKind(rawValue: String(parts[1])) else {
            return nil
        }
        let identity = String(parts[0])
        let controller = self.controller
        let source = LiveKitVideoSource(engine: self.media, viewSize: CGSize(width: 1280, height: 720), resolveTarget: { [weak controller] in
            guard let controller else {
                return nil
            }
            for participant in controller.snapshot.participants {
                for device in participant.devices where device.identity == identity {
                    switch kind {
                    case .camera:
                        return device.camera.map { RelayVideoTarget(trackSid: $0.sid, mirrored: device.isLocal) }
                    case .screen:
                        return device.screenShare.map { RelayVideoTarget(trackSid: $0.sid, mirrored: false) }
                    }
                }
            }
            return nil
        })
        self.videoSources.add(source)
        var entries = (self.sourcesByEndpoint[endpointId] ?? []).filter { $0.value != nil }
        entries.append(WeakVideoSource(source))
        self.sourcesByEndpoint[endpointId] = entries
        self.applyVideoSizes()
        return source
    }

    func requestVideo(deviceId: String, source: VideoSourceMac) {
        self.sources.video = source
        self.cameraRequested = false
        self.publish()
        let device = AVCaptureDevice(uniqueID: deviceId)
        let media = self.media
        let controller = self.controller
        Task { @MainActor [weak self] in
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    self?.sources.video = nil
                    self?.call?.mustStopVideo?()
                    self?.publish()
                    return
                }
            }
            try? await media.setCameraDevice(device)
            guard let self, self.sources.video != nil else {
                return
            }
            self.cameraRequested = true
            controller.setCameraEnabled(true)
        }
    }

    func disableVideo() {
        self.sources.video = nil
        self.cameraRequested = false
        self.controller.setCameraEnabled(false)
        self.publish()
    }

    func requestScreencast(source: VideoSourceMac) {
        self.sources.screencast = source
        self.screenPending = true
        self.publish()
        let media = self.media
        Task { @MainActor [weak self] in
            guard let target = await relayScreenShareSource(media: media, source: source) else {
                self?.screencastFailed()
                return
            }
            do {
                try await media.shareScreen(source: target)
                self?.screenPending = false
                self?.publish()
            } catch {
                self?.screencastFailed()
            }
        }
    }

    private func screencastFailed() {
        self.screenPending = false
        self.sources.screencast = nil
        self.call?.mustStopSharing?()
        self.publish()
    }

    func disableScreencast() {
        self.sources.screencast = nil
        self.screenPending = false
        self.controller.setScreenShare(enabled: false)
        self.publish()
    }

    func setVideoFailed(_ failed: Bool) {
        self.sources.failed = failed
        self.publish()
    }
}
