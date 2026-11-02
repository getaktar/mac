import Foundation
import UniformTypeIdentifiers

/// A link copied to the clipboard, downloaded when its upload starts and
/// then uploaded like any file (docs/capture-and-instant-links.md).
struct RemoteSource: Sendable, Hashable {
    let url: URL
    /// The name guessed from the link before anything is downloaded. The
    /// download's own name replaces it, unless the upload was renamed.
    let suggestedName: String

    init(url: URL) {
        self.url = url
        suggestedName = RemoteFileName.suggestedName(for: url)
    }
}

/// The name a downloaded file goes by.
enum RemoteFileName {
    /// Longer names are cut, keeping the extension.
    static let maxLength = 120

    /// Content types that say nothing about the file, so the link's own
    /// extension is kept.
    private static let genericTypes: Set<String> = [
        "application/octet-stream", "binary/octet-stream", "application/binary", "application/unknown",
        "application/x-download", "application/force-download", "application/download", "text/plain",
    ]

    /// From the link alone: its last path segment, or "download".
    static func suggestedName(for url: URL) -> String {
        sanitized(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent) ?? "download"
    }

    /// Content-Disposition's filename, else the link's last path segment
    /// (after redirects), else "download"; with the extension of
    /// `mimeType` when the name has none, or one of another kind of file.
    static func resolve(url: URL, contentDisposition: String?, mimeType: String?) -> String {
        var name = contentDisposition.flatMap(filename(fromContentDisposition:)).flatMap(sanitized) ?? suggestedName(for: url)
        let mime = mimeType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let mime, !genericTypes.contains(mime), let type = UTType(mimeType: mime),
              let preferred = type.preferredFilenameExtension else { return limited(name) }
        let ext = (name as NSString).pathExtension
        if ext.isEmpty {
            name += "." + preferred
        } else if let current = UTType(filenameExtension: ext), !current.conforms(to: type), !type.conforms(to: current) {
            name = (name as NSString).deletingPathExtension + "." + preferred
        }
        return limited(name)
    }

    /// `filename*=UTF-8''...` (RFC 6266/5987) when there is one, otherwise
    /// `filename="..."` or `filename=...`.
    static func filename(fromContentDisposition header: String) -> String? {
        if let match = header.firstMatch(of: /(?i)filename\*\s*=\s*([^;]+)/) {
            let value = String(match.1).trimmingCharacters(in: .whitespaces)
            let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3, let decoded = String(parts[2]).removingPercentEncoding, !decoded.isEmpty {
                return decoded
            }
        }
        if let match = header.firstMatch(of: /(?i)(?:^|;)\s*filename\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^;]+))/) {
            let raw = match.1.map(String.init)?.replacingOccurrences(of: "\\\"", with: "\"")
                ?? match.2.map { String($0).trimmingCharacters(in: .whitespaces) }
            if let raw, !raw.isEmpty { return raw }
        }
        return nil
    }

    /// One safe path segment, or nil when nothing usable is left.
    private static func sanitized(_ raw: String) -> String? {
        // A name with folders in it ("a/b.png", "..\\c.png") keeps its last part.
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return nil }
        let cleaned = ObjectKeyGenerator.sanitizedFilename(trimmed)
        return cleaned == "file" && trimmed != "file" ? nil : cleaned
    }

    private static func limited(_ name: String) -> String {
        guard name.count > maxLength else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let room = max(1, maxLength - (ext.isEmpty ? 0 : ext.count + 1))
        let cut = String(base.prefix(room))
        return ext.isEmpty ? cut : cut + "." + ext
    }
}

enum RemoteDownloadError: Error, LocalizedError, Equatable {
    case status(Int)
    /// The link opened a web page rather than a file.
    case webPage
    case tooLarge
    case empty

    var errorDescription: String? {
        switch self {
        case .status(let code):
            return String(localized: "The link couldn\u{2019}t be downloaded (HTTP \(code)).")
        case .webPage:
            return String(localized: "The link opens a web page, not a file. Copy the link of the image or file itself.")
        case .tooLarge:
            return String(localized: "The linked file is bigger than the free space on this Mac.")
        case .empty:
            return String(localized: "The link gave an empty file.")
        }
    }
}

/// Downloads a copied link into a folder: the response must be a file
/// (not a web page), no bigger than the disk can take while keeping 2 GB
/// free. No cookies or cache are used or kept. A dropped connection comes
/// back as a `URLError`, which the upload queue retries.
final class RemoteDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Result: Sendable {
        let fileURL: URL
        let filename: String
    }

    /// Kept free on the disk.
    static let reserveBytes: Int64 = 2 * 1024 * 1024 * 1024

    private let source: RemoteSource
    private let folder: URL
    private let maxBytes: Int64
    private let onProgress: @MainActor (Double) -> Void
    private let lock = NSLock()
    /// The last fraction reported, so progress goes out in steps of 1%.
    private var reported = 0.0
    private var continuation: CheckedContinuation<Result, Error>?
    private var outcome: Swift.Result<Result, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    private init(source: RemoteSource, folder: URL, maxBytes: Int64, onProgress: @escaping @MainActor (Double) -> Void) {
        self.source = source
        self.folder = folder
        self.maxBytes = maxBytes
        self.onProgress = onProgress
    }

    /// Downloads `source` into `folder` (which must exist), as the name
    /// `RemoteFileName` gives it.
    static func download(_ source: RemoteSource, into folder: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> Result {
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        let downloader = RemoteDownloader(source: source, folder: folder, maxBytes: max(0, free - reserveBytes), onProgress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.start(continuation)
            }
        } onCancel: {
            downloader.cancel()
        }
    }

    private func start(_ continuation: CheckedContinuation<Result, Error>) {
        lock.lock()
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        configuration.httpAdditionalHeaders = ["User-Agent": "Aktar/\(version) (+https://getaktar.com)"]
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: source.url)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Swift.Result<Result, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let continuation = continuation
        self.continuation = nil
        let session = session
        lock.unlock()
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
            downloadTask.cancel()
            finish(.failure(RemoteDownloadError.tooLarge))
            return
        }
        if totalBytesExpectedToWrite > 0 {
            report(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }
    }

    private func report(_ fraction: Double) {
        lock.lock()
        let due = fraction >= 1 || fraction - reported >= 0.01
        if due { reported = fraction }
        lock.unlock()
        guard due else { return }
        let onProgress = onProgress
        Task { @MainActor in onProgress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            // A busy or failing server may answer later; anything else won't.
            if response.statusCode >= 500 || response.statusCode == 429 || response.statusCode == 408 {
                finish(.failure(URLError(.badServerResponse)))
            } else {
                finish(.failure(RemoteDownloadError.status(response.statusCode)))
            }
            return
        }
        let mime = response.mimeType?.lowercased()
        if mime == "text/html" || mime == "application/xhtml+xml" {
            finish(.failure(RemoteDownloadError.webPage))
            return
        }
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0 else {
            finish(.failure(RemoteDownloadError.empty))
            return
        }
        let name = RemoteFileName.resolve(
            url: response.url ?? source.url,
            contentDisposition: response.value(forHTTPHeaderField: "Content-Disposition"),
            mimeType: response.mimeType
        )
        guard let destination = TempFiles.fileURL(named: name, in: folder) else {
            finish(.failure(RemoteDownloadError.empty))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            // The system deletes `location` once this returns.
            try FileManager.default.moveItem(at: location, to: destination)
            report(1)
            finish(.success(Result(fileURL: destination, filename: destination.lastPathComponent)))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }

    /// Redirects stay on http(s).
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let scheme = request.url?.scheme?.lowercased()
        completionHandler(scheme == "http" || scheme == "https" ? request : nil)
    }
}
