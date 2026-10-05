import Foundation
import NIOHTTP1
import SotoS3
import SotoSignerV4

/// Sending file bytes to S3. The body goes through URLSession, streamed
/// from disk (or one part at a time), so files of any size never sit in
/// memory whole and the progress is real. Requests are signed with SigV4
/// and an unsigned payload, as hashing a multi-GB body up front would read
/// it twice. Creating, completing and aborting multipart uploads, which
/// carry no file data, go through Soto.
extension S3Provider {
    /// Bigger files are sent as a multipart upload.
    static let multipartThreshold: Int64 = 64 * 1024 * 1024
    static let maxConcurrentParts = 4
    /// Waits before each retry of a request that failed for a reason that
    /// might pass (dropped connection, timeout, 5xx, 429).
    static let retryDelays: [Double] = [1, 2, 4, 8, 16]

    /// At least 16 MiB, and big enough for 5 TB to fit in 10,000 parts,
    /// in whole MiB.
    static func partSize(forFileSize size: Int64) -> Int64 {
        let mib: Int64 = 1024 * 1024
        let perPart = (size + 8999) / 9000
        let rounded = (perPart + mib - 1) / mib * mib
        return max(16 * mib, rounded)
    }

    static func partCount(fileSize: Int64, partSize: Int64) -> Int {
        max(1, Int((fileSize + partSize - 1) / partSize))
    }

    static func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// A destination set to `shortCache` sends every file with a one-minute
    /// cache time, so a replaced file shows up everywhere within a minute.
    var cacheControl: String? {
        config.shortCache == true ? "public, max-age=60" : nil
    }

    // MARK: - Single PUT

    /// One PUT streamed from the file. `progress` gets the bytes sent.
    func putObject(fileURL: URL, objectKey: String, contentType: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        var headers = ["Content-Type": contentType]
        if let cacheControl { headers["Cache-Control"] = cacheControl }
        if let disposition = ContentTypeResolver.contentDisposition(names: [objectKey, fileURL.lastPathComponent], contentType: contentType) {
            headers["Content-Disposition"] = disposition
        }
        try await withRetries {
            let request = try signedRequest(method: .PUT, key: objectKey, headers: headers)
            let delegate = UploadProgressDelegate(onProgress: progress)
            let (data, response) = try await Self.transferSession.upload(for: request, fromFile: fileURL, delegate: delegate)
            _ = try check(data, response)
        }
    }

    /// One small PUT from memory, such as a thumbnail.
    func putObject(data: Data, objectKey: String, contentType: String) async throws {
        try await withRetries {
            var headers = ["Content-Type": contentType]
            if let cacheControl { headers["Cache-Control"] = cacheControl }
            let request = try signedRequest(method: .PUT, key: objectKey, headers: headers)
            let (body, response) = try await Self.transferSession.upload(for: request, from: data)
            _ = try check(body, response)
        }
    }

    /// The object at `key` and when it was last written, or nil when there's
    /// no such object. For small objects only: the body is read into memory,
    /// and anything over `maxBytes` is refused.
    func getObject(key: String, maxBytes: Int) async throws -> (data: Data, lastModified: Date?)? {
        try await withRetries {
            let request = try signedRequest(method: .GET, key: key)
            let (data, response) = try await Self.transferSession.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
            let checked = try check(data, response)
            guard data.count <= maxBytes else { throw StorageError.unknown("The object is too large.") }
            let lastModified = checked.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate)
            return (data, lastModified)
        }
    }

    /// Downloads the object at `key` to `destination`, unless it's larger
    /// than `maxBytes`. False when there's no such object.
    func download(key: String, to destination: URL, maxBytes: Int64) async throws -> Bool {
        try await withRetries {
            let request = try signedRequest(method: .GET, key: key)
            let (location, response) = try await Self.transferSession.download(for: request)
            defer { try? FileManager.default.removeItem(at: location) }
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { return false }
            _ = try check(Data(), response)
            guard try Self.fileSize(of: location) <= maxBytes else {
                throw StorageError.unknown("The object is too large.")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            return true
        }
    }

    /// "Wed, 21 Oct 2026 07:28:00 GMT", as HTTP headers write dates.
    private static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }

    // MARK: - Multipart

    /// `fileName` is the name of the file the parts come from, which counts
    /// for active content (see `ContentTypeResolver`) like the key does.
    func createMultipartUpload(objectKey: String, contentType: String, fileName: String) async throws -> String {
        let disposition = ContentTypeResolver.contentDisposition(names: [objectKey, fileName], contentType: contentType)
        do {
            let output = try await s3.createMultipartUpload(.init(
                bucket: config.bucket,
                cacheControl: cacheControl,
                contentDisposition: disposition,
                contentType: contentType,
                key: objectKey
            ))
            guard let uploadId = output.uploadId else {
                throw StorageError.unknown(String(localized: "The provider didn't start the upload."))
            }
            return uploadId
        } catch let error as StorageError {
            throw error
        } catch {
            throw Self.mapError(error, bucket: config.bucket)
        }
    }

    /// The parts the provider already has, by part number. Throws
    /// `MultipartUploadError.noSuchUpload` when the upload was completed,
    /// aborted or expired meanwhile.
    func uploadedParts(objectKey: String, uploadId: String) async throws -> [Int: UploadedPart] {
        var parts: [Int: UploadedPart] = [:]
        var marker: String?
        do {
            repeat {
                let output = try await s3.listParts(.init(bucket: config.bucket, key: objectKey, partNumberMarker: marker, uploadId: uploadId))
                for part in output.parts ?? [] {
                    guard let number = part.partNumber, let eTag = part.eTag else { continue }
                    parts[number] = UploadedPart(eTag: eTag, size: part.size ?? 0)
                }
                marker = output.isTruncated == true ? output.nextPartNumberMarker : nil
            } while marker != nil
        } catch {
            if String(describing: error).lowercased().contains("nosuchupload") { throw MultipartUploadError.noSuchUpload }
            throw Self.mapError(error, bucket: config.bucket)
        }
        return parts
    }

    /// Sends bytes `offset..<offset+length` of the file as part
    /// `partNumber`, read from disk on their own, and returns its ETag.
    func uploadPart(
        fileURL: URL,
        partNumber: Int,
        offset: Int64,
        length: Int64,
        objectKey: String,
        uploadId: String,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> String {
        let body = try Self.readPart(of: fileURL, offset: offset, length: length)
        return try await withRetries {
            progress(0)
            let request = try signedRequest(
                method: .PUT,
                key: objectKey,
                query: [("partNumber", String(partNumber)), ("uploadId", uploadId)]
            )
            let delegate = UploadProgressDelegate(onProgress: progress)
            let (data, response) = try await Self.transferSession.upload(for: request, from: body, delegate: delegate)
            let http = try check(data, response)
            guard let eTag = http.value(forHTTPHeaderField: "ETag"), !eTag.isEmpty else {
                throw StorageError.unknown(String(localized: "The provider didn't confirm part \(partNumber) of the upload."))
            }
            return eTag
        }
    }

    func completeMultipartUpload(objectKey: String, uploadId: String, parts: [Int: String]) async throws {
        let completed = parts.keys.sorted().map { S3.CompletedPart(eTag: parts[$0], partNumber: $0) }
        do {
            _ = try await s3.completeMultipartUpload(.init(
                bucket: config.bucket,
                key: objectKey,
                multipartUpload: .init(parts: completed),
                uploadId: uploadId
            ))
        } catch {
            if String(describing: error).lowercased().contains("nosuchupload") { throw MultipartUploadError.noSuchUpload }
            throw Self.mapError(error, bucket: config.bucket)
        }
    }

    /// Frees the parts stored so far. Errors are ignored: an upload that's
    /// already gone is what this is for, and the provider's own cleanup
    /// (or a lifecycle rule) takes care of one that couldn't be reached.
    func abortMultipartUpload(objectKey: String, uploadId: String) async {
        _ = try? await s3.abortMultipartUpload(.init(bucket: config.bucket, key: objectKey, uploadId: uploadId))
    }

    // MARK: - Requests

    private static let transferSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Per request, while no bytes move; a big body can take as long as
        // it needs.
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = maxConcurrentParts * 2
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private func signedRequest(method: HTTPMethod, key: String, query: [(String, String)] = [], headers: [String: String] = [:]) throws -> URLRequest {
        guard var components = URLComponents(string: config.endpoint.contains("://") ? config.endpoint : "https://\(config.endpoint)"),
              components.host?.isEmpty == false else {
            throw StorageError.unknown(String(localized: "The endpoint URL is not valid."))
        }
        let encodedKey = Self.encodePath(key)
        if config.forcePathStyle {
            components.percentEncodedPath = "/\(config.bucket)/\(encodedKey)"
        } else {
            components.host = "\(config.bucket).\(components.host ?? "")"
            components.percentEncodedPath = "/\(encodedKey)"
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        let signer = AWSSigner(
            credentials: StaticCredential(
                accessKeyId: credentials.accessKeyId,
                secretAccessKey: credentials.secretAccessKey,
                sessionToken: credentials.sessionToken
            ),
            name: "s3",
            region: config.region
        )
        // The signer's own encoding of the path and query is what's signed,
        // so it's also what's sent.
        guard let raw = components.url, let url = signer.processURL(url: raw) else {
            throw StorageError.unknown(String(localized: "The endpoint URL is not valid."))
        }
        var httpHeaders = HTTPHeaders()
        for (name, value) in headers {
            httpHeaders.add(name: name, value: value)
        }
        let signed = signer.signHeaders(url: url, method: method, headers: httpHeaders, body: .unsignedPayload)
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        for (name, value) in signed where name.lowercased() != "host" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// The response, when it's a success. Failures that may pass are
    /// thrown as `TransientFailure`, for `withRetries`.
    private func check(_ data: Data, _ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw TransientFailure(message: String(localized: "The provider didn't answer."))
        }
        if (200..<300).contains(http.statusCode) { return http }
        let (code, message) = LifecycleXML.error(in: String(decoding: data, as: UTF8.self))
        if http.statusCode >= 500 || http.statusCode == 429 || code == "SlowDown" {
            throw TransientFailure(message: message ?? code ?? "HTTP \(http.statusCode)")
        }
        switch (http.statusCode, code) {
        case (_, "NoSuchUpload"):
            throw MultipartUploadError.noSuchUpload
        case (_, "NoSuchBucket"):
            throw StorageError.bucketNotFound(config.bucket)
        case (_, "InvalidAccessKeyId"), (_, "SignatureDoesNotMatch"):
            throw StorageError.invalidCredentials
        case (403, _), (_, "AccessDenied"):
            throw StorageError.accessDenied
        default:
            throw StorageError.unknown(message ?? code ?? "HTTP \(http.statusCode)")
        }
    }

    /// Runs `operation` again after each of `retryDelays` while it fails
    /// in a way that might pass.
    private func withRetries<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard attempt < Self.retryDelays.count, Self.isTransient(error) else { throw Self.finalError(error) }
                try await Task.sleep(for: .seconds(Self.retryDelays[attempt]))
                attempt += 1
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if error is TransientFailure { return true }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .badServerResponse,
             .cannotLoadFromNetwork, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }

    private static func finalError(_ error: Error) -> Error {
        if let failure = error as? TransientFailure { return StorageError.network(failure.message) }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return CancellationError() }
            return StorageError.network(urlError.localizedDescription)
        }
        return error
    }

    private static func readPart(of url: URL, offset: Int64, length: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: Int(length)) ?? Data()
        guard data.count == Int(length) else {
            throw StorageError.unknown(String(localized: "The file changed while it was being uploaded."))
        }
        return data
    }
}

struct UploadedPart: Sendable, Equatable {
    let eTag: String
    let size: Int64
}

enum MultipartUploadError: Error {
    /// The provider no longer knows the upload: it was completed, aborted
    /// or cleaned up.
    case noSuchUpload
}

private struct TransientFailure: Error {
    let message: String
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onProgress(totalBytesSent)
    }
}

/// Adds up the bytes of finished parts and the ones on their way, and
/// passes the share done to the UI at most ten times a second.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private let report: (@MainActor (Double) -> Void)?
    private var completed: Int64 = 0
    private var inFlight: [Int: Int64] = [:]
    private var lastReport = Date.distantPast

    init(total: Int64, report: (@MainActor (Double) -> Void)?) {
        self.total = max(total, 1)
        self.report = report
    }

    /// Bytes of `part` sent so far.
    func update(part: Int, sent: Int64) {
        lock.lock()
        inFlight[part] = sent
        let value = fraction()
        lock.unlock()
        send(value, force: false)
    }

    func finish(part: Int, size: Int64) {
        lock.lock()
        inFlight[part] = nil
        completed += size
        let value = fraction()
        lock.unlock()
        send(value, force: true)
    }

    /// Parts the provider already had, when resuming.
    func addCompleted(_ bytes: Int64) {
        lock.lock()
        completed += bytes
        let value = fraction()
        lock.unlock()
        send(value, force: true)
    }

    private func fraction() -> Double {
        min(1, Double(completed + inFlight.values.reduce(0, +)) / Double(total))
    }

    private func send(_ value: Double, force: Bool) {
        guard let report else { return }
        lock.lock()
        let now = Date()
        let due = force || now.timeIntervalSince(lastReport) >= 0.1
        if due { lastReport = now }
        lock.unlock()
        guard due else { return }
        Task { @MainActor in report(value) }
    }
}
