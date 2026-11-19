import Foundation

public struct RuntimeConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public let mtu: Int
    public let outbound: Outbound
    public let resources: String?
    public let profileID: String?
    public let allowDeferredResources: Bool

    public init(version: Int = 1, mtu: Int = 1280, outbound: Outbound = .direct, resources: String? = nil, profileID: String? = nil, allowDeferredResources: Bool = false) {
        self.version = version
        self.mtu = mtu
        self.outbound = outbound
        self.resources = resources
        self.profileID = profileID
        self.allowDeferredResources = allowDeferredResources
    }

    public enum Outbound: Equatable, Sendable {
        case direct
        case mihomo(yaml: String, selections: [String: String] = [:])
        case socks5(server: String, port: Int, username: String = "", password: String = "", udp: Bool = true)
    }

    private enum CodingKeys: String, CodingKey { case version, mtu, outbound, resources, profileID, allowDeferredResources }

    public init(from decoder: Decoder) throws {
        try rejectUnknownFields(decoder, allowed: ["version", "mtu", "outbound", "resources", "profileID", "allowDeferredResources"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        mtu = try values.decode(Int.self, forKey: .mtu)
        outbound = try values.decode(Outbound.self, forKey: .outbound)
        resources = try values.decodeIfPresent(String.self, forKey: .resources)
        profileID = try values.decodeIfPresent(String.self, forKey: .profileID)
        allowDeferredResources = try values.decodeIfPresent(Bool.self, forKey: .allowDeferredResources) ?? false
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(mtu, forKey: .mtu)
        try values.encode(outbound, forKey: .outbound)
        try values.encodeIfPresent(resources, forKey: .resources)
        try values.encodeIfPresent(profileID, forKey: .profileID)
        if allowDeferredResources { try values.encode(true, forKey: .allowDeferredResources) }
    }

    public func validate() throws {
        guard version == 1 else { throw SnapshotStoreError.unsupportedVersion }
        if allowDeferredResources {
            guard case .mihomo = outbound else { throw SnapshotStoreError.invalidConfiguration }
        }
        guard (1280...9000).contains(mtu) else { throw SnapshotStoreError.invalidMTU }
        if let profileID {
            try CoreStateStore.validateProfileID(profileID)
            guard case .mihomo = outbound else { throw SnapshotStoreError.invalidConfiguration }
        }
        if let resources {
            guard resources.utf8.count == 64,
                  resources.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw SnapshotStoreError.invalidResourceBundle
            }
            guard case .mihomo = outbound else { throw SnapshotStoreError.invalidConfiguration }
        }
        if case let .mihomo(yaml, selections) = outbound {
            guard !yaml.isEmpty, yaml.utf8.count <= 16 * 1024 * 1024,
                  selections.count <= 4096 else { throw SnapshotStoreError.invalidConfiguration }
        }
        if case let .socks5(server, port, username, password, _) = outbound {
            guard !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (1...65_535).contains(port),
                  username.utf8.count <= 255, password.utf8.count <= 255 else {
                throw SnapshotStoreError.invalidOutbound
            }
        }
    }

    public static func decode(_ data: Data) throws -> RuntimeConfiguration {
        guard data.count <= maximumSize else { throw SnapshotStoreError.invalidConfiguration }
        do {
            let configuration = try JSONDecoder().decode(RuntimeConfiguration.self, from: data)
            if case .mihomo = configuration.outbound { return configuration }
            guard data.count <= 16_384 else { throw SnapshotStoreError.invalidConfiguration }
            return configuration
        } catch let error as SnapshotStoreError {
            throw error
        } catch {
            throw SnapshotStoreError.invalidConfiguration
        }
    }

    static let maximumSize = 32 * 1024 * 1024 + 65_536
}

extension RuntimeConfiguration.Outbound: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, server, port, username, password, udp, yaml, selections
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "mihomo":
            try rejectUnknownFields(decoder, allowed: ["type", "yaml", "selections"])
            self = .mihomo(
                yaml: try values.decode(String.self, forKey: .yaml),
                selections: values.contains(.selections) ? try values.decode([String: String].self, forKey: .selections) : [:]
            )
        case "direct":
            try rejectUnknownFields(decoder, allowed: ["type"])
            self = .direct
        case "socks5":
            try rejectUnknownFields(decoder, allowed: ["type", "server", "port", "username", "password", "udp"])
            self = .socks5(
                server: try values.decode(String.self, forKey: .server),
                port: try values.decode(Int.self, forKey: .port),
                username: values.contains(.username) ? try values.decode(String.self, forKey: .username) : "",
                password: values.contains(.password) ? try values.decode(String.self, forKey: .password) : "",
                udp: values.contains(.udp) ? try values.decode(Bool.self, forKey: .udp) : true
            )
        default:
            throw SnapshotStoreError.invalidOutbound
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .mihomo(yaml, selections):
            try values.encode("mihomo", forKey: .type)
            try values.encode(yaml, forKey: .yaml)
            try values.encode(selections, forKey: .selections)
        case .direct:
            try values.encode("direct", forKey: .type)
        case let .socks5(server, port, username, password, udp):
            try values.encode("socks5", forKey: .type)
            try values.encode(server, forKey: .server)
            try values.encode(port, forKey: .port)
            try values.encode(username, forKey: .username)
            try values.encode(password, forKey: .password)
            try values.encode(udp, forKey: .udp)
        }
    }
}

private struct FieldKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownFields(_ decoder: Decoder, allowed: Set<String>) throws {
    let keys = try decoder.container(keyedBy: FieldKey.self).allKeys
    guard keys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw SnapshotStoreError.invalidConfiguration
    }
}

public enum SnapshotStoreError: Error, Equatable, LocalizedError {
    case invalidConfiguration, unsupportedVersion, invalidMTU, invalidOutbound
    case invalidRevision, invalidResourceBundle, missingSnapshot, corruptSnapshot, noSuccessfulSnapshot, storageFailure

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "The runtime configuration is invalid."
        case .unsupportedVersion: return "The runtime configuration version is unsupported."
        case .invalidMTU: return "The tunnel MTU must be between 1280 and 9000."
        case .invalidOutbound: return "The outbound configuration is invalid."
        case .invalidRevision: return "The snapshot revision is invalid."
        case .invalidResourceBundle: return "The resource bundle identifier must be a lowercase SHA-256 hash."
        case .missingSnapshot: return "The requested snapshot is missing."
        case .corruptSnapshot: return "The requested snapshot is damaged."
        case .noSuccessfulSnapshot: return "No successful snapshot is available."
        case .storageFailure: return "The snapshot storage operation failed."
        }
    }
}
