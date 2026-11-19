import Foundation

public struct HTTPQualityResult: Sendable {
    public let latencies: [Double]
    public let attempted: Int
    public let downloadBytesPerSecond: Double?
    public let uploadBytesPerSecond: Double?
    public let errors: [String]
    public var averageLatency: Double? { latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count) }
    public var jitter: Double? {
        guard latencies.count > 1 else { return nil }
        return zip(latencies.dropFirst(), latencies).map { abs($0 - $1) }.reduce(0, +) / Double(latencies.count - 1)
    }
    public var failurePercent: Double { attempted == 0 ? 0 : 100 * Double(attempted - latencies.count) / Double(attempted) }
    public init(latencies: [Double], attempted: Int, downloadBytesPerSecond: Double?, uploadBytesPerSecond: Double?, errors: [String] = []) {
        self.latencies = latencies; self.attempted = attempted
        self.downloadBytesPerSecond = downloadBytesPerSecond; self.uploadBytesPerSecond = uploadBytesPerSecond
        self.errors = errors
    }
}

struct HTTPTransferResult: Sendable {
    let received: Int
    let sent: Int64
    let seconds: Double
}

extension NetworkDiagnostics {
    public static func quality(download: String, upload: String) async throws -> HTTPQualityResult {
        try await quality(download: download, upload: upload) { request, maximum in
            try await LimitedHTTPDiagnosticTransfer().run(request, maximumBytes: maximum)
        }
    }

    static func quality(download: String, upload: String,
                        transfer: (URLRequest, Int) async throws -> HTTPTransferResult) async throws -> HTTPQualityResult {
        let downloadURL = try diagnosticURL(download)
        let uploadURL = try diagnosticURL(upload)
        var latencies: [Double] = [], errors: [String] = []
        let attempts = 5, limit = 2 * 1024 * 1024
        for _ in 0..<attempts {
            try Task.checkCancellation()
            var request = URLRequest(url: downloadURL); request.httpMethod = "HEAD"
            do { latencies.append(try await transfer(request, 0).seconds * 1_000) }
            catch { try Task.checkCancellation(); errors.append("延迟请求失败：\(qualityErrorDescription(error))") }
        }
        var downloadRate: Double?, uploadRate: Double?
        var downloadRequest = URLRequest(url: downloadURL)
        downloadRequest.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        do {
            let result = try await transfer(downloadRequest, limit)
            downloadRate = Double(result.received) / max(result.seconds, 0.001)
        } catch { try Task.checkCancellation(); errors.append("下载失败：\(qualityErrorDescription(error))") }
        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploadRequest.httpBody = Data(repeating: 0x5a, count: limit)
        do {
            let result = try await transfer(uploadRequest, 64 * 1024)
            guard result.sent > 0 else { throw NetworkDiagnosticError.invalidResponse("未记录到上传字节。") }
            uploadRate = Double(result.sent) / max(result.seconds, 0.001)
        } catch { try Task.checkCancellation(); errors.append("上传失败：\(qualityErrorDescription(error))") }
        return HTTPQualityResult(latencies: latencies, attempted: attempts, downloadBytesPerSecond: downloadRate,
                                 uploadBytesPerSecond: uploadRate, errors: errors)
    }

    private static func qualityErrorDescription(_ error: Error) -> String {
        let original = error as NSError
        var current: NSError? = original
        var details: [String] = []
        for _ in 0..<4 {
            guard let value = current else { break }
            details.append("\(value.domain) \(value.code)")
            if let domain = value.userInfo["_kCFStreamErrorDomainKey"] as? NSNumber,
               let code = value.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber {
                details.append("CFStream \(domain.intValue)/\(code.intValue)")
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let description = (error as? NetworkDiagnosticError)?.localizedDescription ?? networkErrorDescription(original)
        return "\(description) [\(details.joined(separator: "; "))]"
    }

    private static func networkErrorDescription(_ error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return "网络请求失败。" }
        switch URLError.Code(rawValue: error.code) {
        case .secureConnectionFailed: return "TLS 安全连接失败。"
        case .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            return "服务器证书验证失败。"
        case .clientCertificateRejected, .clientCertificateRequired: return "客户端证书认证失败。"
        case .timedOut: return "请求超时。"
        case .cannotFindHost, .dnsLookupFailed: return "无法解析服务器地址。"
        case .cannotConnectToHost: return "无法连接服务器。"
        case .networkConnectionLost: return "网络连接中断。"
        case .notConnectedToInternet: return "网络未连接。"
        case .cancelled: return "请求已取消。"
        default: return "网络请求失败。"
        }
    }

    private static func diagnosticURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw NetworkDiagnosticError.invalidInput("请输入不含用户名和密码的 HTTPS 测试地址。上传端点需支持 POST。")
        }
        return url
    }
}

final class LimitedHTTPDiagnosticTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let queue = OperationQueue()
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<HTTPTransferResult, Error>?
    private var maximumBytes = 0
    private var received = 0
    private var sent: Int64 = 0
    private var started: TimeInterval = 0
    private var cancelled = false

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        queue.maxConcurrentOperationCount = 1
        super.init()
    }

    func run(_ request: URLRequest, maximumBytes: Int) async throws -> HTTPTransferResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation { [self] in
                    self.continuation = continuation
                    guard !cancelled else { finish(.failure(CancellationError())); return }
                    self.maximumBytes = maximumBytes
                    configuration.timeoutIntervalForRequest = 10
                    configuration.timeoutIntervalForResource = 20
                    configuration.urlCache = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    configuration.httpCookieStorage = nil
                    configuration.urlCredentialStorage = nil
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    self.session = session
                    var request = request
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    let task = session.dataTask(with: request)
                    self.task = task
                    started = ProcessInfo.processInfo.systemUptime
                    task.resume()
                }
            }
        } onCancel: {
            self.queue.addOperation { self.cancelled = true; self.finish(.failure(CancellationError())) }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(NetworkDiagnosticError.invalidResponse("测试服务器返回非成功 HTTP 状态。")))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(NetworkDiagnosticError.invalidResponse("测试端点发生重定向，请使用最终 HTTPS 地址。")))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += min(data.count, max(0, maximumBytes - received))
        if received >= maximumBytes { finish(.success(result())) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { sent = totalBytesSent }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
        else { finish(.success(result())) }
    }

    private func result() -> HTTPTransferResult {
        HTTPTransferResult(received: received, sent: max(sent, task?.countOfBytesSent ?? 0),
                           seconds: ProcessInfo.processInfo.systemUptime - started)
    }

    private func finish(_ result: Result<HTTPTransferResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        continuation.resume(with: result)
    }
}
