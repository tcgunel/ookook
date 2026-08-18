import Foundation
import Network

/// A deliberately small HTTP/1.1 server, bound to loopback only.
///
/// This exists to carry MCP JSON-RPC between Claude Code and the running app.
/// It handles exactly what that needs - a POST with a Content-Length body, and
/// a JSON response - and nothing else.
final class HTTPServer {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    struct Response {
        var status: Int = 200
        var contentType: String = "application/json"
        var body: Data = Data()

        static func json(_ object: Any) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return Response(status: 200, contentType: "application/json", body: data)
        }

        static func empty(status: Int) -> Response {
            Response(status: status, contentType: "text/plain", body: Data())
        }
    }

    private let queue = DispatchQueue(label: "com.tolga.ookook.http")
    private var listener: NWListener?
    private let handler: (Request, @escaping (Response) -> Void) -> Void

    private(set) var port: UInt16?

    init(handler: @escaping (Request, @escaping (Response) -> Void) -> Void) {
        self.handler = handler
    }

    /// Binds to 127.0.0.1 on `preferredPort`, falling back to an ephemeral port
    /// if it is taken, so two projects can each run their own server.
    func start(preferredPort: UInt16) throws {
        do {
            try listen(on: preferredPort)
        } catch {
            try listen(on: 0)
        }
    }

    private func listen(on port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: port) ?? .any)
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue
                ready.signal()
            case .failed(let error), .waiting(let error):
                failure = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 3) == .timedOut {
            listener.cancel()
            throw ServerError.timeout
        }
        if let failure {
            listener.cancel()
            throw failure
        }
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let error {
                _ = error
                connection.cancel()
                return
            }

            // Keep reading until headers and the declared body have all arrived.
            if let request = Self.parse(buffer) {
                self.handler(request) { response in
                    connection.send(content: Self.serialize(response),
                                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
                return
            }

            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    /// Returns nil when the request is not yet complete.
    private static func parse(_ buffer: Data) -> Request? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        guard let headerText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound],
                                      encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let expected = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[headerEnd.upperBound...]
        guard body.count >= expected else { return nil }

        return Request(method: String(requestLine[0]),
                       path: String(requestLine[1]),
                       headers: headers,
                       body: Data(body.prefix(expected)))
    }

    private static func serialize(_ response: Response) -> Data {
        let reason = response.status == 200 ? "OK" : "Error"
        var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        return data
    }

    enum ServerError: LocalizedError {
        case timeout
        var errorDescription: String? { "The MCP server did not start in time." }
    }
}
