import Foundation

public struct RuntimeConnectionFilter: Sendable {
    public enum Status: String, CaseIterable, Sendable { case all = "全部", active = "活动中", ended = "已结束", failed = "失败" }
    public enum Order: String, CaseIterable, Sendable { case newest = "最近开始", oldest = "最早开始", upload = "上传最多", download = "下载最多", total = "流量最多", host = "域名或目标" }
    public var query = ""
    public var network = ""
    public var host = ""
    public var source = ""
    public var destination = ""
    public var rule = ""
    public var proxy = ""
    public var status = Status.all
    public var order = Order.newest
    public init() {}

    public func apply(_ values: [RuntimeConnection]) -> [RuntimeConnection] {
        values.filter { value in
            (network.isEmpty || value.network == network) &&
            matches(value) && runtimeTextMatches(query, [value.host, value.source, value.destination, value.rule, value.proxy, value.network, value.error]) &&
            runtimeTextMatches(host, [value.host]) && runtimeTextMatches(source, [value.source]) &&
            runtimeTextMatches(destination, [value.destination]) && runtimeTextMatches(rule, [value.rule]) && runtimeTextMatches(proxy, [value.proxy])
        }.sorted { left, right in
            switch order {
            case .newest: if left.startedAt != right.startedAt { return left.startedAt > right.startedAt }
            case .oldest: if left.startedAt != right.startedAt { return left.startedAt < right.startedAt }
            case .upload: if left.upload != right.upload { return left.upload > right.upload }
            case .download: if left.download != right.download { return left.download > right.download }
            case .total:
                let a = Double(left.upload) + Double(left.download), b = Double(right.upload) + Double(right.download)
                if a != b { return a > b }
            case .host:
                let a = left.host.isEmpty ? left.destination : left.host, b = right.host.isEmpty ? right.destination : right.host
                if a != b { return a.localizedStandardCompare(b) == .orderedAscending }
            }
            return left.id < right.id
        }
    }

    private func matches(_ value: RuntimeConnection) -> Bool {
        switch status {
        case .all: true
        case .active: value.endedAt == 0
        case .ended: value.endedAt != 0
        case .failed: !value.error.isEmpty
        }
    }
}

public struct RuntimeDNSQuery: Codable, Sendable, Identifiable {
    public let id: String
    public let domain: String
    public let type: String
    public let initiator: String
    public let upstream: String
    public let mode: String
    public let cached: Bool
    public let startedAt: Int64
    public let durationMS: Int64
    public let status: String
    public let responseCode: String
    public let answers: [String]
    public let omittedAnswers: Int

    public var statusText: String {
        switch status {
        case "success": "成功"
        case "timeout": "超时"
        case "cancelled": "已取消"
        default: "失败"
        }
    }
    public var modeText: String {
        switch mode {
        case "hosts": "Hosts"
        case "fakeip": "Fake-IP"
        case "disabled-ipv6": "IPv6 解析未启用"
        default: cached ? "解析缓存" : "解析器"
        }
    }
}

public struct RuntimeDNSFilter: Sendable {
    public enum Cache: String, CaseIterable, Sendable { case all = "全部", hit = "缓存命中", miss = "未命中缓存" }
    public enum Order: String, CaseIterable, Sendable { case newest = "最近查询", oldest = "最早查询", duration = "耗时最长", domain = "域名" }
    public var query = ""
    public var type = ""
    public var status = ""
    public var initiator = ""
    public var mode = ""
    public var cache = Cache.all
    public var order = Order.newest
    public init() {}

    public func apply(_ values: [RuntimeDNSQuery]) -> [RuntimeDNSQuery] {
        values.filter {
            (type.isEmpty || $0.type == type) && (status.isEmpty || $0.status == status) &&
            (initiator.isEmpty || $0.initiator == initiator) && (mode.isEmpty || $0.mode == mode) &&
            (cache == .all || (cache == .hit ? $0.cached : !$0.cached)) &&
            runtimeTextMatches(query, [$0.domain, $0.upstream, $0.responseCode] + $0.answers)
        }.sorted { left, right in
            switch order {
            case .newest: if left.startedAt != right.startedAt { return left.startedAt > right.startedAt }
            case .oldest: if left.startedAt != right.startedAt { return left.startedAt < right.startedAt }
            case .duration: if left.durationMS != right.durationMS { return left.durationMS > right.durationMS }
            case .domain: if left.domain != right.domain { return left.domain.localizedStandardCompare(right.domain) == .orderedAscending }
            }
            return left.id < right.id
        }
    }
}

private func runtimeTextMatches(_ query: String, _ fields: [String]) -> Bool {
    query.split(whereSeparator: \.isWhitespace).allSatisfy { token in
        fields.contains { $0.localizedCaseInsensitiveContains(String(token)) }
    }
}
