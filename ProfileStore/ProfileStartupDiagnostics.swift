import Foundation

extension ProfileResourceError: TunnelStartupFailureDescribing {
    public var startupFailureMessage: String {
        switch self {
        case let .httpStatus(kind, _, status): return "\(kind.diagnosticName)下载失败：HTTP \(status)。"
        case let .missingLocalFile(kind, _, _): return "缺少已授权的\(kind.diagnosticName)文件。"
        case .requiresConnectedProxy: return "远程资源需要通过代理下载，代理尚未就绪。"
        case .invalidHeader: return "远程资源的请求头配置无效。"
        case .invalidProvider, .unsupportedSource: return "远程资源的来源配置无效。"
        case let .downloadFailed(kind, _, failure): return "\(kind.diagnosticName)下载失败：\(failure.startupFailureMessage)"
        case let .failed(kind, _, _): return "\(kind.diagnosticName)准备失败。"
        }
    }
}

extension ProfileDownloadError: TunnelStartupFailureDescribing {
    public var startupFailureMessage: String {
        switch self {
        case .transport(let code): return TunnelStartupDiagnosticsStore.safeFailureMessage(URLError(code))
        case .headersUnsupported: return "当前下载器不支持所需的请求头。"
        }
    }
}

extension ProfileStoreError: TunnelStartupFailureDescribing {
    public var startupFailureMessage: String {
        switch self {
        case .downloadFailed: return "远程资源下载失败，请检查网络和资源来源。"
        case .httpStatus(let status): return "远程资源下载失败：HTTP \(status)。"
        case .tooLarge: return "配置或远程资源超过大小限制。"
        case .invalidSourceURL: return "远程资源地址无效。"
        default: return "配置文件读取或校验失败。"
        }
    }
}

private extension ResourceKind {
    var diagnosticName: String {
        if let geodata { return geodata.fileName }
        switch self {
        case .proxyProvider: return "节点资源"
        case .ruleProvider: return "规则资源"
        default: return "本地资源"
        }
    }
}
