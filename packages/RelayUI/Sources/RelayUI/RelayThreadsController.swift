import Cocoa
import TGUIKit
import SwiftSignalKit
import TelegramCore
import Postbox
import TelegramTheme
import TelegramContext
import GeneralRows
import InputDataUI
import MattermostSync

private func _id_thread(_ rootPostId: String) -> InputDataIdentifier {
    return InputDataIdentifier("_id_relay_thread_\(rootPostId)")
}

private struct ThreadsState: Equatable {
    var teamId: String?
    var list: [ThreadRow] = []
    var isLoaded: Bool = false
}

private struct ThreadRow: Equatable {
    let rootPostId: String
    let peerId: PeerId
    let threadId: Int64?
    let channelTitle: String
    let rootText: String
    let replyCount: Int
    let unreadReplies: Int
    let unreadMentions: Int
}

/// The followed threads of a team (Mattermost's collapsed reply threads), newest reply first, as the iOS app's Threads
/// tab. A thread opens through `RelayUIHooks.openThread`.
public func RelayThreadsController(context: any AccountContextProtocol) -> InputDataController {
    let accountId = context.account.id
    let initialState = ThreadsState(teamId: MattermostSync.teams(accountId: accountId).first?.id)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((ThreadsState) -> ThreadsState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }
    let listDisposable = MetaDisposable()
    let teamsDisposable = MetaDisposable()

    let subscribe: (String) -> Void = { teamId in
        MattermostSync.reloadThreads(accountId: accountId, teamId: teamId)
        listDisposable.set((MattermostSync.threadList(accountId: accountId, teamId: teamId) |> deliverOnMainQueue).start(next: { list in
            updateState { current in
                var current = current
                guard current.teamId == teamId else {
                    return current
                }
                current.isLoaded = list?.isLoaded ?? false
                current.list = (list?.items ?? []).map { item in
                    return ThreadRow(rootPostId: item.rootPostId, peerId: item.peerId, threadId: item.threadId, channelTitle: item.channelTitle, rootText: item.rootText, replyCount: item.replyCount, unreadReplies: item.unreadReplies, unreadMentions: item.unreadMentions)
                }
                return current
            }
        }))
    }

    teamsDisposable.set((MattermostSync.teamsWhenReady(accountId: accountId) |> take(1) |> deliverOnMainQueue).start(next: { teams in
        let teamId = stateValue.with { $0.teamId } ?? teams.first?.id
        updateState { current in
            var current = current
            current.teamId = teamId
            return current
        }
        if let teamId {
            subscribe(teamId)
        }
    }))

    let signal = statePromise.get() |> deliverOnPrepareQueue |> map { state -> InputDataSignalValue in
        var entries: [InputDataEntry] = []
        var sectionId: Int32 = 0
        var index: Int32 = 0

        entries.append(.sectionId(sectionId, type: .customModern(10)))
        sectionId += 1

        let teams = MattermostSync.teams(accountId: accountId)
        if teams.count > 1 {
            for (i, team) in teams.enumerated() {
                let viewType: GeneralViewType = i == 0 ? .firstItem : (i == teams.count - 1 ? .lastItem : .innerItem)
                entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: InputDataIdentifier("_id_relay_threads_team_\(team.id)"), data: .init(name: team.name, color: theme.colors.text, type: .selectable(state.teamId == team.id), viewType: viewType, action: {
                    updateState { current in
                        var current = current
                        current.teamId = team.id
                        current.list = []
                        current.isLoaded = false
                        return current
                    }
                    subscribe(team.id)
                })))
                index += 1
            }
            entries.append(.sectionId(sectionId, type: .customModern(10)))
            sectionId += 1
        }

        for (i, row) in state.list.enumerated() {
            let viewType: GeneralViewType = state.list.count == 1 ? .singleItem : (i == 0 ? .firstItem : (i == state.list.count - 1 ? .lastItem : .innerItem))
            //TODOLANG
            var description = "\(row.replyCount) repl" + (row.replyCount == 1 ? "y" : "ies")
            if row.unreadMentions > 0 {
                description += " · @\(row.unreadMentions)"
            } else if row.unreadReplies > 0 {
                //TODOLANG
                description += " · \(row.unreadReplies) new"
            }
            let text = row.rootText.replacingOccurrences(of: "\n", with: " ")
            entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_thread(row.rootPostId), data: .init(name: row.channelTitle + ": " + String(text.prefix(80)), color: row.unreadReplies > 0 ? theme.colors.text : theme.colors.listGrayText, type: row.unreadReplies > 0 ? .context("•") : .none, viewType: viewType, description: description, action: {
                if let threadId = row.threadId {
                    RelayUIHooks.shared.openThread(context, row.peerId, threadId)
                } else {
                    RelayUIHooks.shared.openChat(context, row.peerId)
                }
            })))
            index += 1
        }
        if state.list.isEmpty {
            //TODOLANG
            let text = state.isLoaded ? "No followed threads. Threads you start or reply to show here." : "Loading threads…"
            entries.append(.desc(sectionId: sectionId, index: index, text: .plain(text), data: .init(color: theme.colors.listGrayText, viewType: .textTopItem)))
            index += 1
        }

        entries.append(.sectionId(sectionId, type: .customModern(20)))
        sectionId += 1
        return InputDataSignalValue(entries: entries)
    }

    //TODOLANG
    let controller = InputDataController(dataSignal: signal, title: "Threads", afterDisappear: {
    }, removeAfterDisappear: false, hasDone: false)
    controller.onDeinit = {
        listDisposable.dispose()
        teamsDisposable.dispose()
    }
    return controller
}
