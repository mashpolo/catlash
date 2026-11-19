import Foundation
import Network

public struct ExitIP: Codable, Equatable, Sendable {
    public let ip: String
    public let countryCode: String?
    public let organization: String?
    public let networkType: String
    public let quality: String
    public let qualityExplanation: String
    public let qualityDetails: IPQuality?
    public let failures: [IPQualityFailure]
    public let checkedAt: Date?
    public let cached: Bool
    public var addressFamily: String { Self.isIPv4(ip) ? "IPv4" : "IPv6" }

    public static func decodeQuality(_ data: Data) throws -> ExitIP {
        guard data.count <= 65_536 else { throw ExitIPError.invalidResponse }
        let response = try JSONDecoder().decode(QualityResponse.self, from: data)
        guard isIPv4(response.ip) || isNativeIPv6(response.ip) else { throw ExitIPError.invalidResponse }
        let details = response.quality
        return ExitIP(
            ip: response.ip,
            countryCode: countryCode(response.countryCode),
            organization: text(details?.organization, maximumBytes: 512) ?? text(response.organization, maximumBytes: 512),
            networkType: details?.type.label ?? "未分类",
            quality: details?.level.label ?? "未知",
            qualityExplanation: details?.explanation ?? "已取得出口 IP；各来源暂未提供可用的分类信息，质量未知。",
            qualityDetails: details,
            failures: response.failures ?? [],
            checkedAt: response.checkedAt.map(Date.init(timeIntervalSince1970:)),
            cached: response.cached
        )
    }

    public static func decodeIPQuery(_ data: Data) throws -> ExitIP {
        guard data.count <= 65_536 else { throw ExitIPError.invalidResponse }
        let response = try JSONDecoder().decode(IPQueryResponse.self, from: data)
        guard response.error == nil, let ip = response.ip, isIPv4(ip) || isNativeIPv6(ip) else {
            throw ExitIPError.invalidResponse
        }
        let country = countryCode(response.location?.country_code)
        let organization = text(response.isp?.org, maximumBytes: 512) ?? text(response.isp?.isp, maximumBytes: 512)
        let type: IPQualityNetworkType?
        if response.risk?.is_datacenter == true { type = .hosting }
        else if response.risk?.is_mobile == true { type = .mobile }
        else { type = nil }
        let details = type.map {
            IPQuality(source: .ipQuery, type: $0, organization: organization, asn: nil,
                      isProxy: false, isVpn: false, isTor: response.risk?.is_tor == true,
                      isAbuser: false, inferred: false)
        }
        return ExitIP(ip: ip, countryCode: country, organization: organization,
                      networkType: details?.type.label ?? "未分类",
                      quality: response.risk?.is_tor == true ? IPQualityLevel.risky.label : details?.level.label ?? "未知",
                      qualityExplanation: details?.explanation ?? "已取得出口 IP；IPQuery 分类信息不足，暂不评定质量。",
                      qualityDetails: details, failures: [], checkedAt: nil, cached: false)
    }

    private static func isIPv4(_ ip: String) -> Bool {
        ip.utf8.count <= 15 && ip.split(separator: ".", omittingEmptySubsequences: false).count == 4 &&
            ip.utf8.allSatisfy({ $0 == 46 || (48...57).contains($0) }) && IPv4Address(ip) != nil
    }

    private static func isNativeIPv6(_ ip: String) -> Bool {
        guard ip.utf8.count <= 45, !ip.contains("%"), let address = IPv6Address(ip) else { return false }
        let prefix = address.rawValue.prefix(12)
        return prefix != Data(repeating: 0, count: 10) + Data([0xff, 0xff])
    }

    private static func countryCode(_ value: String?) -> String? {
        guard let code = text(value, maximumBytes: 2)?.uppercased(), code.utf8.count == 2,
              code.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return code
    }

    private static func text(_ value: String?, maximumBytes: Int) -> String? {
        guard let value, value.utf8.count <= maximumBytes else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct QualityResponse: Decodable {
    let ip: String
    let countryCode: String?
    let organization: String?
    let quality: IPQuality?
    let failures: [IPQualityFailure]?
    let checkedAt: TimeInterval?
    let cached: Bool
}

private struct IPQueryResponse: Decodable {
    let ip: String?
    let error: String?
    let isp: ISP?
    let location: Location?
    let risk: Risk?

    private enum CodingKeys: String, CodingKey { case ip, error, isp, location, risk }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ip = try values.decodeIfPresent(String.self, forKey: .ip)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        isp = try? values.decodeIfPresent(ISP.self, forKey: .isp)
        location = try? values.decodeIfPresent(Location.self, forKey: .location)
        risk = try? values.decodeIfPresent(Risk.self, forKey: .risk)
    }

    struct ISP: Decodable { let org: String?; let isp: String? }
    struct Location: Decodable { let country_code: String? }
    struct Risk: Decodable {
        let is_datacenter: Bool?
        let is_mobile: Bool?
        let is_tor: Bool?
    }
}

private enum ExitIPError: LocalizedError {
    case invalidResponse
    var errorDescription: String? { "出口 IP 服务返回了无效数据。" }
}
