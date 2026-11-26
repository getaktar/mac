import Foundation
import KeyboardShortcuts
import Observation

/// Persists non-secret destination configuration as JSON.
/// Secrets never live here, see `KeychainService`.
@MainActor
@Observable
final class DestinationStore {
    private(set) var destinations: [DestinationConfig] = []
    /// The default destination. Each destination's `isDefault` flag mirrors
    /// this (Settings shows the flag), and `syncDefaultFlags()` keeps the
    /// two in step after every change.
    private var defaultID: UUID?
    /// Destinations this version can't read, kept for the next save; see
    /// `DestinationsFile`.
    private var unreadable: [Any] = []

    private let fileURL: URL
    /// Told after a saved destination changes, with what it was before.
    @ObservationIgnored var onUpdate: ((_ old: DestinationConfig, _ new: DestinationConfig) -> Void)?
    /// Told after a destination is added or removed.
    @ObservationIgnored var onListChange: (() -> Void)?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aktar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("destinations.json")
        load()
    }

    var defaultDestination: DestinationConfig? {
        destinations.first { $0.id == defaultID } ?? destinations.first
    }

    func add(_ destination: DestinationConfig) {
        var destination = destination
        if destinations.isEmpty {
            destination.isDefault = true
            defaultID = destination.id
        }
        destinations.append(destination)
        syncDefaultFlags()
        save()
        onListChange?()
    }

    func update(_ destination: DestinationConfig) {
        guard let index = destinations.firstIndex(where: { $0.id == destination.id }) else { return }
        let old = destinations[index]
        destinations[index] = destination
        syncDefaultFlags()
        save()
        onUpdate?(old, destination)
    }

    func remove(_ destination: DestinationConfig) {
        destinations.removeAll { $0.id == destination.id }
        try? KeychainService.delete(for: destination.id)
        ExpiryRuleStore.shared.set(destination.id, active: false)
        RemoteThumbnailLoader.shared.forget(destinationID: destination.id)
        KeyboardShortcuts.reset(.uploadToDestination(destination.id))
        if defaultID == destination.id {
            defaultID = destinations.first?.id
        }
        syncDefaultFlags()
        save()
        onListChange?()
    }

    /// A copy under a new ID with the same keys, as a starting point for
    /// another profile on the same bucket. Nil if the keys can't be read.
    func duplicate(_ destination: DestinationConfig) -> DestinationConfig? {
        guard let credentials = try? KeychainService.load(for: destination.id) else { return nil }
        var copy = destination
        copy.id = UUID()
        copy.name = String(localized: "\(destination.name) Copy")
        copy.isDefault = false
        do {
            try KeychainService.save(credentials, for: copy.id)
        } catch {
            return nil
        }
        ExpiryRuleStore.shared.set(copy.id, active: ExpiryRuleStore.shared.isActive(destination.id))
        add(copy)
        return copy
    }

    func setDefault(_ destination: DestinationConfig) {
        defaultID = destination.id
        syncDefaultFlags()
        save()
    }

    /// Before this existed, "Set as Default" only moved `defaultID` and left
    /// the flags as they were, so saved files can disagree. `defaultID` is
    /// what uploads use, so it wins; the flags are only a fallback when it
    /// points nowhere.
    private func syncDefaultFlags() {
        if !destinations.contains(where: { $0.id == defaultID }) {
            defaultID = destinations.first(where: \.isDefault)?.id ?? destinations.first?.id
        }
        for index in destinations.indices {
            destinations[index].isDefault = destinations[index].id == defaultID
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let contents = DestinationsFile.decode(data) else {
            // Not a destinations file at all: keep a copy, since the next
            // save replaces it.
            let copy = fileURL.deletingLastPathComponent().appendingPathComponent("destinations.unreadable.json")
            try? data.write(to: copy, options: .atomic)
            return
        }
        destinations = contents.destinations
        defaultID = contents.defaultID
        unreadable = contents.unreadable
        syncDefaultFlags()
    }

    private func save() {
        let contents = DestinationsFile.Contents(destinations: destinations, defaultID: defaultID, unreadable: unreadable)
        guard let data = DestinationsFile.encode(contents) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
