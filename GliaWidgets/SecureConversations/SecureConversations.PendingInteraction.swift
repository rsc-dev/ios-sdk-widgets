import Foundation
import Combine

extension SecureConversations {
    final class PendingInteraction: ObservableObject {
        @Published private(set) var pendingStatus = false
        @Published private(set) var unreadMessageCount = 0
        @Published private(set) var hasPendingInteraction = false
        @Published private(set) var hasTransferredSecureConversation = false
        private let environment: Environment
        private(set) var pendingStatusCancellationToken: String?
        private(set) var unreadMessageCountCancellationToken: String?
        private var activeInteractor: Interactor?
        private var cancelBag = CancelBag()

        init(environment: Environment) throws {
            self.environment = environment
            let pendingStatusCancellationToken = environment.observePendingSecureConversationsStatus { [weak self] result in
                guard let self else { return }
                // At this point it is enough to know if there is a pending conversation,
                // so no need to handle error.
                pendingStatus = (try? result.get()) ?? false
            }

            guard pendingStatusCancellationToken != nil else {
                throw Error.subscriptionFailure(.pendingStatus)
            }

            self.pendingStatusCancellationToken = pendingStatusCancellationToken

            let unreadMessageCountCancellationToken = environment.observeSecureConversationsUnreadMessageCount { [weak self] result in
                guard let self else { return }
                // At this point it is enough to know if there is an unread message count,
                // so no need to handle error.
                unreadMessageCount = (try? result.get()) ?? 0
            }

            guard unreadMessageCountCancellationToken != nil else {
                throw Error.subscriptionFailure(.unreadMessageCount)
            }

            self.unreadMessageCountCancellationToken = unreadMessageCountCancellationToken

            let interactorStatePublisher = environment.interactorPublisher
                .flatMap { interactor -> AnyPublisher<InteractorState, Never> in
                    guard let interactor else {
                        return Just(.none).eraseToAnyPublisher()
                    }
                    return interactor.$state.eraseToAnyPublisher()
                }
            let currentEngagementPublisher = environment.interactorPublisher
                .flatMap { interactor -> AnyPublisher<CoreSdkClient.Engagement?, Never> in
                    guard let interactor else {
                        return Just(nil).eraseToAnyPublisher()
                    }
                    return interactor.$currentEngagement.eraseToAnyPublisher()
                }
            let hasOngoingOrEnqueueingEngagement = Publishers.CombineLatest(interactorStatePublisher, currentEngagementPublisher)
                .map { state, currentEngagement in
                    if case .engaged = currentEngagement?.status {
                        return true
                    } else {
                        return state.enqueueingEngagementKind != nil
                    }
                }

            currentEngagementPublisher
                .map { $0?.isTransferredSecureConversation ?? false }
                .assign(to: &$hasTransferredSecureConversation)

            $pendingStatus.combineLatest(
                $unreadMessageCount, $hasTransferredSecureConversation, hasOngoingOrEnqueueingEngagement
            )
            .map { hasPending, unreadCount, hasTransferredSecureConversation, hasOngoingOrEnqueueingEngagement in
                (hasPending || unreadCount > 0 || hasTransferredSecureConversation) && !hasOngoingOrEnqueueingEngagement
            }
            .assign(to: &$hasPendingInteraction)
        }

        deinit {
            if let unreadMessageCountCancellationToken {
                environment.unsubscribeFromUnreadCount(unreadMessageCountCancellationToken)
            }

            if let pendingStatusCancellationToken {
                environment.unsubscribeFromPendingStatus(pendingStatusCancellationToken)
            }
        }
    }
}

extension SecureConversations.PendingInteraction {
    struct Environment {
        var observePendingSecureConversationsStatus: CoreSdkClient.ObservePendingSecureConversationStatus
        var observeSecureConversationsUnreadMessageCount: CoreSdkClient.SubscribeForUnreadSCMessageCount
        var unsubscribeFromUnreadCount: CoreSdkClient.UnsubscribeFromUnreadCount
        var unsubscribeFromPendingStatus: CoreSdkClient.UnsubscribeFromPendingSCStatus
        var interactorPublisher: AnyPublisher<Interactor?, Never>
    }
}

extension SecureConversations.PendingInteraction {
    enum Error: Swift.Error {
        enum Subscription {
            case unreadMessageCount
            case pendingStatus
        }
        case subscriptionFailure(Subscription)
    }
}

extension SecureConversations.PendingInteraction.Environment {
    init(
        client: CoreSdkClient,
        interactorPublisher: AnyPublisher<Interactor?, Never>
    ) {
        self.observePendingSecureConversationsStatus = client.observePendingSecureConversationStatus
        self.observeSecureConversationsUnreadMessageCount = client.subscribeForUnreadSCMessageCount
        self.unsubscribeFromPendingStatus = client.unsubscribeFromPendingSecureConversationStatus
        self.unsubscribeFromUnreadCount = client.unsubscribeFromUnreadCount
        self.interactorPublisher = interactorPublisher
    }
}

#if DEBUG
extension SecureConversations.PendingInteraction.Environment {
    static let mock: Self = {
        let uuidGen = UUID.incrementing
        return Self(
            observePendingSecureConversationsStatus: { _ in uuidGen().uuidString },
            observeSecureConversationsUnreadMessageCount: { _ in uuidGen().uuidString },
            unsubscribeFromUnreadCount: { _ in },
            unsubscribeFromPendingStatus: { _ in },
            interactorPublisher: .mock(.mock())
        )
    }()
}

extension SecureConversations.PendingInteraction {
    static func mock(environment: Environment = .mock) throws -> Self {
        try .init(environment: environment)
    }
}
#endif
