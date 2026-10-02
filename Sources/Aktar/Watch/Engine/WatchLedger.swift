import Foundation
import SQLite3

/// One file a watched folder has dealt with, so it's never uploaded twice
/// and a restart picks up where it left off.
struct LedgerEntry: Equatable, Sendable {
    enum State: String, Sendable {
        case uploaded
        /// Left alone on purpose: there before the folder was added, or
        /// skipped in a large batch.
        case skipped
        case failed
        /// Handed to the upload queue and not finished yet.
        case pending
        /// The file was deleted from the folder (checked on disk). A new
        /// file at this path is new, not a change of this one.
        case gone
    }

    /// Deleting the upload of a gone file from the bucket.
    enum RemoteDelete: Int, Sendable {
        case none = 0
        /// Waiting for the grace period, or a retry.
        case scheduled = 1
        /// Waiting for the user: part of a large deletion, or asked about
        /// because the folder asks before deleting.
        case awaitingConfirmation = 2
        /// The user said Delete from Bucket; runs without asking again.
        case confirmed = 3
    }

    var folderID: UUID
    /// "/"-separated path inside the folder.
    var relativePath: String
    var size: Int64
    /// Modification date, as seconds since 1970.
    var mtime: Double
    var fileID: UInt64?
    /// SHA-256 of the file as it was handled, when the folder reacts to
    /// changes.
    var sha256: String?
    var state: State
    var attempts = 0
    var lastError: String?
    /// The failure was the network or a busy provider, so it's retried on
    /// its own.
    var retryable = false
    var objectKey: String?
    var url: String?
    var destinationID: UUID?
    var handledAt = Date()
    /// The upload reused the link of an earlier one, whose file isn't this
    /// row's to delete.
    var reused = false
    /// When the file was found deleted.
    var goneAt: Date?
    var remoteDelete: RemoteDelete = .none

    /// What a gone row was before: uploaded when it has a key, otherwise
    /// left alone.
    var stateBeforeGone: State {
        objectKey != nil ? .uploaded : .skipped
    }

    /// Whether `size` and `mtime` still describe the file.
    func matches(size: Int64, modified: Date) -> Bool {
        self.size == size && abs(mtime - modified.timeIntervalSince1970) < 0.001
    }
}

/// What to do with a file that's ready, given what the ledger knows.
enum LedgerDecision: Equatable, Sendable {
    /// Not seen before (or a pending upload that never finished).
    case upload
    /// It changed since it was uploaded. `replacing` is that upload, whose
    /// key is reused when the folder replaces uploaded files.
    case uploadChanged(replacing: LedgerEntry)
    /// The same file under a new name: the entry moves along, nothing is
    /// uploaded.
    case renamed(from: LedgerEntry)
    /// Size or date changed since the upload, and only the contents can
    /// tell whether it really did: hash it and decide again.
    case needsHash
    /// Already handled. `refresh` is set when the entry should take the
    /// file's new date (touched, same contents).
    case skip(refresh: Bool)
    /// A file came back at a gone row's path within the grace period (an
    /// app saving by replacing it): the row is restored as `restored`, any
    /// remote delete is called off, and the file is decided against it.
    case reappeared(restored: LedgerEntry)
    /// Failed before, and waits for a retry rather than an event.
    case failedEarlier
}

enum LedgerRules {
    /// - `entry`: the ledger's row for this path, if any.
    /// - `renameCandidates`: rows of this folder with the same file ID;
    ///   `pathExists` says whether their path is still on disk.
    /// - `sha256`: the file's hash, once `.needsHash` asked for it.
    /// - `grace`: how long after its deletion a file that comes back is
    ///   still the same file.
    static func decide(
        size: Int64,
        modified: Date,
        fileID: UInt64?,
        entry: LedgerEntry?,
        modifiedPolicy: ModifiedPolicy,
        renameCandidates: [LedgerEntry],
        pathExists: (String) -> Bool,
        sha256: String? = nil,
        now: Date = Date(),
        grace: TimeInterval = 10
    ) -> LedgerDecision {
        guard let entry else {
            if let fileID,
               let moved = renameCandidates.first(where: {
                   $0.fileID == fileID && $0.matches(size: size, modified: modified) && $0.state != .pending && !pathExists($0.relativePath)
               }) {
                return .renamed(from: moved)
            }
            return .upload
        }
        switch entry.state {
        case .pending:
            return .upload
        case .gone:
            if let goneAt = entry.goneAt, now.timeIntervalSince(goneAt) < grace {
                var restored = entry
                restored.state = entry.stateBeforeGone
                restored.goneAt = nil
                restored.remoteDelete = .none
                return .reappeared(restored: restored)
            }
            return .upload
        case .skipped:
            return .skip(refresh: false)
        case .failed:
            return .failedEarlier
        case .uploaded:
            guard modifiedPolicy != .ignore else { return .skip(refresh: false) }
            if entry.matches(size: size, modified: modified) { return .skip(refresh: false) }
            // Without a hash from the upload there's nothing to compare
            // with, and the date says it changed.
            guard let previous = entry.sha256 else { return .uploadChanged(replacing: entry) }
            guard let sha256 else { return .needsHash }
            return sha256 == previous ? .skip(refresh: true) : .uploadChanged(replacing: entry)
        }
    }
}

/// What a scan needs to know about a row: enough to tell, off the main
/// actor, whether a file on disk could be new.
struct LedgerSnapshot: Sendable {
    let size: Int64
    let mtime: Double
    let state: LedgerEntry.State
}

/// What marking files gone did.
struct GoneResult: Sendable, Equatable {
    /// Gone rows whose upload is now scheduled for a remote delete.
    var scheduled: [String] = []
    /// Failed rows whose file is gone: forgotten, nothing to retry.
    var forgotten: [String] = []
}

/// Where the ledger lives. An SQLite file next to the folder list, or in
/// memory for tests. Safe to use from any thread: scans read it off the
/// main actor.
protocol WatchLedgerStore: AnyObject, Sendable {
    func entry(folderID: UUID, relativePath: String) -> LedgerEntry?
    func entries(folderID: UUID) -> [LedgerEntry]
    func entries(folderID: UUID, fileID: UInt64) -> [LedgerEntry]
    func entries(folderID: UUID, state: LedgerEntry.State) -> [LedgerEntry]
    /// Only the paths, for keeping counts and schedules in memory.
    func paths(folderID: UUID, state: LedgerEntry.State) -> [String]
    /// Every row of the folder, reduced to what a scan compares.
    func snapshot(folderID: UUID) -> [String: LedgerSnapshot]
    func count(folderID: UUID, state: LedgerEntry.State) -> Int
    func upsert(_ entry: LedgerEntry)
    func upsert(_ entries: [LedgerEntry])
    /// A finished upload and the folder's last upload time, in one write.
    func recordUpload(_ entry: LedgerEntry, at date: Date)
    func delete(folderID: UUID, relativePath: String)
    func deleteAll(folderID: UUID)
    /// Moves a row to a new path (a rename on disk).
    func move(folderID: UUID, from oldPath: String, to newPath: String)
    /// Marks the uploaded and skipped rows of `paths` gone at `date`, in one
    /// transaction; uploaded ones with a key get a remote delete scheduled
    /// when `deleteRemotely`. Failed rows are forgotten. Other rows are
    /// left alone.
    func markGone(folderID: UUID, paths: [String], at date: Date, deleteRemotely: Bool) -> GoneResult
    /// Sets the remote delete of the gone rows of `paths`.
    func setRemoteDelete(_ state: LedgerEntry.RemoteDelete, folderID: UUID, paths: [String])
    func lastUploadAt(folderID: UUID) -> Date?
    func setLastUploadAt(_ date: Date, folderID: UUID)
    /// Rows other than this one (in any folder) that point at the same
    /// object, whose upload therefore isn't this row's alone to delete.
    func otherReferences(destinationID: UUID, objectKey: String, excludingFolderID: UUID, relativePath: String) -> Int
    /// Forgets gone rows deleted before `date` that have no remote delete
    /// left to do.
    func purgeGone(folderID: UUID, before date: Date)
}

/// The ledger in SQLite: one table of files, keyed by folder and path, and
/// one of per-folder facts that outlive the files (the last upload).
/// Statements are prepared once and reused; a lock serializes callers.
final class SQLiteLedger: WatchLedgerStore, @unchecked Sendable {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let lock = NSRecursiveLock()

    /// `path` nil keeps it in memory.
    init(path: String?) {
        let target = path ?? ":memory:"
        if sqlite3_open_v2(target, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
            sqlite3_close(db)
            db = nil
            sqlite3_open(":memory:", &db)
        }
        execute("PRAGMA journal_mode=WAL")
        // WAL with NORMAL survives a crash; only a power cut can lose the
        // last moments, which the next scan finds again.
        execute("PRAGMA synchronous=NORMAL")
        execute("""
            CREATE TABLE IF NOT EXISTS files (
                folder_id TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                file_id INTEGER,
                sha256 TEXT,
                state TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                retryable INTEGER NOT NULL DEFAULT 0,
                object_key TEXT,
                url TEXT,
                destination_id TEXT,
                handled_at REAL NOT NULL,
                reused INTEGER NOT NULL DEFAULT 0,
                gone_at REAL,
                remote_delete INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (folder_id, relative_path)
            )
            """)
        // Ledgers made before deleted files were tracked.
        execute("ALTER TABLE files ADD COLUMN reused INTEGER NOT NULL DEFAULT 0")
        execute("ALTER TABLE files ADD COLUMN gone_at REAL")
        execute("ALTER TABLE files ADD COLUMN remote_delete INTEGER NOT NULL DEFAULT 0")
        execute("CREATE INDEX IF NOT EXISTS files_object ON files (destination_id, object_key)")
        execute("CREATE INDEX IF NOT EXISTS files_file_id ON files (folder_id, file_id)")
        execute("CREATE INDEX IF NOT EXISTS files_state ON files (folder_id, state)")
        execute("CREATE TABLE IF NOT EXISTS folders (folder_id TEXT PRIMARY KEY, last_upload_at REAL, last_event_id INTEGER)")
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    private static let columns = "folder_id, relative_path, size, mtime, file_id, sha256, state, attempts, last_error, retryable, object_key, url, destination_id, handled_at, reused, gone_at, remote_delete"

    func entry(folderID: UUID, relativePath: String) -> LedgerEntry? {
        query("SELECT \(Self.columns) FROM files WHERE folder_id = ? AND relative_path = ?", [.text(folderID.uuidString), .text(relativePath)]).first
    }

    func entries(folderID: UUID) -> [LedgerEntry] {
        query("SELECT \(Self.columns) FROM files WHERE folder_id = ?", [.text(folderID.uuidString)])
    }

    func entries(folderID: UUID, fileID: UInt64) -> [LedgerEntry] {
        query("SELECT \(Self.columns) FROM files WHERE folder_id = ? AND file_id = ?", [.text(folderID.uuidString), .int(Int64(bitPattern: fileID))])
    }

    func entries(folderID: UUID, state: LedgerEntry.State) -> [LedgerEntry] {
        query("SELECT \(Self.columns) FROM files WHERE folder_id = ? AND state = ?", [.text(folderID.uuidString), .text(state.rawValue)])
    }

    func paths(folderID: UUID, state: LedgerEntry.State) -> [String] {
        var result: [String] = []
        run("SELECT relative_path FROM files WHERE folder_id = ? AND state = ?", [.text(folderID.uuidString), .text(state.rawValue)]) { statement in
            if let raw = sqlite3_column_text(statement, 0) { result.append(String(cString: raw)) }
        }
        return result
    }

    func snapshot(folderID: UUID) -> [String: LedgerSnapshot] {
        var result: [String: LedgerSnapshot] = [:]
        run("SELECT relative_path, size, mtime, state FROM files WHERE folder_id = ?", [.text(folderID.uuidString)]) { statement in
            guard let path = sqlite3_column_text(statement, 0), let state = sqlite3_column_text(statement, 3),
                  let parsed = LedgerEntry.State(rawValue: String(cString: state)) else { return }
            result[String(cString: path)] = LedgerSnapshot(
                size: sqlite3_column_int64(statement, 1),
                mtime: sqlite3_column_double(statement, 2),
                state: parsed
            )
        }
        return result
    }

    func count(folderID: UUID, state: LedgerEntry.State) -> Int {
        var count = 0
        run("SELECT COUNT(*) FROM files WHERE folder_id = ? AND state = ?", [.text(folderID.uuidString), .text(state.rawValue)]) { statement in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        return count
    }

    func upsert(_ entry: LedgerEntry) {
        withLock { write(entry) }
    }

    func upsert(_ entries: [LedgerEntry]) {
        guard !entries.isEmpty else { return }
        transaction { entries.forEach(write) }
    }

    func recordUpload(_ entry: LedgerEntry, at date: Date) {
        transaction {
            write(entry)
            setLastUploadAt(date, folderID: entry.folderID)
        }
    }

    private func write(_ entry: LedgerEntry) {
        run("INSERT OR REPLACE INTO files (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
            .text(entry.folderID.uuidString),
            .text(entry.relativePath),
            .int(entry.size),
            .real(entry.mtime),
            entry.fileID.map { .int(Int64(bitPattern: $0)) } ?? .null,
            entry.sha256.map { .text($0) } ?? .null,
            .text(entry.state.rawValue),
            .int(Int64(entry.attempts)),
            entry.lastError.map { .text($0) } ?? .null,
            .int(entry.retryable ? 1 : 0),
            entry.objectKey.map { .text($0) } ?? .null,
            entry.url.map { .text($0) } ?? .null,
            entry.destinationID.map { .text($0.uuidString) } ?? .null,
            .real(entry.handledAt.timeIntervalSince1970),
            .int(entry.reused ? 1 : 0),
            entry.goneAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            .int(Int64(entry.remoteDelete.rawValue)),
        ])
    }

    func delete(folderID: UUID, relativePath: String) {
        run("DELETE FROM files WHERE folder_id = ? AND relative_path = ?", [.text(folderID.uuidString), .text(relativePath)])
    }

    func deleteAll(folderID: UUID) {
        transaction {
            run("DELETE FROM files WHERE folder_id = ?", [.text(folderID.uuidString)])
            run("DELETE FROM folders WHERE folder_id = ?", [.text(folderID.uuidString)])
        }
    }

    func move(folderID: UUID, from oldPath: String, to newPath: String) {
        transaction {
            run("DELETE FROM files WHERE folder_id = ? AND relative_path = ?", [.text(folderID.uuidString), .text(newPath)])
            run("UPDATE files SET relative_path = ? WHERE folder_id = ? AND relative_path = ?", [.text(newPath), .text(folderID.uuidString), .text(oldPath)])
        }
    }

    func markGone(folderID: UUID, paths: [String], at date: Date, deleteRemotely: Bool) -> GoneResult {
        var result = GoneResult()
        guard !paths.isEmpty else { return result }
        let folder = folderID.uuidString
        transaction {
            for path in paths {
                var state: String?
                var hasKey = false
                run("SELECT state, object_key IS NOT NULL FROM files WHERE folder_id = ? AND relative_path = ?", [.text(folder), .text(path)]) { statement in
                    state = sqlite3_column_text(statement, 0).map { String(cString: $0) }
                    hasKey = sqlite3_column_int64(statement, 1) != 0
                }
                switch state.flatMap(LedgerEntry.State.init(rawValue:)) {
                case .failed:
                    run("DELETE FROM files WHERE folder_id = ? AND relative_path = ?", [.text(folder), .text(path)])
                    result.forgotten.append(path)
                case .uploaded, .skipped:
                    let schedules = deleteRemotely && state == LedgerEntry.State.uploaded.rawValue && hasKey
                    run(
                        "UPDATE files SET state = ?, gone_at = ?, attempts = 0, remote_delete = ? WHERE folder_id = ? AND relative_path = ?",
                        [.text(LedgerEntry.State.gone.rawValue), .real(date.timeIntervalSince1970),
                         .int(Int64(schedules ? LedgerEntry.RemoteDelete.scheduled.rawValue : 0)), .text(folder), .text(path)]
                    )
                    if schedules { result.scheduled.append(path) }
                default:
                    break
                }
            }
        }
        return result
    }

    func setRemoteDelete(_ state: LedgerEntry.RemoteDelete, folderID: UUID, paths: [String]) {
        guard !paths.isEmpty else { return }
        transaction {
            for path in paths {
                run(
                    "UPDATE files SET remote_delete = ? WHERE folder_id = ? AND relative_path = ? AND state = ?",
                    [.int(Int64(state.rawValue)), .text(folderID.uuidString), .text(path), .text(LedgerEntry.State.gone.rawValue)]
                )
            }
        }
    }

    func lastUploadAt(folderID: UUID) -> Date? {
        var date: Date?
        run("SELECT last_upload_at FROM folders WHERE folder_id = ?", [.text(folderID.uuidString)]) { statement in
            if sqlite3_column_type(statement, 0) != SQLITE_NULL {
                date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            }
        }
        return date
    }

    func setLastUploadAt(_ date: Date, folderID: UUID) {
        run(
            "INSERT INTO folders (folder_id, last_upload_at) VALUES (?, ?) ON CONFLICT(folder_id) DO UPDATE SET last_upload_at = excluded.last_upload_at",
            [.text(folderID.uuidString), .real(date.timeIntervalSince1970)]
        )
    }

    func otherReferences(destinationID: UUID, objectKey: String, excludingFolderID: UUID, relativePath: String) -> Int {
        var count = 0
        run(
            "SELECT COUNT(*) FROM files WHERE destination_id = ? AND object_key = ? AND NOT (folder_id = ? AND relative_path = ?)",
            [.text(destinationID.uuidString), .text(objectKey), .text(excludingFolderID.uuidString), .text(relativePath)]
        ) { statement in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        return count
    }

    func purgeGone(folderID: UUID, before date: Date) {
        run(
            "DELETE FROM files WHERE folder_id = ? AND state = ? AND remote_delete = 0 AND gone_at IS NOT NULL AND gone_at < ?",
            [.text(folderID.uuidString), .text(LedgerEntry.State.gone.rawValue), .real(date.timeIntervalSince1970)]
        )
    }

    // MARK: - SQLite

    private enum Value {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    /// SQLite copies bound text right away.
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func transaction(_ body: () -> Void) {
        withLock {
            execute("BEGIN")
            body()
            execute("COMMIT")
        }
    }

    private func execute(_ sql: String) {
        withLock { _ = sqlite3_exec(db, sql, nil, nil, nil) }
    }

    /// The prepared statement for `sql`, made on first use.
    private func statement(_ sql: String) -> OpaquePointer? {
        if let cached = statements[sql] { return cached }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        statements[sql] = statement
        return statement
    }

    private func run(_ sql: String, _ values: [Value], row: ((OpaquePointer) -> Void)? = nil) {
        withLock {
            guard let statement = statement(sql) else { return }
            defer {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            for (index, value) in values.enumerated() {
                let position = Int32(index + 1)
                switch value {
                case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
                case .int(let int): sqlite3_bind_int64(statement, position, int)
                case .real(let real): sqlite3_bind_double(statement, position, real)
                case .null: sqlite3_bind_null(statement, position)
                }
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                row?(statement)
            }
        }
    }

    private func query(_ sql: String, _ values: [Value]) -> [LedgerEntry] {
        var result: [LedgerEntry] = []
        run(sql, values) { statement in
            func text(_ column: Int32) -> String? {
                guard sqlite3_column_type(statement, column) != SQLITE_NULL, let raw = sqlite3_column_text(statement, column) else { return nil }
                return String(cString: raw)
            }
            guard let folderID = text(0).flatMap(UUID.init(uuidString:)),
                  let path = text(1),
                  let state = text(6).flatMap(LedgerEntry.State.init(rawValue:)) else { return }
            result.append(LedgerEntry(
                folderID: folderID,
                relativePath: path,
                size: sqlite3_column_int64(statement, 2),
                mtime: sqlite3_column_double(statement, 3),
                fileID: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : UInt64(bitPattern: sqlite3_column_int64(statement, 4)),
                sha256: text(5),
                state: state,
                attempts: Int(sqlite3_column_int64(statement, 7)),
                lastError: text(8),
                retryable: sqlite3_column_int64(statement, 9) != 0,
                objectKey: text(10),
                url: text(11),
                destinationID: text(12).flatMap(UUID.init(uuidString:)),
                handledAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
                reused: sqlite3_column_int64(statement, 14) != 0,
                goneAt: sqlite3_column_type(statement, 15) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 15)),
                remoteDelete: LedgerEntry.RemoteDelete(rawValue: Int(sqlite3_column_int64(statement, 16))) ?? .none
            ))
        }
        return result
    }
}
