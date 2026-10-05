import Foundation

/// Where a destination's thumbnails live. The Windows and mobile apps use
/// the same raw values, key layout and format; see docs/thumbnails.md.
enum ThumbnailMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// No thumbnails are made, downloaded or shown; rows show file icons.
    case off
    /// Made on this Mac and kept only here.
    case local
    /// Kept here too, and also saved to the bucket under a folder of the
    /// user's choosing, so other devices (and a reinstall) can show them.
    case bucket

    static let `default`: ThumbnailMode = .local

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return String(localized: "Off")
        case .local: return String(localized: "On This Mac")
        case .bucket: return String(localized: "In the Bucket")
        }
    }
}

extension DestinationConfig {
    /// The mode that applies: a destination saved before thumbnails had a
    /// setting keeps them on this Mac, as before.
    var thumbnailMode: ThumbnailMode {
        thumbnails ?? .default
    }

    /// The folder thumbnails are saved under in the bucket, when this
    /// destination saves them there.
    var bucketThumbnailPrefix: String? {
        guard thumbnailMode == .bucket else { return nil }
        return ThumbnailKeys.normalizedPrefix(thumbnailPrefix) ?? ThumbnailKeys.defaultPrefix
    }
}

/// Where a thumbnail goes in the bucket. A thumbnail's key mirrors its
/// file's key under the thumbnail folder, so it's found without a list or a
/// manifest, and an expiring file's thumbnail stays inside the same
/// `tmp/{N}d/` folder so the bucket's lifecycle rule deletes both together,
/// whether or not Aktar is running:
///
///     photos/cat.png        -> .aktar/thumbnails/photos/cat.png.webp
///     tmp/7d/photos/cat.png -> tmp/7d/.aktar/thumbnails/photos/cat.png.webp
enum ThumbnailKeys {
    static let defaultPrefix = ".aktar/thumbnails/"
    static let fileExtension = "webp"
    static let contentType = "image/webp"

    /// `raw` as a folder: trimmed, without leading slashes, ending in one.
    /// Nil when nothing is left.
    static func normalizedPrefix(_ raw: String?) -> String? {
        guard var prefix = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        while prefix.hasPrefix("/") { prefix.removeFirst() }
        while prefix.hasSuffix("/") { prefix.removeLast() }
        guard !prefix.isEmpty else { return nil }
        return prefix + "/"
    }

    /// Why `raw` can't be the thumbnail folder, or nil when it can.
    static func problem(withPrefix raw: String) -> String? {
        guard let prefix = normalizedPrefix(raw) else {
            return String(localized: "Enter a folder for the thumbnails.")
        }
        if let problem = ObjectKeyGenerator.problem(withUserKey: prefix, allowsTrailingSlash: true) {
            return problem.errorDescription
        }
        if prefix.hasPrefix(UploadExpiry.rootPrefix) {
            return String(localized: "The thumbnail folder can\u{2019}t be inside tmp/, where files expire.")
        }
        return nil
    }

    /// The thumbnail's key for the file at `objectKey`, or nil when that
    /// "file" is a folder or a thumbnail itself.
    static func key(for objectKey: String, prefix: String) -> String? {
        guard !objectKey.isEmpty, !objectKey.hasSuffix("/"), !isThumbnail(objectKey, prefixes: [prefix]) else { return nil }
        if let days = UploadExpiry.days(forKey: objectKey) {
            let expiring = UploadExpiry.prefix(days: days)
            return expiring + prefix + objectKey.dropFirst(expiring.count) + "." + fileExtension
        }
        return prefix + objectKey + "." + fileExtension
    }

    /// The folders a prefix's thumbnails are in: at the root, and inside
    /// each `tmp/{N}d/` folder for expiring files.
    static func roots(prefix: String) -> [String] {
        [prefix] + UploadExpiry.options.map { UploadExpiry.prefix(days: $0) + prefix }
    }

    static func isThumbnail(_ key: String, prefixes: [String]) -> Bool {
        prefixes.flatMap(roots).contains { key.hasPrefix($0) }
    }

    /// Whether the bucket view leaves `folder` out: a thumbnail folder or
    /// anything in it, and a dot folder (such as `.aktar/`) on the way to
    /// one, the way Finder hides dot folders.
    static func isHiddenFolder(_ folder: String, prefixes: [String]) -> Bool {
        let name = folder.dropLast().split(separator: "/", omittingEmptySubsequences: false).last ?? ""
        return prefixes.flatMap(roots).contains { root in
            folder.hasPrefix(root) || (root.hasPrefix(folder) && name.hasPrefix("."))
        }
    }

    /// The thumbnail folders in the bucket `destination` points at: its own
    /// when it saves thumbnails there, and those of other destinations on
    /// the same bucket that do (profiles sharing one bucket). Deleting or
    /// moving a file takes its thumbnail in each along.
    static func bucketPrefixes(for destination: DestinationConfig, among destinations: [DestinationConfig]) -> [String] {
        var prefixes: [String] = []
        for candidate in [destination] + destinations
        where candidate.id == destination.id || DestinationTransfer.uploadsToSamePlace(candidate, as: destination) {
            if let prefix = candidate.bucketThumbnailPrefix, !prefixes.contains(prefix) {
                prefixes.append(prefix)
            }
        }
        return prefixes
    }
}
