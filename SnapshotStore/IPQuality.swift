import Foundation

public enum IPQualitySource: String, Codable, Sendable {
    case identMe, ipApiCom, ipQuery, ipLocate, ipApiIs, proxyCheck

    public var label: String {
        switch self {
        case .identMe: return "ident.me"
        case .ipApiCom: return "ip-api.com"
        case .ipQuery: return "IPQuery"
        case .ipLocate: return "IPLocate"
        case .ipApiIs: return "ipapi.is"
        case .proxyCheck: return "proxycheck.io"
        }
    }
}

public enum IPQualityNetworkType: String, Codable, Sendable {
    case residential, mobile, business, hosting

    public var label: String {
        switch self {
        case .residential: return "住宅"
        case .mobile: return "移动"
        case .business: return "商业"
        case .hosting: return "机房"
        }
    }
}

public enum IPQualityLevel: String, Codable, Sendable {
    case good, normal, risky

    public var label: String {
        switch self {
        case .good: return "良好"
        case .normal: return "普通"
        case .risky: return "有风险"
        }
    }
}

public struct IPQuality: Codable, Equatable, Sendable {
    public let source: IPQualitySource
    public let type: IPQualityNetworkType
    public let organization: String?
    public let asn: Int?
    public let isProxy: Bool
    public let isVpn: Bool
    public let isTor: Bool
    public let isAbuser: Bool
    public let inferred: Bool

    public var level: IPQualityLevel {
        if isTor || isAbuser { return .risky }
        return type == .hosting ? .normal : .good
    }

    public var flags: [String] {
        [(isTor, "Tor"), (isAbuser, "滥用"), (isVpn, "VPN"), (isProxy, "代理")]
            .compactMap { $0.0 ? $0.1 : nil }
    }

    public var explanation: String {
        let basis = inferred
            ? "所有来源均未明确返回类型；依据 \(source.label) 未标记机房或移动网络，推断为住宅。"
            : "依据 \(source.label) 返回的网络类型和风险标记分类。"
        return basis + "Tor 或滥用标记为有风险，机房为普通，住宅、移动和商业为良好；VPN 和代理标记单独展示。质量不代表网速或安全保证。"
    }
}

public enum IPQualitySourceStatus: String, Codable, Sendable {
    case noType, timeout, rateLimited, failed, ipMismatch

    public var label: String {
        switch self {
        case .noType: return "无法判定类型"
        case .timeout: return "超时"
        case .rateLimited: return "限流"
        case .failed: return "服务失败"
        case .ipMismatch: return "出站 IP 不一致"
        }
    }
}

public struct IPQualityFailure: Codable, Equatable, Sendable {
    public let source: IPQualitySource
    public let status: IPQualitySourceStatus
}
