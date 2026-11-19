import Combine
import Foundation

@MainActor
final class ExitIPMonitor: ObservableObject {
    typealias Lookup = @MainActor () async throws -> ExitIP

    @Published private(set) var result: ExitIP?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var generation: UInt64 = 0
    private var query: Task<ExitIP, Error>?
    deinit { query?.cancel() }

    func refreshIfNeeded(using lookup: @escaping Lookup) async {
        guard result == nil, error == nil, !isLoading else { return }
        await refresh(using: lookup)
    }

    func refresh(using lookup: @escaping Lookup) async {
        generation &+= 1
        let request = generation
        query?.cancel()
        result = nil
        error = nil
        isLoading = true
        let task = Task {
            try Task.checkCancellation()
            return try await lookup()
        }
        query = task
        defer {
            if request == generation { query = nil; isLoading = false }
        }
        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard request == generation, !Task.isCancelled else { return }
            result = value
        } catch {
            guard request == generation, !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = "查询失败：\(error.localizedDescription)"
        }
    }

    func pause() {
        generation &+= 1
        query?.cancel()
        query = nil
        isLoading = false
    }

    func stop() {
        pause()
        result = nil
        error = nil
    }
}
