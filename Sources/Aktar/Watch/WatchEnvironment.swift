import AppKit
import Darwin
import IOKit.ps
import Network

/// Paths as the user knows them. Inside the sandbox `NSHomeDirectory()` is
/// the app's container, not the user's home folder.
enum UserPaths {
    static var home: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// "~/Desktop" for a path in the home folder.
    static func abbreviated(_ path: String) -> String {
        let home = home
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Aktar's own data, caches and temporary files, which must never be
    /// watched (and nothing around them either).
    static var appDataFolders: [String] {
        var folders = [
            home + "/Library/Containers/com.getaktar.mac",
            home + "/Library/Containers/com.getaktar.mac.share",
            home + "/Library/Application Support/Aktar",
            home + "/Library/Caches/com.getaktar.mac",
        ]
        let manager = FileManager.default
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            if let url = manager.urls(for: directory, in: .userDomainMask).first {
                folders.append(url.path)
            }
        }
        folders.append(manager.temporaryDirectory.path)
        return folders.map(ForbiddenFolders.canonicalPath)
    }
}

/// Where macOS saves screenshots: Screenshot's Options > Save to, which is
/// the Desktop unless changed.
enum ScreenshotLocation {
    static func folder() -> URL {
        let desktop = URL(fileURLWithPath: UserPaths.home, isDirectory: true).appendingPathComponent("Desktop", isDirectory: true)
        guard let raw = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
              !raw.isEmpty else { return desktop }
        let expanded = raw.hasPrefix("~") ? UserPaths.home + raw.dropFirst() : raw
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        return FileInspector.isDirectory(url) ? url : desktop
    }
}

/// The two things that can pause watching on their own: running on
/// battery, and a metered network (Low Data Mode, or one macOS knows is
/// expensive, like a phone's hotspot). Both are system notifications, and
/// each is only listened to while something needs it (see
/// `WatchMonitoring`): nothing runs with no folders.
@MainActor
final class WatchConditions {
    private(set) var onBattery = false
    private(set) var meteredNetwork = false
    private(set) var online = true
    /// Called on the main actor whenever one of them changes. `cameOnline`
    /// is set when the network just came back.
    var onChange: ((_ cameOnline: Bool) -> Void)?

    private var pathMonitor: NWPathMonitor?
    private var powerSource: CFRunLoopSource?

    func setMonitoring(_ needs: WatchMonitoring.Needs) {
        if needs.network, pathMonitor == nil {
            // A monitor can't be restarted once cancelled: a new one each time.
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let online = path.status == .satisfied
                let metered = path.isExpensive || path.isConstrained
                Task { @MainActor in self?.networkChanged(online: online, metered: metered) }
            }
            monitor.start(queue: .main)
            pathMonitor = monitor
        } else if !needs.network, let monitor = pathMonitor {
            monitor.cancel()
            pathMonitor = nil
            meteredNetwork = false
            online = true
        }

        if needs.power, powerSource == nil {
            onBattery = Self.isOnBattery()
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let conditions = Unmanaged<WatchConditions>.fromOpaque(context).takeUnretainedValue()
                // Delivered on the main run loop.
                MainActor.assumeIsolated { conditions.powerChanged() }
            }, context)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
                powerSource = source
            }
        } else if !needs.power, let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = nil
            onBattery = false
        }
    }

    private func networkChanged(online: Bool, metered: Bool) {
        let cameOnline = online && !self.online
        guard online != self.online || metered != meteredNetwork else { return }
        self.online = online
        meteredNetwork = metered
        onChange?(cameOnline)
    }

    private func powerChanged() {
        let battery = Self.isOnBattery()
        guard battery != onBattery else { return }
        onBattery = battery
        onChange?(false)
    }

    private static func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
