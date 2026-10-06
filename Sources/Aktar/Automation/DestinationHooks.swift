import Foundation

/// A destination's After Upload hooks: the same webhooks and scripts as a
/// watched folder's Automation (`WatchHookRunner`), run after each upload
/// made by hand and each replace. Nothing here holds up the upload, and a
/// failing hook is announced at most once a minute per destination.
@MainActor
final class DestinationHooks {
    static let shared = DestinationHooks()

    private var lastFailureNotice: [UUID: Date] = [:]
    private static let noticeInterval: TimeInterval = 60

    struct Upload {
        let fileURL: URL
        let filename: String
        let byteSize: Int64
        let objectKey: String
        let link: String
        var replaced = false
        /// The upload's short link, if it has one.
        var shortUrl: String? = nil
    }

    func run(after upload: Upload, destination: DestinationConfig) {
        let hooks = (destination.hooks ?? []).filter(\.enabled)
        guard !hooks.isEmpty else { return }
        let payload = Self.payload(upload, destination: destination)
        for hook in hooks {
            Task { [weak self] in
                do {
                    try await WatchHookRunner.run(hook, payload: payload)
                } catch {
                    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self?.failed(hook, destinationID: destination.id, reason: reason)
                }
            }
        }
    }

    /// Test in the destination form: a sample upload. Throws what went wrong.
    static func test(_ hook: WatchHook, destination: DestinationConfig) async throws {
        let sample = Upload(
            fileURL: URL(fileURLWithPath: "/tmp/example.png"),
            filename: "example.png",
            byteSize: 12345,
            objectKey: "example.png",
            link: "https://example.com/example.png"
        )
        try await WatchHookRunner.run(hook, payload: payload(sample, destination: destination))
    }

    static func payload(_ upload: Upload, destination: DestinationConfig) -> WatchHookPayload {
        WatchHookPayload(
            event: upload.replaced ? "upload.replaced" : "upload.succeeded",
            destination: .init(id: destination.id.uuidString, name: destination.name),
            file: .init(path: upload.fileURL.path, name: upload.filename, size: upload.byteSize),
            upload: .init(key: upload.objectKey, url: upload.link, destinationID: destination.id.uuidString, reused: false, shortUrl: upload.shortUrl)
        )
    }

    private func failed(_ hook: WatchHook, destinationID: UUID, reason: String) {
        if let last = lastFailureNotice[destinationID], Date.now.timeIntervalSince(last) < Self.noticeInterval { return }
        lastFailureNotice[destinationID] = .now
        NotificationService.notifyHookFailed(target: hook.target, reason: reason)
    }
}
