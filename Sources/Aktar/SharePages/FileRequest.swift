import Foundation

/// A file request (docs/share-pages.md, part 4): a link where anyone who
/// has it can send files into the bucket until it expires. Kept on this Mac
/// only, in `requests.json` next to destinations.json.
struct FileRequest: Codable, Identifiable, Equatable, Sendable {
    /// 10 characters of [0-9A-Za-z].
    var id: String
    var destinationId: UUID
    var title: String
    var note: String
    var createdAt: Date
    var expiresAt: Date
    var slotCount: Int
    var maxBytes: Int64
    /// The page's link, as copied.
    var link: String
    /// Files collected into history so far.
    var received: Int
    /// When it was closed and its prefix emptied; nil while open.
    var closedAt: Date?

    /// Checked until an hour after it expires (a file sent at the last
    /// moment), then closed after a last check.
    static let collectionGrace: TimeInterval = 3600

    var isOpen: Bool { closedAt == nil }

    /// The source label of the files it brings in.
    var sourceLabel: String {
        FileRequests.sourceLabel(title: title)
    }

    func isExpired(now: Date = .now) -> Bool { now >= expiresAt }

    /// Past `expiresAt` + the grace hour: time for the last check.
    func isDueToClose(now: Date = .now) -> Bool { now >= expiresAt.addingTimeInterval(Self.collectionGrace) }
}

enum FileRequests {
    static let rootPrefix = ".aktar/requests/"
    static let idLength = 10
    /// What the sheet offers.
    static let durations: [TimeInterval] = [3600, 86_400, 7 * 86_400]
    static let defaultDuration: TimeInterval = 86_400
    static let slotOptions = [1, 5, 10, 20]
    static let defaultSlots = 10
    static let sizeOptions: [Int64] = [100_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000]
    static let defaultMaxBytes: Int64 = 2_000_000_000
    static let maxTitleLength = 100
    static let maxNoteLength = 1000
    /// A slot's file without its metadata is taken after this long.
    static let metadataWait: TimeInterval = 600
    /// A slot's metadata is read only up to this size.
    static let maxMetadataBytes = 4096
    /// Allowed above `maxBytes` (the page counts decimal units, a browser
    /// may round), before a file is refused unread.
    static let sizeSlack: Int64 = 1_000_000
    static let corsRuleID = "aktar-file-requests"

    static func newID() -> String { ShortCode.make(length: idLength) }

    static func prefix(id: String) -> String { rootPrefix + id + "/" }
    static func pageKey(id: String) -> String { prefix(id: id) + "index.html" }
    static func fileKey(id: String, slot: Int) -> String { prefix(id: id) + String(slot) }
    static func metadataKey(id: String, slot: Int) -> String { prefix(id: id) + String(slot) + ".json" }

    /// "Request: Logs for the crash", or "Request".
    static func sourceLabel(title: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "Request") : String(localized: "Request: \(title)")
    }

    // MARK: - Names

    /// A sender's file name as one safe name: the last path component
    /// only, no control characters or `/ \ :`, at most 200 characters,
    /// never empty (`upload-<slot>`).
    static func sanitizedName(_ raw: String?, slot: Int) -> String {
        var name = raw ?? ""
        if let last = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: last)...])
        }
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { scalar in
            scalar != ":" && scalar != "/" && scalar != "\\" && scalar.properties.generalCategory != .control
        }))
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 200 {
            // Keep the extension when it's short.
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty, ext.count <= 16 {
                name = String(name.prefix(200 - ext.count - 1)) + "." + ext
            } else {
                name = String(name.prefix(200))
            }
        }
        if name.isEmpty || name == "." || name == ".." { return "upload-\(slot)" }
        return name
    }

    /// The name in a slot's metadata (`{ v, name, type, size, sent }`), or
    /// nil when it can't be read. `type` is ignored: the destination
    /// decides the Content-Type from the extension.
    static func metadataName(_ data: Data) -> String? {
        guard data.count <= maxMetadataBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["name"] as? String
    }

    // MARK: - Collecting

    /// One slot that has something to collect.
    struct ReadySlot: Equatable {
        let slot: Int
        let file: BucketObject
        /// Nil when the file waited 10 minutes without one: it's named
        /// `upload-<slot>` then.
        let metadata: BucketObject?
    }

    /// The slots of a request's listing that are ready: the file and its
    /// metadata are both there, or the file is 10 minutes old without one.
    /// Anything else in the prefix (the page, unknown names, slots past the
    /// request's count) is left alone.
    static func readySlots(in objects: [BucketObject], id: String, slotCount: Int, now: Date = .now) -> [ReadySlot] {
        let prefix = prefix(id: id)
        var files: [Int: BucketObject] = [:]
        var metadata: [Int: BucketObject] = [:]
        for object in objects where object.key.hasPrefix(prefix) {
            let name = String(object.key.dropFirst(prefix.count))
            if let slot = slotNumber(name), (1...slotCount).contains(slot) {
                files[slot] = object
            } else if name.hasSuffix(".json"), let slot = slotNumber(String(name.dropLast(5))), (1...slotCount).contains(slot) {
                metadata[slot] = object
            }
        }
        return files.keys.sorted().compactMap { slot in
            let file = files[slot]!
            if let meta = metadata[slot] { return ReadySlot(slot: slot, file: file, metadata: meta) }
            guard let modified = file.lastModified, now.timeIntervalSince(modified) >= metadataWait else { return nil }
            return ReadySlot(slot: slot, file: file, metadata: nil)
        }
    }

    /// "7" as 7; anything but plain digits (no sign, no leading zero) is nil.
    private static func slotNumber(_ name: String) -> Int? {
        guard !name.isEmpty, name.count <= 4, name.allSatisfy(\.isASCII), name.allSatisfy(\.isNumber),
              name.first != "0" else { return nil }
        return Int(name)
    }

    // MARK: - Labels

    static func durationLabel(_ seconds: TimeInterval) -> String {
        switch seconds {
        case 3600: return String(localized: "1 hour")
        case 86_400: return String(localized: "1 day")
        default: return String(localized: "\(Int(seconds / 86_400)) days")
        }
    }

    static func sizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}

/// Saved requests, newest first.
@MainActor
@Observable
final class FileRequestStore {
    private(set) var requests: [FileRequest] = []
    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aktar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("requests.json")
        load()
    }

    var open: [FileRequest] { requests.filter(\.isOpen) }

    func request(id: String) -> FileRequest? { requests.first { $0.id == id } }

    func add(_ request: FileRequest) {
        requests.insert(request, at: 0)
        save()
    }

    func update(_ request: FileRequest) {
        guard let index = requests.firstIndex(where: { $0.id == request.id }) else { return }
        requests[index] = request
        save()
    }

    func remove(id: String) {
        requests.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        requests = (try? decoder.decode([FileRequest].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(requests) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// A bucket's CORS configuration handled as XML text, like `LifecycleXML`:
/// the bucket's other rules go back exactly as they came.
enum CORSXML {
    struct Rule: Equatable {
        let id: String?
        let origins: [String]
        let methods: [String]
        /// The rule's inner XML, as returned.
        let raw: String
    }

    /// The rules of a GET ?cors reply, or nil when it doesn't read as one
    /// whose every rule could be parsed (nothing is written then).
    static func configurationRules(in xml: String) -> [Rule]? {
        guard LifecycleXML.blocks("CORSConfiguration", in: xml).count == 1 else { return nil }
        let raws = LifecycleXML.blocks("CORSRule", in: xml)
        let opened = xml.components(separatedBy: "<CORSRule").count - 1
        guard raws.count == opened else { return nil }
        return raws.map { raw in
            Rule(
                id: LifecycleXML.value("ID", in: raw),
                origins: LifecycleXML.blocks("AllowedOrigin", in: raw).map { LifecycleXML.unescape($0).trimmingCharacters(in: .whitespacesAndNewlines) },
                methods: LifecycleXML.blocks("AllowedMethod", in: raw).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() },
                raw: raw
            )
        }
    }

    /// Aktar's rule for `origin`: PUT with the two headers the page sends.
    static func ruleXML(origin: String) -> String {
        "<ID>\(FileRequests.corsRuleID)</ID>"
            + "<AllowedOrigin>\(escape(origin))</AllowedOrigin>"
            + "<AllowedMethod>PUT</AllowedMethod>"
            + "<AllowedHeader>content-type</AllowedHeader>"
            + "<AllowedHeader>if-none-match</AllowedHeader>"
            + "<ExposeHeader>etag</ExposeHeader>"
            + "<MaxAgeSeconds>3600</MaxAgeSeconds>"
    }

    /// Whether a rule is Aktar's: by its ID, or for a provider that drops
    /// IDs, the same origin with PUT.
    static func isAktarRule(_ rule: Rule, origin: String) -> Bool {
        rule.id == FileRequests.corsRuleID || (rule.origins.contains(origin) && rule.methods.contains("PUT"))
    }

    /// The configuration to PUT: the other rules untouched, Aktar's
    /// replaced. Nil when Aktar's rule is already there as it would write it.
    static func merged(_ existing: [Rule], origin: String) -> String? {
        let ours = ruleXML(origin: origin)
        let matching = existing.filter { isAktarRule($0, origin: origin) }
        if matching.count == 1, matching[0].id == FileRequests.corsRuleID, compact(matching[0].raw) == compact(ours) { return nil }
        let kept = existing.filter { !isAktarRule($0, origin: origin) }.map(\.raw)
        return document(kept + [ours])
    }

    /// The rule as JSON, for pasting into a provider's dashboard.
    static func ruleJSON(origin: String) -> String {
        """
        [
          {
            "AllowedOrigins": ["\(origin)"],
            "AllowedMethods": ["PUT"],
            "AllowedHeaders": ["content-type", "if-none-match"],
            "ExposeHeaders": ["etag"],
            "MaxAgeSeconds": 3600
          }
        ]
        """
    }

    static func document(_ rules: [String]) -> String {
        #"<?xml version="1.0" encoding="UTF-8"?>"#
            + #"<CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">"#
            + rules.map { "<CORSRule>\($0)</CORSRule>" }.joined()
            + "</CORSConfiguration>"
    }

    private static func compact(_ xml: String) -> String {
        xml.filter { !$0.isWhitespace }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
