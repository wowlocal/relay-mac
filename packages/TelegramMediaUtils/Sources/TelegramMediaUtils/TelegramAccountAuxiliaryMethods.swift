import Foundation
import TelegramCore

import Postbox
import SwiftSignalKit
import TelegramMediaResources

public var relayFetchResource: ((Postbox, MediaResource) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError>?)?

public let telegramAccountAuxiliaryMethods = AccountAuxiliaryMethods(fetchResource: { postbox, resource, range, tag in
    if let signal = relayFetchResource?(postbox, resource) {
        return signal
    }
    if let resource = resource as? LocalFileGifMediaResource {
        return fetchGifMediaResource(resource: resource)
    } else if let resource = resource as? LocalFileArchiveMediaResource {
        return fetchArchiveMediaResource(resource: resource)
    } else if let resource = resource as? LocalFileVideoMediaResource {
        return fetchMovMediaResource(resource: resource)
    } else if let resource = resource as? LottieSoundMediaResource {
        return fetchLottieSoundData(resource: resource)
    }
    return nil
}, fetchResourceMediaReferenceHash: { resource in
    return .single(nil)
}, prepareSecretThumbnailData: { resource in
    return nil
}, backgroundUpload: { _, _, _ in
    return .single(nil)
})
