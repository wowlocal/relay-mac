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
import MattermostSyncCore

/// App-side actions the Relay screens need (opening a chat, pushing a screen), installed by the app.
public struct RelayUIHooks {
    public var openChat: (any AccountContextProtocol, PeerId) -> Void = { _, _ in }
    public var push: (any AccountContextProtocol, ViewController) -> Void = { _, _ in }
    public var openThread: (any AccountContextProtocol, PeerId, Int64) -> Void = { _, _, _ in }

    public static var shared = RelayUIHooks()
}

private func directoryErrorText(_ error: MattermostDirectoryError) -> String {
    switch error {
    case .unavailable:
        //TODOLANG
        return "Not available on this server."
    case .network:
        //TODOLANG
        return "Can't reach the server. Check your connection."
    case .urlNameTaken:
        //TODOLANG
        return "A channel with this URL already exists."
    case let .server(message):
        return message
    }
}

// MARK: New Message

private let _id_search = InputDataIdentifier("_id_relay_search")
private let _id_new_channel = InputDataIdentifier("_id_relay_new_channel")
private let _id_browse = InputDataIdentifier("_id_relay_browse")
private func _id_user(_ peerId: PeerId) -> InputDataIdentifier {
    return InputDataIdentifier("_id_relay_user_\(peerId.toInt64())")
}

private struct NewMessageState: Equatable {
    var query: String = ""
    var users: [MattermostDirectoryUser] = []
    var isLoading: Bool = false
    var error: String?
}

public func RelayNewMessageController(context: any AccountContextProtocol) -> InputDataController {
    let accountId = context.account.id
    let initialState = NewMessageState()
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((NewMessageState) -> NewMessageState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }
    let searchDisposable = MetaDisposable()
    let openDisposable = MetaDisposable()
    let queryPromise = ValuePromise<String>("", ignoreRepeated: true)

    let search: (String) -> Void = { query in
        updateState { current in
            var current = current
            current.isLoading = true
            return current
        }
        searchDisposable.set((MattermostDirectory.users(accountId: accountId, query: query, page: 0) |> delay(query.isEmpty ? 0.0 : 0.25, queue: .mainQueue()) |> deliverOnMainQueue).start(next: { page in
            updateState { current in
                var current = current
                current.users = page.users
                current.isLoading = false
                current.error = nil
                return current
            }
        }, error: { error in
            updateState { current in
                var current = current
                current.isLoading = false
                current.error = directoryErrorText(error)
                return current
            }
        }))
    }
    let queryDisposable = queryPromise.get().start(next: { query in
        search(query)
    })

    let openUser: (MattermostDirectoryUser) -> Void = { user in
        openDisposable.set((MattermostDirectory.openDirectMessage(accountId: accountId, userPeerId: user.peer.id) |> deliverOnMainQueue).start(next: { peerId in
            RelayUIHooks.shared.openChat(context, peerId)
        }, error: { error in
            updateState { current in
                var current = current
                current.error = directoryErrorText(error)
                return current
            }
        }))
    }

    let signal = statePromise.get() |> deliverOnPrepareQueue |> map { state -> InputDataSignalValue in
        var entries: [InputDataEntry] = []
        var sectionId: Int32 = 0
        var index: Int32 = 0

        entries.append(.sectionId(sectionId, type: .customModern(10)))
        sectionId += 1

        //TODOLANG
        entries.append(.input(sectionId: sectionId, index: index, value: .string(state.query), error: nil, identifier: _id_search, mode: .plain, data: .init(viewType: .singleItem), placeholder: nil, inputPlaceholder: "Search people", filter: { $0 }, limit: 100))
        index += 1

        entries.append(.sectionId(sectionId, type: .customModern(10)))
        sectionId += 1

        //TODOLANG
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_new_channel, data: .init(name: "New Channel", color: theme.colors.accent, type: .next, viewType: .firstItem, action: {
            RelayUIHooks.shared.push(context, RelayNewChannelController(context: context))
        })))
        index += 1
        //TODOLANG
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_browse, data: .init(name: "Browse Channels", color: theme.colors.accent, type: .next, viewType: .lastItem, action: {
            RelayUIHooks.shared.push(context, RelayBrowseChannelsController(context: context))
        })))
        index += 1

        entries.append(.sectionId(sectionId, type: .customModern(10)))
        sectionId += 1

        if let error = state.error {
            entries.append(.desc(sectionId: sectionId, index: index, text: .plain(error), data: .init(color: theme.colors.redUI, viewType: .textTopItem)))
            index += 1
        }
        let users = state.users.filter { !$0.isBot || !state.query.isEmpty }
        for (i, user) in users.enumerated() {
            let viewType: GeneralViewType = users.count == 1 ? .singleItem : (i == 0 ? .firstItem : (i == users.count - 1 ? .lastItem : .innerItem))
            var description = "@" + user.username
            if !user.position.isEmpty {
                description += " · " + user.position
            }
            entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_user(user.peer.id), data: .init(name: user.peer._asPeer().displayTitle, color: theme.colors.text, type: .none, viewType: viewType, description: description, action: {
                openUser(user)
            })))
            index += 1
        }
        if users.isEmpty && !state.isLoading && !state.query.isEmpty {
            //TODOLANG
            entries.append(.desc(sectionId: sectionId, index: index, text: .plain("No one found."), data: .init(color: theme.colors.listGrayText, viewType: .textTopItem)))
            index += 1
        }

        entries.append(.sectionId(sectionId, type: .customModern(20)))
        sectionId += 1
        return InputDataSignalValue(entries: entries)
    }

    //TODOLANG
    let controller = InputDataController(dataSignal: signal, title: "New Message", updateDatas: { data in
        let query = data[_id_search]?.stringValue ?? ""
        updateState { current in
            var current = current
            current.query = query
            return current
        }
        queryPromise.set(query)
        return .fail(.none)
    }, afterDisappear: {
        searchDisposable.dispose()
        openDisposable.dispose()
        queryDisposable.dispose()
    }, hasDone: false)
    return controller
}

// MARK: New Channel

private let _id_name = InputDataIdentifier("_id_relay_channel_name")
private let _id_purpose = InputDataIdentifier("_id_relay_channel_purpose")
private let _id_private = InputDataIdentifier("_id_relay_channel_private")
private func _id_team(_ id: String) -> InputDataIdentifier {
    return InputDataIdentifier("_id_relay_team_\(id)")
}

private struct NewChannelState: Equatable {
    var teamId: String?
    var name: String = ""
    var purpose: String = ""
    var isPrivate: Bool = false
    var isCreating: Bool = false
    var error: String?
}

public func RelayNewChannelController(context: any AccountContextProtocol) -> InputDataController {
    let accountId = context.account.id
    let teams = MattermostDirectory.teams(accountId: accountId)
    let initialState = NewChannelState(teamId: teams.first?.id)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((NewChannelState) -> NewChannelState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }
    let createDisposable = MetaDisposable()

    let signal = statePromise.get() |> deliverOnPrepareQueue |> map { state -> InputDataSignalValue in
        var entries: [InputDataEntry] = []
        var sectionId: Int32 = 0
        var index: Int32 = 0

        entries.append(.sectionId(sectionId, type: .customModern(10)))
        sectionId += 1

        if teams.count > 1 {
            //TODOLANG
            entries.append(.desc(sectionId: sectionId, index: index, text: .plain("TEAM"), data: .init(color: theme.colors.listGrayText, viewType: .textTopItem)))
            index += 1
            for (i, team) in teams.enumerated() {
                let viewType: GeneralViewType = i == 0 ? .firstItem : (i == teams.count - 1 ? .lastItem : .innerItem)
                entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_team(team.id), data: .init(name: team.displayName, color: theme.colors.text, type: .selectable(state.teamId == team.id), viewType: viewType, action: {
                    updateState { current in
                        var current = current
                        current.teamId = team.id
                        return current
                    }
                })))
                index += 1
            }
            entries.append(.sectionId(sectionId, type: .customModern(10)))
            sectionId += 1
        }

        //TODOLANG
        entries.append(.input(sectionId: sectionId, index: index, value: .string(state.name), error: nil, identifier: _id_name, mode: .plain, data: .init(viewType: .firstItem), placeholder: nil, inputPlaceholder: "Channel name", filter: { $0 }, limit: Int32(ChannelNaming.displayNameMaxLength)))
        index += 1
        //TODOLANG
        entries.append(.input(sectionId: sectionId, index: index, value: .string(state.purpose), error: nil, identifier: _id_purpose, mode: .plain, data: .init(viewType: .lastItem), placeholder: nil, inputPlaceholder: "Purpose (optional)", filter: { $0 }, limit: Int32(ChannelNaming.purposeMaxLength)))
        index += 1

        entries.append(.sectionId(sectionId, type: .customModern(10)))
        sectionId += 1

        let creation = state.teamId.map { MattermostDirectory.channelCreation(accountId: accountId, teamId: $0) } ?? (publicChannel: true, privateChannel: true)
        if creation.publicChannel && creation.privateChannel {
            //TODOLANG
            entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_private, data: .init(name: "Private Channel", color: theme.colors.text, type: .switchable(state.isPrivate), viewType: .singleItem, switchAction: {
                updateState { current in
                    var current = current
                    current.isPrivate = !current.isPrivate
                    return current
                }
            })))
            index += 1
        }

        if state.isCreating {
            //TODOLANG
            entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Creating…"), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
            index += 1
        } else if let error = state.error {
            entries.append(.desc(sectionId: sectionId, index: index, text: .plain(error), data: .init(color: theme.colors.redUI, viewType: .textBottomItem)))
            index += 1
        }

        entries.append(.sectionId(sectionId, type: .customModern(20)))
        sectionId += 1
        return InputDataSignalValue(entries: entries)
    }

    let create: () -> InputDataValidation = {
        let state = stateValue.with { $0 }
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isCreating, let teamId = state.teamId else {
            return .fail(.none)
        }
        if name.isEmpty {
            return .fail(.fields([_id_name: .shake]))
        }
        let creation = MattermostDirectory.channelCreation(accountId: accountId, teamId: teamId)
        let isPrivate = creation.publicChannel ? (creation.privateChannel && state.isPrivate) : true
        let urlName = ChannelNaming.urlName(fromDisplayName: name, fallback: {
            return "channel-" + String(UInt32.random(in: 0 ... UInt32.max), radix: 36)
        })
        updateState { current in
            var current = current
            current.isCreating = true
            current.error = nil
            return current
        }
        let channel = MattermostNewChannel(teamId: teamId, displayName: name, urlName: urlName, isPrivate: isPrivate, purpose: state.purpose.trimmingCharacters(in: .whitespacesAndNewlines), header: "")
        createDisposable.set((MattermostDirectory.createChannel(accountId: accountId, channel: channel) |> deliverOnMainQueue).start(next: { peerId in
            updateState { current in
                var current = current
                current.isCreating = false
                return current
            }
            RelayUIHooks.shared.openChat(context, peerId)
        }, error: { error in
            updateState { current in
                var current = current
                current.isCreating = false
                current.error = directoryErrorText(error)
                return current
            }
        }))
        return .fail(.none)
    }

    //TODOLANG
    let controller = InputDataController(dataSignal: signal, title: "New Channel", validateData: { _ in
        return create()
    }, updateDatas: { data in
        updateState { current in
            var current = current
            current.name = data[_id_name]?.stringValue ?? current.name
            current.purpose = data[_id_purpose]?.stringValue ?? current.purpose
            current.error = nil
            return current
        }
        return .fail(.none)
    }, afterDisappear: {
        createDisposable.dispose()
    }, hasDone: true, doneString: {
        //TODOLANG
        return "Create"
    })
    return controller
}

// MARK: Browse Channels

private func _id_channel(_ id: String) -> InputDataIdentifier {
    return InputDataIdentifier("_id_relay_channel_\(id)")
}

private struct BrowseState: Equatable {
    var teamId: String?
    var query: String = ""
    var channels: [MattermostBrowsedChannel] = []
    var isLoading: Bool = false
    var error: String?
}

public func RelayBrowseChannelsController(context: any AccountContextProtocol) -> InputDataController {
    let accountId = context.account.id
    let teams = MattermostDirectory.teams(accountId: accountId)
    let initialState = BrowseState(teamId: teams.first?.id)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((BrowseState) -> BrowseState) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }
    let loadDisposable = MetaDisposable()
    let joinDisposable = MetaDisposable()

    let load: () -> Void = {
        let state = stateValue.with { $0 }
        guard let teamId = state.teamId else {
            return
        }
        updateState { current in
            var current = current
            current.isLoading = true
            return current
        }
        loadDisposable.set((MattermostDirectory.browseChannels(accountId: accountId, teamId: teamId, query: state.query, archived: false, page: 0) |> delay(state.query.isEmpty ? 0.0 : 0.25, queue: .mainQueue()) |> deliverOnMainQueue).start(next: { page in
            updateState { current in
                var current = current
                current.channels = page.channels
                current.isLoading = false
                current.error = nil
                return current
            }
        }, error: { error in
            updateState { current in
                var current = current
                current.isLoading = false
                current.error = directoryErrorText(error)
                return current
            }
        }))
    }

    let open: (MattermostBrowsedChannel) -> Void = { channel in
        if let peerId = channel.memberPeerId {
            RelayUIHooks.shared.openChat(context, peerId)
            return
        }
        joinDisposable.set((MattermostDirectory.joinChannel(accountId: accountId, channelId: channel.id) |> deliverOnMainQueue).start(next: { peerId in
            RelayUIHooks.shared.openChat(context, peerId)
        }, error: { error in
            updateState { current in
                var current = current
                current.error = directoryErrorText(error)
                return current
            }
        }))
    }

    let signal = statePromise.get() |> deliverOnPrepareQueue |> map { state -> InputDataSignalValue in
        var entries: [InputDataEntry] = []
        var sectionId: Int32 = 0
        var index: Int32 = 0

        entries.append(.sectionId(sectionId, type: .customModern(10)))
        sectionId += 1

        if teams.count > 1 {
            for (i, team) in teams.enumerated() {
                let viewType: GeneralViewType = i == 0 ? .firstItem : (i == teams.count - 1 ? .lastItem : .innerItem)
                entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_team(team.id), data: .init(name: team.displayName, color: theme.colors.text, type: .selectable(state.teamId == team.id), viewType: viewType, action: {
                    updateState { current in
                        var current = current
                        current.teamId = team.id
                        current.channels = []
                        return current
                    }
                    load()
                })))
                index += 1
            }
            entries.append(.sectionId(sectionId, type: .customModern(10)))
            sectionId += 1
        }

        //TODOLANG
        entries.append(.input(sectionId: sectionId, index: index, value: .string(state.query), error: nil, identifier: _id_search, mode: .plain, data: .init(viewType: .singleItem), placeholder: nil, inputPlaceholder: "Search channels", filter: { $0 }, limit: 100))
        index += 1

        entries.append(.sectionId(sectionId, type: .customModern(10)))
        sectionId += 1

        if let error = state.error {
            entries.append(.desc(sectionId: sectionId, index: index, text: .plain(error), data: .init(color: theme.colors.redUI, viewType: .textTopItem)))
            index += 1
        }
        for (i, channel) in state.channels.enumerated() {
            let viewType: GeneralViewType = state.channels.count == 1 ? .singleItem : (i == 0 ? .firstItem : (i == state.channels.count - 1 ? .lastItem : .innerItem))
            var description = channel.purpose
            if let count = channel.memberCount {
                //TODOLANG
                let members = "\(count) member" + (count == 1 ? "" : "s")
                description = description.isEmpty ? members : members + " · " + description
            }
            //TODOLANG
            let joined = channel.memberPeerId != nil ? "Joined" : "Join"
            entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_channel(channel.id), data: .init(name: (channel.isPrivate ? "🔒 " : "") + channel.displayName, color: theme.colors.text, type: .context(joined), viewType: viewType, description: description.isEmpty ? nil : description, action: {
                open(channel)
            })))
            index += 1
        }
        if state.channels.isEmpty && !state.isLoading {
            //TODOLANG
            entries.append(.desc(sectionId: sectionId, index: index, text: .plain(state.query.isEmpty ? "No channels to join." : "No channels found."), data: .init(color: theme.colors.listGrayText, viewType: .textTopItem)))
            index += 1
        }

        entries.append(.sectionId(sectionId, type: .customModern(20)))
        sectionId += 1
        return InputDataSignalValue(entries: entries)
    }

    //TODOLANG
    let controller = InputDataController(dataSignal: signal, title: "Browse Channels", updateDatas: { data in
        let query = data[_id_search]?.stringValue ?? ""
        if query != stateValue.with({ $0.query }) {
            updateState { current in
                var current = current
                current.query = query
                return current
            }
            load()
        }
        return .fail(.none)
    }, afterDisappear: {
        loadDisposable.dispose()
        joinDisposable.dispose()
    }, hasDone: false)
    load()
    return controller
}
