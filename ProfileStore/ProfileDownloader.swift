import Foundation

public protocol ProfileDownloader: Sendable {
    func download(from url: URL, maximumBytes: Int) async throws -> Data
    func download(request: URLRequest, maximumBytes: Int) async throws -> Data
    func downloadSubscription(from url: URL, maximumBytes: Int) async throws -> SubscriptionDownload
}

public extension ProfileDownloader {
    func downloadSubscription(from url: URL, maximumBytes: Int) async throws -> SubscriptionDownload {
        SubscriptionDownload(data: try await download(from: url, maximumBytes: maximumBytes))
    }

    func download(request: URLRequest, maximumBytes: Int) async throws -> Data {
        guard request.allHTTPHeaderFields?.isEmpty != false else { throw ProfileDownloadError.headersUnsupported }
        guard let url = request.url else { throw ProfileStoreError.invalidSourceURL }
        return try await download(from: url, maximumBytes: maximumBytes)
    }
}

public enum ProfileDownloadError: Error, Equatable, LocalizedError {
    case headersUnsupported
    case transport(URLError.Code)

    public var errorDescription: String? {
        switch self {
        case .headersUnsupported:
            return "This downloader cannot apply the provider's HTTP headers."
        case .transport(let code):
            let category: String
            switch code {
            case .timedOut: category = "网络请求超时"
            case .cannotFindHost, .dnsLookupFailed: category = "DNS 解析失败"
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                category = "TLS 连接或证书验证失败"
            case .notConnectedToInternet: category = "当前没有网络连接"
            case .cannotConnectToHost: category = "无法连接服务器"
            case .networkConnectionLost: category = "网络连接已中断"
            default: category = "网络请求失败"
            }
            return "\(category)（URL 错误 \(code.rawValue)）。"
        }
    }
}

public struct URLSessionProfileDownloader: ProfileDownloader {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    public func download(from url: URL, maximumBytes: Int) async throws -> Data {
        try await download(request: URLRequest(url: url), maximumBytes: maximumBytes)
    }

    public func download(request original: URLRequest, maximumBytes: Int) async throws -> Data {
        try await fetch(request: original, maximumBytes: maximumBytes).data
    }

    public func downloadSubscription(from url: URL, maximumBytes: Int) async throws -> SubscriptionDownload {
        try await fetch(request: URLRequest(url: url), maximumBytes: maximumBytes)
    }

    private func fetch(request original: URLRequest, maximumBytes: Int) async throws -> SubscriptionDownload {
        guard let url = original.url, maximumBytes > 0 else { throw ProfileStoreError.invalidSourceURL }
        try validateSubscriptionURL(url)
        do {
            var request = original
            request.timeoutInterval = 30
            if request.value(forHTTPHeaderField: "User-Agent") == nil {
                request.setValue("Clash/FlClash-iOS", forHTTPHeaderField: "User-Agent")
            }
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw ProfileStoreError.downloadFailed }
            guard (200..<300).contains(response.statusCode) else { throw ProfileStoreError.httpStatus(response.statusCode) }
            guard response.expectedContentLength <= maximumBytes else { throw ProfileStoreError.tooLarge }
            if let finalURL = response.url { try validateSubscriptionURL(finalURL) }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw ProfileStoreError.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return SubscriptionDownload(data: data, usage: SubscriptionUsage(header: response.value(forHTTPHeaderField: "Subscription-Userinfo")))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw ProfileDownloadError.transport(error.code)
        } catch let error as ProfileStoreError {
            throw error
        } catch {
            throw ProfileStoreError.downloadFailed
        }
    }
}

func validateSubscriptionURL(_ url: URL) throws {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = url.host, !host.isEmpty else { throw ProfileStoreError.invalidSourceURL }
}
