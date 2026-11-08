import Foundation
import TelegramCore
import Postbox
import TelegramCallsCore
import RelayCallsCore
import RelayCalls
import LiveKit

#if DEBUG
public enum RelayCallDebug {
    @MainActor
    public static func info(peerCall: (any PresentationPeerCall)?, groupCall: (any PresentationGroupCall)?) -> [String: Any] {
        var result: [String: Any] = [:]
        if let session = peerCall as? RelayPeerCallSession, let core = session.core {
            var info: [String: Any] = ["relayCallId": session.relayCallId ?? NSNull(), "isOutgoing": session.isOutgoing, "isVideo": session.isVideo, "isIncomingConference": session.isIncomingConference, "peerTitle": session.peer.map { $0.debugDisplayTitle } ?? NSNull()]
            switch core.mode {
            case let .direct(call):
                info["mode"] = "direct"
                info["controller"] = self.direct(call.snapshot)
            case let .groupRing(call, _):
                info["mode"] = "groupRing"
                info["controller"] = self.group(call.snapshot)
            }
            info["tone"] = core.tones.current.map { "\($0)" } ?? NSNull()
            info["screenShareError"] = core.screenShareError ?? NSNull()
            info["media"] = self.media(core.media)
            info["videoSources"] = core.videoSources.sources.map { $0.debugInfo }
            result["peerCall"] = info
        } else if let peerCall {
            result["peerCall"] = ["type": String(describing: type(of: peerCall))]
        }
        if let call = groupCall as? RelayPresentationGroupCall, let core = call.core {
            var info: [String: Any] = ["relayCallId": call.relayCallId ?? NSNull(), "peerTitle": call.peer.map { $0.debugDisplayTitle } ?? NSNull()]
            info["controller"] = self.group(core.controller.snapshot)
            info["muted"] = core.isMutedAction.isEffectivelyMuted
            info["media"] = self.media(core.media)
            info["videoSources"] = core.videoSources.sources.map { $0.debugInfo }
            result["groupCall"] = info
        } else if let groupCall {
            result["groupCall"] = ["type": String(describing: type(of: groupCall))]
        }
        return result
    }

    private static func direct(_ snapshot: RelayDirectCall.Snapshot) -> [String: Any] {
        return [
            "state": "\(snapshot.state)",
            "callId": snapshot.callId ?? NSNull(),
            "call": snapshot.call.map { self.call($0) } ?? NSNull(),
            "isMuted": snapshot.isMuted,
            "isCameraEnabled": snapshot.isCameraEnabled,
            "isScreenSharing": snapshot.isScreenSharing,
            "mediaState": "\(snapshot.mediaState)",
            "local": snapshot.local.map { self.participant($0) } ?? NSNull(),
            "remote": snapshot.remote.map { self.participant($0) } ?? NSNull(),
        ]
    }

    private static func group(_ snapshot: RelayGroupCall.Snapshot) -> [String: Any] {
        return [
            "state": "\(snapshot.state)",
            "kind": snapshot.kind.rawValue,
            "callId": snapshot.callId ?? NSNull(),
            "call": snapshot.call.map { self.call($0) } ?? NSNull(),
            "invitees": snapshot.invitees.mapValues { $0.rawValue },
            "isMuted": snapshot.isMuted,
            "isCameraEnabled": snapshot.isCameraEnabled,
            "isScreenSharing": snapshot.isScreenSharing,
            "mediaState": "\(snapshot.mediaState)",
            "canEnd": snapshot.canEnd,
            "participants": snapshot.participants.map { participant -> [String: Any] in
                return [
                    "userId": participant.userId,
                    "name": participant.name ?? NSNull(),
                    "isSelf": participant.isSelf,
                    "isSpeaking": participant.isSpeaking,
                    "audioLevel": participant.audioLevel,
                    "microphone": participant.isMicrophoneEnabled,
                    "camera": participant.camera.map { "\($0.track.sid) \($0.track.width ?? 0)x\($0.track.height ?? 0)" } ?? NSNull(),
                    "screenShare": participant.screenShare.map { "\($0.track.sid) \($0.track.width ?? 0)x\($0.track.height ?? 0)" } ?? NSNull(),
                    "devices": participant.devices.count,
                ]
            },
        ]
    }

    private static func call(_ call: RelayCall) -> [String: Any] {
        return ["id": call.id, "kind": call.kind.rawValue, "state": call.state.rawValue, "video": call.video, "participantIds": call.participantIds, "invitees": (call.invitees ?? [:]).mapValues { $0.rawValue }, "endReason": call.endReason?.rawValue ?? NSNull(), "durationMs": call.durationMs ?? NSNull()]
    }

    private static func participant(_ participant: RelayMediaParticipant) -> [String: Any] {
        func track(_ track: RelayMediaTrack?) -> Any {
            guard let track else {
                return NSNull()
            }
            return ["sid": track.sid, "muted": track.isMuted, "width": track.width ?? 0, "height": track.height ?? 0]
        }
        return ["identity": participant.identity, "name": participant.name ?? NSNull(), "speaking": participant.isSpeaking, "audioLevel": participant.audioLevel, "quality": "\(participant.connectionQuality)", "microphone": track(participant.microphone), "camera": track(participant.camera), "screenShare": track(participant.screenShare)]
    }

    @MainActor
    private static func media(_ engine: RelayRoomEngine) -> [String: Any] {
        let room = engine.room
        var remote: [[String: Any]] = []
        for participant in room.remoteParticipants.values {
            var tracks: [[String: Any]] = []
            for publication in participant.trackPublications.values {
                tracks.append(["source": "\(publication.source)", "sid": publication.sid.stringValue, "subscribed": publication.isSubscribed, "muted": publication.isMuted, "dimensions": publication.dimensions.map { "\($0.width)x\($0.height)" } ?? NSNull()])
            }
            remote.append(["identity": participant.identity?.stringValue ?? "", "name": participant.name ?? "", "speaking": participant.isSpeaking, "tracks": tracks])
        }
        var local: [[String: Any]] = []
        for publication in room.localParticipant.trackPublications.values {
            local.append(["source": "\(publication.source)", "sid": publication.sid.stringValue, "muted": publication.isMuted, "dimensions": publication.dimensions.map { "\($0.width)x\($0.height)" } ?? NSNull()])
        }
        var result: [String: Any] = ["connection": "\(room.connectionState)", "room": room.name ?? "", "localIdentity": room.localParticipant.identity?.stringValue ?? "", "localTracks": local, "remote": remote]
        result["cameraDevice"] = engine.cameraDevice?.localizedName ?? NSNull()
        return result
    }
}

private extension Peer {
    var debugDisplayTitle: String {
        if let user = self as? TelegramUser {
            return [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
        }
        if let channel = self as? TelegramChannel {
            return channel.title
        }
        if let group = self as? TelegramGroup {
            return group.title
        }
        return "\(self.id)"
    }
}
#endif
