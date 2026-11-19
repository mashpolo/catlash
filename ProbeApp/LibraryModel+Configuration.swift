import Foundation

struct ConfigurationUpdateRequest {
    let profileID: String
    let revision: String
    let connectionGeneration: UInt64
    let generation: UInt64
    let forceRefresh: Bool
}

extension LibraryModel {
    func requestConfigurationUpdate(forceRefresh: Bool = false) {
        guard loaded, let probe = resourceRefreshProbe, probe.isConnected, let profile = selectedProfile else { return }
        configurationUpdateGeneration &+= 1
        configurationUpdateTask?.cancel()
        pendingConfigurationUpdate = ConfigurationUpdateRequest(
            profileID: profile.id, revision: profile.revisionSHA,
            connectionGeneration: probe.connectionGeneration, generation: configurationUpdateGeneration,
            forceRefresh: forceRefresh
        )
        startConfigurationUpdate()
    }

    func startConfigurationUpdate() {
        guard !busy, !syncBusy, !downloading, let request = pendingConfigurationUpdate,
              let probe = resourceRefreshProbe else { return }
        pendingConfigurationUpdate = nil
        configurationUpdateTask = Task { [weak self, weak probe] in
            guard let self, let probe else { return }
            defer {
                if self.configurationUpdateGeneration == request.generation {
                    self.isUpdatingConfiguration = false
                    self.configurationUpdateTask = nil
                }
            }
            guard self.configurationUpdateIsCurrent(request, using: probe) else { return }
            self.isUpdatingConfiguration = true
            do {
                self.message = "正在准备配置，完成后自动重连…"
                let revision = try await self.prepareSelectedConfiguration(using: probe, forceRefresh: request.forceRefresh) {
                    self.configurationUpdateIsCurrent(request, using: probe)
                }
                guard self.configurationUpdateIsCurrent(request, using: probe) else { throw CancellationError() }
                self.clearDelayResults()
                let response = try await probe.applyConfiguration(revision: revision)
                guard self.configurationUpdateIsCurrent(request, using: probe) else { throw CancellationError() }
                self.activeRevision = response.activeRevision
                await self.refreshCatalog(using: probe)
                guard self.configurationUpdateIsCurrent(request, using: probe) else { throw CancellationError() }
                if let error = response.error {
                    self.message = "配置切换失败：\(error)\n" + (response.restoredPrevious == true ? "已恢复此前运行的配置。" : "请检查连接状态后重试。")
                } else {
                    self.message = "已自动重连，当前配置已生效。"
                }
            } catch is CancellationError {
            } catch {
                if self.configurationUpdateIsCurrent(request, using: probe) {
                    self.message = "配置更新未完成：\(error.localizedDescription)"
                }
            }
        }
    }

    private func configurationUpdateIsCurrent(_ request: ConfigurationUpdateRequest, using probe: ProbeModel) -> Bool {
        !Task.isCancelled && probe.isConnected && probe.connectionGeneration == request.connectionGeneration
            && configurationUpdateGeneration == request.generation && selectedID == request.profileID
            && selectedProfile?.revisionSHA == request.revision
    }

    func updateResources(using probe: ProbeModel) async {
        resourceRefreshProbe = probe
        if probe.isConnected {
            requestConfigurationUpdate(forceRefresh: true)
            await configurationUpdateTask?.value
        } else if await stageSelected(using: probe, forceRefresh: true) {
            message = "本地配置已准备好，连接时将加载远程资源。"
        }
    }
}
