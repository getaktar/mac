import Foundation

/// A folder whose new files are uploaded on their own, with its own rules.
/// Saved in `watched-folders.json` next to `destinations.json`; the Windows
/// app writes the same keys, so the JSON shape here is part of a shared
/// format: camelCase keys, nulls written out, unknown values falling back
/// to the defaults.
struct WatchedFolder: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    /// Shown in Settings, notifications and history; defaults to the
    /// folder's own name.
    var name: String
    /// Absolute path, as picked.
    var path: String
    /// App-scoped security-scoped bookmark, which is what lets the sandboxed
    /// app read the folder again after a restart.
    var bookmark: Data?
    var enabled = true
    var preset: WatchPreset?
    /// Nil uploads to the default destination.
    var destinationID: UUID?
    /// Nil uses the destination's Object Path.
    var pathTemplate: String?
    var subfolders: SubfolderMode = .ignore
    var filter = WatchFilter()
    /// Upload iCloud Drive files that are only in the cloud, which
    /// downloads them first.
    var includeCloudOnly = false
    var modified: ModifiedPolicy = .ignore
    var afterUpload: AfterUploadAction = .keep
    /// What happens to the upload when its file is deleted from the folder.
    /// Only applies while uploaded files stay in the folder; see
    /// `deletesRemotely`.
    var onDelete: OnDeletePolicy = .keep
    /// With `deletesRemotely`, ask before every remote delete instead of
    /// deleting on its own.
    var confirmDelete = true
    var clipboard: ClipboardPolicy = .off
    var notifications: NotificationPolicy = .grouped
    /// Nil follows the destination's Link choice.
    var temporaryLink: WatchLinkOverride?
    /// Nil follows the destination's "Delete after"; 0 keeps the files.
    var expiryDays: Int?
    var hooks: [WatchHook] = []
    var addedAt = Date()

    init(name: String, path: String, bookmark: Data? = nil) {
        self.name = name
        self.path = path
        self.bookmark = bookmark
    }

    /// The defaults for the screenshots folder: every screenshot's link is
    /// copied and announced as soon as it's up.
    static func screenshots(path: String, bookmark: Data?) -> WatchedFolder {
        var folder = WatchedFolder(name: String(localized: "Screenshots"), path: path, bookmark: bookmark)
        folder.preset = .screenshots
        folder.filter.kind = .screenshots
        folder.clipboard = .copyLink
        folder.notifications = .each
        return folder
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// "Delete it from the bucket too" only means something while the
    /// originals stay in the folder; moved ones are gone by design.
    var deletesRemotely: Bool {
        onDelete == .deleteRemote && (afterUpload == .keep || afterUpload == .tag)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, bookmark, enabled, preset, destinationID, pathTemplate, subfolders, filter
        case includeCloudOnly, modified, afterUpload, onDelete, confirmDelete, clipboard, notifications, temporaryLink, expiryDays, hooks, addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? URL(fileURLWithPath: path).lastPathComponent
        bookmark = (try? c.decodeIfPresent(String.self, forKey: .bookmark)).flatMap { Data(base64Encoded: $0) }
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        preset = (try? c.decodeIfPresent(WatchPreset.self, forKey: .preset))
        destinationID = (try? c.decodeIfPresent(UUID.self, forKey: .destinationID))
        pathTemplate = (try? c.decodeIfPresent(String.self, forKey: .pathTemplate))
        subfolders = (try? c.decodeIfPresent(SubfolderMode.self, forKey: .subfolders)) ?? .ignore
        filter = (try? c.decodeIfPresent(WatchFilter.self, forKey: .filter)) ?? WatchFilter()
        includeCloudOnly = (try? c.decodeIfPresent(Bool.self, forKey: .includeCloudOnly)) ?? false
        modified = (try? c.decodeIfPresent(ModifiedPolicy.self, forKey: .modified)) ?? .ignore
        afterUpload = (try? c.decodeIfPresent(AfterUploadAction.self, forKey: .afterUpload)) ?? .keep
        onDelete = (try? c.decodeIfPresent(OnDeletePolicy.self, forKey: .onDelete)) ?? .keep
        confirmDelete = (try? c.decodeIfPresent(Bool.self, forKey: .confirmDelete)) ?? true
        clipboard = (try? c.decodeIfPresent(ClipboardPolicy.self, forKey: .clipboard)) ?? .off
        notifications = (try? c.decodeIfPresent(NotificationPolicy.self, forKey: .notifications)) ?? .grouped
        temporaryLink = (try? c.decodeIfPresent(WatchLinkOverride.self, forKey: .temporaryLink))
        expiryDays = (try? c.decodeIfPresent(Int.self, forKey: .expiryDays))
        hooks = (try? c.decodeIfPresent([WatchHook].self, forKey: .hooks)) ?? []
        addedAt = (try? c.decodeIfPresent(Date.self, forKey: .addedAt)) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(bookmark?.base64EncodedString(), forKey: .bookmark)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(preset, forKey: .preset)
        try c.encode(destinationID, forKey: .destinationID)
        try c.encode(pathTemplate, forKey: .pathTemplate)
        try c.encode(subfolders, forKey: .subfolders)
        try c.encode(filter, forKey: .filter)
        try c.encode(includeCloudOnly, forKey: .includeCloudOnly)
        try c.encode(modified, forKey: .modified)
        try c.encode(afterUpload, forKey: .afterUpload)
        try c.encode(onDelete, forKey: .onDelete)
        try c.encode(confirmDelete, forKey: .confirmDelete)
        try c.encode(clipboard, forKey: .clipboard)
        try c.encode(notifications, forKey: .notifications)
        try c.encode(temporaryLink, forKey: .temporaryLink)
        try c.encode(expiryDays, forKey: .expiryDays)
        try c.encode(hooks, forKey: .hooks)
        try c.encode(addedAt, forKey: .addedAt)
    }
}

enum WatchPreset: String, Codable, Sendable {
    case screenshots
}

enum SubfolderMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Only files directly in the folder.
    case ignore
    /// Files in subfolders too, under the same subfolders in the bucket.
    case keepStructure
    /// Files in subfolders too, all side by side in the bucket.
    case flatten

    var id: String { rawValue }
}

/// What happens when a file that was uploaded changes.
enum ModifiedPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case ignore
    /// A new upload, with a new link.
    case uploadAgain
    /// The new version replaces the uploaded one, so the link stays.
    case overwrite

    var id: String { rawValue }
}

enum AfterUploadAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep
    /// Moved to the Trash, never deleted outright.
    case trash
    /// Moved into the folder's `Uploaded` subfolder.
    case moveToUploaded
    /// The Finder tag "Aktar".
    case tag

    var id: String { rawValue }
}

/// What happens to an upload when its file is deleted from the folder.
enum OnDeletePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case keep
    /// The upload is deleted from the bucket too, after a short grace
    /// period (a save that replaces the file isn't a deletion).
    case deleteRemote

    var id: String { rawValue }
}

enum ClipboardPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case copyLink
    /// Written as "none"; named so it's never mistaken for `Optional.none`.
    case off = "none"

    var id: String { rawValue }
}

enum NotificationPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One per file, like an upload from the menu bar.
    case each
    /// One for each batch of files, once it's done.
    case grouped
    /// Only when something failed.
    case failuresOnly

    var id: String { rawValue }
}

/// Which files of a folder are uploaded.
struct WatchFilter: Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case all
        case images
        case videos
        /// Files macOS marked as screenshots or screen recordings.
        case screenshots
        /// Only files matching `include`.
        case custom

        var id: String { rawValue }
    }

    var kind: Kind = .all
    /// Globs, used when `kind` is custom; see `WatchFileRules`.
    var include: [String] = []
    /// Globs that are always left out, on top of the built-in ignore list.
    var exclude: [String] = []
    var minBytes: Int64?
    var maxBytes: Int64?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case kind, include, exclude, minBytes, maxBytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .all
        include = (try? c.decodeIfPresent([String].self, forKey: .include)) ?? []
        exclude = (try? c.decodeIfPresent([String].self, forKey: .exclude)) ?? []
        minBytes = (try? c.decodeIfPresent(Int64.self, forKey: .minBytes))
        maxBytes = (try? c.decodeIfPresent(Int64.self, forKey: .maxBytes))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(include, forKey: .include)
        try c.encode(exclude, forKey: .exclude)
        try c.encode(minBytes, forKey: .minBytes)
        try c.encode(maxBytes, forKey: .maxBytes)
    }
}

/// A folder's own Link choice: always the public URL, or a temporary link
/// valid this many seconds (the same values as `TemporaryLinkDuration`).
/// Written as "public" or the number of seconds.
enum WatchLinkOverride: Codable, Hashable, Sendable {
    case publicLink
    case temporary(seconds: Int64)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let seconds = try? c.decode(Int64.self) {
            self = .temporary(seconds: seconds)
        } else if try c.decode(String.self) == "public" {
            self = .publicLink
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown link")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .publicLink: try c.encode("public")
        case .temporary(let seconds): try c.encode(seconds)
        }
    }
}

/// Something that runs after each successful upload from a folder.
struct WatchHook: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// POSTs the payload to `target`, a URL.
        case webhook
        /// Runs the script named `target` from Aktar's Application Scripts
        /// folder.
        case script
    }

    var id: UUID = UUID()
    var kind: Kind
    var target: String
    var enabled = true
}

/// Watching as a whole: the folders and when it's paused.
struct WatchSettings: Codable, Equatable, Sendable {
    enum Pause: Equatable, Sendable {
        case until(Date)
        case forever
    }

    var folders: [WatchedFolder] = []
    var pausedUntil: Pause?
    var pauseOnBattery = false
    /// Low Data Mode or an expensive (metered) network.
    var pauseOnMetered = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case folders, pausedUntil, pauseOnBattery, pauseOnMetered
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One folder that can't be read doesn't lose the others.
        let lossy = (try? c.decodeIfPresent([LossyFolder].self, forKey: .folders)) ?? []
        folders = lossy.compactMap(\.folder)
        if let raw = try? c.decodeIfPresent(String.self, forKey: .pausedUntil) {
            if raw == "forever" {
                pausedUntil = .forever
            } else if let date = WatchDates.parse(raw) {
                pausedUntil = .until(date)
            }
        }
        pauseOnBattery = (try? c.decodeIfPresent(Bool.self, forKey: .pauseOnBattery)) ?? false
        pauseOnMetered = (try? c.decodeIfPresent(Bool.self, forKey: .pauseOnMetered)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(folders, forKey: .folders)
        switch pausedUntil {
        case nil: try c.encodeNil(forKey: .pausedUntil)
        case .forever: try c.encode("forever", forKey: .pausedUntil)
        case .until(let date): try c.encode(WatchDates.format(date), forKey: .pausedUntil)
        }
        try c.encode(pauseOnBattery, forKey: .pauseOnBattery)
        try c.encode(pauseOnMetered, forKey: .pauseOnMetered)
    }

    private struct LossyFolder: Decodable {
        let folder: WatchedFolder?

        init(from decoder: Decoder) throws {
            folder = try? WatchedFolder(from: decoder)
        }
    }

    static func decode(_ data: Data) throws -> WatchSettings {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = WatchDates.parse(raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not ISO-8601"))
            }
            return date
        }
        return try decoder.decode(WatchSettings.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(WatchDates.format(date))
        }
        return try encoder.encode(self)
    }
}

/// ISO-8601 dates, with or without fractional seconds (the Windows app
/// writes them).
enum WatchDates {
    static func format(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }
}
