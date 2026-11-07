import Cocoa
import SwiftUI
import TelegramContext
import Postbox
import MattermostKit
import MattermostSync
import RelayCalls
import RelayCallsCore

@MainActor
private final class RelayCallWindow: NSObject, NSWindowDelegate {
    static var current: RelayCallWindow?
    let session: RelayCallSession
    let window: NSWindow

    init(session: RelayCallSession) {
        self.session = session
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = session.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hostingController = NSHostingController(rootView: RelayCallView(session: session, close: { [weak self] in self?.window.close() }))
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 440, height: 500)
        window.setContentSize(NSSize(width: 720, height: 620))
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        Task { await session.leave() }
        RelayCallWindow.current = nil
    }
}

public func openRelayCall(context: any AccountContextProtocol, peerId: PeerId) {
    Task { @MainActor in
        if let current = RelayCallWindow.current {
            current.window.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let target = try await MattermostSync.callTarget(accountId: context.account.id, peerId: peerId)
            if let current = RelayCallWindow.current { current.window.makeKeyAndOrderFront(nil); return }
            let client = RelayCallsClient(serverURL: target.serverURL, token: target.sessionToken, session: MattermostURLSession.current)
            let session = RelayCallSession(client: client, channelId: target.channelId, title: target.title)
            let controller = RelayCallWindow(session: session)
            RelayCallWindow.current = controller
            controller.window.makeKeyAndOrderFront(nil)
            await session.join()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Voice call" //TODOLANG
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
