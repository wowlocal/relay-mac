import Cocoa
import CoreGraphics
import UserNotifications
import FFMpegBinding
import SwiftSignalKit
import Postbox
import TelegramCore
import DateUtils
import TGUIKit
import Quartz
import MtProtoKit
import MTProtoRustEngine
import MTProtoRustEngineMapping
import CoreServices
import LocalAuthentication
import OpenSSLEncryption
import CoreSpotlight
import BuildConfig
import Localization
import ApiCredentials
import EDSunriseSet
import ObjcUtils
import TGModernGrowingTextView
import FoundationUtils
import InAppSettings
import ThemeSettings
import ColorPalette
import WebKit
import CodeSyntax
import MetalEngine
import TelegramMedia
import RLottie
import KeyboardKey
import PasscodeCore
import EntertainmentUI
import NetworkLab
import CallsUI
import GalleryUI
import ChatUI
import PeerInfoUI
import StoriesUI
import ChatListUI
import MattermostSync
import MattermostPush
import TelegramMediaUtils
import RelayUI
import WalletContext
import CrashRecoveryUI
import StarsUI
import PerfLab
import SettingsUI
import RelayTelegramCalls
import GroupCallScreenUI
import TgVoipWebrtc
import TelegramCallsCore

//#if BETA || DEBUG
//import Firebase
//import FirebaseCrashlytics
//#endif


final class CodeSyntax {
    private let syntaxer: Syntaxer
    private let lock = NSLock()
    private init() {
        let pathFile = Bundle.main.path(forResource: "grammars", ofType: "dat")!
        let data = try! Data(contentsOf: URL(fileURLWithPath: pathFile))
        self.syntaxer = Syntaxer(data)!
    }
    private static let standart: CodeSyntax = .init()
    
    fileprivate static func initialize() {
        _ = CodeSyntax.standart
    }
    
    
    static func syntax(code: String, language: String, theme: SyntaxterTheme) -> NSAttributedString {
        let standart = CodeSyntax.standart
        standart.lock.lock()
        defer {
            standart.lock.unlock()
        }
        return standart.syntaxer.syntax(code, language: language, theme: theme)
    }
    static func apply(_ code: NSAttributedString, to: NSMutableAttributedString, offset: Int) {
        code.enumerateAttributes(in: code.range, using: { value, innerRange, _ in
            if let font = value[.foregroundColor] as? NSColor {
                to.addAttribute(.foregroundColor, value: font, range: NSMakeRange(offset + innerRange.location, innerRange.length))
            } else if let font = value[.font] as? NSFont {
                to.addAttribute(.font, value: font, range: NSMakeRange(offset + innerRange.location, innerRange.length))
            }
        })
    }
}

let enableBetaFeatures = true

private(set) var appDelegate: AppDelegate?

#if !SHARE
extension Account {
    var diceCache: DiceCache? {
        return currentDiceCache
    }
}

var currentDiceCache: DiceCache? {
    return appDelegate?.contextValue?.context.diceCache
}
#endif



private struct AutologinToken : Equatable {


    private let token: String
    private let domains:[String]

    fileprivate init(token: String, domains: [String]) {
        self.token = token
        self.domains = domains
    }

    static func with(appConfiguration: AppConfiguration, autologinToken: String?) -> AutologinToken? {
        if let data = appConfiguration.data, let value = autologinToken {
            let dict:[String] = data["autologin_domains"] as? [String] ?? []
            return AutologinToken(token: value, domains: dict)
        } else {
            return nil
        }
    }

    func applyTo(_ link: String, isTestServer: Bool) -> String? {
        let url = URL(string: link)
        if let url = url, let host = url.host, domains.contains(host) {
            var queryItems = [URLQueryItem(name: "autologin_token", value: self.token)]
            if isTestServer {
                queryItems.append(URLQueryItem(name: "_test", value: "1"))
            }
            var urlComps = URLComponents(string: link)!
            urlComps.queryItems = (urlComps.queryItems ?? []) + queryItems
            return urlComps.url?.absoluteString
        }
        return nil
    }
}


final class SharedApplicationContext {
    let sharedContext: SharedAccountContext
    let notificationManager: SharedNotificationManager
    let sharedWakeupManager: SharedWakeupManager
    init(sharedContext: SharedAccountContext, notificationManager: SharedNotificationManager, sharedWakeupManager: SharedWakeupManager) {
        self.sharedContext = sharedContext
        self.notificationManager = notificationManager
        self.sharedWakeupManager = sharedWakeupManager
    }
}

private final class CtxInstallLayer : SimpleLayer {
    private var timer: SwiftSignalKit.Timer?
    override init() {
        super.init()
        self.contentsScale = 1
        self.frame = NSMakeRect(-1, -1, 1, 1)
        self.isOpaque = false
        self.timer = SwiftSignalKit.Timer(timeout: 10, repeat: true, completion: { [weak self] in
            self?.setNeedsDisplay()
        }, queue: .mainQueue())
        
        self.timer?.start()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func draw(in ctx: CGContext) {
//        if FastSettings.useNativeGraphicContext {
//        #if !APP_STORE
//            DeviceGraphicsContextSettings.install(ctx)
//        #endif
//        } else {
//            DeviceGraphicsContextSettings.install(nil)
//        }
    }
}

extension RLottieBridge : @retroactive R_LottieBridge {
   
}


class AppDelegate: NSResponder, NSApplicationDelegate, NSUserNotificationCenterDelegate, NSWindowDelegate {
   

    @IBOutlet weak var window: Window! {
        didSet {
            window.delegate = self
            window.isOpaque = true

            let notInitial = window.initSaver()

            if !notInitial {
                let size = NSMakeSize(700, 550)
                if let screen = NSScreen.main {
                    window.setFrame(NSMakeRect((screen.frame.width - size.width) / 2, (screen.frame.height - size.height) / 2, size.width, size.height), display: true)
                }
            }
        }
    }
    
    override init() {
        super.init()
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_: with:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    
    let presentAccountStatus = Promise(false)
    var containerUrl:String!
    
    private let sharedContextPromise = Promise<SharedApplicationContext>()
    private var sharedContextOnce: Signal<SharedApplicationContext, NoError> {
        return sharedContextPromise.get() |> take(1) |> deliverOnMainQueue
    }
    private(set) var sharedApplicationContextValue: SharedApplicationContext?
    private(set) var supportAccountContextValue: SupportAccountContext? {
        didSet {
            supportAccountContextValue?.didUpdate = { _ in
                self.updateActiveContexts()
            }
        }
    }
    
    var passlock: Signal<Bool, NoError> {
        return sharedContextPromise.get() |> mapToSignal {
            return $0.notificationManager.passlocked
        }
    }

    var isPasscodeLocked: Signal<Bool, NoError> {
        return sharedContextPromise.get() |> mapToSignal {
            return $0.notificationManager.isPasscodeLocked
        }
    }
    
    fileprivate var contextValue: AuthorizedApplicationContext? {
        didSet {
            updateActiveContexts()
        }
    }
    private let context = Promise<AuthorizedApplicationContext?>()
    
    private var authContextValue: UnauthorizedApplicationContext?
    private let authContext = Promise<UnauthorizedApplicationContext?>()
    
    private var activeValue: ValuePromise<Bool> = ValuePromise(true, ignoreRepeated: true)

    var isActive: Signal<Bool, NoError> {
        return self.activeValue.get()
    }
    private var executeUrlAfterLogin: String? = nil
    private var timer: SwiftSignalKit.Timer?
    
    private(set) var appEncryption: AppEncryptionParameters!
    private var memoryPressureMonitor: MemoryPressureMonitor?
    private var rustEngineCrash: CrashedRun?

    func applicationWillFinishLaunching(_ notification: Notification) {
        CodeSyntax.initialize()
        
        
        
        
       // UserDefaults.standard.set(true, forKey: "NSTableViewCanEstimateRowHeights")
     //   UserDefaults.standard.removeObject(forKey: "NSTableViewCanEstimateRowHeights")
    }
    
    var allowedDomains: [String] {
        if let context = contextValue?.context {
            let value = context.appConfiguration.data?["whitelisted_domains"] as? [String]
            return value ?? []
        }
        return []
    }
    
    var baseAppBundleId: String {
        return  Bundle.main.bundleIdentifier!
    }

    var currentContext:AccountContext? {
        var context: AccountContext?
        self.enumerateAccountContexts({ ctx in
            if ctx.isCurrent {
                context = ctx
            }
        })
        return context
    }
    
    private var ctxLayer: CtxInstallLayer?
    
    func updateGraphicContext() {
        ctxLayer?.display()
    }
    
    

    
    func applicationDidFinishLaunching(_ aNotification: Notification) {

        installInvalidFrameDetector()
        memoryPressureMonitor = MemoryPressureMonitor()
        Queue.concurrentBackgroundQueue().async {
            migrateWallpapersToEightBitChannels()
        }

        _ = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            return BrowserStateContext.checkKey(event)
        })

        UserDefaults.standard.set(true, forKey: "NSApplicationCrashOnExceptions")
        
        
       // NSApplication.shared.applicationIconImage = NSImage(resource: .premiumBlack)
      
        let singleColumnThreshold: CGFloat = 650
        let chromeMode: Window.ChromeMode = window.frame.width < singleColumnThreshold ? .compact : .standard
        window.applyChrome(chromeMode)
        window.applyCornerRadius(for: chromeMode)

//        window.styleMask.insert(.unifiedTitleAndToolbar)
        //window.styleMask.insert(.borderless)
//        let customToolbar = NSToolbar(identifier: "main")
//        customToolbar.showsBaselineSeparator = false
////        window.titlebarAppearsTransparent = true
////        window.titleVisibility = .hidden
//        window.toolbar = customToolbar
        
        
        
//        titleBarAccessoryViewController.view = View()
//        titleBarAccessoryViewController.view.background = .random
//
//        titleBarAccessoryViewController.view.frame = NSMakeRect(0, 0, 0, 100) // Width not used.
//        window.addTitlebarAccessoryViewController(titleBarAccessoryViewController)
        
        appDelegate = self
        ApiEnvironment.migrate()
        
        if let containerUrl = ApiEnvironment.containerURL {
            self.containerUrl = containerUrl.path
            #if DEBUG
            RelayDebugSnapshot.install(directory: containerUrl.path)
            RelayDebugCrashScan.install(directory: containerUrl.path)
            self.installRelayDebugRemote(directory: containerUrl.path)
            #endif
            setupLogger(containerPath: containerUrl.path)
            recoverFromCrashOnLaunchIfNeeded(containerPath: containerUrl.path)
        }
        
        initializeSelectManager()
        startLottieCacheCleaner()
        updateDisplayColorSpace()
        NotificationCenter.default.addObserver(forName: NSScreen.colorSpaceDidChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.updateDisplayColorSpace()
        })
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: self.window, queue: .main, using: { [weak self] _ in
            self?.updateDisplayColorSpace()
        })
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenProfileNotification, object: self.window, queue: .main, using: { [weak self] _ in
            self?.updateDisplayColorSpace()
        })
        
        makeRLottie = { json, key in
            return RLottieBridge(json: json, key: key)
        }
        
        guard let containerUrl = ApiEnvironment.containerURL else {
            return
        }
        
        
        self.containerUrl = containerUrl.path

        try! PasscodeEnvironment.shared.configure(PasscodeConfiguration(appGroupIdentifier: ApiEnvironment.group, processRole: .mainApp, biometricKeychainService: walletBiometricKeychainService, keychainScope: ApiEnvironment.keychainScope), privateAccessGroup: { ApiEnvironment.group })
        
        TempBox.initializeShared(basePath: self.containerUrl, processType: "app", launchSpecificId: arc4random64())
        

        let v = FlippableView()
        v.flip = false
        window.contentView = v
        window.contentView?.autoresizingMask = [.width, .height]
        window.contentView?.autoresizesSubviews = true
        

//        delay(2.0, closure: {
        #if arch(arm64)
            v.layer?.addSublayer(MetalEngine.shared.rootLayer)
        #endif
//        })
        
//        let ctxLayer = CtxInstallLayer()
//        self.ctxLayer = ctxLayer
//        window.contentView?.layer?.addSublayer(ctxLayer)
        
//        ctxLayer.setNeedsDisplay()
//        ctxLayer.display()
                

        uiLocalizationFunc = { key in
            return _NSLocalizedString(key)
        }
        
        DateUtils.setDateLocalizationFunc ({ key -> String in
            return _NSLocalizedString(key!)
        })
        
        setInputLocalizationFunc { (key) -> String in
            return _NSLocalizedString(key)
        }
        
        var paths: [String?] = []
        paths.append(Bundle.main.path(forResource: "opening", ofType:"m4a"))
        paths.append(Bundle.main.path(forResource: "voip_busy", ofType:"caf"))
        paths.append(Bundle.main.path(forResource: "voip_ringback", ofType:"caf"))
        paths.append(Bundle.main.path(forResource: "voip_connecting", ofType:"mp3"))
        paths.append(Bundle.main.path(forResource: "voip_fail", ofType:"caf"))
        paths.append(Bundle.main.path(forResource: "voip_end", ofType:"caf"))
        paths.append(Bundle.main.path(forResource: "sent", ofType:"caf"))

        
        DispatchQueue.global(qos: .utility).async {
            for path in paths {
                if let path = path {
                    let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
                    player?.prepareToPlay()
                }
            }
        }
        
        FFMpegGlobals.initializeGlobals()
        
        
        TextView.context_copy_animation = MenuAnimation.menu_copy.value
        
        
        mw = window
        

//        #if BETA || DEBUG
//        FirebaseApp.configure()
//        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
//        Crashlytics.crashlytics().sendUnsentReports()
//        #endif
        
        
        

        telegramUIDeclareEncodables()
        mattermostDeclareEncodables()
        MattermostSessionKeychain.service = "org.relaychat.mattermost.session." + ApiEnvironment.mattermostKeychainScope
        relayFetchResource = { postbox, resource in
            return mattermostFetchResource(postbox: postbox, resource: resource)
        }
        
        initializeMimeStore()
        
//        #if APP_STORE || STABLE
//            logger.logToConsole = false
//            MTLogSetEnabled(false)
//        #endif
        
        let bundleId = Bundle.main.bundleIdentifier
        if let bundleId = bundleId {
            LSSetDefaultHandlerForURLScheme("tg" as CFString, bundleId as CFString)
        }
        
        
        launchInterface()
        
        
    }
    
    
    private func launchInterface() {
        initializeAccountManagement()
        

        let rootPath = containerUrl!
        let window = self.window!
        
        System.updateScaleFactor(window.backingScaleFactor)
        window.minSize = NSMakeSize(400, 550)
        
        let appEncryption = AppEncryptionParameters(path: rootPath)

        let accountManager = AccountManager<TelegramAccountManagerTypes>(basePath: containerUrl + "/accounts-metadata", isTemporary: false, isReadOnly: false, useCaches: true, removeDatabaseOnError: true, accessChallenge: makeAccountManagerAccessChallenge(basePath: containerUrl + "/accounts-metadata", isTemporary: false, isReadOnly: false))

        if let crash = self.rustEngineCrash {
            self.rustEngineCrash = nil
            let _ = recordRustEngineCrash(accountManager: accountManager, appVersion: ApiEnvironment.version, crashedBundleVersion: crash.bundleVersion, timestamp: crash.timestamp).startStandalone()
        }

        if let deviceSpecificEncryptionParameters = appEncryption.decrypt() {
            let parameters = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: ValueBoxEncryptionParameters.Key(data: deviceSpecificEncryptionParameters.key)!, salt: ValueBoxEncryptionParameters.Salt(data: deviceSpecificEncryptionParameters.salt)!)
            self.launchApp(accountManager: accountManager, encryptionParameters: parameters, appEncryption: appEncryption)
        } else {
            
            
            let data = combineLatest(themeSettingsView(accountManager: accountManager) |> take(1), accountManager.transaction { transaction in
                 transaction.getSharedData(SharedDataKeys.localizationSettings)?.get(LocalizationSettings.self)
            }) |> deliverOnMainQueue
            
            _ = data.startStandalone(next: { themeSettings, localization in
                System.legacyMenu = themeSettings.legacyMenu

                if let localization = localization {
                    applyUILocalization(localization)
                    UNUserNotifications.current?.registerCategories()
                }
                
                telegramUpdateTheme(updateTheme(with: themeSettings), window: window, animated: false)

                self.window.makeKeyAndOrderFront(self)
                NSApp.activate(ignoringOtherApps: true)

                showModal(with: ColdStartPasslockController(checkNextValue: { passcode in
                    appEncryption.applyPasscode(passcode)
                    if let params = appEncryption.decrypt() {
                        let parameters = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: ValueBoxEncryptionParameters.Key(data: params.key)!, salt: ValueBoxEncryptionParameters.Salt(data: params.salt)!)
                        if #available(macOS 10.15, *) {
                            Queue.concurrentDefaultQueue().async {
                                syncPasscodeCredential(code: passcode, rootPath: rootPath)
                            }
                        }
                        self.launchApp(accountManager: accountManager, encryptionParameters: parameters, appEncryption: appEncryption)
                        return true
                    } else {
                        return false
                    }
                }, logoutImpl: {
                    return Signal { subscriber in
                        try? FileManager.default.removeItem(atPath: rootPath)
                        subscriber.putCompletion()
                        DispatchQueue.main.async {
                            let appEncryption = AppEncryptionParameters(path: rootPath)
                            let accountManager = AccountManager<TelegramAccountManagerTypes>(basePath: self.containerUrl + "/accounts-metadata", isTemporary: false, isReadOnly: false, useCaches: true, removeDatabaseOnError: true, accessChallenge: makeAccountManagerAccessChallenge(basePath: self.containerUrl + "/accounts-metadata", isTemporary: false, isReadOnly: false))
                            if let params = appEncryption.decrypt() {
                                let parameters = ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: ValueBoxEncryptionParameters.Key(data: params.key)!, salt: ValueBoxEncryptionParameters.Salt(data: params.salt)!)
                                self.launchApp(accountManager: accountManager, encryptionParameters: parameters, appEncryption: appEncryption)
                            }
                        }
                        return EmptyDisposable
                    } |> runOn(prepareQueue)
                }), for: window)
            })
        }
    }
    
    func accountContext(for id: AccountRecordId) -> AccountContext? {
        if let value = supportAccountContextValue?.find(id) {
            return value
        }
        if let context = contextValue?.context, context.account.id == id {
            return context
        }
        return nil
    }
    
    func activeContext(for id: AccountRecordId?) -> AccountContext? {
        if let id = id, let value = accountContext(for: id) {
            return value
        }
        return contextValue?.context
    }
    
    func enumerateAccountContexts(_ f: (AccountContext)->Void) {
        if let contextValue = contextValue {
            f(contextValue.context)
        }
        self.supportAccountContextValue?.enumerateAccountContext(f)
    }
    
    func enumerateExternalChatContexts(_ f: (AccountContext)->Void) {
        self.supportAccountContextValue?.enumerateExternalChatContext(f)
    }
    
    func enumerateApplicationContexts(_ f: (AuthorizedApplicationContext)->Void) {
        if let contextValue = contextValue {
            f(contextValue)
        }
        self.supportAccountContextValue?.enumerateApplicationContext(f)
    }
    
    private var terminated = false
    
    private func launchApp(accountManager: AccountManager<TelegramAccountManagerTypes>, encryptionParameters: ValueBoxEncryptionParameters, appEncryption: AppEncryptionParameters) {
        
        armCrashMarker(folder: containerUrl)
        
        FontCacheKey.initializeCache()
        
        clearUserDefaultsObject(forKeyPrefix: "dice_")
        
        self.appEncryption = appEncryption
        
        let rootPath = containerUrl!
        let window = self.window!
        System.updateScaleFactor(window.backingScaleFactor)
                
        window.applyChrome(.standard)
        
        window.minSize = NSMakeSize(400, 550)
        
        let networkDisposable = MetaDisposable()
        
        
       
//
//        self.window.closeInterceptor = {
//            if !self.terminated {
//                self.currentContext?.bindings.rootNavigation().gotoEmpty(false)
//            }
//            return false
//        }
        
        let displayUpgrade:(Float?) -> Void = { progress in
            if let progress = progress {
                let view = ObjcUtils.findElements(byClass: "Telegram.OpmizeDatabaseView", in: self.window.contentView!).first as? OpmizeDatabaseView ?? OpmizeDatabaseView(frame: self.window.bounds)
                view.setProgress(progress)
                self.window.contentView?.addSubview(view, positioned: .below, relativeTo: self.window.contentView?.subviews.first)
                self.window.makeKeyAndOrderFront(self)
            } else {
                ObjcUtils.findElements(byClass: "Telegram.OpmizeDatabaseView", in: self.window.contentView!).first?.removeFromSuperview()
            }
        }
        
        
        let _ = (upgradedAccounts(accountManager: accountManager, rootPath: rootPath, encryptionParameters: encryptionParameters) |> deliverOnMainQueue).start(next: { value in
            if value > 0 {
                displayUpgrade(value)
            } else {
                displayUpgrade(nil)
            }
        }, completed: {
            armCrashMarker(folder: rootPath)
            
            
            let data = combineLatest(accountManager.transaction {
                $0.getAccessChallengeData()
            }, themeSettingsView(accountManager: accountManager) |> take(1), accountManager.transaction { transaction in
                return transaction.getSharedData(SharedDataKeys.localizationSettings)?.get(LocalizationSettings.self)
            }) |> deliverOnMainQueue
            
            _ = data.start(next: { passcode, themeSettings, localization in
                switch passcode {
                case let .numericalPassword(value), let .plaintextPassword(value):
                    if !value.isEmpty {
                        appEncryption.change(value)
                        _ = accountManager.transaction {
                            $0.setAccessChallengeData(.plaintextPassword(value: ""))
                        }.start()
                    }
                default:
                    break
                }
                
                if let localization = localization {
                    applyUILocalization(localization)
                    UNUserNotifications.current?.registerCategories()
                }
                            
                telegramUpdateTheme(updateTheme(with: themeSettings), window: window, animated: false)

                
                let basicTheme = Atomic<ThemePaletteSettings?>(value: themeSettings)
                let viewDidChangedAppearance: ValuePromise<Bool> = ValuePromise(true)
                let backingProperties:ValuePromise<CGFloat> = ValuePromise(System.backingScale, ignoreRepeated: true)
                
                
                let previousBackingScale: Atomic<CGFloat> = Atomic(value: System.backingScale)
                let signal: Signal<TelegramPresentationTheme?, NoError> = combineLatest(queue: resourcesQueue, themeSettingsView(accountManager: accountManager), backingProperties.get()) |> map { settings, backingScale in
                    let previous = basicTheme.swap(settings)
                    let previousScale = previousBackingScale.swap(backingScale)
                    System.legacyMenu = settings.legacyMenu
                    if previous?.palette != settings.palette || previous?.bubbled != settings.bubbled || previous?.wallpaper.wallpaper != settings.wallpaper.wallpaper || previous?.fontSize != settings.fontSize || previousScale != backingScale  {
                        return updateTheme(with: settings, animated: ((previous?.fontSize == settings.fontSize && previous?.palette != settings.palette) || previous?.bubbled != settings.bubbled || previous?.cloudTheme?.id != settings.cloudTheme?.id || previous?.palette.isDark != settings.palette.isDark))
                    } else {
                        return nil
                    }
                } |> deliverOnMainQueue
                
                _ = signal.start(next: { updatedTheme in
                    if let theme = updatedTheme {
                        if self.contextValue == nil {
                            telegramUpdateTheme(theme, window: window, animated: true)
                        } else {
                            self.enumerateApplicationContexts({ context in
                                telegramUpdateTheme(theme, window: context.context.window, animated: true)
                                context.applyNewTheme()
                            })
                        }
                    }
                })
                

                
                //
                
                NotificationCenter.default.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: window, queue: nil, using: { notification in
                    System.updateScaleFactor(window.backingScaleFactor)
                    backingProperties.set(window.backingScaleFactor)
                })
                
                let autoNightSignal = viewDidChangedAppearance.get() |> mapToSignal { _ in
                    return autoNightSettings(accountManager: accountManager) |> mapToSignal { preference -> Signal<(AutoNightThemePreferences, Void), NoError> in
                        if preference.schedule != nil || preference.systemBased {
                            return combineLatest(.single(preference), Signal<Void, NoError>.single(Void()) |> then( Signal<Void, NoError>.single(Void()) |> delay(60, queue: Queue.mainQueue()) |> restart))
                        } else {
                            return .single((preference, Void()))
                        }
                    }
                    } |> deliverOnMainQueue
                
                
                _ = combineLatest(autoNightSignal, additionalSettings(accountManager: accountManager)).start(next: { value1, value2 in
                    
                    let preference = value1.0
                    _ = value2.alwaysDarkMode
                    
                    var isEnabled: Bool
                    var isDark: Bool = false
                    

                    if let schedule = preference.schedule {
                        
                        isEnabled = true
                        
                        let nowTimestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
                        var now: time_t = time_t(nowTimestamp)
                        var timeinfoNow: tm = tm()
                        localtime_r(&now, &timeinfoNow)
                        let t = timeinfoNow.tm_hour * 60 * 60 + timeinfoNow.tm_min * 60 + timeinfoNow.tm_sec
                        
                        switch schedule {
                        case let .sunrise(latitude, longitude, _):
                            if latitude == 0 || longitude == 0 {
                                isEnabled = theme.colors.isDark
                            } else {
                                if let sunrise = EDSunriseSet(date: Date(), timezone: NSTimeZone.local, latitude: latitude, longitude: longitude) {
                                    let from = Int32(sunrise.sunset.timeIntervalSince1970 - sunrise.sunset.startOfDay.timeIntervalSince1970)
                                    let to = Int32(sunrise.sunrise.timeIntervalSince1970 - sunrise.sunrise.startOfDay.timeIntervalSince1970)
                                    isDark = to > from && t >= from && t <= to || to < from && (t >= from || t <= to)
                                } else {
                                    isDark = false
                                }
                            }
                        case let .timeSensitive(from, to):
                            let from = from * 60 * 60
                            let to = to * 60 * 60
                            isDark = to > from && t >= from && t < to || to < from && (t >= from || t < to)
                        }
                        
                    } else if preference.systemBased {
                        isEnabled = true
                        if #available(OSX 10.14, *) {
                            switch systemAppearance.name {
                            case NSAppearance.Name.aqua:
                                isDark = false
                            case NSAppearance.Name.darkAqua:
                                isDark = true
                            default:
                                isDark = false
                            }
                        } else {
                            isDark = false
                        }
                    } else {
                        isEnabled = false
                    }
                    
                    _ = updateThemeInteractivetly(accountManager: accountManager, f: { settings -> ThemePaletteSettings in
                        var settings = settings
                        if isEnabled {
                            settings = settings.withUpdatedToDefault(dark: isDark)
                            if isDark {
                                if let theme = preference.theme.cloud {
                                    settings = settings.withUpdatedCloudTheme(theme.cloud).withUpdatedPalette(theme.palette).updateWallpaper { current in
                                        return ThemeWallpaper(wallpaper: theme.wallpaper.wallpaper, associated: theme.wallpaper)
                                    }
                                } else {
                                    settings = settings.withUpdatedPalette(preference.theme.local.palette).withUpdatedCloudTheme(nil).installDefaultWallpaper().installDefaultAccent()
                                }
                            }
                        }
                        return settings
                    }).start()
                })
                
                
                let basicLocalization = Atomic<LocalizationSettings?>(value: localization)
                _ = (accountManager.sharedData(keys: [SharedDataKeys.localizationSettings]) |> deliverOnMainQueue).start(next: { view in
                    if let settings = view.entries[SharedDataKeys.localizationSettings]?.get(LocalizationSettings.self) {
                        if basicLocalization.swap(settings) != settings {
                            applyUILocalization(settings)
                            UNUserNotifications.current?.registerCategories()
                        }
                    }
                })
                
                
                let voipVersions = OngoingCallContext.versions(includeExperimental: true, includeReference: false).map { version, supportsVideo -> CallSessionManagerImplementationVersion in
                    CallSessionManagerImplementationVersion(version: version, supportsVideo: supportsVideo)
                }
            
                _ = Configuration.value(for: .source)
                
                
               
                
                let appData: Signal<Data?, NoError> = Signal { subscriber in
                    subscriber.putNext(ApiEnvironment.appData)
                    subscriber.putCompletion()
                    return EmptyDisposable
                } |> runOn(.concurrentBackgroundQueue())
                
                
                var useBetaFeatures: Bool = false
                #if BETA || DEBUG
                useBetaFeatures = false
                #endif
                
                let networkArguments = NetworkInitializationArguments(apiId: ApiEnvironment.apiId, apiHash: ApiEnvironment.apiHash, languagesCategory: ApiEnvironment.language, appVersion: ApiEnvironment.version, voipMaxLayer: OngoingCallContext.maxLayer, voipVersions: voipVersions, appData: appData, externalRequestVerificationStream: .single([:]), externalRecaptchaRequestVerification: { _, _ in return .complete() }, autolockDeadine: .single(nil), encryptionProvider: OpenSSLEncryptionProvider(), deviceModelName: deviceModelPretty(), useBetaFeatures: useBetaFeatures, isICloudEnabled: false, networkEngineFactory: RustNetworkEngineFactory())
                
                let sharedContext = SharedAccountContext(accountManager: accountManager, networkArguments: networkArguments, rootPath: rootPath, encryptionParameters: encryptionParameters, appEncryption: appEncryption, displayUpgradeProgress: displayUpgrade)
                
                self.hangKeybind(sharedContext)
                
                
              
                
                let rawAccounts = sharedContext.activeAccounts
                    |> map { _, accounts, _ -> [Account] in
                        return accounts.map({ $0.1 })
                }
                let _ = (sharedAccountInfos(accountManager: sharedContext.accountManager, accounts: rawAccounts)
                    |> deliverOn(Queue())).start(next: { infos in
                        storeAccountsData(rootPath: rootPath, accounts: infos)
                    })
                
                
                let notificationsBindings = SharedNotificationBindings(navigateToChat: { account, peerId in
                    if let contextValue =  self.accountContext(for: account.id) {
                        let navigation = contextValue.bindings.rootNavigation()
                        
                        if let controller = navigation.controller as? ChatController {
                            if controller.chatInteraction.peerId == peerId {
                                controller.scrollup()
                            } else {
                                navigation.push(ChatAdditionController(context: contextValue, chatLocation: .peer(peerId)))
                            }
                        } else {
                            navigation.push(ChatController(context: contextValue, chatLocation: .peer(peerId)))
                        }
                        NSApp.activate(ignoringOtherApps: true)
                        contextValue.window.deminiaturize(nil)
                    } else {
                        sharedContext.switchToAccount(id: account.id, action: .chat(peerId, necessary: true))
                        NSApp.activate(ignoringOtherApps: true)
                        window.deminiaturize(nil)
                    }
                }, navigateToThread: { account, threadId, fromId, threadData in
                    if let contextValue =  self.accountContext(for: account.id) {
                        let pushController: (ChatLocation, ChatMode, MessageId?, Atomic<ChatLocationContextHolder?>, Bool) -> Void = { chatLocation, mode, messageId, contextHolder, addition in
                            let navigation = contextValue.bindings.rootNavigation()
                            let controller: ChatController
                            if addition {
                                controller = ChatAdditionController(context: contextValue, chatLocation: chatLocation, mode: mode, focusTarget: .init(messageId: messageId), initialAction: nil, chatLocationContextHolder: contextHolder)
                            } else {
                                controller = ChatController(context: contextValue, chatLocation: chatLocation, mode: mode, focusTarget: .init(messageId: messageId), initialAction: nil, chatLocationContextHolder: contextHolder)
                            }
                            navigation.push(controller)
                        }
                        
                        let navigation = contextValue.bindings.rootNavigation()
                        
                        let currentInChat = navigation.controller is ChatController
                        let controller = navigation.controller as? ChatController
                        
                        if controller?.chatLocation.peerId == threadId.peerId,  controller?.chatLocation.threadMsgId == threadId {
                            controller?.scrollup()
                        } else {
                            
                            if let _ = threadData {
                                
                                _ = (ForumUI.openTopic(Int64(threadId.id), peerId: threadId.peerId, context: contextValue) |> take(1)).start()
                            } else if let fromId = fromId {
                                let signal:Signal<ThreadInfo, FetchChannelReplyThreadMessageError> = fetchAndPreloadReplyThreadInfo(context: contextValue, subject: .channelPost(threadId))
                                
                                _ = showModalProgress(signal: signal |> take(1), for: contextValue.window).start(next: { result in
                                    let chatLocation: ChatLocation = .thread(result.message)
                                    
                                    let updatedMode: ReplyThreadMode
                                    if result.isChannelPost {
                                        updatedMode = .comments(origin: fromId)
                                    } else {
                                        updatedMode = .replies(origin: fromId)
                                    }
                                    pushController(chatLocation, .thread(mode: updatedMode), fromId, result.contextHolder, currentInChat)
                                    
                                }, error: { error in
                                    
                                })
                            }
                        }
                        NSApp.activate(ignoringOtherApps: true)
                        contextValue.window.deminiaturize(nil)
                    } else {
                        sharedContext.switchToAccount(id: account.id, action: .thread(threadId, fromId, threadData, necessary: true))
                        NSApp.activate(ignoringOtherApps: true)
                        window.deminiaturize(nil)
                    }
                }, updateCurrectController: {
                    if let contextValue = self.contextValue {
                        contextValue.context.bindings.rootNavigation().controller.updateController()
                    }
                }, applyMaxReadIndexInteractively: { index in
                    if let context = self.contextValue?.context {
                        _ = context.engine.messages.applyMaxReadIndexInteractively(index: index).start()
                    }

                })
                
                let sharedNotificationManager = SharedNotificationManager(activeAccounts: sharedContext.activeAccounts |> map { ($0.0, $0.1.map { ($0.0, $0.1) }) }, appEncryption: appEncryption, accountManager: accountManager, bindings: notificationsBindings)
                let sharedWakeupManager = SharedWakeupManager(sharedContext: sharedContext, inForeground: self.presentAccountStatus.get())
                let sharedApplicationContext = SharedApplicationContext(sharedContext: sharedContext, notificationManager: sharedNotificationManager, sharedWakeupManager: sharedWakeupManager)
                
                self.sharedApplicationContextValue = sharedApplicationContext
                
                self.supportAccountContextValue = .init(applicationContext: sharedApplicationContext)
                
                
                self.sharedContextPromise.set(accountManager.transaction { transaction -> (SharedApplicationContext, LoggingSettings) in
                    return (sharedApplicationContext, transaction.getSharedData(SharedDataKeys.loggingSettings)?.get(LoggingSettings.self) ?? LoggingSettings.defaultSettings)
                }
                |> mapToSignal { sharedApplicationContext, loggingSettings -> Signal<SharedApplicationContext, NoError> in
                    #if BETA || ALPHA
                    Logger.shared.logToFile = true
                    #else
                    Logger.shared.logToFile = loggingSettings.logToFile
                    #endif
                    Logger.shared.logToConsole = false//loggingSettings.logToConsole
                    Logger.shared.redactSensitiveData = true//loggingSettings.redactSensitiveData
                    return .single(sharedApplicationContext)
                })
                
                self.context.set(self.sharedContextPromise.get()
                    |> deliverOnMainQueue
                    |> mapToSignal { sharedApplicationContext -> Signal<AuthorizedApplicationContext?, NoError> in
                        return sharedApplicationContext.sharedContext.activeAccounts
                            |> mapToSignal { primary, _, _ -> Signal<(Account?, LaunchSettings?), NoError> in
                                return .single((primary, nil))
                            }
                            |> distinctUntilChanged(isEqual: { lhs, rhs in
                                if lhs.0 !== rhs.0 {
                                    return false
                                }
                                return true
                            })
                            |> mapToSignal { (account, _) -> Signal<(Account?, LaunchSettings?), NoError> in
                                if let account = account {
                                    if let action = sharedContext.getLaunchActionOnce(for: account.id) {
                                        return .single((account, LaunchSettings(applyText: nil, previousText: nil, navigation: action)))
                                    } else {
                                        return account.postbox.transaction { transaction in
                                            return transaction.getPreferencesEntry(key: ApplicationSpecificPreferencesKeys.launchSettings)?.get(LaunchSettings.self)
                                        } |> map {
                                            return (account, $0)
                                        }
                                    }
                                } else {
                                    return .single((nil, nil))
                                }
                            } |> mapToSignal { (account, settings) -> Signal<(Account?, LaunchSettings?, ChatListFolders?), NoError> in
                                if let account = account {
                                    return chatListFilterPreferences(engine: TelegramEngine(account: account)) |> take(1) |> map {
                                        (account, settings, $0)
                                    }
                                } else {
                                    return .single((account, settings, nil))
                                }
                                
                            } |> deliverOnMainQueue
                            |> map { account, settings, folders in
                                if let account = account {
                                                                    
                                    let context = AccountContext(sharedContext: sharedApplicationContext.sharedContext, window: window, account: account)
                                    return AuthorizedApplicationContext(window: window, context: context, launchSettings: settings ?? LaunchSettings.defaultSettings, callSession: sharedContext.getCrossAccountCallSession(), groupCallContext: sharedContext.getCrossAccountGroupCall(), inlinePlayerContext: sharedContext.getCrossInlinePlayer(), folders: folders)
                                    
                                } else {
                                    return nil
                                }
                        }
                    })
                
                
                self.authContext.set(self.sharedContextPromise.get()
                    |> deliverOnMainQueue
                    |> mapToSignal { sharedApplicationContext -> Signal<UnauthorizedApplicationContext?, NoError> in
                        return sharedApplicationContext.sharedContext.activeAccounts
                            |> map { primary, accounts, auth -> (Account?, UnauthorizedAccount, [Account])? in
                                if let auth = auth {
                                    return (primary, auth, Array(accounts.map({ $0.1 })))
                                } else {
                                    return nil
                                }
                            }
                            |> distinctUntilChanged(isEqual: { lhs, rhs in
                                if lhs?.1 !== rhs?.1 {
                                    return false
                                }
                                return true
                            })
                            |> mapToSignal { authAndAccounts -> Signal<(UnauthorizedAccount, ((String, AccountRecordId, Bool)?, [(String, AccountRecordId, Bool)]))?, NoError> in
                                if let (primary, auth, accounts) = authAndAccounts {
                                    let phoneNumbers = combineLatest(accounts.map { account -> Signal<(AccountRecordId, String, Bool)?, NoError> in
                                        return account.postbox.transaction { transaction -> (AccountRecordId, String, Bool)? in
                                            if let phone = (transaction.getPeer(account.peerId) as? TelegramUser)?.phone {
                                                return (account.id, phone, account.testingEnvironment)
                                            } else {
                                                return nil
                                            }
                                        }
                                    })
                                    return phoneNumbers
                                        |> map { phoneNumbers -> (UnauthorizedAccount, ((String, AccountRecordId, Bool)?, [(String, AccountRecordId, Bool)]))? in
                                            var primaryNumber: (String, AccountRecordId, Bool)?
                                            if let primary = primary {
                                                for idAndNumber in phoneNumbers {
                                                    if let (id, number, testingEnvironment) = idAndNumber, id == primary.id {
                                                        primaryNumber = (number, id, testingEnvironment)
                                                        break
                                                    }
                                                }
                                            }
                                            return (auth, (primaryNumber, phoneNumbers.compactMap({ $0.flatMap({ ($0.1, $0.0, $0.2) }) })))
                                    }
                                } else {
                                    return .single(nil)
                                }
                            }
                            |> mapToSignal { accountAndOtherAccountPhoneNumbers -> Signal<(UnauthorizedAccount, ((String, AccountRecordId, Bool)?, [(String, AccountRecordId, Bool)]))?, NoError> in
                                if let (account, otherAccountPhoneNumbers) = accountAndOtherAccountPhoneNumbers {
                                    return .single((account, otherAccountPhoneNumbers))
                                } else {
                                    return .single(nil)
                                }
                            }
                            |> deliverOnMainQueue
                            |> mapToSignal { accountAndSettings -> Signal<UnauthorizedApplicationContext?, NoError> in
                                if let accountAndSettings = accountAndSettings {
                                    return .single(UnauthorizedApplicationContext(window: window, sharedContext: sharedApplicationContext.sharedContext, account: accountAndSettings.0, otherAccountPhoneNumbers: accountAndSettings.1))
                                } else {
                                    return .single(nil)
                                }
                        }
                    })
                
                
                
                
                _ = (self.context.get() |> mapToSignal { context -> Signal<AuthorizedApplicationContext?, NoError> in
                    if let context = context {
                        return context.ready |> map { [weak context] _ in
                            return context
                        }
                    } else {
                        return .single(nil)
                    }
                    
                    } |> deliverOnMainQueue).start(next: { context in
                        assert(Queue.mainQueue().isCurrent())
                        
                        if let contextValue = self.contextValue {
                            contextValue.context.isCurrent = false
                            contextValue.rootView.removeFromSuperview()
                        }
                        
                        ObjcUtils.findElements(byClass: "Telegram.OpmizeDatabaseView", in: self.window.contentView!).first?.removeFromSuperview()
                        
                        closeModal(ColdStartPasslockController.self)
                        closeAllPopovers(for: window)
                        
                        self.contextValue = context
                                                
                        if let context = context {
                            context.context.isCurrent = true
                            context.applyNewTheme()
                            self.window.contentView?.addSubview(context.rootView, positioned: .below, relativeTo: self.window.contentView?.subviews.first)
                            
                            context.runLaunchAction()
                            #if DEBUG
                            EmojiPanelLab.startIfRequested(context: context.context, outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"))
                            GifPanelLab.startIfRequested(context: context.context, outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"))
                            ScreenCaptureLab.startIfRequested(outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"))
                            CallVideoLab.startIfRequested(outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"))
                            PeerCallLab.startIfRequested(context: context.context, outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"))
                            VideoPlayerLab.startIfRequested(context: context.context, outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"))
                            ChatNavigationLab.startIfRequested(context: context.context, outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"))
                            PeerMediaLab.startIfRequested(context: context.context, outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"))
                            UniqueGiftLab.startIfRequested(context: context.context, outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"))
                            PerfLabViewCensusLab.startIfRequested(window: self.window, outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"), screens: [
                                .init("chats", open: { context.context.bindings.mainViewController.showChatList() }),
                                .init("settings", open: { context.context.bindings.mainViewController.showPreferences() }),
                                .init("calls", open: { context.context.bindings.mainViewController.showCalls() }),
                                .init("edit-profile", open: { EditAccountInfoController(context: context.context, f: { context.context.bindings.rootNavigation().push($0) }) }),
                                .init("peer-info", open: {
                                    let accountContext = context.context
                                    _ = (accountContext.account.postbox.loadedPeerWithId(accountContext.peerId) |> deliverOnMainQueue).start(next: { peer in
                                        accountContext.bindings.rootNavigation().push(PeerInfoController(context: accountContext, peer: peer))
                                    })
                                }),
                                .init("peer-gifts", open: { [weak self] in
                                    let accountContext = context.context
                                    _ = (accountContext.account.postbox.loadedPeerWithId(accountContext.peerId) |> deliverOnMainQueue).start(next: { peer in
                                        accountContext.bindings.rootNavigation().push(PeerInfoController(context: accountContext, peer: peer))
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                            if let root = self?.window.contentView {
                                                PerfLabViewCensus.scrollToBottom(root, minX: 0.3)
                                            }
                                        }
                                    })
                                })
                            ])
                            NetworkLab.startIfRequested(context: context.context, outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"))
                            StoryMorphLab.startIfRequested(context: context.context, outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"))
                            ChatListStoriesLab.startIfRequested(context: context.context, outputDirectory: URL(fileURLWithPath: self.containerUrl).appendingPathComponent("perf-lab"))
                            #endif
                            if let executeUrlAfterLogin = self.executeUrlAfterLogin {
                                self.executeUrlAfterLogin = nil
                                execute(inapp: inApp(for: executeUrlAfterLogin.nsstring, context: context.context))
                            }
                            #if !APP_STORE
                            networkDisposable.set((context.context.account.postbox.preferencesView(keys: [PreferencesKeys.networkSettings]) |> delay(5.0, queue: Queue.mainQueue()) |> deliverOnMainQueue).start(next: { settings in
                                let settings = settings.values[PreferencesKeys.networkSettings]?.get(NetworkSettings.self)
                                
                                let applicationUpdateUrlPrefix: String?
                                if let prefix = settings?.applicationUpdateUrlPrefix {
                                    if prefix.range(of: "://") == nil {
                                        applicationUpdateUrlPrefix = "https://" + prefix
                                    } else {
                                        applicationUpdateUrlPrefix = prefix
                                    }
                                } else {
                                    applicationUpdateUrlPrefix = nil
                                }
                                setAppUpdaterBaseDomain(applicationUpdateUrlPrefix)
                                #if STABLE || BETA || DEBUG
                                updater_resetWithUpdaterSource(.internal(context: context.context))
                                #else
                                updater_resetWithUpdaterSource(.external(context: context.context))
                                #endif
                                
                            }))
                            #endif
                            
                            if let url = AppDelegate.eventProcessed {
                                self.processURL(url)
                            }
                            if let action = AppDelegate.spotlightAction {
                                self.processSpotlightAction(action)
                            }
                            
                            if !self.window.isKeyWindow {
                                self.window.makeKeyAndOrderFront(self)
                            }
                            self.window.deminiaturize(self)
                            NSApp.activate(ignoringOtherApps: true)
                             
                            
                        }
                    })
                
                
                var presentAuthAnimated: Bool = false
                
                let authContextReadyDisposable = MetaDisposable()
                
                _ = (self.authContext.get()
                    |> deliverOnMainQueue).start(next: { context in
                        
                        ObjcUtils.findElements(byClass: "Telegram.OpmizeDatabaseView", in: self.window.contentView!).first?.removeFromSuperview()
                        
                        if let authContextValue = self.authContextValue {
                            authContextValue.account.shouldBeServiceTaskMaster.set(.single(.never))
                            authContextValue.modal.close()
                        }
                        self.authContextValue = context
                        if let context = context {
                            let isReady: Signal<Bool, NoError> = .single(true)
                            authContextReadyDisposable.set((isReady
                                |> filter { $0 }
                                |> take(1)
                                |> deliverOnMainQueue).start(next: { _ in
                                    
                                    window.makeKeyAndOrderFront(nil)
                                    showModal(with: context.modal, for: window, animated: presentAuthAnimated)
                                    
                                    #if !APP_STORE
                                    networkDisposable.set((context.account.postbox.preferencesView(keys: [PreferencesKeys.networkSettings]) |> delay(5.0, queue: Queue.mainQueue()) |> deliverOnMainQueue).start(next: { settings in
                                        let settings = settings.values[PreferencesKeys.networkSettings]?.get(NetworkSettings.self)
                                        
                                        let applicationUpdateUrlPrefix: String?
                                        if let prefix = settings?.applicationUpdateUrlPrefix {
                                            if prefix.range(of: "://") == nil {
                                                applicationUpdateUrlPrefix = "https://" + prefix
                                            } else {
                                                applicationUpdateUrlPrefix = prefix
                                            }
                                        } else {
                                            applicationUpdateUrlPrefix = nil
                                        }
                                        setAppUpdaterBaseDomain(applicationUpdateUrlPrefix)
                                        #if STABLE
                                        if let context = self.contextValue?.context {
                                            updater_resetWithUpdaterSource(.internal(context: context))
                                        } else {
                                            updater_resetWithUpdaterSource(.external(context: nil))
                                        }
                                        #else
                                        updater_resetWithUpdaterSource(.external(context: self.contextValue?.context))
                                        #endif
                                        
                                    }))
                                    #endif
                                    
                                    
                                }))
                        } else {
                            presentAuthAnimated = true
                            authContextReadyDisposable.set(nil)
                        }
                    })
                
                
                
                
                
                //
                
                
                if #available(OSX 10.14, *) {
                    DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: nil, using: { _ in
                        delay(0.1, closure: {
                            forceUpdateStatusBarIconByDockTile(sharedContext: sharedContext)
                            viewDidChangedAppearance.set(true)
                        })
                    })
                    
                    (window.contentView as? View)?.viewDidChangedEffectiveAppearance = {
                        viewDidChangedAppearance.set(true)
                    }
                }
                
                NotificationCenter.default.addObserver(self, selector: #selector(self.windiwDidChangeBackingProperties), name: NSWindow.didChangeBackingPropertiesNotification, object: window)
                
                self.window.contentView?.wantsLayer = true
                
                sharedWakeupManager.onSleepValueUpdated = { value in
                    self.updatePeerPresence()
                }
                sharedContext.updateStatusBarLock(sharedNotificationManager.isLocked)
                sharedNotificationManager.didUpdateLocked = { value in
                    self.updatePeerPresence()
                    sharedContext.updateStatusBarLock(value.isLocked)
                }
                
                self.timer = SwiftSignalKit.Timer(timeout: 5, repeat: true, completion: {
                    self.updatePeerPresence()
                }, queue: .mainQueue())
                self.timer?.start()
                
            })
        })
        
    }

    func openAccountInNewWindow(_ account: Account) {
        supportAccountContextValue?.open(account: account)
    }
    
    func openPeerInNewWindow(peerId: PeerId, parent: AccountContext) {
        supportAccountContextValue?.openChat(peerId: peerId, parent: parent)
    }
    
    
    private func updatePeerPresence() {
        if let sharedApplicationContextValue = sharedApplicationContextValue {
            let isForeground = MattermostBackend.isEnabled || (NSApp.isActive && !NSApp.isHidden)
            let sessionLocked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
            var chatWindows: [NSWindow] = []
            self.enumerateAccountContexts { chatWindows.append($0.window) }
            self.enumerateExternalChatContexts { chatWindows.append($0.window) }
            let receiptVisible = !sessionLocked && !NSApp.isHidden && !sharedApplicationContextValue.sharedWakeupManager.isSleeping && !sharedApplicationContextValue.notificationManager._lockedValue.screenLock && !sharedApplicationContextValue.notificationManager._lockedValue.passcodeLock && chatWindows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
            MattermostSync.updateReceiptDisplayVisibility(visible: receiptVisible)
            let isOnline = isForeground && NSApp.isRunning && !sharedApplicationContextValue.sharedWakeupManager.isSleeping && !sharedApplicationContextValue.notificationManager._lockedValue.screenLock && !sharedApplicationContextValue.notificationManager._lockedValue.passcodeLock && SystemIdleTime() < 30
            
            
            presentAccountStatus.set(.single(isOnline) |> then(.single(isOnline) |> delay(50, queue: Queue.concurrentBackgroundQueue())) |> restart)
        }
    }
    
    @objc public func windiwDidChangeBackingProperties() {
        System.updateScaleFactor(window.backingScaleFactor)
    }
    
    func playSound(_ path: String) {
        if let context = self.contextValue?.context {
            SoundEffectPlay.play(postbox: context.account.postbox, path: path, volume: 0.7)
        }
    }


    @IBAction func checkForUpdates(_ sender: Any) {
        #if !APP_STORE
            showModal(with: InputDataModalController(AppUpdateViewController()), for: window)
            #if STABLE
                if let context = self.contextValue?.context {
                    updater_resetWithUpdaterSource(.internal(context: context))
                } else {
                    updater_resetWithUpdaterSource(.external(context: nil))
                }
            #else
                updater_resetWithUpdaterSource(.external(context: self.contextValue?.context))
            #endif
        #endif
    }
    
    override func awakeFromNib() {
        #if APP_STORE
        if let menu = NSApp.mainMenu?.item(at: 0)?.submenu, let sparkleItem = menu.item(withTag: 1000) {
            menu.removeItem(sparkleItem)
        }
        #endif
        installServicesMenu()
    }

    private func installServicesMenu() {
        guard NSApp.servicesMenu == nil, let menu = NSApp.mainMenu?.item(at: 0)?.submenu, let index = menu.items.firstIndex(where: { $0.action == #selector(showQuickSwitcher(_:)) }) else {
            return
        }
        let servicesMenu = NSMenu(title: strings().appMenuServices)
        let servicesItem = NSMenuItem(title: strings().appMenuServices, action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        menu.insertItem(servicesItem, at: index)
        menu.insertItem(.separator(), at: index + 1)
        NSApp.servicesMenu = servicesMenu
    }
    
    
    @objc func checkUpdates() {
        #if !APP_STORE
        showModal(with: InputDataModalController(AppUpdateViewController()), for: window)
        #endif
    }
    
    
    
    private func setupLogger(containerPath: String) {
        MTLogSetEnabled(UserDefaults.standard.bool(forKey: "enablelogs"))

        let logger = Logger(rootPath: containerPath, basePath: containerPath + "/logs")
        logger.logToConsole = false
        logger.logToFile = UserDefaults.standard.bool(forKey: "enablelogs")
        
        #if DEBUG
            MTLogSetEnabled(true)
            logger.logToConsole = false
            logger.logToFile = true
        #endif
        
        Logger.setSharedLogger(logger)
    }
    
    private func recoverFromCrashOnLaunchIfNeeded(containerPath: String) {
        let marker = readCrashMarker(folder: containerPath)
        self.rustEngineCrash = marker?.crashedRun(onThread: rustEngineOwnsThread(named:), orQueue: rustEngineOwnsQueue(label:))
        clearCrashMarker(folder: containerPath)
        guard let marker = marker else {
            return
        }
        Logger.shared.log("CrashRecovery", "the previous run crashed: signal \(marker.signal) after \(marker.elapsed) s, build \(marker.bundleVersion ?? "unknown"), queue \(marker.queueLabel ?? "unknown"), thread \(marker.threadName ?? "unnamed")")
        guard marker.isInstantCrash else {
            return
        }
        Logger.shared.log("CrashRecovery", "crashed on the previous launch, showing recovery")
        disarmCrashMarker()
        let result = runCrashRecovery(update: crashRecoveryUpdate())
        Logger.shared.log("CrashRecovery", "result: \(result)")
        if result == .resetLocalData {
            try? FileManager.default.removeItem(atPath: containerPath)
            try? FileManager.default.createDirectory(atPath: containerPath, withIntermediateDirectories: true, attributes: nil)
            setupLogger(containerPath: containerPath)
            Logger.shared.log("CrashRecovery", "local data was reset")
        }
        armCrashMarker(folder: containerPath)
    }
    
    private func crashRecoveryUpdate() -> CrashRecoveryUpdate {
        #if APP_STORE
        return .appStore
        #elseif GITHUB || DEBUG
        return .website
        #else
        return .updater(crashRecoveryUpdater())
        #endif
    }
    
    private static var eventProcessed: String? = nil
    private static var spotlightAction: SpotlightIdentifier? = nil

    @objc func handleURLEvent(_ event:NSAppleEventDescriptor, with replyEvent:NSAppleEventDescriptor) {
        let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue
        processURL(url)
    }
    
    private func processURL(_ url: String?) {
        AppDelegate.eventProcessed = url
        
        if let url = AppDelegate.eventProcessed {
            NSApp.activate(ignoringOtherApps: true)
            self.window.deminiaturize(self)
            if let context = self.contextValue?.context {
                AppDelegate.eventProcessed = nil
                
                let link = inApp(for: url as NSString, context: context, openInfo: { (peerId, isChat, postId, action) in
                    context.bindings.rootNavigation().push(ChatController(context: context, chatLocation: .peer(peerId), focusTarget: .init(messageId: postId), initialAction:action), true)
                }, applyProxy: { proxy in
                    applyExternalProxy(proxy, accountManager: context.sharedContext.accountManager)
                })
                execute(inapp: link, isExternal: true)
            } else if let authContext = self.authContextValue {
                let settings = proxySettings(from: url)
                if settings.1 {
                    AppDelegate.eventProcessed = nil
                    if let proxy = settings.0 {
                        applyExternalProxy(proxy, accountManager: authContext.sharedContext.accountManager)
                    } else {
                        _ = updateProxySettingsInteractively(accountManager: authContext.sharedContext.accountManager, { current -> ProxySettings in
                            return current.withUpdatedActiveServer(nil)
                        }).start()
                    }
                }
                
                if url.range(of: legacyPassportUsername) != nil || url.range(of: "tg://passport") != nil {
                    alert(for: mainWindow, info: strings().secureIdLoginText)
                    self.executeUrlAfterLogin = url
                }
            }
        }
    }
    
    private func hangKeybind(_ sharedContext: SharedAccountContext) {
        let signal = combineLatest(queue: .mainQueue(), voiceCallSettings(sharedContext.accountManager), sharedContext.groupCallContext)
        
        _ = signal.start(next: { settings, activeCall in
            if let pushToTalk = settings.pushToTalk, let _ = activeCall {
                self.window.isPushToTalkEquaivalent = { event in
                    if !pushToTalk.modifierFlags.isEmpty, pushToTalk.keyCodes.contains(event.keyCode) {
                        for modifier in pushToTalk.modifierFlags {
                            if modifier.flag == event.modifierFlags.rawValue {
                                return true
                            }
                        }
                    }
                    return false
                }
            } else {
                self.window.isPushToTalkEquaivalent = nil
            }
            
        })

        
        
    }
    
    
    
    
    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        var rect = rect
        rect.origin.y -= 22
        return rect;
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        updatePeerPresence()
    }
    
    func tryApplyAutologinToken(_ url: String) -> String? {
        var result: String?
        self.enumerateAccountContexts { context in
            if context.window == NSApp.keyWindow {
                let config = context.appConfiguration
                if let value = AutologinToken.with(appConfiguration: config, autologinToken: context.autologinToken) {
                    result = value.applyTo(url, isTestServer: contextValue?.context.account.testingEnvironment ?? false)
                }
            }
        }
        return result
    }
    
    func applicationDidHide(_ notification: Notification) {
        updatePeerPresence()
        updateRenderingVisibility()
    }

    func applicationDidUnhide(_ notification: Notification) {
        updateRenderingVisibility()
    }
    
    func applicationDidChangeOcclusionState(_ notification: Notification) {
        updateRenderingVisibility()
    }
    
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        updateDisplayColorSpace()
    }
    
    private func updateDisplayColorSpace() {
        let screen = self.window?.screen ?? NSScreen.main
        setDisplayColorSpace(screen?.colorSpace?.cgColorSpace)
    }
    
    private func updateRenderingVisibility() {
        let visible = !NSApp.isHidden && NSApp.occlusionState.contains(.visible)
        SharedDisplayLinkDriver.shared.updateForegroundState(visible)
        setLottieRenderingSuspended(!visible)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !self.window.isVisible {
            self.window.makeKeyAndOrderFront(self)
            self.window.orderFrontRegardless()
        }
        if viewer != nil {
            viewer?.windowDidResignKey()
        }
        
        return true
    }
    
    
    override func acceptsPreviewPanelControl(_ panel:QLPreviewPanel) ->Bool {
        return true
    }
    
    
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = QuickLookPreview.current
        panel.dataSource = QuickLookPreview.current
    }
    
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = nil
        panel.dataSource = nil
        QuickLookPreview.current.hide()
    }
    
   

   
    @IBAction func paste(_ sender: Any) {
        if let window = NSApp.keyWindow as? Window {
            window.pasteToFirstResponder(sender)
        }
    }
    @IBAction func copy(_ sender: Any) {
        if let window = NSApp.keyWindow as? Window {
            window.copyFromFirstResponder(sender)
        }
    }
    
    func applicationWillUnhide(_ notification: Notification) {
        window.makeKeyAndOrderFront(nil)
    }
    
    func applicationWillBecomeActive(_ notification: Notification) {
        if contextValue != nil, !self.window.isMiniaturized {
            if !self.window.isVisible {
                self.window.makeKeyAndOrderFront(self)
                self.window.orderFrontRegardless()
            }
            if let viewer = viewer {
                viewer.windowDidResignKey()
            }
            self.activeValue.set(true)
            
        }
    }
    
    func updateActiveContexts() {
        let records = [self.contextValue?.context.account.id].compactMap { $0 } + (supportAccountContextValue?.accountIds ?? [])
        BrowserStateContext.focus(records)
    }
    
    
    func applicationDidResignActive(_ notification: Notification) {
        updatePeerPresence()
        if viewer != nil, NSScreen.main == viewer?.window.screen {
            viewer?.window.orderOut(nil)
        }
        self.activeValue.set(false)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        self.terminated = true
        disarmCrashMarker()
        if let containerUrl = self.containerUrl {
            clearCrashMarker(folder: containerUrl)
        }
        
        #if !APP_STORE
            updateAppIfNeeded()
        #endif
        
        holdPostboxQueueUntilExit()
    }
    
    private func holdPostboxQueueUntilExit() {
        let held = DispatchSemaphore(value: 0)
        Postbox.sharedQueue.async {
            held.signal()
            DispatchSemaphore(value: 0).wait()
        }
        _ = held.wait(timeout: .now() + 2.0)
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        
        if let context = self.contextValue?.context {
            let navigation = context.bindings.rootNavigation()
            (navigation.controller as? ChatController)?.chatInteraction.saveState(sync: true)
        }
        
        return .terminateNow
    }
    
    
    func windowDidDeminiaturize(_ notification: Notification) {
        window.makeKeyAndOrderFront(nil)
    }
    
    func windowDidMiniaturize(_ notification: Notification) {
        window.resignMain()
    }
    
    
    
    @IBAction func unhide(_ sender: Any) {
         window.makeKeyAndOrderFront(sender)
    }
    
    @IBAction func aboutAction(_ sender: Any) {
        showModal(with: AboutModalController(), for: window)
        window.makeKeyAndOrderFront(sender)
    }
    @IBAction func preferencesAction(_ sender: Any) {
        
        if let context = contextValue?.context {
            context.bindings.mainViewController.showPreferences()
        }
        window.makeKeyAndOrderFront(sender)

    }
    @IBAction func globalSearch(_ sender: Any) {
        if let context = contextValue?.context {
            context.bindings.mainViewController.focusSearch(animated: true)
        }
    }
    @IBAction func closeWindow(_ sender: Any) {
        NSApp.keyWindow?.close()
    }
    
    func isLocked() -> Signal<Bool, NoError> {
        if let context = sharedApplicationContextValue {
            return context.notificationManager.isLockedValue
        }
        return .single(false)
    }
    func isLockedValue() -> Bool {
        if let context = sharedApplicationContextValue {
            return context.notificationManager.isLocked
        }
        return false
    }
    
    func showSavedPathSuccess(_ path: String) {
        if let context = contextValue?.context {
            
            let text: String = strings().savedAsModalOk
            
            let attributedText = parseMarkdownIntoAttributedString(text, attributes: MarkdownAttributes(body: MarkdownAttributeSet(font: .bold(15), textColor: .white), bold: MarkdownAttributeSet(font: .bold(15), textColor: .white), link: MarkdownAttributeSet(font: .bold(15), textColor: .link), linkAttribute: { contents in
                return (NSAttributedString.Key.link.rawValue, inAppLink.callback(contents, { _ in }))
            })).mutableCopy() as! NSMutableAttributedString
            
            let layout = TextViewLayout(attributedText, alignment: .center, lineSpacing: 5.0, alwaysStaticItems: true)
            layout.interactions = TextViewInteractions(processURL: { _ in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            })
            layout.measure(width: 160)
            
            _ = showSaveModal(for: window, context: context, animation: LocalAnimatedSticker.success_saved, text: layout, delay: 3.0).start()
        }
    }
    
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        if userActivity.activityType == CSSearchableItemActionType {
            if let uniqueIdentifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                if let identifier = parseSpotlightIdentifier(uniqueIdentifier) {
                    self.processSpotlightAction(identifier)
                }
            }
        }
        
        return true
    }
        
    private func processSpotlightAction(_ identifier: SpotlightIdentifier) {
        if let context = contextValue?.context {
            AppDelegate.spotlightAction = nil
            if context.account.id == identifier.recordId {
                switch identifier.source {
                case let .peerId(peerId):
                    navigateToChat(navigation: context.bindings.rootNavigation(), context: context, chatLocation: .peer(peerId))
                }
            } else {
                switch identifier.source {
                case let .peerId(peerId):
                    context.sharedContext.switchToAccount(id: identifier.recordId, action: .chat(peerId, necessary: true))
                }
            }
        } else {
            AppDelegate.spotlightAction = identifier
        }
        
    }
    
    @IBAction func showQuickSwitcher(_ sender: Any) {
        if authContextValue == nil {
            _ = sharedContextOnce.start(next: { applicationContext in
                if !applicationContext.notificationManager.isLocked {
                    self.enumerateApplicationContexts { applicationContext in
                        if applicationContext.context.window.isKeyWindow {
                            if !hasModals(applicationContext.context.window) {
                                showModal(with: QuickSwitcherModalController(applicationContext.context), for: applicationContext.context.window)
                                applicationContext.context.window.makeKeyAndOrderFront(sender)
                            }
                        }
                    }
                }
            })
        }
        
    }
    
    func applyExternalLoginCode(_ code: String) {
        if let modal = findModal(ModalController.self) {
            let controller = modal.controller.controller as? PhoneNumberCodeConfirmController
            if let controller = controller {
                controller.applyExternalLoginCode(code)
                return
            }
        }
        self.authContextValue?.applyExternalLoginCode(code)
    }
}

#if DEBUG
private var relayDebugLastPeerId: PeerId?

extension AppDelegate {
    func installRelayDebugRemote(directory: String) {
        RelayDebugRemote.install(directory: directory)
        RelayDebugRemote.register("activate", { [weak self] _, completion in
            self?.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            completion(true, nil, [:])
        })
        RelayDebugRemote.register("capture-view", { [weak self] command, completion in
            guard let view = self?.window.contentView, let path = command["path"] else {
                completion(false, "missing view or path", [:])
                return
            }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                completion(false, "cannot create view bitmap", [:])
                return
            }
            if command["layers"] == "1", let layer = view.layer, let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                let transform = context.cgContext.ctm
                context.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width / abs(transform.a), y: CGFloat(bitmap.pixelsHigh) / view.bounds.height / abs(transform.d))
                layer.render(in: context.cgContext)
            } else {
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                completion(false, "cannot encode view bitmap", [:])
                return
            }
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                completion(true, nil, ["path": path, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh])
            } catch { completion(false, String(describing: error), [:]) }
        })
        RelayDebugRemote.register("snapshot", { _, completion in
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("org.relaychat.RelayMac.debug.snapshot"), object: nil, userInfo: nil, deliverImmediately: true)
            completion(true, nil, [:])
        })
        RelayDebugRemote.register("state", { [weak self] _, completion in
            guard let context = self?.contextValue?.context else {
                completion(true, nil, ["authorized": false])
                return
            }
            let navigation = context.bindings.rootNavigation()
            var extra: [String: Any] = ["authorized": true, "accountPeerId": "\(context.account.peerId.toInt64())", "controller": String(describing: type(of: navigation.controller))]
            if let peerId = relayDebugLastPeerId {
                extra["lastOpenedPeerId"] = "\(peerId.toInt64())"
            }
            completion(true, nil, extra)
        })
        RelayDebugRemote.register("open-chat", { [weak self] command, completion in
            guard let context = self?.contextValue?.context, let query = command["query"] else {
                completion(false, "no account or query", [:])
                return
            }
            let _ = (context.engine.contacts.searchLocalPeers(query: query) |> take(1) |> deliverOnMainQueue).start(next: { peers in
                let titles = peers.compactMap { $0.peer }.map { ($0.id, $0._asPeer().displayTitle) }
                guard let match = titles.first(where: { $0.1.lowercased() == query.lowercased() }) ?? titles.first else {
                    completion(false, "no chat matches \(query)", [:])
                    return
                }
                relayDebugLastPeerId = match.0
                navigateToChat(navigation: context.bindings.rootNavigation(), context: context, chatLocation: .peer(match.0))
                completion(true, nil, ["peerId": "\(match.0.toInt64())", "title": match.1, "candidates": titles.map { $0.1 }])
            })
        })
        RelayDebugRemote.register("screen", { [weak self] command, completion in
            guard let context = self?.contextValue?.context else {
                completion(false, "no account", [:])
                return
            }
            switch command["name"] ?? "" {
            case "new-message":
                context.bindings.rootNavigation().push(RelayNewMessageController(context: context))
            case "new-channel":
                context.bindings.rootNavigation().push(RelayNewChannelController(context: context))
            case "browse":
                context.bindings.rootNavigation().push(RelayBrowseChannelsController(context: context))
            case "settings":
                context.bindings.mainViewController.showPreferences()
            case "chats":
                context.bindings.mainViewController.showChatList()
            case "threads":
                context.bindings.mainViewController.showThreads()
            default:
                completion(false, "unknown screen", [:])
                return
            }
            completion(true, nil, [:])
        })
        RelayDebugRemote.register("thread", { [weak self] _, completion in
            guard let context = self?.contextValue?.context, let peerId = relayDebugLastPeerId else {
                completion(false, "no account or opened chat", [:])
                return
            }
            let _ = (context.account.postbox.transaction { transaction -> (MessageId, Int32, String)? in
                var found: (MessageId, Int32, String)?
                transaction.scanTopMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, limit: 200, { message in
                    if let attribute = message.attributes.first(where: { $0 is ReplyThreadMessageAttribute }) as? ReplyThreadMessageAttribute, attribute.count > 0 {
                        found = (message.id, attribute.count, message.text)
                        return false
                    }
                    return true
                })
                return found
            } |> deliverOnMainQueue).start(next: { found in
                guard let found else {
                    completion(false, "no post with replies in the last 200", [:])
                    return
                }
                let thread = ChatReplyThreadMessage(peerId: found.0.peerId, threadId: Int64(found.0.id), channelMessageId: nil, isChannelPost: false, isForumPost: true, isMonoforumPost: false, maxMessage: nil, maxReadIncomingMessageId: nil, maxReadOutgoingMessageId: nil, unreadCount: 0, initialFilledHoles: IndexSet(), initialAnchor: .automatic, isNotAvailable: false)
                context.bindings.rootNavigation().push(ChatAdditionController(context: context, chatLocation: .thread(thread), mode: .thread(mode: .replies(origin: found.0)), focusTarget: nil, initialAction: nil, chatLocationContextHolder: Atomic(value: nil)))
                completion(true, nil, ["root": "\(found.0.id)", "replies": found.1, "text": String(found.2.prefix(80))])
            })
        })
        RelayDebugRemote.register("notifications", { _, completion in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                    let items = delivered.map { $0.request.content.title + " | " + $0.request.content.body }
                    DispatchQueue.main.async {
                        completion(true, nil, ["authorization": settings.authorizationStatus.rawValue, "delivered": items])
                    }
                }
            }
        })
        RelayDebugRemote.register("send", { [weak self] command, completion in
            guard let context = self?.contextValue?.context, let text = command["text"], let peerId = relayDebugLastPeerId else {
                completion(false, "no account, text or opened chat", [:])
                return
            }
            let _ = (enqueueMessages(account: context.account, peerId: peerId, messages: [.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: nil, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])]) |> deliverOnMainQueue).start(next: { ids in
                completion(true, nil, ["messageIds": ids.map { $0.map { "\($0.id)" } ?? "nil" }])
            })
        })
        self.installRelayCallDebugRemote()
        self.installRelayChatDebugRemote()
    }
}
#endif

#if DEBUG
private func relayDebugFindPeer(_ context: AccountContext, _ query: String, _ completion: @escaping (PeerId?, String, [String]) -> Void) {
    let _ = (context.engine.contacts.searchLocalPeers(query: query) |> take(1) |> deliverOnMainQueue).start(next: { peers in
        let candidates = peers.compactMap { $0.peer }
        let lower = query.lowercased()
        let match = candidates.first(where: { $0.addressName?.lowercased() == lower }) ?? candidates.first(where: { $0._asPeer().displayTitle.lowercased() == lower }) ?? candidates.first
        completion(match?.id, match?._asPeer().displayTitle ?? "", candidates.map { $0._asPeer().displayTitle })
    })
}

private func relayDebugFlag(_ value: String?) -> Bool? {
    switch value?.lowercased() {
    case "on"?, "1"?, "true"?, "yes"?:
        return true
    case "off"?, "0"?, "false"?, "no"?:
        return false
    default:
        return nil
    }
}

private func relayDebugWindows() -> [[String: Any]] {
    return NSApp.windows.filter { $0.isVisible }.enumerated().map { index, window in
        return ["index": index, "class": String(describing: type(of: window)), "title": window.title, "frame": NSStringFromRect(window.frame), "key": window.isKeyWindow, "level": window.level.rawValue]
    }
}

private func relayDebugCallState(_ state: CallState) -> [String: Any] {
    return ["state": "\(state.state)", "videoState": "\(state.videoState)", "remoteVideoState": "\(state.remoteVideoState)", "isMuted": state.isMuted, "isOutgoingVideoPaused": state.isOutgoingVideoPaused, "remoteAspectRatio": state.remoteAspectRatio, "remoteAudioState": "\(state.remoteAudioState)", "isScreenCapture": state.isScreenCapture, "participants": state.participants.map { $0._asPeer().displayTitle }, "conferenceReference": state.conferenceReference.map { "\($0)" } ?? NSNull()]
}

private func relayDebugText(_ view: NSView) -> String? {
    if let text = view as? TextView, let string = text.textLayout?.attributedString.string {
        return string
    }
    if let text = view as? NSTextField {
        return text.stringValue
    }
    if let button = view as? NSButton {
        return button.title
    }
    return nil
}

private func relayDebugFind(_ view: NSView, _ text: String, _ found: inout [NSView]) {
    if !view.isHidden, let string = relayDebugText(view), string.lowercased() == text.lowercased() {
        found.append(view)
    }
    for subview in view.subviews where !subview.isHidden {
        relayDebugFind(subview, text, &found)
    }
}

extension AppDelegate {
    private var relayDebugShared: SharedAccountContext? {
        return self.contextValue?.context.sharedContext
    }

    func installRelayCallDebugRemote() {
        RelayDebugRemote.register("add-account", { [weak self] _, completion in
            guard let shared = self?.sharedApplicationContextValue?.sharedContext else {
                completion(false, "no shared context", [:])
                return
            }
            shared.beginNewAuth(testingEnvironment: false)
            completion(true, nil, [:])
        })
        RelayDebugRemote.register("accounts", { [weak self] _, completion in
            guard let shared = self?.sharedApplicationContextValue?.sharedContext else {
                completion(false, "no shared context", [:])
                return
            }
            _ = (shared.activeAccounts |> take(1) |> deliverOnMainQueue).start(next: { value in
                let accounts = value.accounts.map { id, account, _ -> [String: Any] in
                    return ["id": "\(id.int64)", "peerId": "\(account.peerId.toInt64())", "primary": value.primary?.id == id]
                }
                completion(true, nil, ["accounts": accounts, "hasCurrentAuth": value.currentAuth != nil])
            })
        })
        RelayDebugRemote.register("logout", { [weak self] command, completion in
            guard let shared = self?.sharedApplicationContextValue?.sharedContext, let id = command["id"].flatMap(Int64.init) else {
                completion(false, "no shared context or id", [:])
                return
            }
            _ = logoutFromAccount(id: AccountRecordId(rawValue: id), accountManager: shared.accountManager, alreadyLoggedOutRemotely: false).start()
            completion(true, nil, [:])
        })
        RelayDebugRemote.register("switch-account", { [weak self] command, completion in
            guard let shared = self?.sharedApplicationContextValue?.sharedContext, let id = command["id"].flatMap(Int64.init) else {
                completion(false, "no shared context or id", [:])
                return
            }
            shared.switchToAccount(id: AccountRecordId(rawValue: id), action: nil)
            completion(true, nil, [:])
        })
        RelayDebugRemote.register("screen-list", { _, completion in
            let screens = DesktopCaptureSourceManagerMac(_s: ()).list()
            let windows = DesktopCaptureSourceManagerMac(_w: ()).list()
            completion(true, nil, ["screens": screens.map { $0.title() }, "windows": windows.count])
        })
        RelayDebugRemote.register("screen-picker", { [weak self] _, completion in
            guard let shared = self?.relayDebugShared else {
                completion(false, "no account", [:])
                return
            }
            let window = presentDesktopCapturerWindow(mode: .screencast, select: { source, _ in
                NSLog("relay debug picker selected \(source.title())")
            }, devices: CallsCoreHooks.shared.devicesContext(shared), microIsOff: false)
            completion(window != nil, nil, ["windows": relayDebugWindows()])
        })
        RelayDebugRemote.register("windows", { _, completion in
            completion(true, nil, ["windows": relayDebugWindows()])
        })
        RelayDebugRemote.register("click", { command, completion in
            guard let text = command["text"] ?? command["value"] else {
                completion(false, "no text", [:])
                return
            }
            let windowFilter = command["window"]?.lowercased()
            var matches: [NSView] = []
            for window in NSApp.windows where window.isVisible {
                if let windowFilter, !String(describing: type(of: window)).lowercased().contains(windowFilter), !window.title.lowercased().contains(windowFilter) {
                    continue
                }
                if let root = window.contentView?.superview ?? window.contentView {
                    relayDebugFind(root, text, &matches)
                }
            }
            let index = Int(command["index"] ?? "0") ?? 0
            guard index < matches.count else {
                completion(false, "no visible view with text \(text)", ["matches": matches.count, "windows": relayDebugWindows()])
                return
            }
            let event: ControlEvent
            switch command["event"]?.lowercased() {
            case "up"?:
                event = .Up
            case "down"?:
                event = .Down
            case "single"?:
                event = .SingleClick
            default:
                event = .Click
            }
            var current: NSView? = matches[index]
            if command["row"] == "1" {
                while let view = current {
                    if let row = view as? TableRowView, let item = row.item as? GeneralRowItem {
                        item.action()
                        completion(true, nil, ["row": String(describing: type(of: item)), "matches": matches.count])
                        return
                    }
                    current = view.superview
                }
                current = matches[index]
            }
            while let view = current {
                if let control = view as? Control, control.userInteractionEnabled {
                    control.send(event: event)
                    completion(true, nil, ["control": String(describing: type(of: control)), "matches": matches.count, "window": String(describing: type(of: control.window))])
                    return
                }
                if let button = view as? NSButton {
                    button.performClick(nil)
                    completion(true, nil, ["control": String(describing: type(of: button)), "matches": matches.count])
                    return
                }
                current = view.superview
            }
            completion(false, "no control around \(text)", ["matches": matches.count])
        })
        RelayDebugRemote.register("call", { [weak self] command, completion in
            guard let context = self?.contextValue?.context, let query = command["user"] ?? command["value"] else {
                completion(false, "no account or user", [:])
                return
            }
            relayDebugFindPeer(context, query) { peerId, title, candidates in
                guard let peerId else {
                    completion(false, "no chat matches \(query)", ["candidates": candidates])
                    return
                }
                let isVideo = relayDebugFlag(command["video"]) ?? false
                let _ = (phoneCall(context: context, peerId: peerId, isVideo: isVideo) |> deliverOnMainQueue).start(next: { result in
                    applyUIPCallResult(context, result)
                    let kind: String
                    switch result {
                    case .success:
                        kind = "success"
                    case .samePeer:
                        kind = "samePeer"
                    case .fail:
                        kind = "fail"
                    }
                    completion(true, nil, ["peerId": "\(peerId.toInt64())", "title": title, "video": isVideo, "result": kind])
                })
            }
        })
        RelayDebugRemote.register("call-state", { [weak self] _, completion in
            guard let shared = self?.relayDebugShared else {
                completion(false, "no account", [:])
                return
            }
            var extra: [String: Any] = MainActor.assumeIsolated {
                RelayCallDebug.info(peerCall: shared.p2pCall, groupCall: shared.getCrossAccountGroupCall()?.call)
            }
            extra["hasActiveCall"] = shared.hasActiveCall
            extra["permissions"] = ["microphone": AVCaptureDevice.authorizationStatus(for: .audio).rawValue, "camera": AVCaptureDevice.authorizationStatus(for: .video).rawValue, "screen": CGPreflightScreenCaptureAccess()]
            extra["windows"] = relayDebugWindows()
            if let screen = shared.peerCall, let window = screen.window {
                extra["peerCallScreen"] = ["frame": NSStringFromRect(window.frame), "visible": window.isVisible, "key": window.isKeyWindow]
            }
            if let session = shared.p2pCall {
                var info: [String: Any] = ["peerId": "\(session.peerId.toInt64())", "peer": session.peer?.displayTitle ?? "", "isOutgoing": session.isOutgoing, "isVideo": session.isVideo]
                _ = (session.state |> take(1)).start(next: { state in
                    info["state"] = relayDebugCallState(state)
                })
                _ = (session.canBeRemoved |> take(1)).start(next: { value in
                    info["canBeRemoved"] = value
                })
                extra["telegramPeerCall"] = info
            }
            guard let group = shared.getCrossAccountGroupCall() else {
                completion(true, nil, extra)
                return
            }
            let call = group.call
            extra["groupWindow"] = ["frame": NSStringFromRect(group.window.window.frame), "visible": group.window.window.isVisible, "key": group.window.window.isKeyWindow, "title": group.window.window.title]
            _ = (combineLatest(queue: .mainQueue(), call.state, call.members, call.invitedPeers, call.summaryState) |> take(1)).start(next: { state, members, invited, summary in
                var info: [String: Any] = ["peerId": call.peerId.map { "\($0.toInt64())" } ?? NSNull(), "peer": call.peer?.displayTitle ?? NSNull()]
                info["networkState"] = "\(state.networkState)"
                info["muted"] = state.muteState != nil
                info["title"] = state.title ?? NSNull()
                info["canManageCall"] = state.canManageCall
                info["sources"] = ["video": state.sources.video != nil, "screencast": state.sources.screencast != nil]
                info["members"] = (members?.participants ?? []).map { participant -> [String: Any] in
                    let peerId = participant.peer?.id
                    return ["peer": participant.peer?._asPeer().displayTitle ?? NSNull(), "peerId": peerId.map { "\($0.toInt64())" } ?? NSNull(), "muted": participant.muteState != nil, "video": participant.videoDescription?.endpointId ?? NSNull(), "presentation": participant.presentationDescription?.endpointId ?? NSNull(), "speaking": peerId.map { members?.speakingParticipants.contains($0) ?? false } ?? false, "activity": participant.activityTimestamp ?? NSNull()]
                }
                info["totalCount"] = members?.totalCount ?? 0
                info["invited"] = invited.map { "\($0.id.toInt64()) \($0.state)" }
                info["summaryParticipantCount"] = summary?.participantCount ?? 0
                extra["telegramGroupCall"] = info
                completion(true, nil, extra)
            })
        })
        RelayDebugRemote.register("call-audio", { _, completion in
            DispatchQueue.global(qos: .userInitiated).async {
                let info = RelayCallDebug.audioInfo()
                DispatchQueue.main.async {
                    completion(true, nil, info)
                }
            }
        })
        RelayDebugRemote.register("call-mic-processing", { [weak self] command, completion in
            let enabled = relayDebugFlag(command["value"]) ?? true
            let result = MainActor.assumeIsolated {
                RelayCallDebug.setMicrophoneProcessing(enabled, peerCall: self?.relayDebugShared?.p2pCall)
            }
            completion(true, nil, ["result": result])
        })
        RelayDebugRemote.register("call-accept", { [weak self] _, completion in
            guard let session = self?.relayDebugShared?.p2pCall else {
                completion(false, "no call", [:])
                return
            }
            session.acceptCallSession()
            completion(true, nil, [:])
        })
        let hangup: RelayDebugRemote.Handler = { [weak self] command, completion in
            guard let shared = self?.relayDebugShared else {
                completion(false, "no account", [:])
                return
            }
            if let session = shared.p2pCall {
                session.setToRemovableState()
                _ = session.hangUpCurrentCall().start()
                completion(true, nil, ["kind": "peer"])
            } else if let group = shared.getCrossAccountGroupCall() {
                if relayDebugFlag(command["end"]) == true {
                    _ = shared.endGroupCall(terminate: true).start()
                } else {
                    group.leave()
                }
                completion(true, nil, ["kind": "group"])
            } else {
                completion(false, "no call", [:])
            }
        }
        RelayDebugRemote.register("call-decline", hangup)
        RelayDebugRemote.register("call-hangup", hangup)
        RelayDebugRemote.register("call-mute", { [weak self] command, completion in
            guard let shared = self?.relayDebugShared else {
                completion(false, "no account", [:])
                return
            }
            let wanted = relayDebugFlag(command["value"])
            if let session = shared.p2pCall {
                _ = (session.state |> take(1) |> deliverOnMainQueue).start(next: { state in
                    if wanted == nil || wanted != state.isMuted {
                        session.toggleMute()
                    }
                    completion(true, nil, ["wasMuted": state.isMuted])
                })
            } else if let group = shared.getCrossAccountGroupCall() {
                _ = (group.call.isMuted |> take(1) |> deliverOnMainQueue).start(next: { isMuted in
                    let mute = wanted ?? !isMuted
                    group.call.setIsMuted(action: mute ? .muted(isPushToTalkActive: false) : .unmuted)
                    completion(true, nil, ["wasMuted": isMuted])
                })
            } else {
                completion(false, "no call", [:])
            }
        })
        RelayDebugRemote.register("call-video", { [weak self] command, completion in
            guard let shared = self?.relayDebugShared else {
                completion(false, "no account", [:])
                return
            }
            let on = relayDebugFlag(command["value"]) ?? true
            if let session = shared.p2pCall {
                if on {
                    session.requestVideo()
                } else {
                    session.disableVideo()
                }
                completion(true, nil, ["kind": "peer"])
            } else if let group = shared.getCrossAccountGroupCall() {
                if on {
                    let devices = CallsCoreHooks.shared.devicesContext(shared)
                    guard let device = devices.currentCameraId.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .video) else {
                        completion(false, "no camera", [:])
                        return
                    }
                    let source = CameraCaptureDevice(device)
                    group.call.requestVideo(deviceId: source.deviceIdKey(), source: source)
                    completion(true, nil, ["kind": "group", "camera": device.localizedName])
                } else {
                    group.call.disableVideo()
                    completion(true, nil, ["kind": "group"])
                }
            } else {
                completion(false, "no call", [:])
            }
        })
        RelayDebugRemote.register("call-screen", { [weak self] command, completion in
            guard let shared = self?.relayDebugShared else {
                completion(false, "no account", [:])
                return
            }
            let on = relayDebugFlag(command["value"]) ?? true
            if let session = shared.p2pCall {
                let result = session.toggleScreenCapture()
                completion(result == nil, result.map { "\($0)" }, ["kind": "peer", "screenCaptureAccess": CGPreflightScreenCaptureAccess(), "windows": relayDebugWindows()])
            } else if let group = shared.getCrossAccountGroupCall() {
                if on {
                    guard let source = DesktopCaptureSourceManagerMac(_s: ()).list().first else {
                        completion(false, "no display", [:])
                        return
                    }
                    group.call.requestScreencast(deviceId: source.deviceIdKey(), source: source)
                } else {
                    group.call.disableScreencast()
                }
                completion(true, nil, ["kind": "group", "screenCaptureAccess": CGPreflightScreenCaptureAccess()])
            } else {
                completion(false, "no call", [:])
            }
        })
        RelayDebugRemote.register("join-call", { [weak self] command, completion in
            guard let context = self?.contextValue?.context, let query = command["channel"] ?? command["value"] else {
                completion(false, "no account or channel", [:])
                return
            }
            relayDebugFindPeer(context, query) { peerId, title, candidates in
                guard let peerId else {
                    completion(false, "no chat matches \(query)", ["candidates": candidates])
                    return
                }
                relayDebugLastPeerId = peerId
                navigateToChat(navigation: context.bindings.rootNavigation(), context: context, chatLocation: .peer(peerId))
                var attempts = 0
                func attempt() {
                    attempts += 1
                    if let controller = context.bindings.rootNavigation().controller as? ChatInterfaceController, controller.chatInteraction.peerId == peerId, let groupCall = controller.chatInteraction.presentation.groupCall {
                        controller.chatInteraction.joinGroupCall(groupCall.activeCall, groupCall.joinHash)
                        completion(true, nil, ["peerId": "\(peerId.toInt64())", "title": title, "panelParticipants": groupCall.data?.participantCount ?? -1, "panelTop": (groupCall.data?.topParticipants ?? []).map { $0.peer?._asPeer().displayTitle ?? "" }])
                    } else if attempts < 25 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: attempt)
                    } else {
                        completion(false, "the chat shows no join panel", ["peerId": "\(peerId.toInt64())", "title": title])
                    }
                }
                attempt()
            }
        })
        RelayDebugRemote.register("messages", { [weak self] command, completion in
            guard let context = self?.contextValue?.context, let peerId = relayDebugLastPeerId else {
                completion(false, "no account or opened chat", [:])
                return
            }
            let limit = Int(command["count"] ?? "6") ?? 6
            let _ = (context.account.postbox.transaction { transaction -> [[String: Any]] in
                var result: [[String: Any]] = []
                transaction.scanTopMessages(peerId: peerId, namespace: Namespaces.Message.Cloud, limit: limit, { message in
                    var item: [String: Any] = ["id": message.id.id, "text": message.text, "author": message.author?.displayTitle ?? "", "incoming": message.flags.contains(.Incoming), "timestamp": message.timestamp]
                    for media in message.media {
                        if let action = media as? TelegramMediaAction {
                            item["action"] = "\(action.action)"
                        } else {
                            item["media"] = String(describing: type(of: media))
                        }
                    }
                    result.append(item)
                    return true
                })
                return result
            } |> deliverOnMainQueue).start(next: { messages in
                completion(true, nil, ["messages": messages])
            })
        })
    }
}
#endif

#if DEBUG
private func relayDebugCollect(_ view: NSView, _ match: (NSView) -> Bool, _ found: inout [NSView]) {
    if view.isHidden {
        return
    }
    if match(view) {
        found.append(view)
    }
    for subview in view.subviews {
        relayDebugCollect(subview, match, &found)
    }
}

private func relayDebugVisibleViews(_ match: (NSView) -> Bool) -> [NSView] {
    var found: [NSView] = []
    for window in NSApp.windows where window.isVisible {
        if let root = window.contentView?.superview ?? window.contentView {
            relayDebugCollect(root, match, &found)
        }
    }
    return found
}

private func relayDebugDrawnLayers(_ layer: CALayer) -> Int {
    if layer.isHidden || layer.opacity <= 0.01 {
        return 0
    }
    var count = layer.contents != nil ? 1 : 0
    for sublayer in layer.sublayers ?? [] {
        count += relayDebugDrawnLayers(sublayer)
    }
    return count
}

private func relayDebugLayerInfo(_ layer: CALayer, depth: Int) -> [String: Any] {
    var info: [String: Any] = ["class": String(describing: type(of: layer)), "frame": NSStringFromRect(layer.frame), "hidden": layer.isHidden, "opacity": layer.opacity, "contents": layer.contents != nil]
    if depth < 4, let sublayers = layer.sublayers, !sublayers.isEmpty {
        info["sublayers"] = sublayers.map { relayDebugLayerInfo($0, depth: depth + 1) }
    }
    return info
}

private func relayDebugViewInfo(_ view: NSView, depth: Int) -> [String: Any] {
    var info: [String: Any] = ["class": String(describing: type(of: view)), "frame": NSStringFromRect(view.frame), "hidden": view.isHidden, "alpha": view.alphaValue]
    if let control = view as? Control {
        info["controlState"] = "\(control.controlState)"
    }
    if let player = view as? LottiePlayerView {
        info["playerState"] = "\(player.currentState)"
        info["hasAnimation"] = player.animation != nil
    }
    if let text = relayDebugText(view) {
        info["text"] = String(text.prefix(80))
    }
    if let layer = view.layer {
        info["drawnLayers"] = relayDebugDrawnLayers(layer)
        let own = (layer.sublayers ?? []).filter { sublayer in !view.subviews.contains(where: { $0.layer === sublayer }) }
        if !own.isEmpty {
            info["layers"] = own.map { relayDebugLayerInfo($0, depth: 1) }
        }
    }
    if depth < 5, !view.subviews.isEmpty {
        info["subviews"] = view.subviews.map { relayDebugViewInfo($0, depth: depth + 1) }
    }
    return info
}

private func relayDebugMatching(_ command: [String: String]) -> [NSView] {
    let className = command["class"]?.lowercased()
    let text = command["text"]?.lowercased()
    let contains = command["contains"] == "1"
    return relayDebugVisibleViews { view in
        if let className, !String(describing: type(of: view)).lowercased().contains(className) {
            return false
        }
        if let text {
            guard let string = relayDebugText(view)?.lowercased() else {
                return false
            }
            return contains ? string.contains(text) : string == text
        }
        return true
    }
}

extension AppDelegate {
    private var relayDebugChat: ChatController? {
        return self.contextValue?.context.bindings.rootNavigation().controller as? ChatController
    }

    func installRelayChatDebugRemote() {
        RelayDebugRemote.register("views", { command, completion in
            let views = relayDebugMatching(command)
            let limit = Int(command["count"] ?? "5") ?? 5
            completion(true, nil, ["matches": views.count, "views": views.prefix(limit).map { relayDebugViewInfo($0, depth: 3) }])
        })
        RelayDebugRemote.register("hover", { command, completion in
            let controls = relayDebugMatching(command).compactMap { $0 as? Control }
            let index = Int(command["index"] ?? "0") ?? 0
            guard index < controls.count else {
                completion(false, "no control", ["matches": controls.count])
                return
            }
            let control = controls[index]
            let before = relayDebugViewInfo(control, depth: 0)
            let state: ControlState
            switch command["state"]?.lowercased() {
            case "normal"?:
                state = .Normal
            case "highlight"?:
                state = .Highlight
            default:
                state = .Hover
            }
            control.controlState = state
            let wait = Double(command["wait"] ?? "1.0") ?? 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: {
                completion(true, nil, ["matches": controls.count, "class": String(describing: type(of: control)), "before": before, "after": relayDebugViewInfo(control, depth: 0)])
            })
        })
        RelayDebugRemote.register("press", { command, completion in
            let controls = relayDebugMatching(command).compactMap { $0 as? Control }
            let index = Int(command["index"] ?? "0") ?? 0
            guard index < controls.count else {
                completion(false, "no control", ["matches": controls.count])
                return
            }
            controls[index].send(event: .Click)
            completion(true, nil, ["matches": controls.count, "class": String(describing: type(of: controls[index]))])
        })
        RelayDebugRemote.register("close-menus", { _, completion in
            AppMenu.closeAll()
            completion(true, nil, [:])
        })
        RelayDebugRemote.register("rightclick", { command, completion in
            let views = relayDebugMatching(command)
            let index = Int(command["index"] ?? "0") ?? 0
            guard index < views.count else {
                completion(false, "no view", ["matches": views.count])
                return
            }
            var current: NSView? = views[index]
            while let view = current, !(view is TableRowView) {
                current = view.superview
            }
            guard let row = current as? TableRowView, let window = row.window else {
                completion(false, "no row around the view", ["matches": views.count])
                return
            }
            let target = views[index]
            let point = target.convert(NSMakePoint(target.bounds.midX, target.bounds.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                completion(false, "no event", [:])
                return
            }
            row.showContextMenu(event)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: {
                let titles = relayDebugVisibleViews { $0 is AppMenuRowView }.compactMap { (($0 as? AppMenuRowView)?.item as? AppMenuRowItem)?.item.title }
                completion(true, nil, ["row": String(describing: type(of: row)), "menu": titles, "windows": relayDebugWindows()])
            })
        })
        RelayDebugRemote.register("menu-item", { command, completion in
            guard let text = command["text"] ?? command["value"] else {
                completion(false, "no text", [:])
                return
            }
            let rows = relayDebugVisibleViews { $0 is AppMenuRowView }.compactMap { $0 as? AppMenuRowView }
            guard let row = rows.first(where: { ($0.item as? AppMenuRowItem)?.item.title.lowercased() == text.lowercased() }) else {
                completion(false, "no menu item \(text)", ["menu": rows.compactMap { ($0.item as? AppMenuRowItem)?.item.title }])
                return
            }
            row.invokeClick()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: {
                completion(true, nil, ["windows": relayDebugWindows()])
            })
        })
        RelayDebugRemote.register("chat-state", { [weak self] _, completion in
            guard let context = self?.contextValue?.context else {
                completion(false, "no account", [:])
                return
            }
            let navigation = context.bindings.rootNavigation()
            var extra: [String: Any] = ["controller": String(describing: type(of: navigation.controller))]
            if let chat = self?.relayDebugChat {
                let presentation = chat.chatInteraction.presentation
                switch chat.chatLocation {
                case let .peer(peerId):
                    extra["location"] = "peer \(peerId.toInt64())"
                case let .thread(data):
                    extra["location"] = "thread \(data.peerId.toInt64()) \(data.threadId) forum=\(data.isForumPost)"
                }
                extra["mode"] = "\(chat.mode)"
                extra["reply"] = presentation.interfaceState.replyMessageId.map { "\($0.messageId.id)" } ?? NSNull()
                extra["input"] = presentation.interfaceState.inputState.inputText
                extra["state"] = "\(presentation.state)"
                extra["firstResponder"] = chat.window?.firstResponder.map { String(describing: type(of: $0)) } ?? NSNull()
                var readMarks: [[String: Any]] = []
                chat.genericView.tableView.enumerateItems { item in
                    if let item = item as? ChatRowItem, let message = item.message {
                        readMarks.append(["id": message.id.id, "text": String(message.text.prefix(100)), "read": item.isRead, "incoming": message.flags.contains(.Incoming)])
                    }
                    return true
                }
                extra["readMarks"] = readMarks
            }
            completion(true, nil, extra)
        })
        RelayDebugRemote.register("compose", { [weak self] command, completion in
            guard let chat = self?.relayDebugChat, let text = command["text"] ?? command["value"] ?? (command["clear"] == "1" ? "" : nil) else {
                completion(false, "no chat or text", [:])
                return
            }
            if command["clear"] == "1" {
                chat.chatInteraction.setupReplyMessage(nil, nil)
                chat.chatInteraction.update({ $0.updatedInterfaceState({ $0.withUpdatedInputState(ChatTextInputState()) }) })
            }
            _ = chat.chatInteraction.appendText(text)
            if command["send"] == "1" {
                chat.chatInteraction.sendMessage(false, nil, nil)
            }
            completion(true, nil, ["input": chat.chatInteraction.presentation.interfaceState.inputState.inputText])
        })
        RelayDebugRemote.register("chat-messages", { [weak self] command, completion in
            guard let context = self?.contextValue?.context, let chat = self?.relayDebugChat else {
                completion(false, "no chat", [:])
                return
            }
            let location = chat.chatLocation
            let limit = Int(command["count"] ?? "8") ?? 8
            let _ = (context.account.postbox.transaction { transaction -> [[String: Any]] in
                var result: [[String: Any]] = []
                for namespace in [Namespaces.Message.Local, Namespaces.Message.Cloud] {
                    transaction.scanTopMessages(peerId: location.peerId, namespace: namespace, limit: limit, { message in
                        var item: [String: Any] = ["id": "\(namespace == Namespaces.Message.Local ? "local" : "cloud") \(message.id.id)", "text": String(message.text.prefix(60)), "threadId": message.threadId.map { "\($0)" } ?? NSNull(), "tags": message.tags.rawValue, "failed": message.flags.contains(.Failed), "unsent": message.flags.contains(.Unsent)]
                        if let reply = message.attributes.first(where: { $0 is ReplyMessageAttribute }) as? ReplyMessageAttribute {
                            item["replyTo"] = "\(reply.messageId.id) thread=\(reply.threadMessageId.map { "\($0.id)" } ?? "nil")"
                        }
                        if let replies = message.attributes.first(where: { $0 is ReplyThreadMessageAttribute }) as? ReplyThreadMessageAttribute {
                            item["replies"] = replies.count
                        }
                        result.append(item)
                        return true
                    })
                }
                return result
            } |> deliverOnMainQueue).start(next: { messages in
                completion(true, nil, ["location": "\(location)", "messages": messages])
            })
        })
    }
}
#endif
