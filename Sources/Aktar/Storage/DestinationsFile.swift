import Foundation

/// destinations.json: `{"destinations": [...], "defaultID": ...}`.
///
/// Each destination is read on its own, so one this version can't read (a
/// kind of storage a newer version added, say) doesn't take the others
/// with it. Those are kept as they were and written back on save, so going
/// back to an older version and forward again loses nothing.
enum DestinationsFile {
    struct Contents {
        var destinations: [DestinationConfig] = []
        var defaultID: UUID?
        /// Destinations this version can't read, as JSON objects.
        var unreadable: [Any] = []
    }

    /// Nil when the data isn't a destinations file at all (not JSON, or
    /// not an object), which the caller keeps a copy of before saving over it.
    static func decode(_ data: Data) -> Contents? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var contents = Contents()
        if let id = root["defaultID"] as? String {
            contents.defaultID = UUID(uuidString: id)
        }
        for entry in root["destinations"] as? [Any] ?? [] {
            if let entryData = try? JSONSerialization.data(withJSONObject: entry),
               let destination = try? JSONDecoder().decode(DestinationConfig.self, from: entryData) {
                contents.destinations.append(destination)
            } else {
                contents.unreadable.append(entry)
            }
        }
        return contents
    }

    static func encode(_ contents: Contents) -> Data? {
        var entries: [Any] = []
        for destination in contents.destinations {
            guard let data = try? JSONEncoder().encode(destination),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            entries.append(object)
        }
        entries.append(contentsOf: contents.unreadable)
        var root: [String: Any] = ["destinations": entries]
        if let defaultID = contents.defaultID {
            root["defaultID"] = defaultID.uuidString
        }
        return try? JSONSerialization.data(withJSONObject: root)
    }
}
