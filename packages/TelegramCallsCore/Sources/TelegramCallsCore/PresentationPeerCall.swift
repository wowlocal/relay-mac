import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import TGUIKit
import TelegramContext
import CallVideoLayer
import TelegramVoip

public protocol PresentationPeerCall: AnyObject {
    var account: Account { get }
    var engine: TelegramEngine { get }
    var sharedContext: (any SharedAccountContextProtocol) { get }
    var accountContext: (any AccountContextProtocol)? { get }
    var peerId: PeerId { get }
    var peer: Peer? { get }
    var internalId: CallSessionInternalId { get }
    var isOutgoing: Bool { get }
    var isVideo: Bool { get }
    var isIncomingConference: Bool { get }
    var window: Window? { get set }

    var state: Signal<CallState, NoError> { get }
    var audioLevel: Signal<Float, NoError> { get }
    var canBeRemoved: Signal<Bool, NoError> { get }

    func acceptCallSession()
    func toggleMute()
    func requestVideo()
    func disableVideo()
    func toggleScreenCapture() -> ScreenCaptureLaunchError?
    func setToRemovableState()
    @discardableResult func hangUpCurrentCall() -> Signal<Bool, NoError>
    func makeVideoSource(isIncoming: Bool) -> VideoSource?
    func makeFallbackVideoView(isIncoming: Bool, completion: @escaping (CallVideoView?) -> Void)
}

extension PCallSession: PresentationPeerCall {
    public func makeVideoSource(isIncoming: Bool) -> VideoSource? {
        return self.makeVideo(isIncoming: isIncoming).map { MetalVideoMakeSource(videoStreamSignal: $0) }
    }

    public func makeFallbackVideoView(isIncoming: Bool, completion: @escaping (CallVideoView?) -> Void) {
        guard isNativeCallVideoRenderingAvailable else {
            completion(nil)
            return
        }
        let deliver: (OngoingCallContextPresentationCallVideoView?) -> Void = { video in
            Queue.mainQueue().async {
                completion(video.flatMap { NativeCallVideoView(video: $0) })
            }
        }
        if isIncoming {
            self.makeIncomingVideoView(completion: deliver)
        } else {
            self.makeOutgoingVideoView(completion: deliver)
        }
    }
}
