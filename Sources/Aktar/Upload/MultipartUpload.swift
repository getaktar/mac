import Foundation

/// A multipart upload that hasn't been completed yet. Kept on disk so a
/// failed upload can be retried, even after a restart, from the parts the
/// provider already has instead of from the start.
struct MultipartSession: Codable, Sendable, Identifiable {
    struct Part: Codable, Sendable, Equatable {
        let number: Int
        let eTag: String
    }

    var id = UUID()
    let destinationID: UUID
    let bucket: String
    let objectKey: String
    let uploadId: String
    let partSize: Int64
    let fileSize: Int64
    let fileModifiedAt: Date?
    /// Path of the file whose bytes are sent. Together with its size and
    /// modification date, or its SHA-256, it recognizes the same file when
    /// it's uploaded again.
    let sourcePath: String
    let contentHash: String?
    var completedParts: [Part]
    let createdAt: Date

    /// Older ones are aborted rather than resumed.
    static let maxAge: TimeInterval = 7 * 86_400

    var isStale: Bool { Date.now.timeIntervalSince(createdAt) > Self.maxAge }
}

/// What identifies the file being uploaded, for finding its session.
struct MultipartFileIdentity: Sendable {
    let path: String
    let size: Int64
    let modifiedAt: Date?
    let contentHash: String?

    init(fileURL: URL, size: Int64, contentHash: String?) {
        path = fileURL.standardizedFileURL.path
        self.size = size
        modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        self.contentHash = contentHash
    }

    func matches(_ session: MultipartSession) -> Bool {
        guard session.fileSize == size else { return false }
        if let contentHash, let saved = session.contentHash { return contentHash == saved }
        return session.sourcePath == path && Self.sameDate(session.fileModifiedAt, modifiedAt)
    }

    private static func sameDate(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSince(b)) < 1
    }
}

/// The open multipart sessions, in a small JSON file in Application
/// Support (inside the app's container).
actor MultipartSessionStore {
    static let shared = MultipartSessionStore()

    private var sessions: [MultipartSession] = []
    private let fileURL: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aktar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("multipart-sessions.json")
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = (try? decoder.decode([MultipartSession].self, from: data)) ?? []
        }
    }

    var all: [MultipartSession] { sessions }

    /// The session for the same file going to the same destination and
    /// bucket, if there is one.
    func session(destinationID: UUID, bucket: String, identity: MultipartFileIdentity) -> MultipartSession? {
        sessions.last { $0.destinationID == destinationID && $0.bucket == bucket && identity.matches($0) }
    }

    func save(_ session: MultipartSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        persist()
    }

    func addPart(_ part: MultipartSession.Part, to id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].completedParts.removeAll { $0.number == part.number }
        sessions[index].completedParts.append(part)
        persist()
    }

    func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Sends a file as an S3 multipart upload: parts of `S3Provider.partSize`
/// read from disk one at a time, up to `S3Provider.maxConcurrentParts` at
/// once, each retried on its own (see `S3Provider.withRetries`). A failure
/// leaves the session in `MultipartSessionStore`, so the next try only
/// sends what the provider doesn't have yet. Cancelling aborts it.
enum MultipartUploader {
    /// `session` continues an earlier upload of the same file; its key is
    /// expected to be `objectKey`. `identity` is saved with a new session
    /// so it can be found again. `onSession` gets the session in use, for
    /// Retry and Cancel.
    static func upload(
        provider: S3Provider,
        fileURL: URL,
        fileSize: Int64,
        objectKey: String,
        contentType: String,
        session existing: MultipartSession?,
        identity: MultipartFileIdentity?,
        reporter: ProgressReporter,
        onSession: @escaping @MainActor (MultipartSession) -> Void = { _ in }
    ) async throws {
        let store = MultipartSessionStore.shared
        var session = existing
        var serverParts: [Int: UploadedPart] = [:]
        if let resumed = session {
            do {
                serverParts = try await provider.uploadedParts(objectKey: resumed.objectKey, uploadId: resumed.uploadId)
            } catch MultipartUploadError.noSuchUpload {
                await store.remove(resumed.id)
                session = nil
            }
        }

        let partSize = session?.partSize ?? S3Provider.partSize(forFileSize: fileSize)
        let partCount = S3Provider.partCount(fileSize: fileSize, partSize: partSize)
        func length(of number: Int) -> Int64 {
            min(partSize, fileSize - Int64(number - 1) * partSize)
        }

        if session == nil {
            let uploadId = try await provider.createMultipartUpload(objectKey: objectKey, contentType: contentType)
            let created = MultipartSession(
                destinationID: provider.config.id,
                bucket: provider.config.bucket,
                objectKey: objectKey,
                uploadId: uploadId,
                partSize: partSize,
                fileSize: fileSize,
                fileModifiedAt: identity?.modifiedAt,
                sourcePath: identity?.path ?? fileURL.standardizedFileURL.path,
                contentHash: identity?.contentHash,
                completedParts: [],
                createdAt: .now
            )
            await store.save(created)
            session = created
        }
        guard var session else { return }
        await onSession(session)

        // What the provider confirms it has, and only whole parts of the
        // expected size, counts as done.
        var done: [Int: String] = [:]
        for (number, part) in serverParts where number >= 1 && number <= partCount && part.size == length(of: number) {
            done[number] = part.eTag
        }
        if existing != nil {
            session.completedParts = done.map { MultipartSession.Part(number: $0.key, eTag: $0.value) }
            await store.save(session)
        }
        reporter.addCompleted(done.keys.reduce(0) { $0 + length(of: $1) })

        let pending = (1...partCount).filter { done[$0] == nil }
        let sessionID = session.id
        let uploadId = session.uploadId
        let key = session.objectKey
        do {
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var iterator = pending.makeIterator()
                func addNext() -> Bool {
                    guard let number = iterator.next() else { return false }
                    let offset = Int64(number - 1) * partSize
                    let size = length(of: number)
                    group.addTask {
                        let eTag = try await provider.uploadPart(
                            fileURL: fileURL,
                            partNumber: number,
                            offset: offset,
                            length: size,
                            objectKey: key,
                            uploadId: uploadId
                        ) { sent in
                            reporter.update(part: number, sent: sent)
                        }
                        await store.addPart(.init(number: number, eTag: eTag), to: sessionID)
                        reporter.finish(part: number, size: size)
                        return (number, eTag)
                    }
                    return true
                }
                for _ in 0..<S3Provider.maxConcurrentParts where !addNext() { break }
                while let (number, eTag) = try await group.next() {
                    done[number] = eTag
                    _ = addNext()
                }
            }
            try await provider.completeMultipartUpload(objectKey: key, uploadId: uploadId, parts: done)
            await store.remove(sessionID)
        } catch {
            if error is CancellationError || Task.isCancelled {
                // Not tied to this (cancelled) task, so it still goes out.
                Task.detached {
                    await provider.abortMultipartUpload(objectKey: key, uploadId: uploadId)
                    await store.remove(sessionID)
                }
                throw CancellationError()
            }
            if case MultipartUploadError.noSuchUpload = error {
                await store.remove(sessionID)
                throw StorageError.unknown(String(localized: "The provider discarded the unfinished upload. Try again to start over."))
            }
            throw error
        }
    }

    /// At launch: aborts sessions older than `MultipartSession.maxAge`,
    /// ones whose destination is gone, and ones whose file has changed
    /// since. Sessions for files that can't be checked (a temporary copy
    /// that's gone, a file outside the sandbox's reach) stay until they're
    /// too old, as they can still be found by their SHA-256.
    static func cleanUp(destinations: [DestinationConfig]) async {
        let store = MultipartSessionStore.shared
        for session in await store.all {
            let destination = destinations.first { $0.id == session.destinationID }
            let changed = fileChanged(session)
            guard session.isStale || changed || destination == nil || destination?.bucket != session.bucket else { continue }
            if let destination, destination.bucket == session.bucket,
               let credentials = try? KeychainService.load(for: destination.id) {
                let provider = S3Provider(config: destination, credentials: credentials)
                await provider.abortMultipartUpload(objectKey: session.objectKey, uploadId: session.uploadId)
            }
            await store.remove(session.id)
        }
    }

    private static func fileChanged(_ session: MultipartSession) -> Bool {
        guard session.contentHash == nil,
              let values = try? URL(fileURLWithPath: session.sourcePath).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return false }
        if Int64(size) != session.fileSize { return true }
        if let saved = session.fileModifiedAt, let current = values.contentModificationDate {
            return abs(saved.timeIntervalSince(current)) >= 1
        }
        return false
    }
}
