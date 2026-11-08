import Foundation
import SwiftSignalKit
import TelegramCore
import Postbox
import TelegramContext

public struct RelayCallHooks {
    public let startPeerCall: (any SharedAccountContextProtocol, Account, PeerId, Bool) -> Signal<(any PresentationPeerCall)?, NoError>
    public let startGroupCall: (any AccountContextProtocol, PeerId, CachedChannelData.ActiveCall?) -> Signal<(any PresentationGroupCall)?, NoError>
    public let groupCallPanelData: (any AccountContextProtocol, PeerId, CachedChannelData.ActiveCall) -> Signal<GroupCallPanelData?, NoError>

    public init(startPeerCall: @escaping (any SharedAccountContextProtocol, Account, PeerId, Bool) -> Signal<(any PresentationPeerCall)?, NoError>,
                startGroupCall: @escaping (any AccountContextProtocol, PeerId, CachedChannelData.ActiveCall?) -> Signal<(any PresentationGroupCall)?, NoError>,
                groupCallPanelData: @escaping (any AccountContextProtocol, PeerId, CachedChannelData.ActiveCall) -> Signal<GroupCallPanelData?, NoError>) {
        self.startPeerCall = startPeerCall
        self.startGroupCall = startGroupCall
        self.groupCallPanelData = groupCallPanelData
    }

    private static var value: RelayCallHooks?

    public static var shared: RelayCallHooks? {
        guard MattermostFeatures.relayCalls else {
            return nil
        }
        return value
    }

    public static func install(_ hooks: RelayCallHooks) {
        self.value = hooks
    }
}
