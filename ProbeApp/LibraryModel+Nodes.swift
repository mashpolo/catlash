import Foundation

struct LibraryNodeGroup: Identifiable {
    let name: String
    let type: String
    let members: [String]
    let selected: String?
    let testURL: String?
    var id: String { name }
    var canSelect: Bool { ["select", "selector"].contains(type.lowercased()) }
}

extension LibraryModel {
    var activeGlobalGroup: ProxySummary? {
        guard catalog?.mode.lowercased() == "global" else { return nil }
        return catalog?.proxies.first { $0.name == "GLOBAL" && $0.all != nil }
    }

    func proxyOverview(connected: Bool) -> String {
        if connected {
            if catalog?.mode.lowercased() == "direct" { return "DIRECT · 直连" }
            if let global = activeGlobalGroup {
                return [global.name, global.now].compactMap { $0 }.joined(separator: " · ")
            }
            if catalog == nil { return "正在读取…" }
        }
        let groups = nodeGroups(connected: connected)
        if groups.isEmpty { return selectedProfile == nil ? "选择配置后查看" : "暂无策略组" }
        return "\(groups.count) 个策略组"
    }

    func nodeGroups(connected: Bool) -> [LibraryNodeGroup] {
        if connected {
            let groups: [LibraryNodeGroup] = catalog?.proxies.compactMap {
                guard let members = $0.all else { return nil }
                return LibraryNodeGroup(name: $0.name, type: $0.type, members: members, selected: $0.now, testURL: $0.testURL)
            } ?? []
            guard let global = groups.first(where: { $0.name == "GLOBAL" }) else { return groups }
            // GLOBAL lists the running configuration's declared groups in order, alongside its nodes.
            var remaining = Dictionary(uniqueKeysWithValues: groups.map { ($0.name, $0) })
            var ordered: [LibraryNodeGroup] = []
            if catalog?.mode.lowercased() == "global" {
                ordered.append(global)
                remaining.removeValue(forKey: global.name)
            }
            ordered += global.members.compactMap { remaining.removeValue(forKey: $0) }
            ordered += groups.filter { remaining[$0.name] != nil }
            return ordered
        }
        let selected = selectedID.flatMap { selections[$0] } ?? [:]
        let overview = offlineOverviewProfileID == selectedID && offlineOverviewRevision == selectedProfile?.revisionSHA
            ? offlineOverview ?? selectedProfile?.overview : selectedProfile?.overview
        return overview?.proxyGroups.map {
            LibraryNodeGroup(name: $0.name, type: $0.type ?? "未知", members: $0.members, selected: selected[$0.name], testURL: nil)
        } ?? []
    }

    func nodeProtocol(_ node: String, connected: Bool) -> String? {
        if connected { return catalog?.proxies.first(where: { $0.name == node })?.type }
        if node == "DIRECT" { return "Direct" }
        if node == "REJECT" || node == "REJECT-DROP" { return "Reject" }
        let overview = offlineOverviewProfileID == selectedID && offlineOverviewRevision == selectedProfile?.revisionSHA
            ? offlineOverview ?? selectedProfile?.overview : selectedProfile?.overview
        guard let type = overview?.proxyTypes?[node], !type.isEmpty else { return nil }
        return type
    }

    @discardableResult
    func stageSelected(using probe: ProbeModel, forceRefresh: Bool = false) async -> Bool {
        await run {
            let intent = self.stageIntent
            _ = try await self.prepareSelectedConfiguration(using: probe, forceRefresh: forceRefresh, shouldContinue: { self.stageIntent == intent })
            self.message = "配置已准备，等待连接验证。"
        }
    }

    func prepareSelectedConfiguration(using probe: ProbeModel, forceRefresh: Bool = false, shouldContinue: @MainActor () -> Bool) async throws -> String {
        guard let profile = selectedProfile else { throw LibraryError.noProfile }
        let snapshotIntent = probe.beginSnapshotIntent()
        preparationMessage = "正在读取配置…"
        defer {
            if probe.isCurrentSnapshotIntent(snapshotIntent) { preparationMessage = "" }
            probe.finishSnapshotIntent(snapshotIntent)
        }
        missingResource = nil
        let overrides = dnsOverrides
        let source = try await currentProfileData(id: profile.id, revision: profile.revisionSHA)
        let (bytes, compatibleSource) = try await Task.detached(priority: .userInitiated) {
            (try overrides.applying(to: source), try overrides.canReuseSourceResources(source) ? source : nil)
        }.value
        guard shouldContinue(), dnsOverrides == overrides else { throw CancellationError() }
        let resourceBundleID = try await prepareSelectedResources(profile: profile, yaml: bytes, compatibleSource: compatibleSource, intent: stageIntent, using: probe, forceRefresh: forceRefresh)
        try Task.checkCancellation()
        try await requireCurrentProfile(id: profile.id, revision: profile.revisionSHA)
        guard shouldContinue(), dnsOverrides == overrides else { throw CancellationError() }
        let revision = try await probe.stageYAML(
            bytes, selections: selections[profile.id] ?? [:], resourceBundleID: resourceBundleID, profileID: profile.id,
            snapshotIntent: snapshotIntent,
            shouldCommit: { shouldContinue() && self.dnsOverrides == overrides && self.selectedID == profile.id && self.selectedProfile?.revisionSHA == profile.revisionSHA }
        )
        revisions[revision] = profile.id
        try await persistPreferences()
        try Task.checkCancellation()
        guard shouldContinue(), probe.isCurrentSnapshotIntent(snapshotIntent) else { throw CancellationError() }
        return revision
    }

    func refreshCatalog(using probe: ProbeModel) async {
        guard probe.isConnected else {
            clearDelayResults()
            catalogGeneration &+= 1
            catalog = nil
            activeRevision = nil
            requestedMode = nil
            modeError = nil
            await refreshOfflineCatalog(using: probe, generation: catalogGeneration)
            return
        }
        guard !modeSwitchRunning else { return }
        catalogGeneration &+= 1
        let generation = catalogGeneration
        do {
            let result = try await probe.control(.init(action: .catalog))
            guard generation == catalogGeneration, probe.isConnected else { return }
            if activeRevision != result.activeRevision { clearDelayResults() }
            catalog = result.catalog
            activeRevision = result.activeRevision
        } catch is CancellationError {
        } catch { if generation == catalogGeneration { message = "读取运行节点失败：\(error.localizedDescription)" } }
    }

    private func refreshOfflineCatalog(using probe: ProbeModel, generation: UInt64) async {
        offlineOverview = nil
        guard let profile = selectedProfile else { return }
        do {
            let overrides = dnsOverrides
            let source = try await currentProfileData(id: profile.id, revision: profile.revisionSHA)
            let bytes = try await Task.detached(priority: .userInitiated) { try overrides.applying(to: source) }.value
            let store = ResourceBundleStore(root: try probe.snapshotDirectory().appendingPathComponent("Resources"))
            for revision in [probe.pendingRevision, probe.successfulRevision].compactMap({ $0 }) {
                guard let configuration = try? await probe.runtimeConfiguration(revision: revision),
                      configuration.profileID == profile.id, let bundle = configuration.resources,
                      case let .mihomo(yaml, _) = configuration.outbound,
                      yaml.utf8.elementsEqual(bytes) || yaml.utf8.elementsEqual(source) else { continue }
                guard let overview = try? await Task.detached(priority: .userInitiated, operation: {
                    let providers = try store.entries(id: bundle, kind: .proxyProvider)
                    return try YAMLDocument.validate(data: bytes, providerData: Dictionary(uniqueKeysWithValues: providers.map { ($0.name, $0.data) }))
                }).value else { continue }
                guard generation == catalogGeneration, !probe.isConnected, dnsOverrides == overrides,
                      selectedID == profile.id, selectedProfile?.revisionSHA == profile.revisionSHA else { return }
                offlineOverviewProfileID = profile.id
                offlineOverviewRevision = profile.revisionSHA
                offlineOverview = overview
                return
            }
        } catch is CancellationError {
        } catch { if generation == catalogGeneration { message = "读取本地节点失败：\(error.localizedDescription)" } }
    }

    func setRoutingMode(_ mode: String, using probe: ProbeModel) async {
        guard probe.isConnected, modeSwitchRunning || catalog?.mode != mode else { return }
        requestedMode = mode
        modeError = nil
        guard !modeSwitchRunning else { return }
        modeSwitchRunning = true
        catalogGeneration &+= 1
        defer { modeSwitchRunning = false; requestedMode = nil }
        while let requested = requestedMode {
            do {
                let result = try await probe.control(.init(action: .setMode, mode: requested))
                guard let confirmed = result.catalog, confirmed.mode == requested else {
                    throw NSError(domain: "RoutingMode", code: 1, userInfo: [NSLocalizedDescriptionKey: "内核未确认所选模式。"])
                }
                if requestedMode != requested { continue }
                catalog = confirmed
                activeRevision = result.activeRevision
                return
            } catch is CancellationError {
                Task { await refreshCatalog(using: probe) }
                return
            } catch {
                if requestedMode != requested { continue }
                modeError = "切换失败：\(error.localizedDescription)"
                Task { await refreshCatalog(using: probe) }
                return
            }
        }
    }

    @discardableResult
    func selectNode(_ node: String, group: LibraryNodeGroup, using probe: ProbeModel) async -> String? {
        guard group.selected != node else { return nil }
        return await runWithError {
            let profileID: String
            if probe.isConnected {
                let result = try await probe.control(.init(action: .select, group: group.name, node: node))
                self.activeRevision = result.activeRevision
                await self.refreshCatalog(using: probe)
                guard let revision = result.activeRevision else {
                    self.message = "运行节点已切换；当前连接未关联本地配置，未保存选择。"
                    return
                }
                let configuration = try await probe.runtimeConfiguration(revision: revision)
                guard probe.isConnected, self.activeRevision == revision else { throw CancellationError() }
                guard let id = configuration.profileID ?? self.revisions[revision],
                      self.profiles.contains(where: { $0.id == id }), case .mihomo = configuration.outbound else {
                    self.message = "运行节点已切换；当前连接未关联本地配置，未保存选择。"
                    return
                }
                self.revisions[revision] = id
                profileID = id
            } else {
                guard let id = self.selectedID else { throw LibraryError.noProfile }
                profileID = id
            }
            self.selections[profileID, default: [:]][group.name] = node
            try await self.persistPreferences()
            if self.profiles.first(where: { $0.id == profileID })?.overview?.storeSelected == false {
                self.message = probe.isConnected ? "节点已切换，选择保留至本次应用退出。" : "下次连接将使用此节点，选择保留至本次应用退出。"
            } else {
                self.message = probe.isConnected ? "节点已切换，选择已保存到实际运行配置。" : "选择已保存，下次连接生效。"
            }
        }
    }

    func testDelay(_ node: String, groupName: String, using probe: ProbeModel) async {
        let group = nodeGroups(connected: probe.isConnected).first { $0.name == groupName }
        await testDelays([node], groupURL: group?.testURL, using: probe)
    }

    func testAllDelays(using probe: ProbeModel) async {
        let requests = nodeGroups(connected: probe.isConnected).flatMap { group in
            let settings = effectiveDelaySettings(groupURL: group.testURL)
            return group.members.map { ProxyDelayKey(node: $0, settings: settings) }
        }
        await testDelays(requests, using: probe)
    }

    func testDelays(_ nodes: [String], groupURL: String?, using probe: ProbeModel) async {
        let settings = effectiveDelaySettings(groupURL: groupURL)
        await testDelays(nodes.map { ProxyDelayKey(node: $0, settings: settings) }, using: probe)
    }

    private func testDelays(_ requests: [ProxyDelayKey], using probe: ProbeModel) async {
        guard !isTestingDelays, probe.isConnected, !requests.isEmpty else { return }
        do { for settings in Set(requests.map(\.settings)) { try settings.validate() } }
        catch { message = error.localizedDescription; return }
        delayGeneration &+= 1
        let generation = delayGeneration
        let sessionGeneration = probe.latencySessionGeneration
        let revision = probe.activeRuntimeRevision
        testingNodes = Set(requests)
        for key in testingNodes { delayResults.removeValue(forKey: key) }
        delayCompleted = 0
        delayTotal = testingNodes.count
        isTestingDelays = true
        delayTask = Task { [weak self, weak probe] in
            guard let probe else { return }
            await ProxyDelayBatch.run(nodes: requests, test: { request in
                return try await probe.measureDelay(node: request.node, settings: request.settings, generation: sessionGeneration, revision: revision)
            }, receive: { [weak self, weak probe] key, result in
                guard let self, let probe, self.delayGeneration == generation,
                      probe.isConnected, probe.latencySessionGeneration == sessionGeneration,
                      probe.activeRuntimeRevision == revision else { return }
                self.delayResults[key] = result
                self.testingNodes.remove(key)
                self.delayCompleted += 1
            })
            guard let self, self.delayGeneration == generation else { return }
            self.testingNodes.removeAll()
            self.isTestingDelays = false
            self.delayTask = nil
        }
        await delayTask?.value
    }

    func cancelDelay(using probe: ProbeModel) async {
        guard isTestingDelays else { return }
        delayGeneration &+= 1
        let generation = delayGeneration
        delayTask?.cancel()
        testingNodes.removeAll()
        defer { if generation == delayGeneration { isTestingDelays = false; delayTask = nil } }
        do { _ = try await probe.control(.init(action: .cancelTests)); message = "延迟测试已取消。" }
        catch { message = "取消测试失败：\(error.localizedDescription)" }
    }

    func clearDelayResults() {
        delayGeneration &+= 1
        delayTask?.cancel()
        delayTask = nil
        isTestingDelays = false
        testingNodes.removeAll()
        delayResults.removeAll()
    }

    private func effectiveDelaySettings(groupURL: String?) -> ProxyDelaySettings {
        var settings = delayPreferences.settings
        if let groupURL, !groupURL.isEmpty { settings.url = groupURL }
        return settings
    }

    func delayResult(_ node: String, groupURL: String?, connected: Bool = false) -> ProxyDelayResult? {
        if let result = delayResults[ProxyDelayKey(node: node, settings: effectiveDelaySettings(groupURL: groupURL))] { return result }
        guard connected, let value = catalog?.proxies.first(where: { $0.name == node })?.delay else { return nil }
        return value > 0 ? .measured(value) : .failed
    }

    func delayText(_ node: String, groupURL: String?) -> String? {
        delayResult(node, groupURL: groupURL)?.text
    }

    func isTestingNode(_ node: String, groupURL: String?) -> Bool {
        testingNodes.contains(ProxyDelayKey(node: node, settings: effectiveDelaySettings(groupURL: groupURL)))
    }

    func visibleNodes(_ members: [String], groupURL: String?, connected: Bool = false) -> [String] {
        var results: [String: ProxyDelayResult] = [:]
        for node in members { results[node] = delayResult(node, groupURL: groupURL, connected: connected) }
        return ProxyDelayPreferences.ordered(members, results: results, sort: delayPreferences.sort, hideFailures: delayPreferences.hideFailures)
    }

    @discardableResult
    func saveDelayPreferences(_ value: ProxyDelayPreferences) -> Bool {
        do {
            try value.save()
            if value.settings != delayPreferences.settings { delayResults.removeAll() }
            delayPreferences = value
            return true
        }
        catch { message = error.localizedDescription; return false }
    }
}
