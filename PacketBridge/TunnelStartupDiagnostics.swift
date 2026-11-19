import Foundation
import NetworkExtension

public protocol TunnelStartupFailureDescribing: Error {
    var startupFailureMessage: String { get }
}

public protocol TunnelRuntimeFailureDescribing: Error {
    var runtimeFailureMessage: String { get }
}

public struct TunnelStartupDiagnostic: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case preparing, starting, connected, failed, stopped }

    public let attemptID: UUID
    public let phase: Phase
    public let revision: String?
    public let message: String
    public let updatedAt: Date
    public var stopReason: Int? = nil

    public var disconnectMessage: String? {
        if phase == .failed { return message }
        guard phase == .stopped, let stopReason, stopReason != NEProviderStopReason.userInitiated.rawValue else { return nil }
        return message
    }
}

/// The extension owns writes; the app can open a separate instance for reads.
public final class TunnelStartupDiagnosticsStore: @unchecked Sendable {
    private let url: URL
    private let previousURL: URL
    private let lock = NSLock()

    public init(root: URL) {
        url = root.appendingPathComponent("Library/Application Support/tunnel-startup.json")
        previousURL = root.appendingPathComponent("tunnel-startup.json")
    }

    public func load() throws -> TunnelStartupDiagnostic? {
        let files = FileManager.default
        if !files.fileExists(atPath: url.path) {
            guard files.fileExists(atPath: previousURL.path) else { return nil }
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Publish the complete legacy file without overwriting a newer writer.
            do { try files.linkItem(at: previousURL, to: url) }
            catch let error as CocoaError where error.code == .fileWriteFileExists { }
        }
        return try JSONDecoder().decode(TunnelStartupDiagnostic.self, from: Data(contentsOf: url))
    }

    public func begin(attemptID: UUID, revision: String?, at date: Date = Date()) throws {
        try lock.withLock {
            try write(.init(attemptID: attemptID, phase: .preparing, revision: Self.safeRevision(revision),
                            message: "正在准备配置与资源。", updatedAt: date))
        }
    }

    @discardableResult
    public func record(attemptID: UUID, phase: TunnelStartupDiagnostic.Phase, revision: String? = nil,
                       error: Error? = nil, stopReason: NEProviderStopReason? = nil, at date: Date = Date()) throws -> Bool {
        try lock.withLock {
            guard let current = try load(), current.attemptID == attemptID,
                  current.phase != .failed, current.phase != .stopped,
                  !(current.phase == .connected && (phase == .preparing || phase == .starting)),
                  !(current.phase == .starting && phase == .preparing) else { return false }
            let message: String
            if phase == .failed && current.phase == .connected {
                message = Self.safeRuntimeFailureMessage(error)
            } else if phase == .stopped, let stopReason {
                message = Self.stopMessage(stopReason)
            } else {
                message = Self.message(phase: phase, error: error)
            }
            try write(.init(attemptID: attemptID, phase: phase, revision: Self.safeRevision(revision) ?? current.revision,
                            message: message, updatedAt: date, stopReason: stopReason?.rawValue))
            return true
        }
    }

    private func write(_ diagnostic: TunnelStartupDiagnostic) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(diagnostic).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func safeRevision(_ value: String?) -> String? {
        guard let value, value.utf8.count == 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }

    private static func message(phase: TunnelStartupDiagnostic.Phase, error: Error?) -> String {
        switch phase {
        case .preparing: return "正在准备配置与资源。"
        case .starting: return "正在准备运行资源并启动隧道。"
        case .connected: return "隧道已连接。"
        case .stopped: return "隧道已停止。"
        case .failed: return safeFailureMessage(error)
        }
    }

    private static func stopMessage(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case .userInitiated: return "VPN 已手动断开。"
        case .noNetworkAvailable: return "网络不可用，VPN 已断开。"
        case .unrecoverableNetworkChange: return "切换网络后无法恢复连接，VPN 已断开。"
        case .providerFailed, .connectionFailed: return "系统报告 VPN 连接失败。"
        case .configurationFailed: return "VPN 配置生效失败。"
        case .superceded: return "另一项 VPN 配置已接管连接。"
        case .idleTimeout: return "VPN 因空闲超时而断开。"
        case .sleep: return "设备休眠时系统断开了 VPN。"
        case .appUpdate: return "系统更新应用时停止了 VPN。"
        case .configurationDisabled, .providerDisabled: return "VPN 已被停用。"
        case .configurationRemoved: return "系统已移除 VPN 配置。"
        case .authenticationCanceled: return "验证已取消，VPN 已断开。"
        case .userLogout, .userSwitch: return "系统用户会话发生变化，VPN 已断开。"
        default: return "系统停止了 VPN（原因代码 \(reason.rawValue)）。"
        }
    }

    public static func safeRuntimeFailureMessage(_ error: Error?) -> String {
        if let runtime = error as? TunnelRuntimeFailureDescribing { return runtime.runtimeFailureMessage }
        guard let error else { return "VPN 运行中断，系统未提供具体原因。" }
        let failure = error as NSError
        if ["go", "MihomoBridge"].contains(failure.domain) {
            switch failure.localizedDescription {
            case "packet queue is full": return "VPN 运行中断，内核数据包队列已满。"
            case "packet length is outside the MTU": return "VPN 运行中断，数据包长度超出隧道 MTU。"
            case "invalid IPv4 packet length", "invalid IPv6 packet length", "packet is not IPv4 or IPv6":
                return "VPN 运行中断，内核收到格式无效的数据包。"
            default: return "VPN 内核运行中断（代码 \(failure.code)）。"
            }
        }
        if failure.domain == "NEVPNConnectionErrorDomain" || failure.domain == "NEVPNErrorDomain" {
            return "系统报告 VPN 运行中断（\(failure.domain)，代码 \(failure.code)）。"
        }
        return "VPN 运行中断（代码 \(failure.code)）。"
    }

    public static func safeFailureMessage(_ error: Error?) -> String {
        if let error, let parseFailure = safeConfigurationError(error.localizedDescription) { return parseFailure }
        if let failure = error as? TunnelStartupFailureDescribing { return failure.startupFailureMessage }
        if error is SnapshotStoreError { return "运行配置读取或校验失败。" }
        if error is ResourceBundleError { return "配置资源读取或校验失败。" }
        if let error {
            let networkError = error as NSError
            if networkError.domain == NSURLErrorDomain {
                return networkFailure(URLError.Code(rawValue: networkError.code))
            }
            if ["go", "MihomoBridge"].contains(networkError.domain),
               let resourceFailure = safeCoreResourceFailure(networkError.localizedDescription) {
                return resourceFailure
            }
            let domains = ["go", "MihomoBridge", "NEVPNErrorDomain", "NEVPNConnectionErrorDomain",
                           NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain]
            if domains.contains(networkError.domain) {
                return "隧道启动失败（\(networkError.domain)，代码 \(networkError.code)）。"
            }
            return "隧道启动失败（代码 \(networkError.code)），请检查配置与网络。"
        }
        return "隧道启动失败，请检查配置与网络。"
    }

    private static func networkFailure(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "下载远程资源超时。"
        case .notConnectedToInternet: return "当前网络不可用，无法下载远程资源。"
        case .cancelled: return "连接准备已取消。"
        default: return "下载远程资源时发生网络错误（代码 \(code.rawValue)）。"
        }
    }

    private static func safeCoreResourceFailure(_ message: String) -> String? {
        if message.contains("exceeds tunnel memory budget") { return "可用内存不足，已暂停加载额外规则。" }
        if message.contains("invalid provider health-check options") {
            return "节点订阅健康检查设置无效。"
        }
        if let provider = message.range(of: "rule-provider "),
           let failure = message.range(of: " download failed", range: provider.upperBound..<message.endIndex) {
            let reason = message[failure.upperBound...]
            if reason.contains("context deadline exceeded") || reason.contains("timeout") {
                return "规则资源下载超时。"
            }
        }
        if message.contains("resource download proxy dependency cannot be prepared") {
            return "资源下载所需代理节点无法加载。"
        }
        return nil
    }

    private static func safeConfigurationError(_ message: String) -> String? {
        let prefix = "null is unsupported at "
        guard message.hasPrefix(prefix) else { return nil }
        let path = message.dropFirst(prefix.count)
        guard !path.isEmpty, path.utf8.count <= 160,
              path.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                  || "_.[]-".utf8.contains($0) }) else { return nil }
        return message
    }

}
