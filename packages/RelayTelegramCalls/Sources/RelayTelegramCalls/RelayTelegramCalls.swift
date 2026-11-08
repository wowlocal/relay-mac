import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import TelegramContext
import TelegramCallsCore
import MattermostSync
import RelayCallsCore

public func installRelayTelegramCalls() {
    RelayCallHooks.install(RelayCallHooks(startPeerCall: { sharedContext, account, peerId, isVideo in
        return Signal<Void, NoError>.single(Void())
        |> deliverOnMainQueue
        |> mapToSignal { _ -> Signal<(any PresentationPeerCall)?, NoError> in
            return MainActor.assumeIsolated {
                return RelayPeerCallSession.outgoing(sharedContext: sharedContext, account: account, peerId: peerId, isVideo: isVideo) |> map { session -> (any PresentationPeerCall)? in
                    return session
                }
            }
        }
    }, startGroupCall: { context, peerId, activeCall in
        return Signal<Void, NoError>.single(Void())
        |> deliverOnMainQueue
        |> mapToSignal { _ -> Signal<(any PresentationGroupCall)?, NoError> in
            return MainActor.assumeIsolated {
                return RelayPresentationGroupCall.start(accountContext: context, peerId: peerId, activeCall: activeCall) |> map { call -> (any PresentationGroupCall)? in
                    return call
                }
            }
        }
    }, groupCallPanelData: { context, peerId, activeCall in
        return relayGroupCallPanelData(account: context.account, peerId: peerId, activeCall: activeCall)
    }))
}

public func relayIncomingRings(accountId: AccountRecordId) -> Signal<RelayCall, NoError> {
    return Signal { subscriber in
        var seen = Set<String>()
        let emit: ([RelayCall]) -> Void = { calls in
            guard let ownUserId = MattermostSync.relayCallsAccount(accountId: accountId)?.ownUserId else {
                return
            }
            let now = Date()
            for call in calls where call.kind != .channel && call.isRinging(for: ownUserId) && !seen.contains(call.id) {
                if let expiry = call.ringExpiryDate, expiry < now {
                    continue
                }
                seen.insert(call.id)
                if MattermostSync.relayCallPeerId(accountId: accountId, userId: call.startedBy) != nil {
                    subscriber.putNext(call)
                } else {
                    Task {
                        await MattermostSync.ensureRelayCallUsers(accountId: accountId, userIds: [call.startedBy])
                        Queue.mainQueue().async {
                            subscriber.putNext(call)
                        }
                    }
                }
            }
        }
        let disposable = (MattermostSync.relayCallEvents(accountId: accountId) |> deliverOnMainQueue).start(next: { event in
            switch event {
            case let .incoming(call, _):
                emit([call])
            case let .activeCalls(calls):
                emit(calls)
            default:
                break
            }
        })
        Queue.mainQueue().async {
            emit(MattermostSync.relayLiveCalls(accountId: accountId))
        }
        Task {
            await MattermostSync.refreshRelayCalls(accountId: accountId)
        }
        return disposable
    }
}

public func relayDeclineBusy(accountId: AccountRecordId, callId: String) {
    guard let account = MattermostSync.relayCallsAccount(accountId: accountId) else {
        return
    }
    let client = account.client
    let deviceId = account.deviceId
    Task {
        await RelayDirectCall.declineBusy(api: client, callId: callId, deviceId: deviceId)
    }
}

public func relayIsCurrentCall(_ callId: String, peerCall: (any PresentationPeerCall)?, groupCall: (any PresentationGroupCall)?) -> Bool {
    if let session = peerCall as? RelayPeerCallSession, session.relayCallId == callId {
        return true
    }
    if let call = groupCall as? RelayPresentationGroupCall, call.relayCallId == callId {
        return true
    }
    return false
}

func relayGroupCallPanelData(account: Account, peerId: PeerId, activeCall: CachedChannelData.ActiveCall) -> Signal<GroupCallPanelData?, NoError> {
    let accountId = account.id
    return MattermostSync.relayLiveCallsSignal(accountId: accountId)
    |> map { calls -> RelayCall? in
        return calls.last(where: { $0.kind != .direct && $0.isLive && MattermostSync.relayGroupCallId(callId: $0.id) == activeCall.id })
    }
    |> distinctUntilChanged
    |> mapToSignal { call -> Signal<GroupCallPanelData?, NoError> in
        guard let call else {
            return .single(nil)
        }
        let participantCount = call.participantIds.isEmpty ? call.participants : call.participantIds.count
        let topUserIds = Array(call.participantIds.prefix(3))
        let info = GroupCallInfo(id: activeCall.id, accessHash: activeCall.accessHash, participantCount: participantCount, streamDcId: nil, title: nil, scheduleTimestamp: nil, subscribedToScheduled: false, recordingStartTimestamp: nil, sortAscending: true, defaultParticipantsAreMuted: nil, messagesAreEnabled: nil, isVideoEnabled: true, unmutedVideoLimit: 100, isStream: false, isCreator: false, defaultSendAs: nil)
        let empty = GroupCallPanelData(peerId: peerId, isChannel: false, info: info, topParticipants: [], participantCount: participantCount, activeSpeakers: Set(), groupCall: nil)
        let participants = Signal<[GroupCallParticipantsContext.Participant], NoError> { subscriber in
            let disposable = MetaDisposable()
            let task = Task {
                await MattermostSync.ensureRelayCallUsers(accountId: accountId, userIds: topUserIds)
                let peerIds = topUserIds.compactMap { MattermostSync.relayCallPeerId(accountId: accountId, userId: $0) }
                disposable.set((account.postbox.transaction { transaction -> [GroupCallParticipantsContext.Participant] in
                    return peerIds.compactMap { peerId in
                        guard let peer = transaction.getPeer(peerId) else {
                            return nil
                        }
                        return GroupCallParticipantsContext.Participant(id: .peer(peerId), peer: EnginePeer(peer), ssrc: nil, videoDescription: nil, presentationDescription: nil, joinTimestamp: 0, raiseHandRating: nil, hasRaiseHand: false, activityTimestamp: nil, activityRank: nil, muteState: nil, volume: nil, about: nil, joinedVideo: true, paidStarsTotal: nil)
                    }
                }).start(next: { participants in
                    subscriber.putNext(participants)
                    subscriber.putCompletion()
                }))
            }
            return ActionDisposable {
                task.cancel()
                disposable.dispose()
            }
        }
        return Signal<GroupCallPanelData?, NoError>.single(empty) |> then(participants |> map { participants -> GroupCallPanelData? in
            return GroupCallPanelData(peerId: peerId, isChannel: false, info: info, topParticipants: participants, participantCount: participantCount, activeSpeakers: Set(), groupCall: nil)
        })
    }
}
