import Foundation

struct ConnectionResult {
    let bucketReachable: Bool
    let writable: Bool
    let publicURLReachable: Bool?
}

struct UploadResult: Sendable {
    let objectKey: String
    let publicURL: URL
    let byteSize: Int
}

enum StorageError: Error, LocalizedError {
    case invalidCredentials
    case bucketNotFound(String)
    case accessDenied
    case network(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Could not authenticate. Check your Access Key ID and Secret Access Key."
        case .bucketNotFound(let bucket):
            return "Bucket \"\(bucket)\" could not be found."
        case .accessDenied:
            return "Connected successfully, but this key cannot upload files."
        case .network(let message):
            return "Upload interrupted. \(message)"
        case .unknown(let message):
            return message
        }
    }
}

protocol StorageProvider {
    func testConnection() async throws -> ConnectionResult
    func upload(
        fileURL: URL,
        objectKey: String,
        contentType: String,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> UploadResult
    func delete(objectKey: String) async throws
}
