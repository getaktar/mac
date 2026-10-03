import Foundation

/// The limits on a timed pause, wherever its length comes from (a menu,
/// an aktar:// link or the local API), so a huge number can't overflow the
/// date or the timer that ends the pause.
enum WatchPause {
    /// One year.
    static let maxMinutes = 525_600
    /// The longest single wait for the end of a pause; a longer pause
    /// waits again when it's over.
    static let maxWait: TimeInterval = 86_400

    /// `minutes` within 1...`maxMinutes`, or nil for zero or less.
    static func clampedMinutes(_ minutes: Int) -> Int? {
        guard minutes > 0 else { return nil }
        return min(minutes, maxMinutes)
    }

    /// The minutes of a link's `minutes=`: digits only, more than zero.
    /// A number too big for an Int is a year like any other big one.
    /// Anything else is nil (and the link is ignored).
    static func minutes(fromQuery raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard let value = Int(raw) else { return maxMinutes }
        return clampedMinutes(value)
    }

    /// When a pause of `minutes` started at `now` ends.
    static func end(minutes: Int, from now: Date = Date()) -> Date {
        now.addingTimeInterval(TimeInterval(clampedMinutes(minutes) ?? 1) * 60)
    }

    /// How long to wait before looking at a pause that ends at `date`
    /// again: never negative, never more than `maxWait`.
    static func wait(until date: Date, from now: Date = Date()) -> TimeInterval {
        let remaining = date.timeIntervalSince(now)
        guard remaining.isFinite else { return remaining > 0 ? maxWait : 0 }
        return min(max(remaining, 0), maxWait) + 0.5
    }
}
