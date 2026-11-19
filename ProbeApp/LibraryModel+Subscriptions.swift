import Foundation

extension LibraryModel {
    func downloadSubscription(url: URL, name: String, replacing profile: ProfileRecord? = nil) {
        if let profile { updateSubscriptions([profile]); return }
        guard !downloading else { return }
        stageIntent &+= 1
        downloading = true
        subscriptionUpdates = []
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.downloading = false; self.downloadTask = nil }
            do {
                let candidate = try await self.repository.fetchSubscriptionDownload(from: url)
                try Task.checkCancellation()
                let profile = try await self.repository.importSubscription(candidate, name: name, sourceURL: url)
                try await self.didSave(profile)
            } catch is CancellationError { self.message = "订阅下载已取消。" }
            catch { self.message = "订阅未导入：\(error.localizedDescription)" }
        }
    }

    func updateSubscriptions(_ profiles: [ProfileRecord], automatic: Bool = false) {
        let subscriptions = profiles.filter { $0.sourceURL != nil }
        guard !downloading, !busy, !subscriptions.isEmpty else { return }
        stageIntent &+= 1
        downloading = true
        automaticSubscriptionUpdate = automatic
        subscriptionUpdates = subscriptions.map { .init(id: $0.id, name: $0.displayName, status: .pending) }
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.downloading = false
                self.automaticSubscriptionUpdate = false
                self.downloadTask = nil
            }
            let results = await self.repository.updateSubscriptions(subscriptions, checkSync: { [weak self] id in
                guard let self else { throw CancellationError() }
                try await self.checkSubscriptionSync(id)
            }, progress: { [weak self] result in
                await self?.receiveSubscriptionUpdate(result)
            })
            self.subscriptionUpdates = results
            do { try await self.refreshProfiles() }
            catch { self.message = "订阅处理结束，但列表刷新失败：\(error.localizedDescription)"; return }
            let succeeded = results.filter { $0.status == .updated }.count
            let failed = results.filter { if case .failed = $0.status { return true }; return false }.count
            let cancelled = results.filter { $0.status == .cancelled }.count
            self.message = "订阅更新结束：成功 \(succeeded) 项，失败 \(failed) 项，取消 \(cancelled) 项。当前配置有变化时将自动重连。"
            self.scheduleSync()
        }
    }

    private func receiveSubscriptionUpdate(_ result: SubscriptionUpdateResult) {
        if let index = subscriptionUpdates.firstIndex(where: { $0.id == result.id }) { subscriptionUpdates[index] = result }
    }

    private func checkSubscriptionSync(_ id: String) async throws {
        try Task.checkCancellation()
        if automaticSubscriptionUpdate && !isForeground { throw CancellationError() }
        if syncEnabled && syncArmed { try await scan() }
        guard !hasBlockedSync(id) else { throw LibraryError.syncConflict }
    }

    func refreshSubscriptionsIfDue() {
        guard isForeground, loaded, !busy, !downloading, !syncBusy else { return }
        let now = Date()
        updateSubscriptions(profiles.filter { $0.subscription?.isDue(at: now) == true }, automatic: true)
    }

    func setSubscriptionInterval(_ seconds: TimeInterval?, profileID: String) async {
        await run {
            try await self.repository.setSubscriptionInterval(id: profileID, seconds: seconds)
            try await self.refreshProfiles()
        }
        refreshSubscriptionsIfDue()
    }

    func moveProfiles(from offsets: IndexSet, to destination: Int) async {
        var ordered = profiles.map(\.id)
        let moving = offsets.sorted().map { ordered[$0] }
        for index in offsets.sorted(by: >) { ordered.remove(at: index) }
        let insertion = destination - offsets.filter { $0 < destination }.count
        ordered.insert(contentsOf: moving, at: insertion)
        await run {
            try await self.repository.reorder(ids: ordered)
            try await self.refreshProfiles()
        }
    }

    func cancelDownload() { downloadTask?.cancel() }
}
