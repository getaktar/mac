import Foundation
import Observation

/// Live, folder-by-folder view of one destination's bucket. S3 has no real
/// folders, so a "folder" is a key prefix ending in "/", listed one level at
/// a time with a "/" delimiter and paged 1000 keys per request.
@MainActor
@Observable
final class BucketBrowserModel {
    let destination: DestinationConfig

    private(set) var prefix = ""
    private(set) var folders: [String] = []
    private(set) var objects: [BucketObject] = []
    private(set) var nextContinuationToken: String?
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var hasLoaded = false
    private(set) var busyKeys: Set<String> = []

    var selection: Set<String> = []
    var searchText = ""
    var searchScope: SearchScope = .bucket

    enum SearchScope: Hashable {
        case bucket
        case folder
    }

    // Search results. S3 can't search server-side, so a search lists every
    // key in scope page by page and matches names locally; the keys are kept
    // so refining the query doesn't list the bucket again.
    private(set) var searchResults: [BucketObject] = []
    private(set) var searchFolderResults: [String] = []
    private(set) var isSearching = false
    private(set) var searchScannedCount = 0
    private(set) var searchComplete = false
    private(set) var searchError: String?
    /// Bumped when the index is thrown away (Refresh), so a search that's
    /// showing restarts on fresh data.
    private(set) var searchGeneration = 0
    static let maxSearchResults = 2000
    /// An error from an action (delete, rename, new folder), shown as an alert.
    var actionError: String?

    @ObservationIgnored private var provider: S3Provider?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var temporaryURLs: [String: (url: URL, expires: Date)] = [:]
    @ObservationIgnored private var searchIndex: SearchIndex?
    @ObservationIgnored private var appliedQuery = ""

    private struct SearchIndex {
        let prefix: String
        var objects: [BucketObject] = []
        var folders: Set<String> = []
        var nextContinuationToken: String?
        var isComplete = false
    }

    init(destination: DestinationConfig) {
        self.destination = destination
    }

    // MARK: - Listing

    var isSearchActive: Bool { !searchQuery.isEmpty }

    private var searchQuery: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Where a search looks: the whole bucket, or the open folder and
    /// everything below it.
    var searchPrefix: String { searchScope == .folder ? prefix : "" }

    var visibleFolders: [String] { isSearchActive ? searchFolderResults : folders }

    var visibleObjects: [BucketObject] { isSearchActive ? searchResults : objects }

    var selectedObjects: [BucketObject] {
        visibleObjects.filter { selection.contains($0.key) }
    }

    func object(forKey key: String) -> BucketObject? {
        visibleObjects.first { $0.key == key } ?? objects.first { $0.key == key }
    }

    /// Breadcrumb entries from the bucket root down to the current folder.
    var breadcrumbs: [(name: String, prefix: String)] {
        var result: [(String, String)] = [(destination.bucket, "")]
        var running = ""
        for component in prefix.split(separator: "/") {
            running += component + "/"
            result.append((String(component), running))
        }
        return result
    }

    var parentPrefix: String? {
        guard !prefix.isEmpty else { return nil }
        return Self.parent(ofFolder: prefix)
    }

    func loadIfNeeded() {
        guard !hasLoaded, !isLoading else { return }
        reload()
    }

    func open(_ newPrefix: String) {
        prefix = newPrefix
        selection = []
        searchText = ""
        reload()
    }

    /// Reloads the open folder and forgets what search has listed so far.
    func refresh() {
        searchIndex = nil
        searchGeneration += 1
        reload()
    }

    func reload() {
        loadTask?.cancel()
        folders = []
        objects = []
        nextContinuationToken = nil
        load(continuationToken: nil)
    }

    func loadMore() {
        guard let nextContinuationToken, !isLoading else { return }
        load(continuationToken: nextContinuationToken)
    }

    private func load(continuationToken: String?) {
        isLoading = true
        loadError = nil
        let requestedPrefix = prefix
        loadTask = Task {
            defer {
                if requestedPrefix == prefix { isLoading = false }
            }
            do {
                let listing = try await storage().list(prefix: requestedPrefix, continuationToken: continuationToken)
                guard !Task.isCancelled, requestedPrefix == prefix else { return }
                folders += listing.folders
                objects += listing.objects
                nextContinuationToken = listing.nextContinuationToken
                hasLoaded = true
            } catch {
                guard !Task.isCancelled, requestedPrefix == prefix else { return }
                loadError = Self.message(for: error)
            }
        }
    }

    /// Reloads the current folder when an upload lands in it, and adds the
    /// new object to the search index.
    func uploadFinished(objectKey: String, byteSize: Int64) {
        addToSearchIndex(BucketObject(key: objectKey, size: byteSize, lastModified: .now))
        guard Self.parent(ofKey: objectKey) == prefix else { return }
        reload()
    }

    // MARK: - Search

    func runSearch() async {
        let query = searchQuery
        guard !query.isEmpty else {
            searchResults = []
            searchFolderResults = []
            isSearching = false
            searchError = nil
            return
        }
        let scopePrefix = searchPrefix
        if searchIndex?.prefix != scopePrefix {
            searchIndex = SearchIndex(prefix: scopePrefix)
        }
        searchError = nil
        applySearch(query)
        guard searchIndex?.isComplete == false else {
            isSearching = false
            return
        }

        isSearching = true
        do {
            while let index = searchIndex, index.prefix == scopePrefix, !index.isComplete {
                let page = try await storage().listRecursively(prefix: scopePrefix, continuationToken: index.nextContinuationToken)
                guard !Task.isCancelled, searchIndex?.prefix == scopePrefix,
                      searchIndex?.nextContinuationToken == index.nextContinuationToken else { return }
                searchIndex?.objects += page.objects
                searchIndex?.folders.formUnion(page.folders)
                for object in page.objects {
                    searchIndex?.folders.formUnion(Self.folders(containing: object.key, under: scopePrefix))
                }
                searchIndex?.nextContinuationToken = page.nextContinuationToken
                searchIndex?.isComplete = page.nextContinuationToken == nil
                applySearch(query, newObjects: page.objects)
            }
        } catch {
            guard !Task.isCancelled else { return }
            searchError = Self.message(for: error)
        }
        if !Task.isCancelled { isSearching = false }
    }

    /// Matches `query` against the index. With `newObjects`, only that page
    /// is matched and appended, so a long scan doesn't rescan what it has.
    private func applySearch(_ query: String, newObjects: [BucketObject]? = nil) {
        guard let index = searchIndex else { return }
        let matches: (BucketObject) -> Bool = { $0.name.localizedStandardContains(query) }
        if let newObjects, query == appliedQuery {
            let room = Self.maxSearchResults - searchResults.count
            if room > 0 { searchResults += newObjects.lazy.filter(matches).prefix(room) }
        } else {
            searchResults = Array(index.objects.lazy.filter(matches).prefix(Self.maxSearchResults))
        }
        appliedQuery = query
        searchFolderResults = index.folders
            .filter { Self.displayName(ofFolder: $0).localizedStandardContains(query) }
            .sorted()
        searchScannedCount = index.objects.count
        searchComplete = index.isComplete
    }

    private func addToSearchIndex(_ object: BucketObject) {
        guard var index = searchIndex, object.key.hasPrefix(index.prefix) else { return }
        index.objects.removeAll { $0.key == object.key }
        index.objects.append(object)
        index.folders.formUnion(Self.folders(containing: object.key, under: index.prefix))
        searchIndex = index
        if isSearchActive { applySearch(searchQuery) }
    }

    private func removeFromSearchIndex(key: String) {
        searchIndex?.objects.removeAll { $0.key == key }
        searchResults.removeAll { $0.key == key }
        searchScannedCount = searchIndex?.objects.count ?? 0
    }

    /// The folders between `prefix` and `key`, e.g. "a/" and "a/b/" for
    /// "a/b/c.png" under the bucket root.
    private static func folders(containing key: String, under prefix: String) -> [String] {
        guard key.hasPrefix(prefix) else { return [] }
        var result: [String] = []
        var running = prefix
        let components = key.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false).dropLast()
        for component in components {
            running += component + "/"
            result.append(running)
        }
        return result
    }

    // MARK: - Links

    func publicURL(for key: String) -> URL {
        PublicURLResolver.resolve(baseURL: destination.publicBaseURL, objectKey: key)
    }

    /// A presigned link. Previews use these too (cached for most of their
    /// lifetime), so they work for private buckets and misconfigured public
    /// base URLs alike.
    func temporaryURL(for key: String, validFor seconds: Int64) async throws -> URL {
        try await storage().temporaryURL(for: key, expiresIn: seconds)
    }

    func previewURL(for key: String) async -> URL? {
        if let cached = temporaryURLs[key], cached.expires > .now { return cached.url }
        guard let url = try? await temporaryURL(for: key, validFor: 3600) else { return nil }
        temporaryURLs[key] = (url, Date.now.addingTimeInterval(3000))
        return url
    }

    // MARK: - Actions

    /// Uploads into the current folder under each file's own name, adding
    /// " 2", " 3"… when that name is already taken so nothing is overwritten.
    func upload(_ fileURLs: [URL], source: UploadSource, using uploadManager: UploadManager) {
        let targetPrefix = prefix
        Task {
            var inputs: [UploadInput] = []
            var claimed = Set<String>()
            for fileURL in fileURLs {
                do {
                    let key = try await availableKey(for: fileURL.lastPathComponent, in: targetPrefix, excluding: claimed)
                    claimed.insert(key)
                    inputs.append(UploadInput(
                        fileURL: fileURL,
                        originalFilename: fileURL.lastPathComponent,
                        source: source,
                        objectKey: key
                    ))
                } catch {
                    actionError = Self.message(for: error)
                    return
                }
            }
            uploadManager.upload(inputs, to: destination)
        }
    }

    func createFolder(named rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty else { return }
        let folder = prefix + name + "/"
        do {
            try await storage().createFolder(prefix: folder)
            if !folders.contains(folder) {
                folders.append(folder)
                folders.sort()
            }
            if let index = searchIndex, folder.hasPrefix(index.prefix) {
                searchIndex?.folders.insert(folder)
                if isSearchActive { applySearch(searchQuery) }
            }
        } catch {
            actionError = Self.message(for: error)
        }
    }

    func delete(_ keys: [String], repository: UploadRepository) async {
        for key in keys {
            busyKeys.insert(key)
            defer { busyKeys.remove(key) }
            do {
                try await storage().delete(objectKey: key)
                objects.removeAll { $0.key == key }
                removeFromSearchIndex(key: key)
                selection.remove(key)
                repository.objectDeleted(key: key, destinationID: destination.id)
            } catch {
                actionError = Self.message(for: error)
                return
            }
        }
    }

    /// Renames or moves an object: `newKey` is a full key, so changing the
    /// folder part moves it. S3 does this as a copy followed by a delete.
    func move(_ object: BucketObject, to rawKey: String, repository: UploadRepository) async {
        let newKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !newKey.isEmpty, newKey != object.key else { return }
        busyKeys.insert(object.key)
        defer { busyKeys.remove(object.key) }
        do {
            let storage = try storage()
            if try await storage.objectExists(key: newKey) {
                actionError = String(localized: "An object named \u{201C}\(newKey)\u{201D} already exists.")
                return
            }
            try await storage.copy(from: object.key, to: newKey)
            try await storage.delete(objectKey: object.key)
            repository.objectMoved(from: object.key, to: newKey, destination: destination)
            temporaryURLs[object.key] = nil
            objects.removeAll { $0.key == object.key }
            removeFromSearchIndex(key: object.key)
            addToSearchIndex(BucketObject(key: newKey, size: object.size, lastModified: .now))
            selection.remove(object.key)
            if Self.parent(ofKey: newKey) == prefix {
                objects.append(BucketObject(key: newKey, size: object.size, lastModified: .now))
                objects.sort { $0.key < $1.key }
                selection = [newKey]
            } else {
                let folder = Self.topLevelFolder(of: newKey, under: prefix)
                if let folder, !folders.contains(folder) {
                    folders.append(folder)
                    folders.sort()
                }
            }
        } catch {
            actionError = Self.message(for: error)
        }
    }

    // MARK: - Helpers

    private func storage() throws -> S3Provider {
        if let provider { return provider }
        let credentials = try KeychainService.load(for: destination.id)
        let provider = S3Provider(config: destination, credentials: credentials)
        self.provider = provider
        return provider
    }

    private func availableKey(for filename: String, in folder: String, excluding claimed: Set<String>) async throws -> String {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder + filename
        var counter = 2
        while true {
            if !claimed.contains(candidate), try await !storage().objectExists(key: candidate) {
                return candidate
            }
            guard counter < 1000 else { return candidate }
            candidate = folder + Self.numbered(base, ext, counter)
            counter += 1
        }
    }

    private static func numbered(_ base: String, _ ext: String, _ counter: Int) -> String {
        ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
    }

    static func displayName(ofFolder folder: String) -> String {
        String(folder.dropLast().split(separator: "/", omittingEmptySubsequences: false).last ?? "")
    }

    static func parent(ofKey key: String) -> String {
        guard let slash = key.lastIndex(of: "/") else { return "" }
        return String(key[...slash])
    }

    static func parent(ofFolder folder: String) -> String {
        parent(ofKey: String(folder.dropLast()))
    }

    /// The folder directly under `prefix` that contains `key`, if any.
    private static func topLevelFolder(of key: String, under prefix: String) -> String? {
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return prefix + rest[...slash]
    }

    private static func message(for error: Error) -> String {
        if let error = error as? KeychainError, case .notFound = error {
            return String(localized: "No credentials found in Keychain for this destination.")
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
