import AppKit

enum WatchHookError: LocalizedError {
    case invalidURL
    case insecureURL
    case status(Int)
    case scriptMissing(String)
    case scriptFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "The webhook address isn't a valid http or https URL.")
        case .insecureURL:
            return String(localized: "Use an https:// webhook address. Plain http:// only works for this Mac or your local network.")
        case .status(let code):
            return String(localized: "The webhook answered with HTTP \(String(code)).")
        case .scriptMissing(let name):
            return String(localized: "\u{201C}\(name)\u{201D} isn't in Aktar's scripts folder.")
        case .scriptFailed(let message):
            return message
        case .timedOut:
            return String(localized: "It took longer than 10 seconds.")
        }
    }
}

/// Runs a watched folder's Automation after an upload. Nothing here holds
/// up the upload or the next one; a hook gets 10 seconds.
///
/// A webhook gets the payload POSTed as JSON. A script gets it on standard
/// input, with the link, the key, the file and the folder as its four
/// arguments. A sandboxed app can only run scripts the user put in its
/// Application Scripts folder (~/Library/Application Scripts/com.getaktar.mac),
/// which is also why they can't be given environment variables.
enum WatchHookRunner {
    static let timeout: TimeInterval = 10

    static func run(_ hook: WatchHook, payload: WatchHookPayload) async throws {
        switch hook.kind {
        case .webhook:
            try await postWebhook(to: hook.target, payload: payload)
        case .script:
            try await runScript(named: hook.target, payload: payload)
        }
    }

    private static func postWebhook(to target: String, payload: WatchHookPayload) async throws {
        switch WatchHookAddress.check(target) {
        case .allowed: break
        case .invalid: throw WatchHookError.invalidURL
        case .insecure: throw WatchHookError.insecureURL
        }
        guard let url = URL(string: target.trimmingCharacters(in: .whitespaces)) else {
            throw WatchHookError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        request.setValue("Aktar/\(version)", forHTTPHeaderField: "User-Agent")
        request.httpBody = payload.json()
        do {
            // A redirect to another host would get the upload's details
            // sent on; its 3xx answer counts as a failure instead.
            let (_, response) = try await URLSession.shared.data(for: request, delegate: SameHostRedirects())
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw WatchHookError.status(status) }
        } catch let error as URLError where error.code == .timedOut {
            throw WatchHookError.timedOut
        }
    }

    // MARK: - Scripts

    /// ~/Library/Application Scripts/com.getaktar.mac, which macOS makes for
    /// the app and only the user can put files in.
    static var scriptsFolder: URL? {
        try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    /// The scripts there, by name.
    static func availableScripts() -> [String] {
        guard let folder = scriptsFolder,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func openScriptsFolder() {
        guard let folder = scriptsFolder else { return }
        NSWorkspace.shared.open(folder)
    }

    private static func runScript(named name: String, payload: WatchHookPayload) async throws {
        guard !name.contains("/"), let folder = scriptsFolder else { throw WatchHookError.scriptMissing(name) }
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw WatchHookError.scriptMissing(name) }
        let task: NSUserUnixTask
        do {
            task = try NSUserUnixTask(url: url)
        } catch {
            throw WatchHookError.scriptFailed(error.localizedDescription)
        }
        // The payload is far smaller than a pipe's buffer, so it's written
        // in full before the script starts.
        let input = Pipe()
        input.fileHandleForWriting.write(payload.json())
        try? input.fileHandleForWriting.close()
        task.standardInput = input.fileHandleForReading
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let arguments = [payload.upload.url, payload.upload.key, payload.file.path, payload.folder.name]

        // Whichever comes first: the script ending or the time running out.
        // A script that runs longer is left to finish on its own.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            task.execute(withArguments: arguments) { error in
                once.resume(error.map { WatchHookError.scriptFailed($0.localizedDescription) })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(WatchHookError.timedOut)
            }
        }
    }
}

/// Follows a webhook's redirects only within its own host.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let target = request.url,
              WatchHookAddress.mayFollowRedirect(from: original, to: target) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Resumes a continuation the first time only.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
