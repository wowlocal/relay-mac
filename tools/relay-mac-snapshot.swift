import Foundation
// Asks a running debug build of Relay for macOS to write PNGs of its windows (RelayDebugSnapshot).
DistributedNotificationCenter.default().postNotificationName(Notification.Name("org.relaychat.RelayMac.debug.snapshot"), object: nil, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
