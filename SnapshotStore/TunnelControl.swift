import Foundation

public struct ProxyCatalog: Codable, Sendable {
    public let mode: String
    public let proxies: [ProxySummary]
    public let warnings: [String]?
}

public struct ProxySummary: Codable, Identifiable, Sendable {
    public let name: String
    public let type: String
    public let all: [String]?
    public let now: String?
    public let delay: Int64?
    public let testURL: String?
    public var id: String { name }
}

public struct EffectiveConfigurationPage: Codable, Sendable {
    public let sessionID: String
    public let data: Data
    public let nextOffset: Int?
}

public struct RuntimeProviderUsage: Codable, Sendable {
    public let upload: Int64?
    public let download: Int64?
    public let total: Int64?
    public let expiresAt: Date?
}

public struct RuntimeProviderSummary: Codable, Identifiable, Sendable {
    public let kind: ResourceKind
    public let name: String
    public let source: String
    public let status: String
    public let count: Int?
    public let updatedAt: Date?
    public let subscription: RuntimeProviderUsage?
    public var canRefresh: Bool { source == "http" && status == "ready" }
    public var id: String { kind.rawValue + "/" + name }
}

public struct TunnelControlRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case catalog, select, setMode, exitIP, cancelExitIP, delay, cancelTests, applyRevision, metrics, runtimeSnapshot, closeConnection, closeAllConnections, clearDNSCache, sharingStatus, configureSharing, refreshResources, effectiveConfiguration, providerCatalog, refreshProvider }
    public let id: UUID
    public let action: Action
    public let mode: String?
    public let group: String?
    public let node: String?
    public let revision: String?
    public let connectionID: String?
    public let sharingConfiguration: ProxySharingConfiguration?
    public let forceRefresh: Bool?
    public let cancellingRequestID: UUID?
    public let delaySettings: ProxyDelaySettings?
    public let expectedSessionID: String?
    public let selections: [String: String]?

    public let offset: Int?
    public let providerKind: ResourceKind?
    public let providerName: String?

    public init(action: Action, mode: String? = nil, group: String? = nil, node: String? = nil, revision: String? = nil, connectionID: String? = nil, sharingConfiguration: ProxySharingConfiguration? = nil, forceRefresh: Bool? = nil, cancellingRequestID: UUID? = nil, delaySettings: ProxyDelaySettings? = nil, expectedSessionID: String? = nil, selections: [String: String]? = nil, offset: Int? = nil, providerKind: ResourceKind? = nil, providerName: String? = nil) {
        id = UUID()
        self.action = action
        self.mode = mode
        self.group = group
        self.node = node
        self.revision = revision
        self.connectionID = connectionID
        self.sharingConfiguration = sharingConfiguration
        self.forceRefresh = forceRefresh
        self.cancellingRequestID = cancellingRequestID
        self.delaySettings = delaySettings
        self.expectedSessionID = expectedSessionID
        self.offset = offset
        self.providerKind = providerKind
        self.providerName = providerName
        self.selections = selections
    }
}

public struct TunnelControlResponse: Codable, Sendable {
    public let id: UUID
    public let catalog: ProxyCatalog?
    public let delayMilliseconds: Int64?
    public let delayFailure: ProxyDelayFailure?
    public let error: String?
    public let activeRevision: String?
    public let restoredPrevious: Bool?
    public let metrics: ProcessMemorySample?
    public let runtime: RuntimeSnapshot?
    public let sharing: ProxySharingStatus?
    public let exitIP: ExitIP?
    public let resourceStatus: TunnelResourceStatus?
    public let configurationPage: EffectiveConfigurationPage?
    public let providers: [RuntimeProviderSummary]?
    public let inspectionSessionID: String?

    public init(id: UUID, catalog: ProxyCatalog? = nil, delayMilliseconds: Int64? = nil, error: String? = nil,
                activeRevision: String? = nil, restoredPrevious: Bool? = nil, metrics: ProcessMemorySample? = nil,
                runtime: RuntimeSnapshot? = nil, sharing: ProxySharingStatus? = nil, exitIP: ExitIP? = nil, delayFailure: ProxyDelayFailure? = nil,
                resourceStatus: TunnelResourceStatus? = nil, configurationPage: EffectiveConfigurationPage? = nil,
                providers: [RuntimeProviderSummary]? = nil, inspectionSessionID: String? = nil) {
        self.id = id
        self.catalog = catalog
        self.delayMilliseconds = delayMilliseconds
        self.delayFailure = delayFailure
        self.error = error
        self.activeRevision = activeRevision
        self.restoredPrevious = restoredPrevious
        self.metrics = metrics
        self.runtime = runtime
        self.sharing = sharing
        self.exitIP = exitIP
        self.resourceStatus = resourceStatus
        self.configurationPage = configurationPage
        self.providers = providers
        self.inspectionSessionID = inspectionSessionID
    }

    public func withResourceStatus(_ status: TunnelResourceStatus?) -> TunnelControlResponse {
        TunnelControlResponse(
            id: id, catalog: catalog, delayMilliseconds: delayMilliseconds, error: error,
            activeRevision: activeRevision, restoredPrevious: restoredPrevious, metrics: metrics,
            runtime: runtime, sharing: sharing, exitIP: exitIP, delayFailure: delayFailure, resourceStatus: status,
            configurationPage: configurationPage, providers: providers, inspectionSessionID: inspectionSessionID
        )
    }
}
