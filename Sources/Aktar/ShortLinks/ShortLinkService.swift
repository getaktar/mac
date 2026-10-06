import Foundation
import SwiftData

/// Short links for uploads: making them after an upload or by hand,
/// cleaning them up when files are deleted, moved or expire, and their
/// stats. The one place the Library, the upload pipeline and the local API
/// go through. Short links never hold up or fail a file operation
/// (docs/short-links.md, "Behavior rules").
@MainActor
final class ShortLinkService {
    private let destinationStore: DestinationStore
    private let modelContext: ModelContext

    init(destinationStore: DestinationStore, modelContext: ModelContext) {
        self.destinationStore = destinationStore
        self.modelContext = modelContext
    }

    /// A short link made at the provider and not stored yet (the upload's
    /// history entry comes after it).
    struct Pending {
        let created: CreatedShortLink
        let provider: String
        let providerName: String
        let domain: String?
        let targetUrl: String
        let expiresAt: Date?
    }

    enum Attempt {
        /// Not for this link (off, too short, a temporary link, ...).
        case skipped
        case created(Pending)
        /// Made the user's way, so the original link is copied and the
        /// user told; the message never contains the token.
        case failed(String)
    }

    // MARK: - Engines

    /// The destination's shortener, with its token; nil when it has none.
    func operations(for destination: DestinationConfig) -> ShortLinkEngine? {
        guard let settings = destination.shortLinks, let definition = settings.definition else { return nil }
        let token = (try? KeychainService.load(for: destination.id))?.shortLinkToken
        return ShortLinkEngine(definition: definition, settings: settings, token: token)
    }

    private func destination(_ id: UUID) -> DestinationConfig? {
        destinationStore.destinations.first { $0.id == id }
    }

    // MARK: - Creating

    /// Rule 2 and 6: shortens `link` when the destination's rules say so.
    /// Waited for before the link is copied; a failure comes back as
    /// `.failed`, never as an error.
    func shorten(
        _ link: URL,
        destination: DestinationConfig,
        temporaryExpiresAt: Date?,
        uploadExpiresAt: Date?,
        isFolderFile: Bool,
        explicit: Bool = false
    ) async -> Attempt {
        guard let engine = operations(for: destination) else {
            return explicit ? .failed(ShortLinkError.notConfigured.localizedDescription) : .skipped
        }
        let decision = ShortLinkRules.decide(
            settings: engine.settings,
            capabilities: engine.capabilities,
            link: link.absoluteString,
            temporaryExpiresAt: temporaryExpiresAt,
            uploadExpiresAt: uploadExpiresAt,
            isFolderFile: isFolderFile,
            explicit: explicit
        )
        guard case .create(let expiresAt) = decision else { return .skipped }
        do {
            let created = try await engine.create(url: link.absoluteString, expiresAt: expiresAt)
            return .created(Pending(
                created: created,
                provider: engine.provider,
                providerName: engine.definition.name,
                domain: engine.settings.trimmedDomain,
                targetUrl: link.absoluteString,
                expiresAt: engine.capabilities.supportsExpiration ? expiresAt : nil
            ))
        } catch {
            return .failed(Self.message(for: error, token: engine.token))
        }
    }

    /// Stores a short link made by `shorten` for the upload `uploadID`.
    @discardableResult
    func store(_ pending: Pending, uploadID: UUID) -> ShortLink {
        let link = ShortLink(
            uploadID: uploadID,
            provider: pending.provider,
            providerName: pending.providerName,
            providerId: pending.created.providerId,
            domain: pending.domain,
            shortUrl: pending.created.shortUrl,
            targetUrl: pending.targetUrl,
            expiresAt: pending.expiresAt
        )
        modelContext.insert(link)
        try? modelContext.save()
        return link
    }

    /// Create Short Link and Retry: a short link for the upload's link,
    /// whatever its length. A destination that copies temporary links gets
    /// one for a fresh temporary link when it shortens those, otherwise for
    /// the public URL. Returns the stored link, or throws why it couldn't.
    func createShortLink(for record: UploadRecord, temporaryURL: (TemporaryLinkDuration) async throws -> URL) async throws -> ShortLink {
        guard let destination = destination(record.destinationID) else {
            throw StorageError.unknown(String(localized: "This upload's destination was removed."))
        }
        guard let publicURL = record.publicURL else { throw ShortLinkError.invalidEndpoint }
        var link = publicURL
        var temporaryExpiresAt: Date?
        if let duration = destination.temporaryLink, destination.shortLinks?.shortenTemporaryLinks == true,
           ShortLinkRules.canShortenTemporaryLinks(destination.shortLinks?.definition?.capabilities),
           let signed = try? await temporaryURL(duration) {
            link = signed
            temporaryExpiresAt = Date.now.addingTimeInterval(TimeInterval(duration.rawValue))
        }
        let attempt = await shorten(
            link,
            destination: destination,
            temporaryExpiresAt: temporaryExpiresAt,
            uploadExpiresAt: record.expiresAt,
            isFolderFile: false,
            explicit: true
        )
        switch attempt {
        case .created(let pending): return store(pending, uploadID: record.id)
        case .failed(let message): throw StorageError.unknown(message)
        case .skipped: throw ShortLinkError.unsupported
        }
    }

    // MARK: - Reading

    func links(for uploadID: UUID) -> [ShortLink] {
        let descriptor = FetchDescriptor<ShortLink>(
            predicate: #Predicate { $0.uploadID == uploadID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// The short link shown and copied for an upload (rule 4), if any.
    func active(for uploadID: UUID) -> ShortLink? {
        ShortLinkRules.active(links(for: uploadID))
    }

    /// Whether the Library offers Create Short Link: the destination has a
    /// shortener, and the upload has no active link made with it (none
    /// yet, or the provider was switched since).
    func canCreate(for record: UploadRecord) -> Bool {
        guard let settings = destination(record.destinationID)?.shortLinks, settings.definition != nil else { return false }
        guard let active = active(for: record.id) else { return true }
        return active.provider != settings.providerId
    }

    // MARK: - Deleting

    /// Delete Short Link: deletes it at the provider. Throws when it can't
    /// (nothing changes then).
    func delete(_ link: ShortLink) async throws {
        let engine = upload(link.uploadID).flatMap { destination($0.destinationID) }.flatMap(operations(for:))
        let status = try await ShortLinkLifecycle.delete(link.snapshot, operations: engine)
        link.status = status
        try? modelContext.save()
    }

    /// After the upload's file was deleted (rule 5): its short links are
    /// deleted too, in the background. Ones that couldn't be are marked
    /// orphaned and the user is told; the file's delete stands either way.
    func cleanUpAfterFileDeleted(uploadID: UUID, destination: DestinationConfig?, filename: String) {
        let snapshots = links(for: uploadID).map(\.snapshot)
        guard snapshots.contains(where: { $0.status == .active || $0.status == .unknown || $0.status == .expired }) else { return }
        let engine = destination.flatMap(operations(for:))
        Task {
            let statuses = await ShortLinkLifecycle.deleteAll(snapshots, operations: engine)
            apply(statuses, uploadID: uploadID)
            if statuses.values.contains(.orphaned) {
                NotificationService.notifyShortLinkCleanupFailed(filename: filename)
            }
        }
    }

    /// Remove from History: the upload's short links are forgotten here
    /// too. Nothing is deleted at the provider; the file stays, and so do
    /// its links.
    func forget(uploadID: UUID) {
        for link in links(for: uploadID) { modelContext.delete(link) }
        try? modelContext.save()
    }

    // MARK: - Moving

    /// What moving the object at `key` would mean for its uploads' short
    /// links (rule 7).
    func movePlan(key: String, destination: DestinationConfig, records: [UploadRecord]) -> ShortLinkRules.MovePlan {
        let snapshots = records.flatMap { links(for: $0.id) }.map(\.snapshot)
        return ShortLinkRules.movePlan(snapshots, operations: operations(for: destination))
    }

    /// The object was copied to `newURL`: points the active short links of
    /// `records` there. False when one couldn't be updated: those are
    /// `unknown`, and the old object has to stay.
    func updateTargets(of records: [UploadRecord], to newURL: URL, destination: DestinationConfig) async -> Bool {
        guard let engine = operations(for: destination) else { return false }
        var allUpdated = true
        for record in records {
            let links = links(for: record.id)
            let (statuses, updated) = await ShortLinkLifecycle.updateAll(links.map(\.snapshot), to: newURL.absoluteString, operations: engine)
            apply(statuses, uploadID: record.id)
            for link in links where statuses[link.id] == .active { link.targetUrl = newURL.absoluteString }
            if !updated { allUpdated = false }
        }
        try? modelContext.save()
        return allUpdated
    }

    /// Moved without updating: the links may point at nothing now.
    func orphanLinks(of records: [UploadRecord]) {
        for record in records {
            apply(ShortLinkLifecycle.orphanAll(links(for: record.id).map(\.snapshot)), uploadID: record.id)
        }
    }

    // MARK: - Expiry

    /// The upload expired (rule 10).
    func markExpired(uploadID: UUID) {
        apply(ShortLinkLifecycle.expireAll(links(for: uploadID).map(\.snapshot)), uploadID: uploadID)
    }

    // MARK: - Stats

    /// How long fetched stats are shown before they're fetched again.
    static let statsLifetime: TimeInterval = 5 * 60

    /// Fetches clicks and the last click when the provider has them and
    /// the cached ones are older than `statsLifetime`. Failures keep what
    /// was there.
    func refreshStats(_ link: ShortLink, force: Bool = false) async {
        if !force, let checked = link.statsCheckedAt, Date.now.timeIntervalSince(checked) < Self.statsLifetime { return }
        guard link.status == .active || link.status == .unknown, let target = link.snapshot.target,
              let engine = upload(link.uploadID).flatMap({ destination($0.destinationID) }).flatMap(operations(for:)),
              engine.provider == link.provider, engine.capabilities.hasStats,
              let stats = try? await engine.stats(target) else { return }
        link.clicks = stats.clicks ?? link.clicks
        link.lastClickAt = stats.lastClickAt ?? link.lastClickAt
        link.statsCheckedAt = .now
        try? modelContext.save()
    }

    /// Whether the provider of `link` reports clicks.
    func hasStats(_ link: ShortLink) -> Bool {
        guard let settings = upload(link.uploadID).flatMap({ destination($0.destinationID) })?.shortLinks,
              settings.providerId == link.provider else { return false }
        return settings.definition?.capabilities.hasStats ?? false
    }

    // MARK: - Helpers

    private func upload(_ id: UUID) -> UploadRecord? {
        let descriptor = FetchDescriptor<UploadRecord>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    private func apply(_ statuses: [UUID: ShortLinkStatus], uploadID: UUID) {
        guard !statuses.isEmpty else { return }
        for link in links(for: uploadID) {
            if let status = statuses[link.id] { link.status = status }
        }
        try? modelContext.save()
    }

    static func message(for error: Error, token: String?) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return ShortLinkResponse.redact(message, token: token)
    }
}
