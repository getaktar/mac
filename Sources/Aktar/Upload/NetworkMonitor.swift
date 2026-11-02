import Foundation
import Network

/// Whether the Mac is online, for uploads waiting for a connection (see
/// `UploadManager`, "Offline queue"). One system path monitor, delivered
/// on the main queue.
@MainActor
final class NetworkMonitor {
    private(set) var isOnline = true
    /// Called when the network comes back.
    var onCameOnline: (() -> Void)?

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            MainActor.assumeIsolated { self?.update(online: online) }
        }
        monitor.start(queue: .main)
    }

    private func update(online: Bool) {
        let cameOnline = online && !isOnline
        isOnline = online
        if cameOnline { onCameOnline?() }
    }
}

/// When an upload waiting for the network tries again while the network
/// looks up (one that's down waits for it to come back instead).
enum OfflineRetry {
    static let delays: [TimeInterval] = [15, 30, 60, 120, 300]

    /// The wait after `tries` failed tries (the last delay from then on).
    static func delay(afterTries tries: Int) -> TimeInterval {
        delays[min(max(tries, 1), delays.count) - 1]
    }
}
