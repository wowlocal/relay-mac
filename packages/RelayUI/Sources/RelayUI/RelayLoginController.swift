import Cocoa
import TGUIKit
import SwiftSignalKit
import TelegramCore
import Postbox
import TelegramTheme
import GeneralRows
import InputDataUI
import MattermostKit
import MattermostSync

private let _id_server = InputDataIdentifier("_id_relay_server")
private let _id_login = InputDataIdentifier("_id_relay_login")
private let _id_password = InputDataIdentifier("_id_relay_password")
private let _id_mfa = InputDataIdentifier("_id_relay_mfa")

private struct State: Equatable {
    var server: String = ""
    var login: String = ""
    var password: String = ""
    var mfa: String = ""
    var needsMFA: Bool = false
    var isLoading: Bool = false
    var error: String?
}

private func entries(_ state: State) -> [InputDataEntry] {
    var entries: [InputDataEntry] = []
    var sectionId: Int32 = 0
    var index: Int32 = 0

    entries.append(.sectionId(sectionId, type: .customModern(20)))
    sectionId += 1

    //TODOLANG
    entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Sign in to your Mattermost server."), data: .init(color: theme.colors.listGrayText, viewType: .textTopItem)))
    index += 1

    //TODOLANG
    entries.append(.input(sectionId: sectionId, index: index, value: .string(state.server), error: nil, identifier: _id_server, mode: .plain, data: .init(viewType: .firstItem), placeholder: nil, inputPlaceholder: "Server, e.g. chat.example.com", filter: { $0 }, limit: 255))
    index += 1
    //TODOLANG
    entries.append(.input(sectionId: sectionId, index: index, value: .string(state.login), error: nil, identifier: _id_login, mode: .plain, data: .init(viewType: .innerItem), placeholder: nil, inputPlaceholder: "Email or username", filter: { $0 }, limit: 255))
    index += 1
    //TODOLANG
    entries.append(.input(sectionId: sectionId, index: index, value: .string(state.password), error: nil, identifier: _id_password, mode: .secure, data: .init(viewType: state.needsMFA ? .innerItem : .lastItem), placeholder: nil, inputPlaceholder: "Password", filter: { $0 }, limit: 255))
    index += 1
    if state.needsMFA {
        //TODOLANG
        entries.append(.input(sectionId: sectionId, index: index, value: .string(state.mfa), error: nil, identifier: _id_mfa, mode: .plain, data: .init(viewType: .lastItem), placeholder: nil, inputPlaceholder: "Authentication code", filter: { $0.filter { $0.isNumber } }, limit: 12))
        index += 1
    }

    if state.isLoading {
        //TODOLANG
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Signing in…"), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
        index += 1
    } else if let error = state.error {
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain(error), data: .init(color: theme.colors.redUI, viewType: .textBottomItem)))
        index += 1
    } else if state.needsMFA {
        //TODOLANG
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain("Enter the code from your authenticator app."), data: .init(color: theme.colors.listGrayText, viewType: .textBottomItem)))
        index += 1
    }

    entries.append(.sectionId(sectionId, type: .customModern(20)))
    sectionId += 1

    return entries
}

/// The Mattermost login (server, login id, password, MFA code) in place of Telegram's phone login. It creates the
/// account on the auth record (`MattermostAccountSetup`, as Relay for iOS does), which the shared context then loads.
public func RelayLoginController(account: UnauthorizedAccount, accountManager: AccountManager<TelegramAccountManagerTypes>) -> InputDataController {
    let initialState = State()
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((State) -> State) -> Void = { f in
        statePromise.set(stateValue.modify(f))
    }

    var loginTask: Task<Void, Never>?

    let signal = statePromise.get() |> deliverOnPrepareQueue |> map { state in
        return InputDataSignalValue(entries: entries(state))
    }

    let logIn: () -> InputDataValidation = {
        let state = stateValue.with { $0 }
        if state.isLoading {
            return .fail(.none)
        }
        var shake: [InputDataIdentifier: InputDataValidationFailAction] = [:]
        if state.server.trimmingCharacters(in: .whitespaces).isEmpty {
            shake[_id_server] = .shake
        }
        if state.login.trimmingCharacters(in: .whitespaces).isEmpty {
            shake[_id_login] = .shake
        }
        if state.password.isEmpty {
            shake[_id_password] = .shake
        }
        if state.needsMFA && state.mfa.isEmpty {
            shake[_id_mfa] = .shake
        }
        if !shake.isEmpty {
            return .fail(.fields(shake))
        }
        updateState { current in
            var current = current
            current.isLoading = true
            current.error = nil
            return current
        }
        #if DEBUG
        let allowInsecureLocal = true
        #else
        let allowInsecureLocal = false
        #endif
        let loginId = state.login.trimmingCharacters(in: .whitespaces)
        loginTask = Task {
            var message: String?
            var needsMFA = false
            do {
                let server = try await MattermostAccountSetup.probe(address: state.server, allowInsecureLocal: allowInsecureLocal)
                let login = try await MattermostAccountSetup.login(server: server.url, loginId: loginId, password: state.password, mfaToken: state.needsMFA ? state.mfa : nil)
                try await MattermostAccountSetup.createAccount(server: server, serverURL: server.url, login: login, loginId: loginId, target: .authorization(account), accountManager: accountManager)
            } catch let error as MattermostServerProbeError {
                message = error.message
            } catch let error as MattermostAccountSetupError {
                message = error.message
            } catch let error as MattermostError where error.isMFARequired {
                needsMFA = true
            } catch {
                message = MattermostAccountSetup.loginErrorMessage(error)
            }
            let result = (message, needsMFA)
            Queue.mainQueue().async {
                updateState { current in
                    var current = current
                    current.isLoading = false
                    current.error = result.0
                    if result.1 {
                        current.needsMFA = true
                    }
                    return current
                }
            }
        }
        return .fail(.none)
    }

    #if DEBUG
    RelayDebugRemote.register("login", { command, completion in
        updateState { current in
            var current = current
            current.server = command["server"] ?? current.server
            current.login = command["login"] ?? current.login
            current.password = command["password"] ?? current.password
            current.mfa = command["mfa"] ?? current.mfa
            return current
        }
        let _ = logIn()
        completion(true, nil, [:])
    })
    RelayDebugRemote.register("login-state", { _, completion in
        let state = stateValue.with { $0 }
        completion(true, nil, ["isLoading": state.isLoading, "needsMFA": state.needsMFA, "error": state.error ?? ""])
    })
    #endif

    //TODOLANG
    let controller = InputDataController(dataSignal: signal, title: "Relay", validateData: { _ in
        return logIn()
    }, updateDatas: { data in
        updateState { current in
            var current = current
            current.server = data[_id_server]?.stringValue ?? current.server
            current.login = data[_id_login]?.stringValue ?? current.login
            current.password = data[_id_password]?.stringValue ?? current.password
            current.mfa = data[_id_mfa]?.stringValue ?? current.mfa
            current.error = nil
            return current
        }
        return .fail(.none)
    }, afterDisappear: {
        loginTask?.cancel()
    }, hasDone: true, doneString: {
        //TODOLANG
        return "Log In"
    })
    return controller
}
