import Combine
import Foundation

struct DNSOverridePreferences: Codable, Equatable, Sendable {
    struct Field: Codable, Equatable, Sendable {
        var enabled: Bool
        var value: String
    }

    var appendSystemDNS = false
    var dns: [String: Field] = [:]
    var tun: [String: Field] = [:]

    var effective: DNSOverrides {
        DNSOverrides(
            appendSystemDNS: appendSystemDNS,
            dns: dns.filter { $0.value.enabled }.mapValues(\.value),
            tun: tun.filter { $0.value.enabled }.mapValues(\.value)
        )
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var dnsPreferences = DNSOverridePreferences()
    var dnsOverrides: DNSOverrides { dnsPreferences.effective }

    @Published var profiles: [ProfileRecord] = []
    @Published var selectedID: String? {
        didSet {
            if oldValue != selectedID {
                stageIntent &+= 1
                missingResource = nil
                configurationUpdateTask?.cancel()
                pendingConfigurationUpdate = nil
            }
        }
    }
    var selectionCleared = false
    @Published var syncDeletedProfileIDs: Set<String> = []
    @Published var message = "导入并选择配置后，即可连接。"
    @Published var busy = false { didSet { if !busy { startConfigurationUpdate() } } }
    @Published var downloading = false { didSet { if !downloading { startConfigurationUpdate() } } }
    @Published var isUpdatingConfiguration = false
    @Published var preparationMessage = ""
    @Published var subscriptionUpdates: [SubscriptionUpdateResult] = []
    var automaticSubscriptionUpdate = false
    @Published var syncEnabled = false
    @Published var syncBusy = false { didSet { if !syncBusy { startConfigurationUpdate() } } }
    @Published var syncDirectory: URL?
    @Published var syncResults: [YAMLSyncFileResult] = []
    @Published var requestedMode: String?
    @Published var modeError: String?
    var modeSwitchRunning = false
    @Published var catalog: ProxyCatalog?
    @Published var offlineOverview: YAMLDocument?
    var offlineOverviewProfileID: String?
    var offlineOverviewRevision: String?
    @Published var activeRevision: String?
    @Published var delayResults: [ProxyDelayKey: ProxyDelayResult] = [:]
    @Published var testingNodes: Set<ProxyDelayKey> = []
    @Published var isTestingDelays = false
    @Published var delayCompleted = 0
    @Published var delayTotal = 0
    @Published var delayPreferences = ProxyDelayPreferences.load()
    var delayTask: Task<Void, Never>?
    @Published var selections: [String: [String: String]] = [:]
    @Published var resourceFiles: [ProfileLinkedResource] = []
    @Published var missingResource: MissingProfileResource?

    let repository: ProfileRepository
    let root: URL
    let preferences: LibraryPreferences
    let bookmarks: DirectoryBookmarkStore
    let resourceLinks: ProfileResourceLinks
    var revisions: [String: String] = [:]
    var engine: YAMLSyncEngine?
    var access: ScopedDirectoryAccess?
    var localObserver: DirectoryObserver?
    var remoteObserver: DirectoryObserver?
    var foregroundTask: Task<Void, Never>?
    var changeTask: Task<Void, Never>?
    var downloadTask: Task<Void, Never>?
    var syncArmed = false
    var isForeground = false
    var loaded = false
    var syncRequestCount = 0
    var delayGeneration: UInt64 = 0
    var catalogGeneration: UInt64 = 0
    var stageIntent: UInt64 = 0
    var configurationUpdateGeneration: UInt64 = 0
    var pendingConfigurationUpdate: ConfigurationUpdateRequest?
    var configurationUpdateTask: Task<Void, Never>?
    weak var resourceRefreshProbe: ProbeModel?
    @Published var resourceRefreshRunning = false
    lazy var resourceRefreshSchedule = ResourceRefreshSchedule(url: root.appendingPathComponent("resource-refresh.json"))

    init(root: URL? = nil, downloader: any ProfileDownloader = URLSessionProfileDownloader()) {
        let directory = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeProfiles", isDirectory: true)
        self.root = directory
        repository = ProfileRepository(root: directory, downloader: downloader)
        preferences = LibraryPreferences(url: directory.appendingPathComponent("selections.json"))
        bookmarks = DirectoryBookmarkStore(bookmarkURL: directory.appendingPathComponent("sync-directory.bookmark"))
        resourceLinks = ProfileResourceLinks(root: directory.appendingPathComponent("ResourceLinks", isDirectory: true))
    }

    deinit {
        foregroundTask?.cancel()
        changeTask?.cancel()
        downloadTask?.cancel()
        delayTask?.cancel()
        configurationUpdateTask?.cancel()
    }

    var selectedProfile: ProfileRecord? { profiles.first { $0.id == selectedID } }

    func load() async {
        guard !loaded else { return }
        loaded = true
        loaded = await run {
            let stored = try await self.preferences.load()
            self.dnsPreferences = stored.dnsOverrides ?? DNSOverridePreferences()
            self.selections = stored.selections
            self.revisions = stored.revisions
            self.selectionCleared = stored.selectionCleared ?? false
            self.syncDeletedProfileIDs = stored.syncDeletedProfileIDs ?? []
            self.selectedID = stored.selectedID
            try await self.refreshProfiles()
            self.selections = self.persistentSelections
            await self.restoreSyncDirectory()
            self.configureObservers()
        }
        if loaded { scheduleSync() }
    }

    func refreshProfiles(selectFallback: Bool = false) async throws {
        let previousID = selectedID
        let previousRevision = selectedProfile?.revisionSHA
        let knownIDs = Set(profiles.map(\.id)).union(selections.keys).union(revisions.values).union(selectedID.map { [$0] } ?? [])
        profiles = try await repository.refresh()
        let currentIDs = Set(profiles.map(\.id))
        let removedIDs = knownIDs.subtracting(currentIDs)
        if let selectedID, !currentIDs.contains(selectedID) {
            self.selectedID = nil
            selectionCleared = !selectFallback
        }
        if selectedID == nil && !selectionCleared { selectedID = profiles.first?.id }
        syncDeletedProfileIDs.subtract(currentIDs)
        for id in removedIDs {
            selections.removeValue(forKey: id)
            revisions = revisions.filter { $0.value != id }
            try await resourceLinks.delete(profileID: id)
        }
        try await preferences.removeSelections(for: profilesNotStoringSelections)
        if !removedIDs.isEmpty { try await persistPreferences() }
        if previousRevision != selectedProfile?.revisionSHA { stageIntent &+= 1; missingResource = nil }
        try await refreshResourceLinks()
        if previousID != selectedID || previousRevision != selectedProfile?.revisionSHA {
            requestConfigurationUpdate()
        }
    }

    @discardableResult
    func select(_ id: String) async -> String? {
        guard profiles.contains(where: { $0.id == id }) else { return LibraryError.noProfile.localizedDescription }
        let changed = selectedID != id
        selectionCleared = false
        selectedID = id
        do {
            try await persistPreferences()
            try await refreshResourceLinks()
            if changed { requestConfigurationUpdate() }
            return nil
        } catch {
            let failure = "选择未保存：\(error.localizedDescription)"
            message = failure
            return failure
        }
    }

    func importFile(_ url: URL) async {
        await run {
            let data = try await Task.detached(priority: .userInitiated) { try Self.readImportedFile(url) }.value
            let record = try await self.repository.importData(data: data, name: url.deletingPathExtension().lastPathComponent)
            try await self.didSave(record)
        }
    }

    func importText(_ text: String, name: String) async -> Bool {
        await run {
            let record = try await self.repository.importData(data: Data(text.utf8), name: name)
            try await self.didSave(record)
        }
    }

    func save(_ text: String, profile: ProfileRecord) async -> Bool {
        await run {
            let record = try await self.repository.update(id: profile.id, data: Data(text.utf8), expectedRevision: profile.revisionSHA)
            try await self.didSave(record, selecting: false)
        }
    }

    func addDirectExample() async {
        _ = await importText("""
        # DIRECT 示例：用于配置和同步验证
        mode: rule
        proxies: []
        proxy-groups:
          - name: 默认出口
            type: select
            proxies: [DIRECT, REJECT]
        rules:
          - MATCH,默认出口

        """, name: "DIRECT 示例")
    }

    @discardableResult
    func rename(_ profile: ProfileRecord, name: String) async -> String? {
        await runWithError {
            _ = try await self.repository.rename(id: profile.id, name: name)
            try await self.refreshProfiles()
            self.message = "名称已保存；YAML 原文未改动。"
        }
    }

    @discardableResult
    func duplicate(_ profile: ProfileRecord) async -> String? {
        await runWithError {
            let copy = try await self.repository.duplicate(id: profile.id)
            try await self.resourceLinks.copy(from: profile.id, to: copy.id)
            try await self.didSave(copy)
        }
    }

    @discardableResult
    func delete(_ profile: ProfileRecord) async -> String? {
        await runWithError {
            try await self.repository.delete(id: profile.id, expectedRevision: profile.revisionSHA)
            try await self.resourceLinks.delete(profileID: profile.id)
            self.selections.removeValue(forKey: profile.id)
            try await self.refreshProfiles(selectFallback: true)
            try await self.persistPreferences()
            self.message = "已删除本地配置；同步目录中的文件保留。"
        }
    }

    func didSave(_ profile: ProfileRecord, selecting: Bool = true) async throws {
        let changedSelection = selecting && selectedID != profile.id
        if selecting { selectionCleared = false; selectedID = profile.id }
        try await refreshProfiles()
        try await persistPreferences()
        message = "配置已保存。"
        if changedSelection { requestConfigurationUpdate() }
        scheduleSync()
    }

    @discardableResult
    func run(_ operation: () async throws -> Void) async -> Bool {
        await runWithError(operation) == nil
    }

    func runWithError(_ operation: () async throws -> Void) async -> String? {
        guard !busy else { return "操作进行中，请稍后重试。" }
        stageIntent &+= 1
        busy = true
        defer { busy = false }
        do { try await operation(); return nil }
        catch {
            let failure = error is CancellationError ? "操作已取消。" : error.localizedDescription
            message = failure
            return failure
        }
    }

    func saveDNSPreferences(_ value: DNSOverridePreferences) async throws {
        guard value != dnsPreferences else { return }
        let effective = value.effective
        try effective.validate()
        let previous = dnsPreferences
        dnsPreferences = value
        do {
            try await persistPreferences()
        } catch {
            if dnsPreferences == value { dnsPreferences = previous }
            throw error
        }
        if dnsPreferences == value, previous.effective != effective {
            stageIntent &+= 1
            requestConfigurationUpdate()
        }
    }

    func persistPreferences() async throws {
        try await preferences.save(.init(selectedID: selectedID, selections: persistentSelections, revisions: revisions, dnsOverrides: dnsPreferences, selectionCleared: selectionCleared, syncDeletedProfileIDs: syncDeletedProfileIDs))
    }

    private var profilesNotStoringSelections: Set<String> {
        Set(profiles.filter { $0.overview?.storeSelected == false }.map(\.id))
    }

    private var persistentSelections: [String: [String: String]] {
        let excluded = profilesNotStoringSelections
        return selections.filter { !excluded.contains($0.key) }
    }

    nonisolated static func readImportedFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var result: Result<Data, Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { location in
            result = Result {
                let attributes = try location.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw ProfileStoreError.unsafeFile }
                guard let size = attributes.fileSize, size <= YAMLDocument.maximumBytes else { throw ProfileStoreError.tooLarge }
                let data = try Data(contentsOf: location)
                guard data.count <= YAMLDocument.maximumBytes else { throw ProfileStoreError.tooLarge }
                return data
            }
        }
        if coordinationError != nil { throw ProfileStoreError.storageFailure }
        guard let result else { throw ProfileStoreError.storageFailure }
        return try result.get()
    }
}

actor LibraryPreferences {
    struct Value: Codable {
        var selectedID: String?
        var selections: [String: [String: String]] = [:]
        var revisions: [String: String] = [:]
        var dnsOverrides: DNSOverridePreferences?
        var selectionCleared: Bool?
        var syncDeletedProfileIDs: Set<String>?
    }
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return Value() }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }
    func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func removeSelections(for ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        var stored = try load()
        guard stored.selections.keys.contains(where: ids.contains) else { return }
        for id in ids { stored.selections.removeValue(forKey: id) }
        try save(stored)
    }
}

enum LibraryError: LocalizedError {
    case syncConflict, noProfile, noFolder, resourceRequired
    var errorDescription: String? {
        switch self {
        case .syncConflict: "该文件有未解决的同步问题，请先处理后再更新订阅。"
        case .noProfile: "请先选择配置。"
        case .noFolder: "请先选择同步目录。"
        case .resourceRequired: "缺少本地资源。请在资源区域选择对应文件，然后重新连接或更新资源。"
        }
    }
}
