import Foundation
import Network

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    /// Header names are lowercased.
    let headers: [String: String]
    /// Small bodies are kept in memory; larger ones are streamed to
    /// `bodyFile` instead and `body` is left empty.
    let body: Data
    let bodyFile: URL?
}

struct HTTPResponse: Sendable {
    var status: Int
    var body: Data
    var contentType = "application/json; charset=utf-8"

    static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: data)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse {
        json(status, ["error": message])
    }
}

/// A deliberately tiny HTTP/1.1 server for the local API: loopback only,
/// one request per connection, `Content-Length` bodies only (no chunked
/// encoding), and every request must carry the bearer token. Callers are
/// local tools like the Raycast extension, never browsers, so any request
/// with an `Origin` header is refused outright.
final class LocalHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    enum State: Sendable, Equatable {
        case starting
        case ready
        case failed(String)
    }

    private let port: UInt16
    private let token: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.getaktar.mac.local-api")
    private var listener: NWListener?

    init(port: UInt16, token: String, handler: @escaping Handler) {
        self.port = port
        self.token = token
        self.handler = handler
    }

    func start(onStateChange: @escaping @Sendable (State) -> Void) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LocalAPIError.invalidPort
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onStateChange(.ready)
            case .failed(let error):
                onStateChange(.failed(error.localizedDescription))
            case .waiting(let error):
                onStateChange(.failed(error.localizedDescription))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            HTTPConnection(connection: connection, server: self).start()
        }
        self.listener = listener
        onStateChange(.starting)
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    fileprivate var connectionQueue: DispatchQueue { queue }
    fileprivate var requestHandler: Handler { handler }

    /// Checked as soon as the headers arrive, before any body is read, so an
    /// unauthorized upload is refused without buffering it first.
    fileprivate func rejection(for head: RequestHead) -> HTTPResponse? {
        if head.headers["origin"] != nil {
            return .error(403, "Browser requests are not allowed.")
        }
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = head.headers["host"]?.lowercased(), allowedHosts.contains(host) else {
            return .error(403, "Unexpected Host header.")
        }
        guard let authorization = head.headers["authorization"],
              authorization.hasPrefix("Bearer "),
              Self.constantTimeEquals(String(authorization.dropFirst(7)), token) else {
            return .error(401, "Missing or invalid API token.")
        }
        if head.headers["transfer-encoding"] != nil {
            return .error(411, "Send a Content-Length instead of a chunked body.")
        }
        return nil
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices {
            difference |= a[index] ^ b[index]
        }
        return difference == 0
    }
}

enum LocalAPIError: Error, LocalizedError {
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPort: return String(localized: "The port must be a number between 1024 and 65535.")
        }
    }
}

fileprivate struct RequestHead {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let contentLength: Int

    /// Parses the request line and headers (everything before the blank line).
    init?(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return nil }
        method = String(requestLine[0]).uppercased()

        guard let components = URLComponents(string: String(requestLine[1])) else { return nil }
        path = components.path
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        self.query = query

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        self.headers = headers
        contentLength = Int(headers["content-length"] ?? "0") ?? -1
    }
}

/// One request/response exchange. All state is touched only on the
/// server's serial queue.
private final class HTTPConnection: @unchecked Sendable {
    private static let maxHeaderSize = 64 * 1024
    private static let maxInMemoryBody = 1024 * 1024
    private static let headerTimeout: DispatchTimeInterval = .seconds(30)
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private let connection: NWConnection
    private let server: LocalHTTPServer
    private var buffer = Data()
    private var head: RequestHead?
    private var bodyFile: URL?
    private var bodyHandle: FileHandle?
    private var bodyReceived = 0
    private var hasResponded = false
    private var isFinished = false

    init(connection: NWConnection, server: LocalHTTPServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        let queue = server.connectionQueue
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.headerTimeout) { [self] in
            if head == nil, !isFinished { finish() }
        }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                consume(data)
            }
            if isFinished { return }
            if error != nil || isComplete {
                finish()
                return
            }
            receive()
        }
    }

    private func consume(_ data: Data) {
        guard !hasResponded else { return }
        guard head == nil else {
            appendBody(data)
            return
        }
        buffer.append(data)
        guard let range = buffer.range(of: Self.headerTerminator) else {
            if buffer.count > Self.maxHeaderSize { respond(.error(431, "Request headers are too large.")) }
            return
        }
        guard let parsed = RequestHead(buffer[..<range.lowerBound]), parsed.contentLength >= 0 else {
            respond(.error(400, "Malformed request."))
            return
        }
        if let rejection = server.rejection(for: parsed) {
            respond(rejection)
            return
        }
        head = parsed
        let rest = buffer[range.upperBound...]
        buffer = Data()
        if parsed.contentLength > Self.maxInMemoryBody {
            openBodyFile()
        }
        appendBody(Data(rest))
    }

    private func openBodyFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AktarLocalAPI", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        bodyFile = url
        bodyHandle = try? FileHandle(forWritingTo: url)
        if bodyHandle == nil { respond(.error(500, "Could not buffer the request body.")) }
    }

    private func appendBody(_ data: Data) {
        guard let head, !hasResponded else { return }
        let remaining = head.contentLength - bodyReceived
        let chunk = data.prefix(max(remaining, 0))
        if let bodyHandle {
            do {
                try bodyHandle.write(contentsOf: chunk)
            } catch {
                respond(.error(500, "Could not buffer the request body."))
                return
            }
        } else {
            buffer.append(chunk)
        }
        bodyReceived += chunk.count
        if bodyReceived >= head.contentLength {
            dispatch(head)
        }
    }

    private func dispatch(_ head: RequestHead) {
        try? bodyHandle?.close()
        bodyHandle = nil
        let request = HTTPRequest(
            method: head.method,
            path: head.path,
            query: head.query,
            headers: head.headers,
            body: bodyFile == nil ? buffer : Data(),
            bodyFile: bodyFile
        )
        buffer = Data()
        let handler = server.requestHandler
        let queue = server.connectionQueue
        Task {
            let response = await handler(request)
            queue.async { [self] in respond(response) }
        }
    }

    private func respond(_ response: HTTPResponse) {
        guard !hasResponded, !isFinished else { return }
        hasResponded = true
        var header = "HTTP/1.1 \(response.status) \(Self.reason(for: response.status))\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { [self] _ in finish() })
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        try? bodyHandle?.close()
        if let bodyFile { try? FileManager.default.removeItem(at: bodyFile) }
        connection.cancel()
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 422: return "Unprocessable Content"
        case 431: return "Request Header Fields Too Large"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Internal Server Error"
        }
    }
}
