import Foundation

enum ShortLinkStatus: String, Codable, CaseIterable, Sendable {
    case active
    /// Its upload (or the temporary link it points at) expired.
    case expired
    case deleted
    /// The file is gone or moved, and the short link may still exist.
    case orphaned
    /// Updating its target failed: it may point at the old place.
    case unknown
}

/// The rules of docs/short-links.md ("Behavior rules"), apart from the
/// app around them so they can be tested.
enum ShortLinkRules {
    enum Decision: Equatable {
        case skip
        /// With this expiry (nil: none).
        case create(expiresAt: Date?)
    }

    /// Whether a link gets a short link, and when that expires.
    /// - `temporaryExpiresAt`: the link is a temporary (presigned) one,
    ///   valid until then. Those are shortened only with
    ///   `shortenTemporaryLinks` and a provider that can expire links, and
    ///   the short link expires with it, so it never outlives its target.
    /// - `uploadExpiresAt`: the upload's "Delete after", passed on when the
    ///   provider can expire links.
    /// - `isFolderFile`: one file of a folder uploaded with its structure;
    ///   only the link Aktar copies for a whole upload is shortened.
    /// - `explicit`: asked for by hand (Create Short Link, Retry), so the
    ///   length limit doesn't apply.
    static func decide(
        settings: ShortLinkSettings?,
        capabilities: ShortLinkCapabilities?,
        link: String,
        temporaryExpiresAt: Date? = nil,
        uploadExpiresAt: Date? = nil,
        isFolderFile: Bool = false,
        explicit: Bool = false,
        now: Date = .now
    ) -> Decision {
        guard let settings, let capabilities, !isFolderFile else { return .skip }
        if !explicit, settings.onlyLongerThan > 0, link.count <= settings.onlyLongerThan { return .skip }
        let expiresAt: Date?
        if let temporaryExpiresAt {
            guard settings.shortenTemporaryLinks, capabilities.supportsExpiration else { return .skip }
            expiresAt = min(temporaryExpiresAt, uploadExpiresAt ?? temporaryExpiresAt)
        } else {
            expiresAt = capabilities.supportsExpiration ? uploadExpiresAt : nil
        }
        // A relative expiry is at least a minute.
        if let expiresAt, expiresAt.timeIntervalSince(now) < 60 { return .skip }
        return .create(expiresAt: expiresAt)
    }

    /// Whether "Also shorten temporary links" can be turned on.
    static func canShortenTemporaryLinks(_ capabilities: ShortLinkCapabilities?) -> Bool {
        capabilities?.supportsExpiration ?? false
    }

    /// The short link shown and copied for an upload: the newest active one
    /// that hasn't run out.
    static func active<Link: ShortLinkSnapshotConvertible>(_ links: [Link], now: Date = .now) -> Link? {
        links
            .filter { $0.snapshot.status == .active && !isPastExpiry($0.snapshot, now: now) }
            .max { $0.snapshot.createdAt < $1.snapshot.createdAt }
    }

    static func isPastExpiry(_ link: ShortLinkSnapshot, now: Date = .now) -> Bool {
        guard let expiresAt = link.expiresAt else { return false }
        return expiresAt <= now
    }

    /// What moving a file means for its short links (rule 7).
    enum MovePlan: Equatable {
        /// No active short link: nothing to do.
        case nothing
        /// Create the new object, update the targets, delete the old one.
        case update
        /// The provider can't change a target (or isn't the one set up any
        /// more): warn first, and orphan the links if the user goes ahead.
        case warn
    }

    static func movePlan(_ links: [ShortLinkSnapshot], operations: ShortLinkOperations?, now: Date = .now) -> MovePlan {
        let active = links.filter { $0.status == .active && !isPastExpiry($0, now: now) }
        guard !active.isEmpty else { return .nothing }
        guard let operations, operations.capabilities.updateDestination,
              active.allSatisfy({ $0.provider == operations.provider && $0.providerId != nil }) else { return .warn }
        return .update
    }
}

/// What the rules need to know about a stored short link.
struct ShortLinkSnapshot: Equatable, Sendable {
    var id: UUID
    var provider: String
    var providerId: String?
    var domain: String?
    var status: ShortLinkStatus
    var createdAt: Date
    var expiresAt: Date?

    var target: ShortLinkTarget? {
        providerId.map { ShortLinkTarget(providerId: $0, domain: domain) }
    }
}

protocol ShortLinkSnapshotConvertible {
    var snapshot: ShortLinkSnapshot { get }
}

extension ShortLinkSnapshot: ShortLinkSnapshotConvertible {
    var snapshot: ShortLinkSnapshot { self }
}

/// The provider side of deletes and moves: what each link's status
/// becomes. File operations never wait on, or fail because of, these.
enum ShortLinkLifecycle {
    /// After the file was deleted (rule 5): every short link that may
    /// still work is deleted at the provider. One that can't be (no delete
    /// support, another provider, or the request failed) is `orphaned`;
    /// an expired one that can't be stays `expired`. Links already deleted
    /// or orphaned aren't in the result.
    static func deleteAll(_ links: [ShortLinkSnapshot], operations: ShortLinkOperations?) async -> [UUID: ShortLinkStatus] {
        var result: [UUID: ShortLinkStatus] = [:]
        for link in links where link.status == .active || link.status == .unknown || link.status == .expired {
            let failed: ShortLinkStatus = link.status == .expired ? .expired : .orphaned
            guard let operations, operations.provider == link.provider, operations.capabilities.delete,
                  let target = link.target else {
                result[link.id] = failed
                continue
            }
            do {
                try await operations.delete(target)
                result[link.id] = .deleted
            } catch {
                result[link.id] = failed
            }
        }
        return result
    }

    /// One short link deleted by hand: `deleted`, or the error.
    static func delete(_ link: ShortLinkSnapshot, operations: ShortLinkOperations?) async throws -> ShortLinkStatus {
        guard let operations, operations.provider == link.provider else { throw ShortLinkError.notConfigured }
        guard operations.capabilities.delete, let target = link.target else { throw ShortLinkError.unsupported }
        try await operations.delete(target)
        return .deleted
    }

    /// A move with `.update` (rule 7): each active link is pointed at
    /// `newURL`. `allUpdated` false means at least one may still point at
    /// the old object, which is then kept; that one is `unknown`.
    static func updateAll(_ links: [ShortLinkSnapshot], to newURL: String, operations: ShortLinkOperations, now: Date = .now) async -> (statuses: [UUID: ShortLinkStatus], allUpdated: Bool) {
        var statuses: [UUID: ShortLinkStatus] = [:]
        var allUpdated = true
        for link in links where link.status == .active && !ShortLinkRules.isPastExpiry(link, now: now) {
            guard let target = link.target, link.provider == operations.provider else {
                statuses[link.id] = .unknown
                allUpdated = false
                continue
            }
            do {
                try await operations.update(target, url: newURL)
                statuses[link.id] = .active
            } catch {
                statuses[link.id] = .unknown
                allUpdated = false
            }
        }
        return (statuses, allUpdated)
    }

    /// The user moved a file anyway: its active links may now point at
    /// nothing.
    static func orphanAll(_ links: [ShortLinkSnapshot]) -> [UUID: ShortLinkStatus] {
        Dictionary(uniqueKeysWithValues: links.filter { $0.status == .active }.map { ($0.id, ShortLinkStatus.orphaned) })
    }

    /// The upload expired (rule 10): its links are marked `expired` here;
    /// the provider expires them itself when it supports that.
    static func expireAll(_ links: [ShortLinkSnapshot]) -> [UUID: ShortLinkStatus] {
        Dictionary(uniqueKeysWithValues: links.filter { $0.status == .active || $0.status == .unknown }.map { ($0.id, ShortLinkStatus.expired) })
    }
}
