import Foundation

public struct ProxySharingConfiguration: Codable, Sendable {
    public var enabled: Bool
    public var listenAddress: String
    public var httpPort: Int
    public var socksPort: Int
    public var username: String
    public var password: String

    public init(enabled: Bool, listenAddress: String = "0.0.0.0", httpPort: Int = 7890, socksPort: Int = 7891,
                username: String = "", password: String = "") {
        self.enabled = enabled
        self.listenAddress = listenAddress
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.username = username
        self.password = password
    }
}

public struct ProxySharingStatus: Codable, Sendable {
    public let enabled: Bool
    public let listenAddress: String
    public let httpPort: Int
    public let socksPort: Int
}
