import Foundation
import MihomoBridge

public final class GoPacketSession: PacketSession, @unchecked Sendable {
    private let session: MobileSession
    private let qualityCacheRoot: URL?
    private let resourceRoot: URL?
    private let stateRoot: URL?
    private let inspectionYAML: String?
    private let inspectionLock = NSLock()
    private var inspectionFile: FileHandle?
    private var inspectionID: String?


    public static var version: String { MobileVersion() }

    public static func registerBundledGeodata() throws {
        guard let database = BundledGeodata.countryDatabaseURL() else { throw GoControlError.resourcesUnavailable }
        var error: NSError?
        guard MobileSetBundledGeoIPPath(database.path, &error) else { throw error ?? GoControlError.resourcesUnavailable }
    }

    public init(mtu: Int32) throws {
        var error: NSError?
        guard let session = MobileNewSession(mtu, &error) else {
            throw error ?? NSError(domain: "MihomoBridge", code: 1)
        }
        self.session = session
        self.qualityCacheRoot = nil
        self.inspectionYAML = nil
        self.resourceRoot = nil
        self.stateRoot = nil
    }

    public init(configuration: String, resourceRoot: URL? = nil, stateRoot: URL? = nil, qualityCacheRoot: URL? = nil) throws {
        let validated = try RuntimeConfiguration.decode(Data(configuration.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var error: NSError?
        let created: MobileSession?
        switch validated.outbound {
        case let .mihomo(yaml, selections):
            self.inspectionYAML = yaml
            let choices = String(decoding: try encoder.encode(selections), as: UTF8.self)
            let resourcePath: String
            if let resources = validated.resources {
                guard let resourceRoot, resourceRoot.lastPathComponent == resources else { throw GoControlError.resourcesUnavailable }
                resourcePath = resourceRoot.path
            } else { resourcePath = "" }
            if validated.allowDeferredResources {
                if let profileID = validated.profileID, stateRoot?.lastPathComponent != CoreStateStore.identifier(profileID: profileID) {
                    throw GoControlError.stateUnavailable
                }
                created = MobileNewYAMLSessionWithDeferredResources(yaml, choices, resourcePath, stateRoot?.path ?? "", Int32(validated.mtu), &error)
            } else if let profileID = validated.profileID {
                guard let stateRoot, stateRoot.lastPathComponent == CoreStateStore.identifier(profileID: profileID) else { throw GoControlError.stateUnavailable }
                created = MobileNewYAMLSessionWithStorage(yaml, choices, resourcePath, stateRoot.path, Int32(validated.mtu), &error)
            } else if validated.resources != nil {
                created = MobileNewYAMLSessionWithResources(yaml, choices, resourcePath, Int32(validated.mtu), &error)
            } else {
                created = MobileNewYAMLSession(yaml, choices, Int32(validated.mtu), &error)
            }
        default:
            self.inspectionYAML = nil
            let canonical = String(decoding: try encoder.encode(validated), as: UTF8.self)
            created = MobileNewConfiguredSession(canonical, &error)
        }
        guard let session = created else {
            throw error ?? NSError(domain: "MihomoBridge", code: 1)
        }
        self.session = session
        self.qualityCacheRoot = qualityCacheRoot
        self.resourceRoot = resourceRoot
        self.stateRoot = stateRoot
    }

    public var resourcesPending: Bool { session.resourcesPending() }

    public func makeResourcePreparation(configuration: RuntimeConfiguration, resourceRoot: URL?, stateRoot: URL?) throws -> GoResourcePreparation {
        guard case let .mihomo(yaml, selections) = configuration.outbound else { throw GoControlError.resourcesUnavailable }
        let choices = String(decoding: try JSONEncoder().encode(selections), as: UTF8.self)
        let preparation = try session.newResourcePreparation(yaml, selectionsJSON: choices, resourceRoot: resourceRoot?.path ?? "",
                                                            stateRoot: stateRoot?.path ?? "", mtu: Int32(configuration.mtu))
        return GoResourcePreparation(preparation)
    }

    public func makeProviderUpdate(kind: ResourceKind, name: String) throws -> GoResourcePreparation {
        guard let inspectionYAML else { throw GoControlError.resourcesUnavailable }
        let preparation = try session.newProviderUpdate(inspectionYAML, resourceRoot: resourceRoot?.path ?? "",
                                                        stateRoot: stateRoot?.path ?? "", kind: kind.rawValue, name: name)
        return GoResourcePreparation(preparation)
    }

    public func writePacket(_ packet: Data) throws {
        try session.submitPacket(packet)
    }

    public func readPacket() throws -> Data {
        try session.readPacket()
    }

    public func close() throws {
        try session.close()
    }

    public func proxyCatalog() throws -> ProxyCatalog {
        var error: NSError?
        let json = session.proxiesJSON(&error)
        if let error { throw error }
        guard json.utf8.count <= 1_048_576 else { throw GoControlError.responseTooLarge }
        return try JSONDecoder().decode(ProxyCatalog.self, from: Data(json.utf8))
    }

    public func providers() throws -> [RuntimeProviderSummary] {
        var error: NSError?
        let json = session.providersJSON(&error)
        if let error { throw error }
        guard json.utf8.count <= 1_048_576 else { throw GoControlError.responseTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([RuntimeProviderSummary].self, from: Data(json.utf8))
    }

    public func configurationPage(offset: Int, expectedID: String?) throws -> EffectiveConfigurationPage {
        try inspectionLock.withLock {
            guard let inspectionYAML, offset >= 0 else { throw GoControlError.resourcesUnavailable }
            if offset == 0 {
                let id = UUID().uuidString
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("effective-" + id + ".yaml")
                try session.writeEffectiveConfiguration(inspectionYAML, path: url.path)
                defer { try? FileManager.default.removeItem(at: url) }
                inspectionFile = try FileHandle(forReadingFrom: url)
                inspectionID = id
            }
            guard let handle = inspectionFile, let id = inspectionID, offset == 0 || expectedID == id else {
                throw GoControlError.resourcesUnavailable
            }
            let size = try handle.seekToEnd()
            guard UInt64(offset) < size else { throw GoControlError.resourcesUnavailable }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: 32 * 1024) ?? Data()
            let next = offset + data.count
            return EffectiveConfigurationPage(sessionID: id, data: data, nextOffset: UInt64(next) < size ? next : nil)
        }
    }

    public func exitIP(requestID: Int64, forceRefresh: Bool = false) throws -> ExitIP {
        var error: NSError?
        let json = session.exitIPQualityJSON(forRequest: requestID, forceRefresh: forceRefresh, cacheDirectory: qualityCacheRoot?.path ?? "", error: &error)
        if let error { throw error }
        return try ExitIP.decodeQuality(Data(json.utf8))
    }

    public func cancelExitIP() { session.cancelExitIP() }

    public func cancelExitIP(requestID: Int64) { session.cancelExitIP(forRequest: requestID) }

    public func setMode(_ mode: String) throws {
        try session.setMode(mode)
    }

    public func selectProxy(group: String, name: String) throws {
        try session.selectProxy(group, name: name)
    }

    public func testProxy(name: String, settings: ProxyDelaySettings = ProxyDelaySettings()) throws -> Int64 {
        try settings.validate()
        var error: NSError?
        let json = session.testProxyResultJSON(name, url: settings.url, timeoutMS: Int32(settings.timeoutMilliseconds), error: &error)
        if let error { throw error }
        let result = try JSONDecoder().decode(ProxyDelayCoreResult.self, from: Data(json.utf8))
        if result.status == "success" { return result.delayMilliseconds }
        guard let failure = ProxyDelayFailure(rawValue: result.status) else { throw ProxyDelayFailure.failed }
        throw failure
    }

    public func cancelTests() { session.cancelTests() }

    public func runtimeSnapshot() throws -> RuntimeSnapshot {
        var error: NSError?
        let json = session.runtimeSnapshotJSON(&error)
        if let error { throw error }
        guard json.utf8.count <= 1_048_576 else { throw GoControlError.responseTooLarge }
        return try JSONDecoder().decode(RuntimeSnapshot.self, from: Data(json.utf8))
    }

    public func closeConnection(id: String) throws {
        try session.closeConnection(id)
    }

    public func closeAllConnections(expectedSessionID: String) throws {
        try session.closeAllConnections(expectedSessionID)
    }

    public func clearDNSCache(expectedSessionID: String) throws {
        try session.clearDNSCache(expectedSessionID)
    }

    public func sharingStatus() throws -> ProxySharingStatus {
        var error: NSError?
        let json = session.sharingStatusJSON(&error)
        if let error { throw error }
        return try JSONDecoder().decode(ProxySharingStatus.self, from: Data(json.utf8))
    }

    public func configureSharing(_ configuration: ProxySharingConfiguration) throws -> ProxySharingStatus {
        let data = try JSONEncoder().encode(configuration)
        var error: NSError?
        let json = session.configureSharing(String(decoding: data, as: UTF8.self), error: &error)
        if let error { throw error }
        return try JSONDecoder().decode(ProxySharingStatus.self, from: Data(json.utf8))
    }

    public static func networkPlan(configuration: RuntimeConfiguration) throws -> TunnelNetworkPlan {
        guard case let .mihomo(yaml, _) = configuration.outbound else {
            return try TunnelNetworkPlan(configuration: configuration)
        }
        var error: NSError?
        let json = MobileYAMLNetworkSettings(yaml, &error)
        if let error { throw error }
        return try TunnelNetworkPlan(configuration: configuration, yamlSettings: Data(json.utf8))
    }
}

private enum GoControlError: Error, LocalizedError {
    case responseTooLarge
    case resourcesUnavailable
    case stateUnavailable

    var errorDescription: String? {
        switch self {
        case .responseTooLarge: return "The core response exceeds the size limit."
        case .stateUnavailable: return "The persistent core state directory is unavailable."
        case .resourcesUnavailable: return "The runtime resource bundle is unavailable."
        }
    }
}

private struct ProxyDelayCoreResult: Decodable {
    let status: String
    let delayMilliseconds: Int64
}

public final class GoResourcePreparation: @unchecked Sendable {
    private let preparation: MobileResourcePreparation
    fileprivate init(_ preparation: MobileResourcePreparation) {
        self.preparation = preparation
    }
    public func cancel() { preparation.cancel() }
    public func setMemoryBudget(_ bytes: Int) { preparation.setMemoryBudget(Int64(bytes)) }
    public func updateProvider() throws { try preparation.updateProvider() }
    public func prepare(for activation: TunnelLifecycle.Activation, snapshotRoot: URL) throws -> TunnelLifecycle.Activation {
        try preparation.prepare()
        return try YAMLResourceActivation.stageResources(preparation, for: activation, snapshotRoot: snapshotRoot)
    }
}
