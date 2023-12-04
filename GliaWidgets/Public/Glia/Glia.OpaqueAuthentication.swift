extension Glia {
    /// Entry point for Visitor authentication.
    public struct Authentication {
        typealias Callback = (Result<Void, Error>) -> Void
        typealias GetVisitor = () -> Void

        var authenticateWithIdToken: (_ idToken: IdToken, _ accessToken: AccessToken?, _ callback: @escaping Callback) -> Void
        var deauthenticateWithCallback: (@escaping Callback) -> Void
        var isAuthenticatedClosure: () -> Bool
        var environment: Environment
    }
}

extension Glia.Authentication {
    /// Behavior for authentication and deauthentication.
    public enum Behavior {
        /// Restrict authentication and deauthentication during ongoing engagement.
        case forbiddenDuringEngagement
    }
}

extension Glia.Authentication.Behavior {
    init(with behavior: CoreSdkClient.AuthenticationBehavior) {
        switch behavior {
        case .forbiddenDuringEngagement:
            self = .forbiddenDuringEngagement
        @unknown default:
            self = .forbiddenDuringEngagement
        }
    }

    func toCoreSdk() -> CoreSdkClient.AuthenticationBehavior {
        switch self {
        case .forbiddenDuringEngagement:
            return .forbiddenDuringEngagement
        }
    }
}

extension Glia {
    public func authentication(with behavior: Glia.Authentication.Behavior) throws -> Authentication {
        let auth = try environment.coreSdk.authentication(behavior.toCoreSdk())

        // Reset navigation and UI back to initial state,
        // effectively removing bubble view (if there was one).
        let cleanup = { [weak self] in
            self?.rootCoordinator?.popCoordinator()
            self?.rootCoordinator?.end()
            self?.rootCoordinator = nil
        }

        return .init(
            authenticateWithIdToken: { idToken, accessToken, callback in
                auth.authenticate(
                    with: .init(rawValue: idToken),
                    externalAccessToken: accessToken.map { .init(rawValue: $0) }
                ) { result in
                    switch result {
                    case .success:
                        // Cleanup navigation and views.
                        cleanup()

                    case .failure:
                        break
                    }

                    callback(result.mapError(Glia.Authentication.Error.init) )
                }
            },
            deauthenticateWithCallback: { callback in
                auth.deauthenticate { result in
                    switch result {
                    case .success:
                        // Cleanup navigation and views.
                        cleanup()
                    case .failure:
                        break
                    }

                    callback(result.mapError(Glia.Authentication.Error.init))
                }
            },
            isAuthenticatedClosure: {
                auth.isAuthenticated
            },
            environment: .init(log: loggerPhase.logger)
        )
    }
}

extension Glia.Authentication {
    /// JWT token represented by `String`.
    public typealias IdToken = String
    /// Access token represented by `String`.
    public typealias AccessToken = String

    /// Authenticate visitor.
    /// - Parameters:
    /// - Parameter idToken: JWT token for visitor authentication.
    /// - Parameter accessToken: Access token for visitor authentication.
    /// - Parameter completion: Completion handler.
    public func authenticate(
        with idToken: IdToken,
        accessToken: AccessToken?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        self.authenticateWithIdToken(
            idToken,
            accessToken,
            completion
        )
    }

    /// Deauthenticate Visitor.
    /// - Parameter completion: Completion handler.
    public func deauthenticate(completion: @escaping (Result<Void, Error>) -> Void) {
        self.deauthenticateWithCallback(completion)
    }

    /// Initialize placeholder instance.
    /// Useful during unit testing.
    public var isAuthenticated: Bool {
        self.isAuthenticatedClosure()
    }
}

extension Glia.Authentication {
    /// Authentication error.
    public struct Error: Swift.Error {
        /// Reason of error.
        public var reason: String
    }
}

extension Glia.Authentication.Error {
    init(error: CoreSdkClient.SalemoveError) {
        self.reason = error.reason
    }
}

extension Glia.Authentication {
    struct Environment {
        var log: CoreSdkClient.Logger
    }
}
