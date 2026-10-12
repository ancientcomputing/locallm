import Foundation
import LocalLMLabSDKCore
import Network

/// A request, as much of HTTP/1.1 as jev-serve needs: method, path (query dropped), headers
/// (names lowercased), and a `Content-Length` body.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var contentType = "application/json"

    public static func json(_ status: Int, _ body: Data) -> HTTPResponse { HTTPResponse(status: status, body: body) }
}

/// A minimal HTTP/1.1 server on `Network.framework`: keep-alive, `Content-Length` bodies only (no
/// chunked uploads), a size cap on headers and body, and an idle timeout. Enough for JSON APIs on
/// this Mac; not a general web server.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let handler: Handler
    private let maxBodyBytes: Int
    private let maxHeaderBytes = 16 * 1024
    private let idleTimeout: TimeInterval = 30
    private let queue = DispatchQueue(label: "jev-serve.http")

    /// `port` 0 lets the system pick one; read it from `port` after `start()`.
    public init(host: String, port: UInt16, maxBodyBytes: Int, handler: @escaping Handler) throws {
        let nwPort: NWEndpoint.Port
        if port == 0 { nwPort = .any } else {
            guard let p = NWEndpoint.Port(rawValue: port) else { throw ServerError("invalid port \(port)") }
            nwPort = p
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        self.listener = try NWListener(using: params)
        self.handler = handler
        self.maxBodyBytes = maxBodyBytes
    }

    /// The bound port, once started.
    public var port: UInt16? { listener.port?.rawValue }

    /// Stops accepting connections; open ones finish or time out.
    public func stop() { listener.cancel() }

    /// Starts listening; returns once the port is bound, or throws (e.g. the port is in use).
    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // State updates arrive on `queue` (serial), so this flag is only touched there.
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { state in
                guard !once.done else {
                    if case .failed(let e) = state { FileHandle.standardError.write(Data("listener failed: \(e)\n".utf8)) }
                    return
                }
                switch state {
                case .ready: once.done = true; cont.resume()
                case .failed(let e): once.done = true; cont.resume(throwing: ServerError("can't listen: \(e)"))
                case .cancelled: once.done = true; cont.resume(throwing: ServerError("listener cancelled"))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }

    private func accept(_ conn: NWConnection) {
        let c = Connection(conn: conn, server: self)
        conn.start(queue: queue)
        c.readMore()
    }

    // MARK: Per connection

    private final class Connection: @unchecked Sendable {
        let conn: NWConnection
        let server: HTTPServer        // strong: callbacks can outlive the caller's reference (no cycle: the server doesn't keep connections)
        var buffer = Data()
        var idle: DispatchWorkItem?

        init(conn: NWConnection, server: HTTPServer) {
            self.conn = conn
            self.server = server
        }

        func resetIdle() {
            idle?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.conn.cancel() }
            idle = item
            server.queue.asyncAfter(deadline: .now() + server.idleTimeout, execute: item)
        }

        func readMore() {
            resetIdle()
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
                if let data { buffer.append(data) }
                if error != nil { close(); return }
                if process() { return }
                if isComplete { close(); return }
                readMore()
            }
        }

        /// Handles a complete request in the buffer, if there is one. Returns true when it took
        /// over the connection (responding, then reading again or closing).
        func process() -> Bool {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > server.maxHeaderBytes { fail(431, "Request headers too large."); return true }
                return false
            }
            let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
            guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { fail(400, "Malformed request line."); return true }
            var headers: [String: String] = [:]
            for line in lines where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { fail(400, "Malformed header."); return true }
                headers[line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if headers["transfer-encoding"] != nil { fail(411, "Send a Content-Length body; chunked uploads aren't supported."); return true }
            let length = headers["content-length"].flatMap(Int.init) ?? 0
            guard length >= 0 else { fail(400, "Invalid Content-Length."); return true }
            guard length <= server.maxBodyBytes else { fail(413, "The body is over \(server.maxBodyBytes) bytes."); return true }
            let bodyStart = headerEnd.upperBound
            guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return false }   // wait for the rest
            let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
            buffer.removeSubrange(buffer.startIndex..<(bodyStart + length))
            var path = String(requestLine[1])
            if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
            let request = HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: body)
            let keepAlive = headers["connection"]?.lowercased() != "close"
            idle?.cancel()
            Task {
                let response = await server.handler(request)
                send(response, keepAlive: keepAlive)
            }
            return true
        }

        func send(_ r: HTTPResponse, keepAlive: Bool) {
            let head = "HTTP/1.1 \(r.status) \(Self.reason(r.status))\r\n" +
                "Content-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\n" +
                "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
            conn.send(content: Data(head.utf8) + r.body, completion: .contentProcessed { [self] error in
                if error != nil || !keepAlive { close(); return }
                server.queue.async { [self] in
                    if !process() { readMore() }
                }
            })
        }

        func fail(_ status: Int, _ message: String) {
            send(.json(status, JevWire.encodeError(message: message, type: status == 413 ? "payload_too_large" : "invalid_request", code: status)), keepAlive: false)
        }

        func close() {
            idle?.cancel()
            conn.cancel()
        }

        static func reason(_ s: Int) -> String {
            switch s {
            case 200: "OK"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 404: "Not Found"
            case 405: "Method Not Allowed"
            case 411: "Length Required"
            case 413: "Payload Too Large"
            case 431: "Request Header Fields Too Large"
            case 500: "Internal Server Error"
            case 503: "Service Unavailable"
            default: "Status"
            }
        }
    }
}

public struct ServerError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
