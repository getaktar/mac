import Foundation
import Observation

/// Persists non-secret destination configuration as JSON.
/// Secrets never live here, see `KeychainService`.
@MainActor
@Observable
final class DestinationStore {
    private(set) var destinations: [DestinationConfig] = []
    private var defaultID: UUID?

    private let fileURL: URL

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
        save()
    }

    func update(_ destination: DestinationConfig) {
        guard let index = destinations.firstIndex(where: { $0.id == destination.id }) else { return }
        destinations[index] = destination
        save()
    }

    func remove(_ destination: DestinationConfig) {
        destinations.removeAll { $0.id == destination.id }
        try? KeychainService.delete(for: destination.id)
        if defaultID == destination.id {
            defaultID = destinations.first?.id
        }
        save()
    }

    func setDefault(_ destination: DestinationConfig) {
        defaultID = destination.id
        save()
    }

    private struct Wrapper: Codable {
        var destinations: [DestinationConfig]
        var defaultID: UUID?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { return }
        destinations = wrapper.destinations
        defaultID = wrapper.defaultID
    }

    private func save() {
        let wrapper = Wrapper(destinations: destinations, defaultID: defaultID)
        guard let data = try? JSONEncoder().encode(wrapper) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
