import Foundation

/// Expiring uploads ("Delete after N days"). An expiring upload is stored
/// under `tmp/{N}d/` in front of the key the destination's template would
/// produce, and a bucket lifecycle rule per duration deletes everything under
/// that prefix N days after upload, whether or not any Aktar app is still
/// around. The Windows and mobile apps use the same prefixes and rule IDs, so
/// a bucket shared between devices ends up with one set of rules.
enum UploadExpiry {
    /// The only durations offered. Each one is its own prefix and its own
    /// lifecycle rule, so arbitrary values aren't possible.
    static let options = [1, 7, 14, 30]

    static let rootPrefix = "tmp/"
    static let defaultsKey = "uploadExpiryDays"

    static func prefix(days: Int) -> String {
        "\(rootPrefix)\(days)d/"
    }

    static func ruleID(days: Int) -> String {
        "aktar-expire-\(days)d"
    }

    static func key(_ key: String, days: Int?) -> String {
        guard let days else { return key }
        return prefix(days: days) + key
    }

    /// The duration a key's prefix stands for, or nil if it isn't under one
    /// of the expiring prefixes.
    static func days(forKey key: String) -> Int? {
        options.first { key.hasPrefix(prefix(days: $0)) }
    }

    /// Accepts 0 (off) or one of `options`; anything else is invalid.
    static func isValid(_ days: Int) -> Bool {
        days == 0 || options.contains(days)
    }

    static func label(days: Int) -> String {
        switch days {
        case 0: return String(localized: "Never")
        case 1: return String(localized: "1 day")
        default: return String(localized: "\(days) days")
        }
    }

    static func deletionLabel(for date: Date, now: Date = .now) -> String {
        if date <= now { return String(localized: "Expired") }
        return String(localized: "Deletes \(date.formatted(.dateTime.month(.abbreviated).day()))")
    }
}

/// Which destinations have Aktar's lifecycle rules in their bucket. Only
/// those offer "Delete after": without the rules nothing would delete the
/// file while Aktar isn't running. Observable so the menu bar updates as
/// soon as a destination is set up.
@MainActor
@Observable
final class ExpiryRuleStore {
    static let shared = ExpiryRuleStore()

    private static let defaultsKey = "expiryRulesActiveDestinations"
    private var activeIDs: Set<String>

    private init() {
        activeIDs = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func isActive(_ destinationID: UUID) -> Bool {
        activeIDs.contains(destinationID.uuidString)
    }

    func set(_ destinationID: UUID, active: Bool) {
        if active {
            activeIDs.insert(destinationID.uuidString)
        } else {
            activeIDs.remove(destinationID.uuidString)
        }
        UserDefaults.standard.set(Array(activeIDs), forKey: Self.defaultsKey)
    }
}
