import CryptoKit
import Foundation

extension LibraryModel {
    private var enabledKey: String { "NativeProfiles.sync.enabled" }
    private var armedKey: String { "NativeProfiles.sync.started." + (syncDirectory.map(directoryID) ?? "none") }

    func setForeground(_ active: Bool, using probe: ProbeModel) {
        resourceRefreshProbe = probe
        isForeground = active
        foregroundTask?.cancel()
        foregroundTask = nil
        configureObservers()
        guard active else {
            changeTask?.cancel()
            if automaticSubscriptionUpdate { cancelDownload() }
            return
        }
        foregroundTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshForeground()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private func refreshForeground() async {
        do { try await refreshProfiles() } catch { message = error.localizedDescription }
        if syncEnabled && syncArmed { await synchronize(manual: false) }
        refreshSubscriptionsIfDue()
        if let probe = resourceRefreshProbe { await refreshProviderResources(using: probe) }
    }

    func configureObservers() {
        localObserver = nil
        remoteObserver = nil
        guard isForeground else { return }
        let callback: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleSync() }
        }
        localObserver = DirectoryObserver(url: repository.yamlDirectory, changed: callback)
        if let syncDirectory, syncEnabled {
            remoteObserver = DirectoryObserver(url: syncDirectory, changed: callback)
        }
    }

    func restoreSyncDirectory() async {
        syncEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        do {
            let bookmarks = bookmarks
            let access = try await Task.detached(priority: .utility) { try bookmarks.restoreAccess() }.value
            installDirectory(access)
            syncArmed = UserDefaults.standard.bool(forKey: armedKey)
        } catch DirectoryBookmarkError.missing { }
        catch { message = "同步目录授权需要更新：\(error.localizedDescription)" }
    }

    func chooseSyncDirectory(_ url: URL) async {
        guard !syncBusy, !downloading else { return }
        await run {
            let bookmarks = self.bookmarks
            let access = try await Task.detached(priority: .userInitiated) {
                let access = try ScopedDirectoryAccess(url: url)
                try bookmarks.save(url)
                return access
            }.value
            self.installDirectory(access)
            self.syncArmed = false
            UserDefaults.standard.set(false, forKey: self.armedKey)
            self.setSyncEnabled(true)
            self.message = "目录已选择。首次同步将检查 \(self.profiles.count) 个本地配置；请点击“开始首次同步”确认。"
        }
    }

    private func installDirectory(_ lease: ScopedDirectoryAccess) {
        guard syncDirectory?.standardizedFileURL != lease.url.standardizedFileURL else { return }
        remoteObserver = nil
        access = lease
        syncDirectory = lease.url
        engine = YAMLSyncEngine(
            localDirectory: repository.yamlDirectory,
            remoteDirectory: lease.url,
            stateDirectory: root.appendingPathComponent("SyncState", isDirectory: true).appendingPathComponent(directoryID(lease.url)),
            validate: { _ = try YAMLDocument.validate(data: $0) }
        )
        syncResults = []
        configureObservers()
    }

    func setSyncEnabled(_ enabled: Bool) {
        syncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        configureObservers()
        if enabled { scheduleSync() }
        else { changeTask?.cancel() }
    }

    func scheduleSync() {
        changeTask?.cancel()
        guard isForeground else { return }
        changeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard let self else { return }
            do { try await self.refreshProfiles() } catch { self.message = error.localizedDescription }
            if self.syncEnabled && self.syncArmed { await self.synchronize(manual: false) }
        }
    }

    func synchronize(manual: Bool = true) async {
        guard !syncBusy, !busy, syncEnabled else { return }
        if manual {
            syncArmed = true
            UserDefaults.standard.set(true, forKey: armedKey)
        }
        guard syncArmed else { return }
        do {
            try await scan()
            if manual {
                message = syncResults.contains { $0.status == .deletedLocally }
                    ? "同步目录中的删除已同步到配置列表；移除前的内容可在同步备份中恢复。"
                    : "目录扫描完成，请查看各文件状态。"
            }
        } catch { message = "同步未完成：\(error.localizedDescription)" }
    }

    func scan() async throws {
        guard let engine, let access else { throw LibraryError.noFolder }
        syncRequestCount += 1
        syncBusy = true
        defer {
            syncRequestCount -= 1
            syncBusy = syncRequestCount > 0
        }
        let report = try await engine.synchronize()
        withExtendedLifetime(access) { syncResults = report.files }
        try await applySyncRemovals(report.files)
    }

    func applySyncRemovals(_ results: [YAMLSyncFileResult]) async throws {
        let deleted = Set(results.filter { $0.status == .deletedLocally }.map(\.fileName))
        syncDeletedProfileIDs.formUnion(deleted)
        for id in deleted {
            selections.removeValue(forKey: id)
            revisions = revisions.filter { $0.value != id }
            try await resourceLinks.delete(profileID: id)
        }
        try await refreshProfiles()
        if !deleted.isEmpty { try await persistPreferences() }
    }

    func resolveRemoteDeletion(_ file: String, localHash: String, choice: YAMLConflictChoice) async {
        guard !syncBusy, let engine, let access else { return }
        syncRequestCount += 1
        syncBusy = true
        defer {
            syncRequestCount -= 1
            syncBusy = syncRequestCount > 0
        }
        do {
            let result = try await engine.resolveRemoteDeletion(file: file, choice: choice, expectedLocalHash: localHash)
            withExtendedLifetime(access) {
                syncResults.removeAll { $0.fileName == file }
                syncResults.append(result)
                syncResults.sort { $0.fileName < $1.fileName }
            }
            try await applySyncRemovals([result])
            message = choice == .local ? "本地版本已重新上传到同步目录。" : "已接受远端删除，本地版本已备份并移出配置列表。"
        } catch { message = "删除冲突处理失败，请重新扫描：\(error.localizedDescription)" }
    }

    func resolve(_ file: String, conflict: YAMLConflict, choice: YAMLConflictChoice) async {
        guard !syncBusy, let engine, let access else { return }
        syncRequestCount += 1
        syncBusy = true
        defer {
            syncRequestCount -= 1
            syncBusy = syncRequestCount > 0
        }
        do {
            let result = try await engine.resolve(file: file, choice: choice, expectedL: conflict.localHash, expectedR: conflict.remoteHash)
            withExtendedLifetime(access) {
                syncResults.removeAll { $0.fileName == file }
                syncResults.append(result)
                syncResults.sort { $0.fileName < $1.fileName }
            }
            try await refreshProfiles()
            message = "冲突已按所选版本处理。当前配置有变化时将自动重连。"
        } catch { message = "冲突处理失败，请重新扫描：\(error.localizedDescription)" }
    }

    func hasBlockedSync(_ id: String) -> Bool {
        guard let result = syncResults.first(where: { $0.fileName == id }) else { return false }
        switch result.status {
        case .conflict, .remoteDeletionConflict, .providerConflict, .waitingDownload, .failed: return true
        default: return false
        }
    }

    private func directoryID(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
