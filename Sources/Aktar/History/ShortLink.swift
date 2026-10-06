import Foundation
import SwiftData

/// A short link made for an upload. Separate from `UploadRecord` (one
/// upload can have several, and they outlive its history entry when
/// cleanup fails), tied to it by `uploadID` rather than a relationship, so
/// adding this model is a lightweight migration that keeps history as is.
@Model
final class ShortLink: Identifiable {
    @Attribute(.unique) var id: UUID
    var uploadID: UUID
    /// The definition's id, or "custom".
    var provider: String
    var providerName: String
    /// The provider's id or code, for delete, update and stats.
    var providerId: String?
    /// The short domain it was made on, for providers that need it again.
    var domain: String?
    var shortUrl: String
    var targetUrl: String
    var createdAt: Date
    var expiresAt: Date?
    /// A `ShortLinkStatus`.
    var statusRaw: String
    var clicks: Int?
    var lastClickAt: Date?
    var statsCheckedAt: Date?

    init(
        id: UUID = UUID(),
        uploadID: UUID,
        provider: String,
        providerName: String,
        providerId: String?,
        domain: String?,
        shortUrl: String,
        targetUrl: String,
        createdAt: Date = .now,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.uploadID = uploadID
        self.provider = provider
        self.providerName = providerName
        self.providerId = providerId
        self.domain = domain
        self.shortUrl = shortUrl
        self.targetUrl = targetUrl
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.statusRaw = ShortLinkStatus.active.rawValue
    }

    var status: ShortLinkStatus {
        get { ShortLinkStatus(rawValue: statusRaw) ?? .unknown }
        set { statusRaw = newValue.rawValue }
    }

    var url: URL? { URL(string: shortUrl) }

    /// Active, but past its expiry: shown as expired.
    var displayStatus: ShortLinkStatus {
        status == .active && ShortLinkRules.isPastExpiry(snapshot) ? .expired : status
    }
}

extension ShortLink: ShortLinkSnapshotConvertible {
    var snapshot: ShortLinkSnapshot {
        ShortLinkSnapshot(id: id, provider: provider, providerId: providerId, domain: domain, status: status, createdAt: createdAt, expiresAt: expiresAt)
    }
}
