import Foundation

struct RunningProviderCatalog {
    let entries: [RuntimeProviderSummary]
    let revision: String
    let sessionID: String
    let status: TunnelResourceStatus?

    init(_ response: TunnelControlResponse) throws {
        if let failure = response.error { throw RemoteResourceError.message(failure) }
        guard let entries = response.providers, let revision = response.activeRevision,
              let sessionID = response.inspectionSessionID else {
            throw RemoteResourceError.message("未能读取正在运行的资源。")
        }
        self.entries = entries
        self.revision = revision
        self.sessionID = sessionID
        self.status = response.resourceStatus
    }
}

enum RemoteResourceError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case let .message(text): return text }
    }
}

extension LibraryModel {
    func runningProviders(using probe: ProbeModel) async throws -> RunningProviderCatalog {
        try await RunningProviderCatalog(probe.control(.init(action: .providerCatalog)))
    }

    func updateRunningProviders(_ entries: [RuntimeProviderSummary], in catalog: RunningProviderCatalog,
                                using probe: ProbeModel) async throws -> RunningProviderCatalog {
        guard !resourceRefreshRunning else { throw RemoteResourceError.message("正在更新资源，请稍后再试。") }
        resourceRefreshRunning = true
        defer { resourceRefreshRunning = false }
        let generation = probe.connectionGeneration
        var latest = catalog
        for provider in entries where provider.canRefresh {
            try Task.checkCancellation()
            guard isForeground, probe.isConnected, probe.connectionGeneration == generation else { throw CancellationError() }
            let request = TunnelControlRequest(action: .refreshProvider, revision: catalog.revision,
                expectedSessionID: catalog.sessionID, providerKind: provider.kind, providerName: provider.name)
            let reply = try await probe.control(request)
            if let failure = reply.error { throw RemoteResourceError.message(failure) }
            // Read the operation result and its session together.
            repeat {
                try Task.checkCancellation()
                latest = try await runningProviders(using: probe)
                guard latest.revision == catalog.revision, latest.sessionID == catalog.sessionID else { throw CancellationError() }
                guard let status = latest.status else { throw RemoteResourceError.message("未能读取更新结果。") }
                guard status.operationID == request.id else { throw CancellationError() }
                if status.phase == .failed { throw RemoteResourceError.message(status.message) }
                if status.phase == .ready { break }
                try await Task.sleep(for: .seconds(1))
            } while true
        }
        return latest
    }

    func refreshProviderResources(using probe: ProbeModel) async {
        guard isForeground, probe.isConnected, !busy, !syncBusy, !isUpdatingConfiguration, !resourceRefreshRunning,
              !probe.isPreparingSnapshot, let revision = probe.successfulRevision,
              probe.pendingRevision == revision else { return }
        let intent = stageIntent
        let overrides = dnsOverrides
        let generation = probe.connectionGeneration
        var attemptedProfile: String?
        do {
            let configuration = try await probe.runtimeConfiguration(revision: revision)
            guard case let .mihomo(yaml, _) = configuration.outbound,
                  let profileID = configuration.profileID ?? revisions[revision],
                  let profile = profiles.first(where: { $0.id == profileID }), !hasBlockedSync(profileID) else { return }
            let source = try await repository.data(id: profileID)
            let interval = try await Task.detached(priority: .utility) {
                let effective = try overrides.applying(to: source)
                guard effective.elementsEqual(yaml.utf8) else { return nil as TimeInterval? }
                return try ResourceRefreshSchedule.interval(yaml: effective)
            }.value
            guard let interval, !Task.isCancelled, isForeground, probe.isConnected,
                  probe.connectionGeneration == generation, stageIntent == intent, dnsOverrides == overrides,
                  probe.pendingRevision == revision, probe.successfulRevision == revision, !busy, !syncBusy,
                  !resourceRefreshRunning, !isUpdatingConfiguration,
                  profiles.first(where: { $0.id == profileID })?.revisionSHA == profile.revisionSHA,
                  !hasBlockedSync(profileID),
                  try await resourceRefreshSchedule.claim(profileID: profileID, interval: interval) else { return }
            attemptedProfile = profileID
            let catalog = try await runningProviders(using: probe)
            guard catalog.revision == revision, isForeground, stageIntent == intent else { throw CancellationError() }
            _ = try await updateRunningProviders(catalog.entries, in: catalog, using: probe)
            await refreshCatalog(using: probe)
            try await resourceRefreshSchedule.finish(profileID: profileID, succeeded: true)
        } catch is CancellationError {
        } catch {
            if let attemptedProfile { try? await resourceRefreshSchedule.finish(profileID: attemptedProfile, succeeded: false) }
            if stageIntent == intent, isForeground, probe.connectionGeneration == generation {
                message = "资源自动刷新未完成：\(error.localizedDescription)"
            }
        }
    }
}
