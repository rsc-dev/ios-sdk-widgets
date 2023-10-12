import GliaCoreSDK
import UIKit

/// Engagement media type.
public enum EngagementKind: Equatable {
    /// No engagement
    case none
    /// Chat
    case chat
    /// Audio call
    case audioCall
    /// Video call
    case videoCall
    /// Secure conversations
    case messaging(SecureConversations.InitialScreen = .welcome)
}

extension SecureConversations {
    /// The initial screen seen by a visitor when starting a secure conversation.
    public enum InitialScreen: Equatable {
        /// Shows a screen that has welcome text, and allows to send messages and
        /// attachments. It also allows navigation to the chat transcript screen.
        case welcome
        /// Shows a screen with the chat transcript, which consists of the message
        /// history of the currently authenticated visitor. Also allows sending
        /// messages and attachments.
        case chatTranscript
    }
}

/// An event providing engagement state information.
public enum GliaEvent: Equatable {
    /// Session was started
    case started
    /// Engagement media type changed
    case engagementChanged(EngagementKind)
    /// Session has ended
    case ended
    /// Engagement window was minimized
    case minimized
    /// Engagement window was maximized
    case maximized
}

/// Used to provide `UIWindowScene` to the framework.
public protocol SceneProvider: AnyObject {
    @available(iOS 13.0, *)
    func windowScene() -> UIWindowScene?
}

/// Glia's engagement interface.
public class Glia {
    /// A singleton to access the Glia's interface.
    public static let sharedInstance = Glia(environment: .live)
    /// Current engagement media type.
    public var engagement: EngagementKind { return rootCoordinator?.engagementKind ?? .none }
    /// Used to monitor engagement state changes.
    public var onEvent: ((GliaEvent) -> Void)?

    var stringProviding: StringProviding?

    public lazy var callVisualizer = CallVisualizer(
        environment: .init(
            data: environment.data,
            uuid: environment.uuid,
            gcd: environment.gcd,
            imageViewCache: environment.imageViewCache,
            timerProviding: environment.timerProviding,
            uiApplication: environment.uiApplication,
            uiScreen: environment.uiScreen,
            uiDevice: environment.uiDevice,
            notificationCenter: environment.notificationCenter,
            requestVisitorCode: environment.coreSdk.requestVisitorCode,
            interactorProviding: { [weak self] in self?.interactor },
            callVisualizerPresenter: environment.callVisualizerPresenter,
            bundleManaging: environment.bundleManaging,
            screenShareHandler: environment.screenShareHandler,
            audioSession: environment.audioSession,
            date: environment.date,
            engagedOperator: { [weak self] in
                self?.environment.coreSdk.getCurrentEngagement()?.engagedOperator
            },
            uiConfig: { [weak self] in self?.uiConfig },
            assetsBuilder: { [weak self] in self?.assetsBuilder ?? .standard },
            getCurrentEngagement: environment.coreSdk.getCurrentEngagement,
            eventHandler: onEvent,
            orientationManager: environment.orientationManager,
            proximityManager: environment.proximityManager
        )
    )
    var rootCoordinator: EngagementCoordinator?
    var interactor: Interactor?
    var environment: Environment
    var messageRenderer: MessageRenderer? = .webRenderer
    var uiConfig: RemoteConfiguration?
    var assetsBuilder: RemoteConfiguration.AssetsBuilder = .standard

    private(set) var configuration: Configuration?

    init(environment: Environment) {
        self.environment = environment
    }

    /// Setup SDK using specific engagement configuration without starting the engagement.
    /// - Parameters:
    ///   - configuration: Engagement configuration.
    ///   - visitorContext: Visitor context.
    ///   - uiConfig: Remote UI configuration.
    ///   - assetsBuilder: Provides assets for remote configuration.
    ///   - completion: Optional completion handler that will be fired once configuration is complete.
    ///   Passing  `nil` will defer configuration. Passing closure will start configuration immediately.
    public func configure(
        with configuration: Configuration,
        uiConfig: RemoteConfiguration? = nil,
        assetsBuilder: RemoteConfiguration.AssetsBuilder = .standard,
        completion: (() -> Void)? = nil
    ) throws {
        guard environment.coreSdk.getCurrentEngagement() == nil else {
            throw GliaError.configuringDuringEngagementIsNotAllowed
        }
        self.uiConfig = uiConfig
        self.assetsBuilder = assetsBuilder
        self.configuration = configuration

        self.callVisualizer.delegate = { action in
            switch action {
            case .visitorCodeIsRequested:
                self.setupInteractor(configuration: configuration)
            }
        }

        // TODO: - Non-optional completion will be added in MOB-2784
        do {
            try environment.coreSDKConfigurator.configureWithConfiguration(configuration) { [weak self] in
                guard let self else { return }
                let getRemoteString = self.environment.coreSdk.localeProvider.getRemoteString
                self.stringProviding = .init(getRemoteString: getRemoteString)

                if let engagement = self.environment.coreSdk.getCurrentEngagement(),
                   engagement.source == .callVisualizer {
                    self.setupInteractor(configuration: configuration)
                }

                completion?()
            }
        } catch {
            self.configuration = nil
            debugPrint("💥 Core SDK configuration is not valid. Unexpected error='\(error)'.")
        }
    }

    /// Minimizes engagement view if ongoing engagement exists.
    /// Use this function for hiding the engagement view programmatically during ongoing engagement.
    /// If you do so, the operator bubble appears.
    public func minimize() {
        rootCoordinator?.minimize()
    }

    /// Maximizes engagement view if ongoing engagement exists.
    /// Throws error if ongoing engagement not exist.
    /// Use this function for resuming engagement view If bubble is hidden programmatically and you need to
    /// present engagement view.
    public func resume() throws {
        guard engagement != .none else { throw GliaError.engagementNotExist }
        rootCoordinator?.maximize()
    }

    /// This custom message renderer used for rendering AI custom cards.
    /// Glia Widgets contains implementation for HTML based custom cards. See MessegeRenderer.webRenderer
    ///
    /// - Parameter messageRenderer: Custom message renderer.
    ///
    public func setChatMessageRenderer(messageRenderer: MessageRenderer?) {
        self.messageRenderer = messageRenderer
    }

    /// Clear visitor session
    ///
    /// - Parameter completion: Completion handler.
    ///
    /// - Important: Note, that in case of ongoing engagement, `clearVisitorSession` must be called after ending engagement,
    /// because `GliaError.clearingVisitorSessionDuringEngagementIsNotAllowed` will occur otherwise.
    ///
    public func clearVisitorSession(_ completion: @escaping (Result<Void, Error>) -> Void) {
        guard environment.coreSdk.getCurrentEngagement() == nil else {
            completion(.failure(GliaError.clearingVisitorSessionDuringEngagementIsNotAllowed))
            return
        }
        environment.coreSdk.clearSession()
        completion(.success(()))
    }

    /// Fetch current Visitor's information.
    ///
    /// The information provided by this endpoint is available to all the Operators observing or interacting with the
    /// Visitor. This means that this endpoint can be used to provide additional context about the Visitor to the
    /// Operators.
    ///
    /// - Parameters:
    ///   - completion: A callback that will return the update result or `SalemoveError`
    ///
    /// If the request is unsuccessful for any reason then the completion will have an Error.
    /// The Error may have one of the following causes:
    ///
    /// - `GliaCoreSDK.GeneralError.internalError`
    /// - `GliaCoreSDK.GeneralError.networkError`
    /// - `GliaCoreSDK.ConfigurationError.invalidSite`
    /// - `GliaCoreSDK.ConfigurationError.invalidEnvironment`
    /// - `GliaError.sdkIsNotConfigured`
    ///
    /// - Important: Note, that in case of engagement has not been started yet, `configure(with:queueID:visitorContext:)` must be called initially prior to this method,
    /// because `GliaError.sdkIsNotConfigured` will occur otherwise.
    ///
    public func fetchVisitorInfo(completion: @escaping (Result<GliaCore.VisitorInfo, Error>) -> Void) {
        guard interactor != nil else {
            completion(.failure(GliaError.sdkIsNotConfigured))
            return
        }
        environment.coreSdk.fetchVisitorInfo(completion)
    }

    /// Update current Visitor's information.
    ///
    /// The information provided by this endpoint is available to all the Operators observing or interacting with the
    /// Visitor. This means that this endpoint can be used to provide additional context about the Visitor to the
    /// Operators.
    ///
    /// In a similar manner custom attributes can be also be used to provide additional context. For example, if your
    /// site separates paying users from free users, then setting a custom attribute of 'user_type' with a value of
    /// either 'free' or 'paying' depending on the Visitor's account can help Operators prioritize different Visitors.
    ///
    /// - Parameters:
    ///   - info: The information for updating Visitor
    ///   - completion: A callback that will return the update result or `SalemoveError`
    ///
    /// If the request is unsuccessful for any reason then the completion will have an Error.
    /// The Error may have one of the following causes:
    ///
    /// - `GliaCoreSDK.GeneralError.internalError`
    /// - `GliaCoreSDK.GeneralError.networkError`
    /// - `GliaCoreSDK.ConfigurationError.invalidSite`
    /// - `GliaCoreSDK.ConfigurationError.invalidEnvironment`
    /// - `GliaError.sdkIsNotConfigured`
    ///
    /// - Important: Note, that in case of engagement has not been started yet, `configure(with:queueID:visitorContext:)` must be called initially prior to this method,
    /// because `GliaError.sdkIsNotConfigured` will occur otherwise.
    ///
    public func updateVisitorInfo(
        _ info: VisitorInfoUpdate,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        guard interactor != nil else {
            completion(.failure(GliaError.sdkIsNotConfigured))
            return
        }
        environment.coreSdk.updateVisitorInfo(info, completion)
    }

    /// Ends active engagement if existing and closes Widgets SDK UI (includes bubble).
    public func endEngagement(_ completion: @escaping (Result<Void, Error>) -> Void) {
        defer {
            onEvent?(.ended)
            rootCoordinator = nil
        }

        guard interactor != nil else {
            completion(.failure(GliaError.sdkIsNotConfigured))
            return
        }

        interactor?.endSession(
            success: { completion(.success(())) },
            failure: { completion(.failure($0)) }
        )
    }

    /// List all Queues of the configured site.
    /// It is also possible to monitor Queues changes with [subscribeForUpdates](x-source-tag://subscribeForUpdates) method.
    /// If the request is unsuccessful for any reason then the completion will have an Error.
    /// - Parameters:
    ///   - completion: A callback that will return the Result struct with `Queue` list or `GliaCoreError`
    ///
    public func listQueues(_ completion: @escaping (Result<[Queue], Error>) -> Void) {
        guard interactor != nil else {
            completion(.failure(GliaError.sdkIsNotConfigured))
            return
        }

        environment.coreSdk.listQueues { queues, error in
            if let error {
                completion(.failure(error))
                return
            }

            if let queues {
                completion(.success(queues))
                return
            }

            completion(.failure(GliaError.internalError))
        }
    }
}

// MARK: - Internal

extension Glia {
    internal func startObservingInteractorEvents() {
        interactor?.addObserver(self) { [weak self] event in
            guard
                let engagement = self?.environment.coreSdk.getCurrentEngagement(),
                engagement.source == .callVisualizer
            else { return }

            switch event {
            case .screenShareOffer(answer: let answer):
                self?.environment.coreSdk.requestEngagedOperator { operators, _ in
                    self?.callVisualizer.offerScreenShare(
                        from: operators ?? [],
                        configuration: Theme().alertConfiguration.screenShareOffer,
                        accepted: { answer(true) },
                        declined: { answer(false) }
                    )
                }
            case let .upgradeOffer(offer, answer):
                self?.environment.coreSdk.requestEngagedOperator { operators, _ in
                    self?.callVisualizer.offerMediaUpgrade(
                        from: operators ?? [],
                        offer: offer,
                        answer: answer,
                        accepted: {
                            answer(true, nil)
                            self?.callVisualizer.handleAcceptedUpgrade()
                        },
                        declined: { answer(false, nil) }
                    )
                }
            case let .videoStreamAdded(stream):
                self?.callVisualizer.addVideoStream(stream: stream)
            case let .stateChanged(state):
                if case .ended = state {
                    self?.callVisualizer.endSession()
                    self?.onEvent?(.ended)
                } else if case .engaged = state {
                    self?.callVisualizer.handleEngagementRequestAccepted()
                    self?.onEvent?(.started)
                }
            default:
                break
            }
        }
    }

    @discardableResult
    func setupInteractor(
        configuration: Configuration,
        queueIds: [String] = []
    ) -> Interactor {
        let interactor = Interactor(
            visitorContext: configuration.visitorContext,
            queueIds: queueIds,
            environment: .init(coreSdk: environment.coreSdk, gcd: environment.gcd)
        )

        interactor.state = environment.coreSdk
            .getCurrentEngagement()?.engagedOperator
            .map(InteractorState.engaged) ?? interactor.state

        environment.coreSDKConfigurator.configureWithInteractor(interactor)
        self.interactor = interactor

        startObservingInteractorEvents()
        return interactor
    }
}

#if DEBUG
extension Glia {
    /// Used for unit tests only
    var isConfigured: Bool {
        configuration != nil
    }
}
#endif
