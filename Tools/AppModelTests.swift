import Foundation
import PacketBridge

// The system boundary is replaced; configuration storage and all LibraryModel
// operations are the production implementations compiled by test-app-model.py.
@MainActor final class ProbeModel {
    var isConnected = true
    var connectionGeneration: UInt64 = 1
    var latencySessionGeneration: UInt64 { connectionGeneration }
    var activeRuntimeRevision: String?
    var activeRuntimeProfileID: String?
    var pendingRevision: String?
    var successfulRevision: String?
    var isPreparingSnapshot = false
    var delayRequests: [ProxyDelayKey] = []
    var activeDelayRequests = 0
    var peakDelayRequests = 0
    var delayDuration: Duration = .milliseconds(15)
    var cancelTestRequests = 0
    var selectionRequests = 0
    var modeRequests = 0
    var applied: [String] = []
    var preparations: [Data] = []
    var providerCatalog: [RuntimeProviderSummary] = []
    var providerRequests: [TunnelControlRequest] = []
    var providerStatus = TunnelResourceStatus(phase: .ready, message: "")
    var providerSession = "active-session"
    var resourcePreparer: ProfileResourcePreparer?
    var failApplication = false
    var failPreparation = false
    var suspendNextPreparation = false
    var preparationContinuation: CheckedContinuation<Void, Never>?
    var suspendNextApplication = false
    var applicationContinuation: CheckedContinuation<Void, Never>?
    let root: URL
    private let commits = SnapshotCommitCoordinator()

    init(root: URL) { self.root = root.appendingPathComponent("Runtime") }

    func beginSnapshotIntent() -> SnapshotCommitCoordinator.Intent { commits.begin() }
    func finishSnapshotIntent(_ intent: SnapshotCommitCoordinator.Intent) { commits.finish(intent) }
    func isCurrentSnapshotIntent(_ intent: SnapshotCommitCoordinator.Intent) -> Bool { commits.isCurrent(intent) }
    func snapshotDirectory() throws -> URL { root }

    func prepareResources(yaml: Data, localFiles: [String: Data] = [:], scope: ProfileResourcePreparationScope = .connection, forceRefresh: Bool = false,
                          progress: (@Sendable (ProfileResourceProgress) async -> Void)? = nil) async throws -> String? {
        preparations.append(yaml)
        if suspendNextPreparation {
            suspendNextPreparation = false
            await withCheckedContinuation { preparationContinuation = $0 }
        }
        if failPreparation { throw AppModelFailure.failed("resource download failed") }
        if let resourcePreparer {
            return try await resourcePreparer.prepare(yaml: yaml, localFiles: localFiles, deferProxyDownloads: true, scope: scope, forceRefresh: forceRefresh, progress: progress)
        }
        return nil
    }

    func stageYAML(_ data: Data, selections: [String: String], resourceBundleID: String? = nil,
                   profileID: String? = nil, snapshotIntent: SnapshotCommitCoordinator.Intent? = nil,
                   shouldCommit: @MainActor () -> Bool = { true }) async throws -> String {
        try Task.checkCancellation()
        guard shouldCommit() else { throw CancellationError() }
        let store = SnapshotStore(root: root)
        let configuration = RuntimeConfiguration(outbound: .mihomo(yaml: String(decoding: data, as: UTF8.self), selections: selections),
                                                 resources: resourceBundleID, profileID: profileID)
        let prepared = try store.prepare(configuration: configuration)
        let intent = snapshotIntent ?? commits.begin()
        let revision = try commits.commit(prepared, to: store, intent: intent)
        pendingRevision = revision
        return revision
    }

    func applyConfiguration(revision: String) async throws -> TunnelControlResponse {
        applied.append(revision)
        if suspendNextApplication {
            suspendNextApplication = false
            await withCheckedContinuation { applicationContinuation = $0 }
        }
        if failApplication {
            return .init(id: UUID(), error: "core rejected configuration", activeRevision: activeRuntimeRevision, restoredPrevious: true)
        }
        activeRuntimeRevision = revision
        activeRuntimeProfileID = try await runtimeConfiguration(revision: revision).profileID
        successfulRevision = revision
        return .init(id: UUID(), activeRevision: revision)
    }

    func control(_ request: TunnelControlRequest) async throws -> TunnelControlResponse {
        if request.action == .providerCatalog {
            return .init(id: request.id, activeRevision: activeRuntimeRevision, resourceStatus: providerStatus, providers: providerCatalog, inspectionSessionID: providerSession)
        }
        if request.action == .refreshProvider {
            providerRequests.append(request)
            providerStatus = .init(phase: providerStatus.phase, message: providerStatus.message, operationID: request.id)
            return .init(id: request.id, activeRevision: activeRuntimeRevision, resourceStatus: .init(phase: .ready, message: ""), inspectionSessionID: "active-session")
        }
        if request.action == .setMode { modeRequests += 1 }
        if request.action == .select { selectionRequests += 1 }
        if request.action == .cancelTests { cancelTestRequests += 1 }
        return .init(id: request.id, activeRevision: activeRuntimeRevision)
    }

    func runtimeConfiguration(revision: String) async throws -> RuntimeConfiguration {
        try RuntimeConfiguration.decode(SnapshotStore(root: root).load(revision: revision))
    }

    func measureDelay(node: String, settings: ProxyDelaySettings, generation: UInt64, revision: String?) async throws -> Int64 {
        delayRequests.append(.init(node: node, settings: settings))
        activeDelayRequests += 1
        peakDelayRequests = max(peakDelayRequests, activeDelayRequests)
        defer { activeDelayRequests -= 1 }
        try await Task.sleep(for: delayDuration)
        return settings.url.contains("second") ? 22 : 11
    }
    func reloadSnapshots() {}

    func disconnect() {
        isConnected = false
        connectionGeneration &+= 1
        let intent = commits.begin()
        commits.finish(intent)
    }
}
final class DirectoryObserver { init(url: URL, changed: @escaping @Sendable () -> Void) {} }

actor AppModelDownloader: ProfileDownloader {
    func download(from url: URL, maximumBytes: Int) async throws -> Data {
        Data("mode: global\n".utf8)
    }
}

enum AppModelFailure: LocalizedError, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
    var errorDescription: String? { description }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AppModelFailure.failed(message) }
}

@main struct AppModelTests {
    @MainActor static func main() async {
        do {
            try await externallyRemovedSelectionDoesNotSwitchVPN()
            try await remoteDeletionReportsClearProfilesAndBlockConflicts()
            try await removedSelectionOnLaunchAndManualDeletionSemantics()
            try await homeProxyFollowsConfirmedMode()
            try await groupListUsesRunningConfigurationOrder()
            try await reselectingCurrentNodeKeepsExitRoute()
            try await ruleEditsUseRevisionChecksAndAutomaticApplication()
            try await allGroupDelaysUseEffectiveURLsAndOneBatch()
            try await allGroupDelaysCancelAndDiscardOldSessionResults()
            try await dnsPreferencesSurviveRelaunch()
            try await enabledDNSReusesLegacySuccessfulResourcesConservatively()
            try await dnsOverridesUseEffectiveConfigurationWithoutChangingSource()
            try await dnsOverridesKeepScheduledResourceRefreshWorking()
            try await changedDNSOverridesCancelOldPreparation()
            try await switchingBackReusesProfileResources()
            try await offlineProviderSelectionIsSessionOnlyWhenStorageDisabled()
            try await editingAnotherProfileKeepsSelection()
            try await currentEditsAndSelectionApplyAutomatically()
            try await offlineChangesDoNotConnect()
            try await rapidSelectionAppliesOnlyLatest()
            try await disconnectCancelsPreparation()
            try await disconnectIgnoresLateApplicationResponse()
            try await busyChangesCoalesce()
            try await failuresPreserveRunningConfiguration()
            try await batchSubscriptionsApplyCurrentOnlyOnce()
            try await removingLastLocalResourcePreventsBundleReuse()
            try await connectionReusesOnlyMatchingVerifiedResources()
            try await explicitOfflineResourceRefreshPreservesNewResources()
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor static func externallyRemovedSelectionDoesNotSwitchVPN() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = records[0]
        model.selections[removed.id] = ["group": "node"]
        model.revisions["removed-revision"] = removed.id
        _ = try await model.resourceLinks.associate(profileID: removed.id, path: "rules.yaml", displayName: "rules.yaml", data: Data("payload: []".utf8))
        try await model.persistPreferences()
        try FileManager.default.removeItem(at: model.repository.yamlDirectory.appendingPathComponent(removed.id))
        try await model.refreshProfiles()
        await settle(model)
        try require(model.selectedID == nil, "external deletion selected another profile")
        try require(probe.applied.isEmpty && probe.activeRuntimeProfileID == removed.id, "external deletion switched the running VPN")
        try require(!model.profiles.contains { $0.id == removed.id }, "deleted profile stayed in the list")
        try require(model.selections[removed.id] == nil && !model.revisions.values.contains(removed.id), "deleted profile preferences survived")
        let links = try await model.resourceLinks.list(profileID: removed.id)
        try require(links.isEmpty, "deleted profile resource associations survived")
        try await model.refreshProfiles()
        try require(model.selectedID == nil, "a later refresh silently selected a fallback")
        let restarted = LibraryModel(root: root)
        await restarted.load()
        try require(restarted.selectedID == nil, "relaunch selected a fallback after external deletion")
        await model.select(records[1].id)
        await settle(model)
        try require(probe.applied.count == 1 && probe.activeRuntimeProfileID == records[1].id, "explicit replacement selection did not apply")
        probe.disconnect()
        try FileManager.default.removeItem(at: model.repository.yamlDirectory.appendingPathComponent(records[1].id))
        try await model.refreshProfiles()
        try require(model.selectedID == nil && probe.applied.count == 1, "offline deletion selected or applied another profile")
        print("PASS: externally deleted selections clear preferences and resources without switching VPN, including refresh and relaunch")
    }

    @MainActor static func remoteDeletionReportsClearProfilesAndBlockConflicts() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("Remote")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let engine = YAMLSyncEngine(localDirectory: model.repository.yamlDirectory, remoteDirectory: remote,
                                   stateDirectory: root.appendingPathComponent("TestSyncState"), validate: { _ = try YAMLDocument.validate(data: $0) })
        _ = try await engine.synchronize()
        for record in records.prefix(2) {
            try FileManager.default.removeItem(at: remote.appendingPathComponent(record.id))
        }
        let edited = Data("mode: direct\n# local edit\n".utf8)
        try edited.write(to: model.repository.yamlDirectory.appendingPathComponent(records[1].id))
        let report = try await engine.synchronize()
        model.syncResults = report.files
        try await model.applySyncRemovals(report.files)
        await settle(model)
        try require(model.selectedID == nil && probe.applied.isEmpty, "sync deletion switched the running VPN")
        try require(model.syncDeletedProfileIDs.contains(records[0].id), "remote deletion notice was not retained")
        try require(model.hasBlockedSync(records[1].id), "remote deletion conflict did not block automatic overwrite")
        guard case let .remoteDeletionConflict(hash)? = report.files.first(where: { $0.fileName == records[1].id })?.status else {
            throw AppModelFailure.failed("expected a remote deletion conflict")
        }
        try require(model.profiles.contains { $0.id == records[1].id }, "conflicting local edit was removed")
        let resolved = try await engine.resolveRemoteDeletion(file: records[1].id, choice: .remote, expectedLocalHash: hash)
        model.syncResults.removeAll { $0.fileName == resolved.fileName }
        model.syncResults.append(resolved)
        try await model.applySyncRemovals([resolved])
        try require(!model.hasBlockedSync(records[1].id) && !model.profiles.contains { $0.id == records[1].id }, "accepted remote deletion did not clear the conflict and list entry")
        let restarted = LibraryModel(root: root)
        await restarted.load()
        try require(restarted.selectedID == nil && restarted.syncDeletedProfileIDs.contains(records[0].id), "sync deletion selection or notice was lost on relaunch")
        print("PASS: real sync deletion reports remove list entries, preserve the active VPN and expose deletion conflicts")
    }

    @MainActor static func removedSelectionOnLaunchAndManualDeletionSemantics() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Simulate the app exiting after the engine removed the file but before
        // the model consumed its report and persisted the empty selection.
        let source = try await model.repository.data(id: records[0].id)
        let file = model.repository.yamlDirectory.appendingPathComponent(records[0].id)
        try FileManager.default.removeItem(at: file)
        let restarted = LibraryModel(root: root)
        await restarted.load()
        try require(restarted.selectedID == nil, "startup silently replaced a missing saved selection")
        try source.write(to: file)
        try await model.refreshProfiles()
        await model.delete(records[0])
        await settle(model)
        try require(model.selectedID == model.profiles.first?.id && model.selectedID != nil, "manual deletion lost its existing fallback behavior")
        try require(probe.applied.count == 1, "manual deletion did not apply its explicit fallback")
        print("PASS: missing saved selections stay empty after startup; manual deletion retains its fallback behavior")
    }

    @MainActor static func reselectingCurrentNodeKeepsExitRoute() async throws {
        let (model, probe, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let group = LibraryNodeGroup(name: "Exit", type: "select", members: ["DIRECT", "REJECT"], selected: "DIRECT", testURL: nil)
        let choices = model.selections
        let previousMessage = model.message
        await model.selectNode("DIRECT", group: group, using: probe)
        try require(probe.selectionRequests == 0 && model.selections == choices && model.message == previousMessage,
                    "reselecting current member changed the route or saved a new choice")
        model.catalog = try JSONDecoder().decode(ProxyCatalog.self, from: Data(#"{"mode":"rule","proxies":[]}"#.utf8))
        await model.setRoutingMode("rule", using: probe)
        try require(probe.modeRequests == 0, "reselecting the active mode issued a route change")
        await model.selectNode("REJECT", group: group, using: probe)
        try require(probe.selectionRequests == 1, "a different member did not issue one selection request")
    }

    @MainActor static func ruleEditsUseRevisionChecksAndAutomaticApplication() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = "# preserve this header\nmode: rule\n"
        let source = prefix + "rules: ['MATCH,DIRECT']\n"
        let initial = await model.save(source, profile: records[0])
        try require(initial, "could not install rule fixture")
        await settle(model)
        probe.applied = []
        let draft = try await model.loadRules()
        let rule = try ProfileRule(raw: "DOMAIN,edited.example,REJECT")
        let saved = await model.saveRules([rule] + draft.document.rules, draft: draft)
        try require(saved, "rule draft did not save through the repository")
        await settle(model)
        try require(probe.applied.count == 1, "current rule edit did not automatically apply exactly once")
        let bytes = try await model.repository.data(id: records[0].id)
        try require(String(decoding: bytes, as: UTF8.self).hasPrefix(prefix), "rule save rewrote other configuration bytes")
        let reloaded = try await model.loadRules()
        try require(reloaded.document.rules.map(\.raw) == [rule.raw, "MATCH,DIRECT"], "rule edit did not persist")
        probe.disconnect()
        let external = Data((prefix + "rules: ['MATCH,REJECT']\n").utf8)
        _ = try await model.repository.update(id: records[0].id, data: external, expectedRevision: reloaded.profile.revisionSHA)
        let stale = await model.saveRules([rule], draft: reloaded)
        try require(!stale, "stale rule draft overwrote a concurrent edit")
        let after = try await model.repository.data(id: records[0].id)
        try require(after == external, "concurrent original YAML was overwritten")
        try await model.refreshProfiles()
        let offline = try await model.loadRules()
        let offlineSaved = await model.saveRules([try ProfileRule(raw: "MATCH,DIRECT")], draft: offline)
        try require(offlineSaved, "offline rule save failed")
        await settle(model)
        try require(!probe.isConnected && probe.applied.count == 1, "offline rule edit started or applied the VPN")
        print("PASS: rule edits preserve original YAML, apply online, save offline and reject stale revisions")
    }

    @MainActor static func homeProxyFollowsConfirmedMode() async throws {
        let (model, _, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let proxies = #"[{"name":"AI","type":"Selector","all":["MAIN"],"now":"MAIN"},{"name":"GLOBAL","type":"Selector","all":["Grass-BD","MAIN"],"now":"Grass-BD"}]"#
        func setMode(_ mode: String) throws {
            model.catalog = try JSONDecoder().decode(ProxyCatalog.self, from: Data("{\"mode\":\"\(mode)\",\"proxies\":\(proxies)}".utf8))
        }
        try setMode("global")
        try require(model.proxyOverview(connected: true) == "GLOBAL · Grass-BD", "home omitted the selected global member")
        try require(model.nodeGroups(connected: true).first?.name == "GLOBAL", "the global chooser starts on a different group")
        try setMode("rule")
        try require(model.proxyOverview(connected: true) == "2 个策略组", "rule mode presented the first group as a single exit")
        try setMode("direct")
        try require(model.proxyOverview(connected: true) == "DIRECT · 直连", "direct mode reported a proxy group")
        try require(model.proxyOverview(connected: false) != "DIRECT · 直连", "offline home used the previous session's mode")
        print("PASS: home proxy entry follows the confirmed routing mode and active global selection")
    }

    @MainActor static func groupListUsesRunningConfigurationOrder() async throws {
        let (model, _, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // The local selection intentionally disagrees with the live configuration.
        let yaml = "proxy-groups: [{name: AI, type: select, proxies: [DIRECT]}, {name: MAIN, type: select, proxies: [DIRECT]}]\nrules: ['MATCH,DIRECT']"
        let selected = try await model.repository.importData(data: Data(yaml.utf8), name: "Local.yaml")
        try await model.refreshProfiles()
        model.selectedID = selected.id
        let proxies = #"[{"name":"AI","type":"Selector","all":["DIRECT"]},{"name":"DIRECT","type":"Direct"},{"name":"Extra","type":"Selector","all":["REJECT"]},{"name":"GLOBAL","type":"Selector","all":["JP","MAIN","AI","DIRECT","REJECT"]},{"name":"MAIN","type":"Selector","all":["JP","DIRECT"]}]"#
        func setMode(_ mode: String) throws {
            model.catalog = try JSONDecoder().decode(ProxyCatalog.self, from: Data("{\"mode\":\"\(mode)\",\"proxies\":\(proxies)}".utf8))
        }
        try setMode("rule")
        let live = model.nodeGroups(connected: true)
        try require(live.map(\.name) == ["MAIN", "AI", "Extra", "GLOBAL"], "connected groups did not follow the session's declaration order")
        try require(live.first?.members == ["JP", "DIRECT"], "group ordering changed member order")
        try require(model.nodeGroups(connected: false).map(\.name) == ["AI", "MAIN"], "offline group order changed")
        try setMode("global")
        try require(model.nodeGroups(connected: true).map(\.name) == ["GLOBAL", "MAIN", "AI", "Extra"], "global mode did not pin GLOBAL above declared groups")
        print("PASS: group order uses the running configuration online and the selected file offline")
    }

    @MainActor static func delayCatalog() throws -> ProxyCatalog {
        try JSONDecoder().decode(ProxyCatalog.self, from: Data(#"""
        {"mode":"rule","proxies":[
          {"name":"First","type":"select","all":["shared","a","b","c","d"],"testURL":"https://first.invalid/check"},
          {"name":"Duplicate","type":"select","all":["shared","a"],"testURL":"https://first.invalid/check"},
          {"name":"Second","type":"select","all":["shared","e"],"testURL":"https://second.invalid/check"},
          {"name":"Default","type":"select","all":["shared"]}
        ]}
        """#.utf8))
    }

    @MainActor static func allGroupDelaysUseEffectiveURLsAndOneBatch() async throws {
        let (model, probe, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.delayPreferences.settings = .init(url: "https://first.invalid/check", timeoutMilliseconds: 1234)
        model.catalog = try delayCatalog()
        await model.testAllDelays(using: probe)
        try require(probe.delayRequests.count == 7 && Set(probe.delayRequests).count == 7, "all-group tests did not deduplicate node and effective URL")
        try require(probe.peakDelayRequests == 4, "all groups did not share the four-request limit")
        try require(probe.delayRequests.allSatisfy { $0.settings.timeoutMilliseconds == 1234 }, "all-group test lost timeout preference")
        try require(model.delayResult("shared", groupURL: "https://first.invalid/check") == .measured(11), "first group result used another URL")
        try require(model.delayResult("shared", groupURL: "https://second.invalid/check") == .measured(22), "second group result was merged with first URL")
        try require(model.delayResult("shared", groupURL: nil) == .measured(11), "default group did not inherit test preference")
        try require(model.delayCompleted == 7 && model.delayTotal == 7 && model.testingNodes.isEmpty && !model.isTestingDelays, "all-group progress did not finish")
        probe.delayRequests = []
        await model.testDelays(["shared", "shared"], groupURL: "https://second.invalid/check", using: probe)
        try require(probe.delayRequests.count == 1 && model.delayTotal == 1, "single-group compatibility or deduplication changed")
        print("PASS: all-group delays preserve each URL and share deduplication, four-request limit and progress")
    }

    @MainActor static func allGroupDelaysCancelAndDiscardOldSessionResults() async throws {
        let (model, probe, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.catalog = try delayCatalog()
        probe.delayDuration = .seconds(10)
        let task = Task { await model.testAllDelays(using: probe) }
        try await waitUntil("first delay wave") { probe.delayRequests.count == 4 }
        await model.cancelDelay(using: probe)
        await task.value
        try require(probe.delayRequests.count == 4 && probe.activeDelayRequests == 0 && probe.cancelTestRequests == 1, "cancel did not stop the batch and running requests")
        try require(model.delayResults.isEmpty && model.testingNodes.isEmpty && !model.isTestingDelays, "cancelled results or progress remained")
        probe.delayDuration = .milliseconds(30)
        probe.delayRequests = []
        let stale = Task { await model.testAllDelays(using: probe) }
        try await waitUntil("replacement delay wave") { !probe.delayRequests.isEmpty }
        probe.connectionGeneration += 1
        await stale.value
        try require(model.delayResults.isEmpty && model.delayCompleted == 0, "old session results contaminated the new session")
        probe.isConnected = false
        probe.delayRequests = []
        await model.testAllDelays(using: probe)
        try require(probe.delayRequests.isEmpty, "offline all-group testing launched requests")
        print("PASS: all-group cancellation stops queued work and rejects old session results")
    }

    @MainActor static func offlineProviderSelectionIsSessionOnlyWhenStorageDisabled() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.isConnected = false
        let yaml = """
        profile: {store-selected: false}
        proxy-providers:
          nodes:
            type: http
            url: https://example.invalid/nodes
            override: {additional-prefix: 'Subscription-', additional-suffix: '-test'}
        proxy-groups: [{name: Main, type: select, proxies: [DIRECT], use: [nodes]}]
        """
        let saved = await model.save(yaml, profile: records[0])
        try require(saved, "provider selection fixture did not save")
        let directGroup = model.nodeGroups(connected: false)[0]
        await model.selectNode("DIRECT", group: directGroup, using: probe)
        try require(model.selections[records[0].id]?["Main"] == "DIRECT", "store-selected false disabled an offline session selection")
        let resources = ResourceBundleStore(root: probe.root.appendingPathComponent("Resources"))
        let bundle = try resources.stage(entries: [.init(kind: .proxyProvider, name: "nodes", data: Data("proxies: [{name: JP, type: ss}, {name: Default, type: anytls}]".utf8))])
        let store = SnapshotStore(root: probe.root)
        let revision = try store.stage(configuration: .init(outbound: .mihomo(yaml: yaml), resources: bundle, profileID: records[0].id))
        probe.pendingRevision = revision
        await model.refreshCatalog(using: probe)
        let group = model.nodeGroups(connected: false)[0]
        try require(group.members.contains("Subscription-JP-test"), "offline catalog omitted a verified provider node or its name override")
        try require(model.nodeProtocol("Subscription-JP-test", connected: false) == "ss", "offline provider protocol did not use the final renamed node")
        try require(model.nodeProtocol("Subscription-Default-test", connected: false) == "anytls", "offline protocol was inferred instead of read from provider data")
        model.catalog = try JSONDecoder().decode(ProxyCatalog.self, from: Data(#"{"mode":"rule","proxies":[{"name":"Subscription-JP-test","type":"Shadowsocks","delay":140},{"name":"Subscription-Default-test","type":"AnyTLS","delay":0}]}"#.utf8))
        try require(model.nodeProtocol("Subscription-JP-test", connected: true) == "Shadowsocks", "online protocol did not use the current core catalog")
        try require(model.nodeProtocol("Main", connected: true) == nil, "online protocol incorrectly reused an offline-only entry")
        try require(model.delayResult("Subscription-JP-test", groupURL: nil, connected: true) == .measured(140), "connected row omitted real core latency")
        try require(model.delayResult("Subscription-Default-test", groupURL: nil, connected: true) == .failed, "core failure was displayed as zero millisecond success")
        try require(model.delayResult("Subscription-JP-test", groupURL: nil, connected: false) == nil, "offline row displayed stale core latency")
        let key = ProxyDelayKey(node: "Subscription-JP-test", settings: model.delayPreferences.settings)
        model.delayResults[key] = .measured(25)
        try require(model.delayResult("Subscription-JP-test", groupURL: nil, connected: true) == .measured(25), "new manual latency did not override the older core measurement")
        model.delayPreferences.sort = .delay
        try require(model.visibleNodes(["Subscription-Default-test", "Subscription-JP-test"], groupURL: nil, connected: true).first == "Subscription-JP-test", "latency sort disagreed with displayed measurements")
        model.delayPreferences.hideFailures = true
        try require(model.visibleNodes(["Subscription-Default-test", "Subscription-JP-test"], groupURL: nil, connected: true) == ["Subscription-JP-test"], "failure visibility disagreed with core measurements")
        model.delayPreferences = ProxyDelayPreferences()
        model.delayResults.removeAll()
        await model.selectNode("Subscription-JP-test", group: group, using: probe)
        try await model.refreshProfiles()
        await model.refreshCatalog(using: probe)
        try require(model.selections[records[0].id]?["Main"] == "Subscription-JP-test", "refresh removed the current session selection")
        try require(model.nodeGroups(connected: false)[0].selected == "Subscription-JP-test", "offline catalog did not display the current session selection")
        let stored = try await model.preferences.load()
        try require(stored.selections[records[0].id] == nil, "store-selected false wrote the session selection to disk")
        try await model.preferences.save(.init(selectedID: records[0].id, selections: [records[0].id: ["Main": "stale-disk-choice"]]))
        let reopened = LibraryModel(root: model.root, downloader: AppModelDownloader())
        await reopened.load()
        try require(reopened.selections[records[0].id] == nil, "a new model restored a false profile's stale disk selection")
        probe.successfulRevision = revision
        probe.pendingRevision = try store.stage(configuration: .init(outbound: .mihomo(yaml: "mode: direct"), resources: bundle, profileID: records[0].id))
        await model.refreshCatalog(using: probe)
        try require(model.nodeGroups(connected: false)[0].members.contains("Subscription-JP-test"), "a mismatched pending revision hid matching successful provider resources")
        probe.successfulRevision = nil
        await model.refreshCatalog(using: probe)
        try require(!model.nodeGroups(connected: false)[0].members.contains("Subscription-JP-test"), "offline catalog reused provider nodes from different YAML")
        let original = try await model.repository.data(id: records[0].id)
        try require(original == Data(yaml.utf8), "offline selection modified the YAML source")
        print("PASS: verified providers expand offline; disabled selection storage preserves only the current session")
    }

    @MainActor static func editingAnotherProfileKeepsSelection() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = await model.save("mode: global\n", profile: records[1])
        try require(saved, "editing another profile failed")
        await settle(model)
        try require(model.selectedID == records[0].id, "editing another profile changed the selected configuration")
        let stored = try await model.preferences.load()
        try require(stored.selectedID == records[0].id, "editing another profile changed the saved selection")
        try require(probe.applied.isEmpty, "editing another profile restarted the VPN")
        print("PASS: editing another profile preserves selection and running configuration")
    }

    @MainActor static func enabledDNSReusesLegacySuccessfulResourcesConservatively() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.isConnected = false
        let source = "dns: {enable: true, nameserver: ['1.1.1.1']}\ntun: {dns-hijack: ['any:53', 'tcp://any:53']}\nproxy-providers: {nodes: {type: http, url: 'https://example.invalid/nodes'}}"
        let saved = await model.save(source, profile: records[0])
        try require(saved, "legacy cache fixture did not save")
        let resources = ResourceBundleStore(root: probe.root.appendingPathComponent("Resources"))
        let legacyBundle = try resources.stage(entries: [.init(kind: .proxyProvider, name: "nodes", data: Data("proxies: []\n# legacy".utf8))])
        let store = SnapshotStore(root: probe.root)
        let legacy = try store.stage(configuration: .init(outbound: .mihomo(yaml: source), resources: legacyBundle, profileID: records[0].id))
        try store.markSuccessful(revision: legacy)
        probe.pendingRevision = legacy
        probe.successfulRevision = legacy
        let reused = await model.stageSelected(using: probe)
        let initial = try await probe.runtimeConfiguration(revision: probe.pendingRevision!)
        try require(reused && probe.preparations.isEmpty && initial.resources == legacyBundle, "TUN-only normalization did not reuse the original successful resource bundle")

        let effective = try model.dnsOverrides.applying(to: Data(source.utf8))
        try require(initial.outbound == .mihomo(yaml: String(decoding: effective, as: UTF8.self)), "legacy resource reuse restored old YAML instead of current TUN settings")
        let currentBundle = try resources.stage(entries: [.init(kind: .proxyProvider, name: "nodes", data: Data("proxies: []\n# effective".utf8))])
        let current = try store.stage(configuration: .init(outbound: .mihomo(yaml: String(decoding: effective, as: UTF8.self)), resources: currentBundle, profileID: records[0].id))
        try store.markSuccessful(revision: current)
        probe.pendingRevision = current
        probe.successfulRevision = current
        let preferred = await model.stageSelected(using: probe)
        let preferredConfiguration = try await probe.runtimeConfiguration(revision: probe.pendingRevision!)
        try require(preferred && preferredConfiguration.resources == currentBundle, "legacy resources replaced a successful effective-YAML bundle")

        probe.resourcePreparer = ProfileResourcePreparer(bundleStore: resources, cacheDirectory: probe.root.appendingPathComponent("DownloaderCache"), download: { _, _ in Data("proxies: []\n# explicitly refreshed".utf8) })
        let refreshed = await model.stageSelected(using: probe, forceRefresh: true)
        let refreshedBundle = try await probe.runtimeConfiguration(revision: probe.pendingRevision!).resources
        try require(refreshed && refreshedBundle != currentBundle && refreshedBundle != legacyBundle && probe.preparations.count == 1, "explicit refresh reused successful resources")
        let prepared = await model.stageSelected(using: probe)
        let retainedBundle = try await probe.runtimeConfiguration(revision: probe.pendingRevision!).resources
        try require(prepared && retainedBundle == refreshedBundle && probe.preparations.count == 2, "legacy fallback discarded newly refreshed pending resources")

        try await model.saveDNSPreferences(.init(appendSystemDNS: true))
        let changed = await model.stageSelected(using: probe)
        try require(changed && probe.preparations.count == 3, "system DNS append reused incompatible original resources")
        print("PASS: TUN-only changes reuse original successful resources after effective lookup; refresh and changed DNS retain precedence")
    }

    @MainActor static func dnsOverridesUseEffectiveConfigurationWithoutChangingSource() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.isConnected = false
        let source = try await model.repository.data(id: records[0].id)
        try await model.saveDNSPreferences(.init(appendSystemDNS: true))
        let prepared = await model.stageSelected(using: probe)
        try require(prepared, "DNS overrides did not prepare")
        let effective = try model.dnsOverrides.applying(to: source)
        try require(probe.preparations.last == effective, "resource preparation did not use effective DNS YAML")
        let configuration = try await probe.runtimeConfiguration(revision: probe.pendingRevision!)
        guard case let .mihomo(yaml, _) = configuration.outbound else { throw AppModelFailure.failed("missing effective YAML") }
        try require(Data(yaml.utf8) == effective && yaml.contains("system://"), "runtime and resource preparation used different YAML")
        let original = try await model.repository.data(id: records[0].id)
        try require(original == source, "DNS overrides rewrote the user's original configuration")
        let reopened = LibraryModel(root: root, downloader: AppModelDownloader())
        await reopened.load()
        try require(reopened.dnsOverrides.appendSystemDNS, "saved DNS preferences were not restored")

        let bundle = try ResourceBundleStore(root: probe.root.appendingPathComponent("Resources"))
            .stage(entries: [.init(kind: .ruleProvider, name: "rules", data: Data("payload: []".utf8))])
        let store = SnapshotStore(root: probe.root)
        let successful = try store.stage(configuration: .init(outbound: .mihomo(yaml: yaml), resources: bundle, profileID: records[0].id))
        try store.markSuccessful(revision: successful)
        probe.pendingRevision = successful
        probe.successfulRevision = successful
        probe.preparations.removeAll()
        let reused = await model.stageSelected(using: probe)
        try require(reused && probe.preparations.isEmpty, "unchanged DNS overrides did not reuse matching successful resources")
        probe.isConnected = true
        try await model.saveDNSPreferences(.init(appendSystemDNS: false))
        await settle(model)
        try require(probe.preparations.count == 1 && probe.applied.count == 1, "changed DNS preferences did not prepare and apply automatically")
        let changed = try await probe.runtimeConfiguration(revision: probe.activeRuntimeRevision!)
        guard case let .mihomo(changedYAML, _) = changed.outbound else { throw AppModelFailure.failed("missing changed DNS YAML") }
        try require(!changedYAML.contains("system://") && probe.preparations.last == Data(changedYAML.utf8), "changed overrides reused stale effective configuration")
        let finalSource = try await model.repository.data(id: records[0].id)
        try require(finalSource == source, "online DNS changes rewrote original YAML")
        print("PASS: DNS overrides persist and apply; preparation, runtime and resource reuse follow effective YAML while original bytes remain unchanged")
    }

    @MainActor static func dnsOverridesKeepScheduledResourceRefreshWorking() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.isConnected = false
        let source = "proxy-providers: {nodes: {type: http, url: 'https://example.invalid/nodes', interval: 60}}"
        let saved = await model.save(source, profile: records[0])
        try require(saved, "scheduled resource fixture was not saved")
        try await model.saveDNSPreferences(.init(appendSystemDNS: true))
        let staged = await model.stageSelected(using: probe)
        try require(staged, "scheduled resource fixture did not prepare")
        let revision = probe.pendingRevision!
        try SnapshotStore(root: probe.root).markSuccessful(revision: revision)
        probe.successfulRevision = revision
        probe.activeRuntimeRevision = revision
        probe.activeRuntimeProfileID = records[0].id
        probe.isConnected = true
        model.isForeground = true
        model.activeRevision = revision
        _ = try await model.resourceRefreshSchedule.claim(profileID: records[0].id, interval: 60, now: Date(timeIntervalSinceNow: -3600))
        probe.preparations.removeAll()
        probe.providerCatalog = try JSONDecoder().decode([RuntimeProviderSummary].self, from: Data("""
        [{"name":"nodes","kind":"proxy-provider","source":"http","status":"ready"},
         {"name":"local","kind":"rule-provider","source":"file","status":"ready"}]
        """.utf8))
        await model.refreshProviderResources(using: probe)
        try require(probe.applied.isEmpty && probe.preparations.isEmpty, "scheduled provider refresh restarted the VPN or staged a configuration")
        try require(probe.providerRequests.count == 1 && probe.providerRequests[0].providerName == "nodes" &&
                    probe.providerRequests[0].revision == revision && probe.providerRequests[0].expectedSessionID == "active-session",
                    "scheduled refresh failed to target the running HTTP provider")
        let running = try await model.runningProviders(using: probe)
        probe.providerStatus = .init(phase: .failed, message: "provider rejected invalid payload")
        do {
            _ = try await model.updateRunningProviders(running.entries, in: running, using: probe)
            throw AppModelFailure.failed("provider update ignored a rejected payload")
        } catch let error as RemoteResourceError {
            try require(error.localizedDescription == probe.providerStatus.message, "provider failure lost its reason")
        }
        probe.providerStatus = .init(phase: .ready, message: "")
        probe.providerSession = "replaced-session"
        do {
            _ = try await model.updateRunningProviders(running.entries, in: running, using: probe)
            throw AppModelFailure.failed("new session was treated as an update of the original")
        } catch is CancellationError {}
        try require(probe.applied.isEmpty && !model.resourceRefreshRunning, "failed refresh restarted the VPN or left the controls disabled")
        print("PASS: live provider updates preserve the VPN and reject failed or stale session results")
    }

    @MainActor static func changedDNSOverridesCancelOldPreparation() async throws {
        let (model, probe, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.isConnected = false
        probe.suspendNextPreparation = true
        let old = Task { await model.stageSelected(using: probe) }
        try await waitUntil("DNS configuration preparation", { probe.preparationContinuation != nil })
        try await model.saveDNSPreferences(.init(appendSystemDNS: true))
        probe.preparationContinuation?.resume()
        probe.preparationContinuation = nil
        let completed = await old.value
        try require(!completed && probe.pendingRevision == nil, "old DNS settings committed after the user changed them")
        print("PASS: changed DNS settings invalidate a suspended configuration preparation")
    }

    @MainActor static func switchingBackReusesProfileResources() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let yaml = try await model.repository.data(id: records[0].id)
        let resources = ResourceBundleStore(root: probe.root.appendingPathComponent("Resources"))
        let bundle = try resources.stage(entries: [.init(kind: .ruleProvider, name: "rules", data: Data("payload: [example.test]".utf8))])
        let store = SnapshotStore(root: probe.root)
        let original = try store.stage(configuration: .init(outbound: .mihomo(yaml: String(decoding: try model.dnsOverrides.applying(to: yaml), as: UTF8.self)), resources: bundle, profileID: records[0].id))
        try store.markSuccessful(revision: original)
        probe.pendingRevision = original
        probe.successfulRevision = original
        await model.select(records[1].id)
        await settle(model)
        try require(probe.activeRuntimeProfileID == records[1].id, "switch to DIRECT did not apply")
        try store.markSuccessful(revision: probe.successfulRevision!)
        probe.preparations.removeAll()
        await model.select(records[0].id)
        await settle(model)
        try require(probe.activeRuntimeProfileID == records[0].id, "switch back did not apply original profile")
        try require(probe.preparations.isEmpty, "switching back downloaded resources instead of reusing that profile's successful bundle")
        let restored = try await probe.runtimeConfiguration(revision: probe.activeRuntimeRevision!)
        try require(restored.resources == bundle, "switching back lost previously successful rules")
        probe.isConnected = false
        try FileManager.default.removeItem(at: resources.directory(id: bundle))
        let prepared = await model.stageSelected(using: probe)
        try require(prepared && probe.preparations.count == 1, "missing indexed resource files bypassed resource preparation")
        print("PASS: switching through DIRECT reuses verified profile resources; missing files prepare again")
    }

    @MainActor static func connectionReusesOnlyMatchingVerifiedResources() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.isConnected = false
        let yaml = try await model.repository.data(id: records[0].id)
        let bundle = try ResourceBundleStore(root: probe.root.appendingPathComponent("Resources"))
            .stage(entries: [.init(kind: .ruleProvider, name: "test", data: Data("payload: []".utf8)),
                             .init(kind: .geoIPMMDB, name: "default", data: Data("legacy downloaded GeoIP".utf8))])
        let revision = try SnapshotStore(root: probe.root).stage(configuration: .init(
            outbound: .mihomo(yaml: String(decoding: try model.dnsOverrides.applying(to: yaml), as: UTF8.self)), resources: bundle, profileID: records[0].id
        ))
        model.revisions[revision] = records[0].id
        probe.pendingRevision = revision
        let unverified = await model.stageSelected(using: probe)
        try require(unverified && probe.preparations.count == 1, "unverified pending resources were reused before a successful connection")
        try SnapshotStore(root: probe.root).markSuccessful(revision: revision)
        probe.successfulRevision = revision
        probe.pendingRevision = revision
        probe.preparations.removeAll()
        let reused = await model.stageSelected(using: probe)
        try require(reused && probe.preparations.isEmpty, "normal reconnect unnecessarily downloaded matching verified resources")
        let updated = try await probe.runtimeConfiguration(revision: probe.pendingRevision!)
        let cachedStore = ResourceBundleStore(root: probe.root.appendingPathComponent("Resources"))
        try require(updated.resources != nil, "cached provider was dropped")
        let cachedID = updated.resources!
        let geo = try cachedStore.entries(id: cachedID, kind: .geoIPMMDB)
        let rules = try cachedStore.entries(id: cachedID, kind: .ruleProvider)
        try require(geo.isEmpty && rules.count == 1, "cached GeoIP took precedence over installed GeoIP")
        let refreshed = await model.stageSelected(using: probe, forceRefresh: true)
        try require(refreshed && probe.preparations.count == 1, "explicit resource refresh reused old resources")
        _ = await model.save("mode: direct\n", profile: records[0])
        let changed = await model.stageSelected(using: probe)
        try require(changed && probe.preparations.count == 2, "changed YAML reused resources from another source revision")
        print("PASS: normal connection reuses matching verified resources; explicit refresh and changed YAML prepare again")
    }

    @MainActor static func explicitOfflineResourceRefreshPreservesNewResources() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.isConnected = false
        let yaml = "proxy-providers: {nodes: {type: http, url: 'https://example.test/nodes'}}"
        let saved = await model.save(yaml, profile: records[0])
        try require(saved, "resource refresh fixture did not save")
        let resources = ResourceBundleStore(root: probe.root.appendingPathComponent("Resources"))
        let oldBundle = try resources.stage(entries: [.init(kind: .proxyProvider, name: "nodes", data: Data("proxies: []".utf8))])
        let store = SnapshotStore(root: probe.root)
        let successful = try store.stage(configuration: .init(outbound: .mihomo(yaml: String(decoding: try model.dnsOverrides.applying(to: Data(yaml.utf8)), as: UTF8.self)), resources: oldBundle, profileID: records[0].id))
        try store.markSuccessful(revision: successful)
        probe.successfulRevision = successful
        probe.pendingRevision = successful
        probe.resourcePreparer = ProfileResourcePreparer(bundleStore: resources, cacheDirectory: probe.root.appendingPathComponent("DownloaderCache"), download: { _, _ in
            Data("proxies: []\n# refreshed resource".utf8)
        })
        let refreshed = await model.stageSelected(using: probe, forceRefresh: true)
        try require(refreshed, "explicit offline refresh failed")
        let newBundle = try await probe.runtimeConfiguration(revision: probe.pendingRevision!).resources
        try require(newBundle != oldBundle, "explicit refresh did not prepare new resource bytes")
        let prepared = await model.stageSelected(using: probe)
        let connectedBundle = try await probe.runtimeConfiguration(revision: probe.pendingRevision!).resources
        try require(prepared && connectedBundle == newBundle, "normal connection discarded explicitly refreshed resources for an old successful bundle")
        print("PASS: normal connection keeps explicitly refreshed resources through the HTTP request cache")
    }

    @MainActor static func removingLastLocalResourcePreventsBundleReuse() async throws {
        let node = "{name: node, type: trojan, server: example.test, port: 443, password: test-only, certificate: local-cert.pem}"
        let cases: [(String, String, Data)] = [
            ("proxy-providers: {nodes: {type: file, path: nodes.yaml}}", "nodes.yaml", Data("proxies: []".utf8)),
            ("rule-providers: {domains: {type: file, path: rules.yaml, behavior: domain}}", "rules.yaml", Data("payload: [example.test]".utf8)),
            ("proxies: [\(node)]", "local-cert.pem", Data("certificate fixture".utf8)),
            ("proxy-providers: {nodes: {type: inline, payload: [\(node)]}}", "local-cert.pem", Data("certificate fixture".utf8)),
            ("proxy-providers: {nodes: {type: http, url: 'https://example.test/nodes'}}", "local-cert.pem", Data("certificate fixture".utf8)),
            ("geox-url: {geosite: 'https://example.test/site.dat'}\nrules: ['GEOSITE,TEST,DIRECT']", "GeoSite.dat", Data("local geodata fixture".utf8)),
        ]
        for (yaml, path, bytes) in cases {
            let (model, probe, records, root) = try await fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            probe.isConnected = false
            let downloaded = path == "GeoSite.dat" ? Data("remote geodata fixture".utf8) : Data("proxies: [\(node)]".utf8)
            probe.resourcePreparer = ProfileResourcePreparer(
                bundleStore: ResourceBundleStore(root: probe.root.appendingPathComponent("Resources")),
                cacheDirectory: probe.root.appendingPathComponent("DownloaderCache"),
                download: { _, _ in downloaded }
            )
            let saved = await model.save(yaml, profile: records[0])
            try require(saved, "local resource fixture did not save")
            _ = try await model.resourceLinks.associate(profileID: records[0].id, path: path, displayName: path, data: bytes)
            try await model.refreshResourceLinks()
            let link = model.resourceFiles[0]
            let original = await model.stageSelected(using: probe, forceRefresh: true)
            try require(original, "authorized local resource was not prepared: \(path)")
            let revision = probe.pendingRevision!
            try SnapshotStore(root: probe.root).markSuccessful(revision: revision)
            probe.successfulRevision = revision
            await model.removeResource(link)
            try require(model.resourceFiles.isEmpty, "last local resource association remained")
            let prepared = await model.stageSelected(using: probe)
            try require(probe.preparations.count == 2, "removed local resource was reused from a successful bundle: \(path)")
            if path == "GeoSite.dat" || path == "rules.yaml" || yaml.contains("type: http") {
                try require(prepared, "resource delegated to Mihomo blocked application preparation")
                let configuration = try await probe.runtimeConfiguration(revision: probe.pendingRevision!)
                try require(configuration.resources == nil, "removed local resource was forwarded to Mihomo")
                let refreshed = await model.stageSelected(using: probe, forceRefresh: true)
                try require(refreshed, "explicit refresh must delegate remote resources to Mihomo")
            } else {
                try require(!prepared, "removed local resource unexpectedly prepared: \(path)")
                try require(model.missingResource?.path == path, "missing local resource did not request reassociation: \(path)")
                try require(probe.pendingRevision == revision, "failed resource preparation replaced the prior revision")
            }
        }
        print("PASS: local node certificates are required; Mihomo resolves remote providers and missing geodata")
    }

    @MainActor static func fixture() async throws -> (LibraryModel, ProbeModel, [ProfileRecord], URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = LibraryModel(root: root, downloader: AppModelDownloader())
        var records: [ProfileRecord] = []
        for name in ["One", "Two", "Three"] {
            records.append(try await model.repository.importData(data: Data("mode: rule\n# \(name)\n".utf8), name: name,
                                                                 sourceURL: URL(string: "https://example.invalid/\(name)")!))
        }
        await model.load()
        await model.select(records[0].id)
        let probe = ProbeModel(root: root)
        probe.activeRuntimeRevision = "previous-running-configuration"
        probe.activeRuntimeProfileID = records[0].id
        model.activeRevision = probe.activeRuntimeRevision
        model.resourceRefreshProbe = probe
        return (model, probe, records, root)
    }

    @MainActor static func settle(_ model: LibraryModel) async {
        await model.configurationUpdateTask?.value
    }

    @MainActor static func waitUntil(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw AppModelFailure.failed("timed out: \(message)") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor static func currentEditsAndSelectionApplyAutomatically() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = await model.save("mode: direct\n", profile: records[0])
        try require(saved, "current configuration edit failed")
        await settle(model)
        try require(probe.applied.count == 1, "current edit did not automatically apply once")
        try require(probe.activeRuntimeProfileID == records[0].id, "current edit applied another profile")
        await model.rename(model.selectedProfile!, name: "Renamed")
        await settle(model)
        try require(probe.applied.count == 1, "rename unnecessarily reapplied configuration")
        await model.select(records[1].id)
        await settle(model)
        try require(probe.applied.count == 2 && probe.activeRuntimeProfileID == records[1].id, "selection did not automatically apply selected profile")
        try require(!model.isUpdatingConfiguration, "update progress remained active after completion")
        print("PASS: current edit and selection apply automatically; rename does not restart")
    }

    @MainActor static func offlineChangesDoNotConnect() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.disconnect()
        await model.select(records[1].id)
        _ = await model.save("mode: direct\n", profile: records[1])
        await settle(model)
        try require(probe.applied.isEmpty, "offline change attempted to apply a configuration")
        try require(!probe.isConnected, "offline change connected the VPN")
        print("PASS: offline edits and selection do not connect")
    }

    @MainActor static func rapidSelectionAppliesOnlyLatest() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.suspendNextPreparation = true
        await model.select(records[1].id)
        try await waitUntil("first preparation", { probe.preparationContinuation != nil })
        let previous = model.configurationUpdateTask
        await model.select(records[2].id)
        probe.preparationContinuation?.resume()
        probe.preparationContinuation = nil
        await previous?.value
        await settle(model)
        try require(probe.applied.count == 1, "superseded preparation was applied")
        try require(probe.activeRuntimeProfileID == records[2].id, "latest selected configuration did not win")
        print("PASS: rapid selection applies only the latest configuration")
    }

    @MainActor static func disconnectCancelsPreparation() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.suspendNextPreparation = true
        await model.select(records[1].id)
        try await waitUntil("preparation before disconnect", { probe.preparationContinuation != nil })
        probe.disconnect()
        probe.preparationContinuation?.resume()
        probe.preparationContinuation = nil
        await settle(model)
        try require(probe.applied.isEmpty, "preparation applied after disconnect")
        try require(!model.isUpdatingConfiguration, "cancelled preparation left progress active")
        print("PASS: disconnect prevents late preparation from applying")
    }

    @MainActor static func disconnectIgnoresLateApplicationResponse() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.suspendNextApplication = true
        await model.select(records[1].id)
        try await waitUntil("application before disconnect", { probe.applicationContinuation != nil })
        probe.disconnect()
        model.activeRevision = nil
        model.message = "已断开"
        probe.applicationContinuation?.resume()
        probe.applicationContinuation = nil
        await settle(model)
        try require(model.activeRevision == nil, "late application response overwrote disconnected state")
        try require(model.message == "已断开", "late application response overwrote the current status message")
        try require(!model.isUpdatingConfiguration, "late application response left progress active")
        print("PASS: late application response cannot overwrite disconnected state")
    }

    @MainActor static func busyChangesCoalesce() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.busy = true
        await model.select(records[1].id)
        await model.select(records[2].id)
        try require(probe.preparations.isEmpty, "configuration preparation raced a busy library operation")
        model.busy = false
        await settle(model)
        try require(probe.applied.count == 1 && probe.activeRuntimeProfileID == records[2].id,
                    "queued selections did not coalesce to the latest configuration")
        print("PASS: changes during a busy operation coalesce to the latest selection")
    }

    @MainActor static func failuresPreserveRunningConfiguration() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = probe.activeRuntimeRevision
        probe.failPreparation = true
        await model.select(records[1].id)
        await settle(model)
        try require(probe.applied.isEmpty && model.activeRevision == previous, "preparation failure changed running configuration")
        try require(model.message.contains("resource download failed"), "preparation failure was not reported")
        probe.failPreparation = false
        probe.failApplication = true
        await model.select(records[2].id)
        await settle(model)
        try require(model.activeRevision == previous, "failed application did not retain actual previous configuration")
        try require(model.message.contains("已恢复此前运行的配置"), "restoration was not reported")
        print("PASS: preparation and application failures preserve actual running state")
    }

    @MainActor static func batchSubscriptionsApplyCurrentOnlyOnce() async throws {
        let (model, probe, records, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.updateSubscriptions(records)
        await model.downloadTask?.value
        await settle(model)
        try require(model.subscriptionUpdates.allSatisfy { $0.status == .updated }, "batch subscriptions did not all update")
        try require(model.selectedID == records[0].id, "batch subscriptions changed selection")
        try require(probe.applied.count == 1, "batch subscriptions should apply current configuration only once")
        try require(probe.activeRuntimeProfileID == records[0].id, "batch subscriptions applied a different profile")
        print("PASS: batch subscription updates apply only the current configuration once")
    }
}

extension AppModelTests {
    @MainActor static func dnsPreferencesSurviveRelaunch() async throws {
        let (model, probe, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        probe.disconnect()
        let draft = DNSOverridePreferences(
            appendSystemDNS: true,
            dns: ["nameserver": .init(enabled: false, value: "[9.9.9.9]")],
            tun: ["dns-hijack": .init(enabled: true, value: "[]")]
        )
        try await model.saveDNSPreferences(draft)
        let reopened = LibraryModel(root: root)
        await reopened.load()
        try require(reopened.dnsPreferences == draft, "disabled field text or enabled fields lost across relaunch")
        try require(reopened.dnsOverrides.dns.isEmpty && reopened.dnsOverrides.tun["dns-hijack"] == "[]",
                    "disabled field was applied or explicit empty list was lost")
        print("PASS: DNS and TUN override choices survive relaunch without activating unchecked fields")
    }
}
