import CryptoKit
import Foundation

struct MissingProfileResource: Identifiable {
    let profileID: String
    let revision: String
    let kind: ResourceKind
    let name: String
    let path: String
    var id: String { profileID + ":" + path }
}

extension LibraryModel {
    func refreshResourceLinks() async throws {
        guard let id = selectedID else { resourceFiles = []; return }
        let links = try await resourceLinks.list(profileID: id)
        if selectedID == id { resourceFiles = links }
    }

    func associateResource(_ url: URL, request: MissingProfileResource) async {
        await run {
            let bytes = try await Task.detached(priority: .userInitiated) { try Self.readImportedFile(url) }.value
            try await self.requireCurrentProfile(id: request.profileID, revision: request.revision)
            _ = try await self.resourceLinks.associate(
                profileID: request.profileID, path: request.path,
                displayName: url.lastPathComponent, data: bytes
            )
            self.stageIntent &+= 1
            self.missingResource = nil
            try await self.refreshResourceLinks()
            self.message = "资源副本已保存到本机。连接时将继续检查其余资源。"
            self.requestConfigurationUpdate()
        }
    }

    func removeResource(_ link: ProfileLinkedResource) async {
        await run {
            guard let id = self.selectedID else { throw LibraryError.noProfile }
            try await self.resourceLinks.remove(profileID: id, path: link.path)
            self.stageIntent &+= 1
            try await self.refreshResourceLinks()
            self.message = "已解除本地资源关联，下次准备配置时将重新检查。"
        }
    }

    func prepareSelectedResources(profile: ProfileRecord, yaml: Data, compatibleSource: Data? = nil, intent: UInt64, using probe: ProbeModel, forceRefresh: Bool = false) async throws -> String? {
        let localFiles = try await resourceLinks.localFiles(profileID: profile.id)
        if !forceRefresh, localFiles.isEmpty {
            let candidates = [yaml] + (compatibleSource.map { [$0] } ?? [])
            for candidate in candidates {
                if let cached = try await preparedResources(profile: profile, yaml: candidate, using: probe) {
                    preparationMessage = "使用已下载的配置资源。"
                    return cached
                }
            }
        }
        do {
            return try await probe.prepareResources(yaml: yaml, localFiles: localFiles, scope: .connection, forceRefresh: forceRefresh) { [weak self] progress in
                await self?.showResourceProgress(progress, profileID: profile.id, intent: intent)
            }
        } catch ProfileResourceError.missingLocalFile(let kind, let name, let path) {
            guard stageIntent == intent, selectedID == profile.id else { throw CancellationError() }
            missingResource = MissingProfileResource(profileID: profile.id, revision: profile.revisionSHA, kind: kind, name: name, path: path)
            throw LibraryError.resourceRequired
        }
    }

    private func preparedResources(profile: ProfileRecord, yaml: Data, using probe: ProbeModel) async throws -> String? {
        guard !(try await resourceLinks.hasLocalResourceHistory(profileID: profile.id)) else { return nil }
        let snapshots = SnapshotStore(root: try probe.snapshotDirectory())
        guard let revision = try? await Task.detached(operation: {
            try snapshots.lastSuccessfulRevision(profileID: profile.id, yaml: yaml)
        }).value else { return nil }
        // A freshly prepared update for this profile takes precedence over its
        // older successful resources. Another profile's pending revision does not.
        if let pending = probe.pendingRevision, pending != probe.successfulRevision, pending != revision,
           let configuration = try? await probe.runtimeConfiguration(revision: pending),
           configuration.profileID == profile.id { return nil }
        try Task.checkCancellation()
        guard let configuration = try? await probe.runtimeConfiguration(revision: revision),
              configuration.profileID == profile.id, let bundle = configuration.resources,
              case let .mihomo(source, _) = configuration.outbound, source.utf8.elementsEqual(yaml) else { return nil }
        let store = ResourceBundleStore(root: try probe.snapshotDirectory().appendingPathComponent("Resources"))
        return try? await Task.detached { try store.cachedResourcesUsingBundledGeodata(id: bundle) }.value
    }

    private func showResourceProgress(_ progress: ProfileResourceProgress, profileID: String, intent: UInt64) {
        guard selectedID == profileID, stageIntent == intent else { return }
        switch progress.phase {
        case .downloading: preparationMessage = "正在下载：\(progress.name)"
        case .cached: preparationMessage = "使用缓存：\(progress.name)"
        case .local: preparationMessage = "读取本地资源：\(progress.name)"
        case .deferred: preparationMessage = "连接时通过代理准备：\(progress.name)"
        }
    }

    func requireCurrentProfile(id: String, revision: String) async throws {
        _ = try await currentProfileData(id: id, revision: revision)
    }

    func currentProfileData(id: String, revision: String) async throws -> Data {
        guard selectedID == id else { throw CancellationError() }
        let bytes = try await repository.data(id: id)
        let hash = await Task.detached(priority: .utility) {
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }.value
        guard selectedID == id else { throw CancellationError() }
        guard hash == revision else { throw ProfileStoreError.staleRevision }
        return bytes
    }
}
