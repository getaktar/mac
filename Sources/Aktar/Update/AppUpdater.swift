import AppKit
import Observation
import Sparkle

/// Wraps Sparkle's standard updater so SwiftUI views can drive it. Updates
/// are published as GitHub release assets: the feed is `appcast.xml` on the
/// latest release (see `SUFeedURL` in project.yml and scripts/release.sh),
/// and every archive is verified against `SUPublicEDKey` before installing.
@MainActor
@Observable
final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    override init() {
        super.init()
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        // Sparkle changes this on the main thread, so KVO delivers there too.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            access(keyPath: \.automaticallyDownloadsUpdates)
            return controller?.updater.automaticallyDownloadsUpdates ?? false
        }
        set {
            withMutation(keyPath: \.automaticallyDownloadsUpdates) {
                controller?.updater.automaticallyDownloadsUpdates = newValue
            }
        }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    // MARK: - SPUStandardUserDriverDelegate

    // Aktar is a menu bar (accessory) app, so Sparkle can't count on a
    // focused window to show a scheduled update in. Opting into gentle
    // reminders tells Sparkle that we bring the alert forward ourselves.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // The alert window becoming key promotes Aktar to a regular app (see
        // AppDelegate); activating makes sure it's in front, not behind
        // whatever the user is working in.
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}
