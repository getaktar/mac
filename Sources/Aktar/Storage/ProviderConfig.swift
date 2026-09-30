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

    static func deriveR2Endpoint(accountID: String) -> String {
        "https://\(accountID).r2.cloudflarestorage.com"
    }
}
