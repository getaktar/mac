import Foundation

/// How long the watcher waits, and for what. Tests shrink these.
struct WatchTiming: Sendable {
    /// The first recheck of a new file; later ones back off from here.
    var stabilityInitial: TimeInterval = 0.5
    var stabilityMax: TimeInterval = 30
    /// A file whose last write is more recent than this is still being
    /// written, whatever its size says.
    var minimumAge: TimeInterval = 1
    /// Ready files are collected this long after the last one, and
    /// uploaded together.
    var batchWindow: TimeInterval = 0.5
    /// More new files than this at once need a confirmation.
    var largeBatch = 50
    /// Network volumes don't report other computers' changes, so they're
    /// polled: this often after a change, backing off to 5 minutes while
    /// nothing changes.
    var networkPoll: TimeInterval = 30
    /// Every folder is scanned this often (plus a random part, so folders
    /// don't wake together), only as a backstop for a missed event.
    var safetyScan: TimeInterval = 3600
    /// How long a deleted file's upload waits before it's deleted from the
    /// bucket, in case the file comes back (an app saving by replacing it).
    var deleteGrace: TimeInterval = 3
    /// More deletions than this at once need a confirmation.
    var largeDeletion = 50
    /// How long the ledger remembers a deleted file.
    var goneRetention: TimeInterval = 86_400
    /// Waits before retrying an upload that failed on the network.
    var retryDelays: [TimeInterval] = [60, 300, 900, 3600]

    static let standard = WatchTiming()

    /// The wait before retry number `attempts` (1 for the first failure);
    /// the last delay repeats.
    func retryDelay(afterAttempts attempts: Int) -> TimeInterval {
        guard !retryDelays.isEmpty else { return 60 }
        return retryDelays[min(max(attempts, 1), retryDelays.count) - 1]
    }
}

/// Decides when a file has finished being written. Writers give no signal,
/// so a file counts as done once two checks in a row see the same size and
/// modification date, and that date is a little in the past. Checks start a
/// second apart and back off to half a minute for a file that's still
/// growing (a long download). A file never times out: it stays waiting.
struct StabilityTracker: Equatable, Sendable {
    struct Observation: Equatable, Sendable {
        var size: Int64
        var modified: Date
    }

    enum Verdict: Equatable, Sendable {
        case ready
        /// Check again after this long.
        case wait(TimeInterval)
    }

    private(set) var last: Observation?
    private(set) var interval: TimeInterval
    private let timing: WatchTiming

    static func == (lhs: StabilityTracker, rhs: StabilityTracker) -> Bool {
        lhs.last == rhs.last && lhs.interval == rhs.interval
    }

    init(timing: WatchTiming) {
        self.timing = timing
        interval = timing.stabilityInitial
    }

    mutating func observe(_ observation: Observation, now: Date) -> Verdict {
        defer { last = observation }
        let age = now.timeIntervalSince(observation.modified)
        if let last, last == observation, age >= timing.minimumAge {
            return .ready
        }
        let delay = interval
        interval = min(interval * 2, timing.stabilityMax)
        // Unchanged but too fresh: no point waiting past the moment it's
        // old enough.
        if let last, last == observation {
            return .wait(min(delay, max(timing.minimumAge - age, 0.05)))
        }
        return .wait(delay)
    }

    /// "Upload Pending Now": the next check decides on what it sees.
    mutating func expedite() {
        interval = timing.stabilityInitial
    }
}
