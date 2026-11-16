import Foundation

protocol AppUpdateChecking: Sendable {
    func fetchRelease(from manifestURL: URL) async throws -> AppUpdateRelease
}

final class AppUpdateRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let maximumRedirects = 3

    private let lock = NSLock()
    private var redirectCounts: [Int: Int] = [:]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.lock()
        let nextCount = (redirectCounts[task.taskIdentifier] ?? 0) + 1
        redirectCounts[task.taskIdentifier] = nextCount
        lock.unlock()

        let sourceIsSafe = AppUpdateURLPolicy.manifestURL(response.url?.absoluteString) != nil
        let destinationIsSafe = AppUpdateURLPolicy.manifestURL(request.url?.absoluteString) != nil
        let isGET = request.httpMethod?.uppercased() == "GET"
        completionHandler(
            nextCount <= Self.maximumRedirects && sourceIsSafe && destinationIsSafe && isGET
                ? request
                : nil
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        redirectCounts.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }
}

final class AppUpdateService: AppUpdateChecking, @unchecked Sendable {
    private let session: URLSession

    init(configuration: URLSessionConfiguration? = nil) {
        let effectiveConfiguration = configuration
            ?? NetworkTransportPolicy.configuration(for: .brandResource)
        effectiveConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        effectiveConfiguration.urlCache = nil
        effectiveConfiguration.httpShouldSetCookies = false
        session = URLSession(
            configuration: effectiveConfiguration,
            delegate: AppUpdateRedirectDelegate(),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func fetchRelease(from manifestURL: URL) async throws -> AppUpdateRelease {
        guard AppUpdateURLPolicy.manifestURL(manifestURL.absoluteString) == manifestURL else {
            throw AppUpdateError.invalidConfiguration
        }
        var request = URLRequest(
            url: manifestURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: NetworkTransportPolicy.requestTimeout(for: .brandResource)
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  AppUpdateURLPolicy.manifestURL(http.url?.absoluteString) == http.url,
                  Self.isJSONContentType(http.value(forHTTPHeaderField: "Content-Type")),
                  data.count <= AppUpdateManifestLimits.maximumResponseBytes else {
                SafeLog.warning("[Update] manifest rejected category=response_policy")
                throw AppUpdateError.invalidResponse
            }
            let manifest = try JSONDecoder().decode(AppUpdateManifest.self, from: data)
            let release = try manifest.validatedIOSRelease()
            SafeLog.info("[Update] manifest loaded result=validated")
            return release
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw CancellationError()
        } catch let error as AppUpdateError {
            throw error
        } catch {
            SafeLog.warning("[Update] manifest failed category=network_or_decoding")
            throw AppUpdateError.invalidResponse
        }
    }

    static func isJSONContentType(_ value: String?) -> Bool {
        guard let mediaType = value?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return false }
        return mediaType == "application/json" || mediaType.hasSuffix("+json")
    }
}
