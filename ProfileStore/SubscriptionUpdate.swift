import Foundation

public enum SubscriptionUpdateStatus: Equatable, Sendable {
    case pending, updating, updated, cancelled
    case failed(String)
}

public struct SubscriptionUpdateResult: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: SubscriptionUpdateStatus

    public init(id: String, name: String, status: SubscriptionUpdateStatus) {
        self.id = id
        self.name = name
        self.status = status
    }
}

extension ProfileRepository {
    public func updateSubscriptions(
        _ profiles: [ProfileRecord],
        checkSync: @escaping @Sendable (String) async throws -> Void = { _ in },
        progress: @escaping @Sendable (SubscriptionUpdateResult) async -> Void = { _ in }
    ) async -> [SubscriptionUpdateResult] {
        var results: [SubscriptionUpdateResult] = []
        for profile in profiles {
            let status: SubscriptionUpdateStatus
            do {
                try Task.checkCancellation()
                await progress(.init(id: profile.id, name: profile.displayName, status: .updating))
                try recordSubscriptionAttempt(id: profile.id, expectedRevision: profile.revisionSHA)
                try await checkSync(profile.id)
                let candidate = try await fetchSubscriptionDownload(id: profile.id, expectedRevision: profile.revisionSHA)
                try await checkSync(profile.id)
                try Task.checkCancellation()
                _ = try applySubscription(candidate, id: profile.id, expectedRevision: profile.revisionSHA)
                status = .updated
            } catch is CancellationError {
                status = .cancelled
            } catch {
                status = .failed(error.localizedDescription)
            }
            let result = SubscriptionUpdateResult(id: profile.id, name: profile.displayName, status: status)
            results.append(result)
            await progress(result)
        }
        return results
    }
}
