import Foundation
import Observation

/// Persists the watched folders and the pause settings as
/// `watched-folders.json`, next to `destinations.json`.
@MainActor
@Observable
final class WatchedFolderStore {
    private(set) var settings = WatchSettings()

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Aktar", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("watched-folders.json")
        }
        load()
    }

    var folders: [WatchedFolder] { settings.folders }

    func folder(id: UUID) -> WatchedFolder? {
        settings.folders.first { $0.id == id }
    }

    func add(_ folder: WatchedFolder) {
        settings.folders.append(folder)
        save()
    }

    func update(_ folder: WatchedFolder) {
        guard let index = settings.folders.firstIndex(where: { $0.id == folder.id }) else { return }
        settings.folders[index] = folder
        save()
    }

    func remove(id: UUID) {
        settings.folders.removeAll { $0.id == id }
        save()
    }

    func setPausedUntil(_ pause: WatchSettings.Pause?) {
        settings.pausedUntil = pause
        save()
    }

    func setPauseOnBattery(_ on: Bool) {
        settings.pauseOnBattery = on
        save()
    }

    func setPauseOnMetered(_ on: Bool) {
        settings.pauseOnMetered = on
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? WatchSettings.decode(data) else { return }
        settings = decoded
    }

    private func save() {
        guard let data = try? settings.encoded() else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
