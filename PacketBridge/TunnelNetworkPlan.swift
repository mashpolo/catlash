import Foundation
import NetworkExtension

public struct TunnelNetworkPlan: Sendable, Equatable {
    public let mtu: Int
    public let ipv4DefaultRoute: Bool
    public let ipv6DefaultRoute: Bool
    public let dnsServers: [String]
    public let ipv4Address: String
    public let ipv4PrefixLength: Int
    public let ipv6Address: String
    public let ipv6PrefixLength: Int
    public let ipv4ExcludedRoutes: [Route]
    public let ipv6ExcludedRoutes: [Route]

    public var ipv4SubnetMask: String {
        Self.subnetMask(prefixLength: ipv4PrefixLength)
    }

    public init(configuration: RuntimeConfiguration, yamlSettings: Data? = nil) throws {
        mtu = configuration.mtu
        if case .mihomo = configuration.outbound {
            guard let yamlSettings, yamlSettings.count <= 16_384,
                  let settings = try? JSONDecoder().decode(YAMLSettings.self, from: yamlSettings),
                  (0...32).contains(settings.ipv4PrefixLength), (0...128).contains(settings.ipv6PrefixLength),
                  (settings.ipv4ExcludedRoutes ?? []).allSatisfy({ (0...32).contains($0.prefixLength) }),
                  (settings.ipv6ExcludedRoutes ?? []).allSatisfy({ (0...128).contains($0.prefixLength) }) else {
                throw TunnelNetworkPlanError.invalidCoreSettings
            }
            ipv4DefaultRoute = true
            ipv6DefaultRoute = settings.ipv6
            dnsServers = settings.dnsServers
            ipv4Address = settings.ipv4Address
            ipv4PrefixLength = settings.ipv4PrefixLength
            ipv6Address = settings.ipv6Address
            ipv6PrefixLength = settings.ipv6PrefixLength
            ipv4ExcludedRoutes = settings.ipv4ExcludedRoutes ?? []
            ipv6ExcludedRoutes = settings.ipv6ExcludedRoutes ?? []
        } else {
            ipv4DefaultRoute = false
            ipv6DefaultRoute = false
            dnsServers = []
            ipv4Address = "198.18.0.1"
            ipv4PrefixLength = 30
            ipv6Address = "fd00:198:18::1"
            ipv6PrefixLength = 126
            ipv4ExcludedRoutes = []
            ipv6ExcludedRoutes = []
        }
    }

    public func networkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: [ipv4Address], subnetMasks: [ipv4SubnetMask])
        ipv4.includedRoutes = ipv4DefaultRoute ? [.default()] : [
            NEIPv4Route(destinationAddress: "1.1.1.1", subnetMask: "255.255.255.255")
        ]
        ipv4.excludedRoutes = ipv4ExcludedRoutes.map {
            NEIPv4Route(destinationAddress: $0.address, subnetMask: Self.subnetMask(prefixLength: $0.prefixLength))
        }
        settings.ipv4Settings = ipv4
        if ipv6DefaultRoute {
            let ipv6 = NEIPv6Settings(addresses: [ipv6Address], networkPrefixLengths: [NSNumber(value: ipv6PrefixLength)])
            ipv6.includedRoutes = [.default()]
            ipv6.excludedRoutes = ipv6ExcludedRoutes.map {
                NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefixLength))
            }
            settings.ipv6Settings = ipv6
        }
        if !dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: dnsServers)
            dns.matchDomains = [""]
            settings.dnsSettings = dns
        }
        settings.mtu = NSNumber(value: mtu)
        return settings
    }

    public struct Route: Decodable, Sendable, Equatable {
        public let address: String
        public let prefixLength: Int
    }

    private static func subnetMask(prefixLength: Int) -> String {
        let mask = prefixLength == 0 ? 0 : UInt32.max << (32 - prefixLength)
        return [24, 16, 8, 0].map { String((mask >> $0) & 255) }.joined(separator: ".")
    }

    private struct YAMLSettings: Decodable {
        let ipv6: Bool
        let dnsServers: [String]
        let ipv4Address: String
        let ipv4PrefixLength: Int
        let ipv6Address: String
        let ipv6PrefixLength: Int
        let ipv4ExcludedRoutes: [Route]?
        let ipv6ExcludedRoutes: [Route]?
    }
}

private enum TunnelNetworkPlanError: Error, LocalizedError {
    case invalidCoreSettings
    var errorDescription: String? { "The core returned invalid tunnel network settings." }
}
