import Foundation

enum ProviderPreset: String, Codable, CaseIterable, Identifiable {
    case cloudflareR2
    case amazonS3
    case minIO
    case backblazeB2
    case digitalOceanSpaces
    case customS3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cloudflareR2: return "Cloudflare R2"
        case .amazonS3: return "Amazon S3"
        case .minIO: return "MinIO"
        case .backblazeB2: return "Backblaze B2"
        case .digitalOceanSpaces: return "DigitalOcean Spaces"
        case .customS3: return String(localized: "Other S3-Compatible")
        }
    }

    var defaultRegion: String {
        switch self {
        case .cloudflareR2: return "auto"
        case .amazonS3: return "us-east-1"
        default: return "auto"
        }
    }

    /// MinIO deployments commonly run without DNS-based virtual-hosted buckets.
    var defaultForcePathStyle: Bool {
        self == .minIO
    }

    var symbolName: String {
        switch self {
        case .cloudflareR2: return "cloud.fill"
        case .amazonS3: return "shippingbox.fill"
        case .minIO: return "server.rack"
        case .backblazeB2: return "externaldrive.fill"
        case .digitalOceanSpaces: return "circle.hexagongrid.fill"
        case .customS3: return "cylinder.split.1x2.fill"
        }
    }
}

struct DestinationConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var preset: ProviderPreset
    var accountID: String?
    var endpoint: String
    var region: String
    var bucket: String
    var publicBaseURL: String
    var objectPathTemplate: String
    var forcePathStyle: Bool
    var isDefault: Bool
    /// What's copied after an upload here; nil follows Settings > Output.
    /// With this and `expiryDays`, destinations work as upload profiles
    /// ("Builds", "Logs", "Screenshots"), even several on one bucket.
    var outputMode: OutputMode?
    /// "Delete after" for uploads here, in days (0 keeps them); nil until
    /// it's picked for this destination, when the last choice applies.
    var expiryDays: Int?
    /// Copy a temporary link valid this long after each upload instead of
    /// the public URL; nil copies the public URL.
    var temporaryLink: TemporaryLinkDuration?
    /// What to strip from photos before they're uploaded here; nil is
    /// `ImageMetadataPolicy.default` (remove the location).
    var imageMetadata: ImageMetadataPolicy?
    /// How folders are uploaded here; nil is `FolderUploadMode.default`
    /// (as a ZIP).
    var folderUpload: FolderUploadMode?
    /// Conversion, recompression and resizing of photos before they're
    /// uploaded here; nil leaves them as they are.
    var imageProcessing: ImageProcessing?
    /// Where thumbnails of uploads here are kept; nil is
    /// `ThumbnailMode.default` (on this Mac). See `thumbnailMode`.
    var thumbnails: ThumbnailMode?
    /// The bucket folder for `.bucket` thumbnails; nil is
    /// `ThumbnailKeys.defaultPrefix`. See `bucketThumbnailPrefix`.
    var thumbnailPrefix: String?
    /// The kinds of files and extensions that come here when an upload
    /// doesn't name a destination; see `DestinationRouting`.
    var useFor: FileRouting?
    /// Uploads here are sent with a one-minute cache time, so a replaced
    /// file shows up everywhere within about a minute.
    var shortCache: Bool?
    /// The Cloudflare zone whose cache is cleared for a replaced file; the
    /// token is in the Keychain with the keys (`StorageCredentials`).
    var cloudflareZoneId: String?
    /// Run after each upload and replace here (not for a watched folder's
    /// files, which run their folder's own).
    var hooks: [WatchHook]?
    /// The link shortener uploads here go through; nil is off. Its token
    /// is in the Keychain with the keys (`StorageCredentials`).
    var shortLinks: ShortLinkSettings?

    /// The path template of a new destination. Saved ones keep theirs.
    static let defaultObjectPathTemplate = "{year}/{month}/{short}.{ext}"
    /// The shortest links: just the code, on the bucket's own domain.
    static let cleanURLTemplate = "{short}.{ext}"

    static func deriveR2Endpoint(accountID: String) -> String {
        "https://\(accountID).r2.cloudflarestorage.com"
    }
}
