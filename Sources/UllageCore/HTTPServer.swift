import Foundation
#if canImport(Darwin)
import Darwin
private let streamSocketType = SOCK_STREAM
private let sendFlags: Int32 = 0
#else
import Glibc
private let streamSocketType = Int32(SOCK_STREAM.rawValue)
private let sendFlags: Int32 = Int32(MSG_NOSIGNAL)
#endif

/// A very small HTTP/1.1 server: enough to hand a browser one page and some
/// JSON, and deliberately no more.
///
/// It binds **127.0.0.1 and nothing else** — there is no bind-address option,
/// because the way this is meant to be reached from a phone is
/// `tailscale serve`, which terminates TLS and proxies to loopback. That keeps
/// the promise sharper than a `--bind` flag could: Ullage never opens a socket
/// the rest of the network can see, so exposure is Tailscale's decision and
/// revoking it is `tailscale serve --https=443 off`.
///
/// POSIX sockets rather than Network.framework, so this compiles on Linux with
/// the rest of Core.
public final class HTTPServer: @unchecked Sendable {

    public struct Response {
        public var status: Int
        public var contentType: String
        public var body: Data

        public init(status: Int = 200, contentType: String, body: Data) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }

        public static func json(_ body: Data) -> Response {
            Response(contentType: "application/json; charset=utf-8", body: body)
        }

        public static func html(_ text: String) -> Response {
            Response(contentType: "text/html; charset=utf-8", body: Data(text.utf8))
        }

        public static func text(_ status: Int, _ message: String) -> Response {
            Response(status: status, contentType: "text/plain; charset=utf-8", body: Data((message + "\n").utf8))
        }
    }

    public struct Request {
        public var method: String
        public var path: String
        public var host: String?
        public var body: Data = Data()
    }

    public typealias Handler = (Request) -> Response

    public enum Failure: Error, CustomStringConvertible {
        case syscall(String, Int32)

        public var description: String {
            switch self {
            case let .syscall(name, code):
                return "\(name): \(String(cString: strerror(code))) (errno \(code))"
            }
        }
    }

    /// The only body this accepts is a push subscription, which is a few
    /// hundred bytes; the cap is what stops a client that promises more than it
    /// sends from holding memory open.
    static let maximumBody = 64 * 1024

    /// How long one connection may take to send its request or take our
    /// response. A phone that walks out of Wi-Fi range mid-request must not
    /// hold anything open past this.
    static let socketTimeout: TimeInterval = 10

    private let requestedPort: UInt16
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "com.sturdynut.ullage.http.accept")
    /// Socket reads and writes happen here, concurrently, so a slow client
    /// only ever costs itself. Only the handler is serialised (below).
    private let connectionQueue = DispatchQueue(label: "com.sturdynut.ullage.http.io", attributes: .concurrent)
    /// Serial on purpose: a `Store` is one SQLite connection and is not thread
    /// safe, so every handler call is serialised rather than trusting whatever
    /// the handler happens to close over. The handler is the *only* thing that
    /// goes through here — never a socket read — so a stalled connection cannot
    /// block the others.
    private let handlerQueue = DispatchQueue(label: "com.sturdynut.ullage.http.handler")
    private var listenDescriptor: Int32 = -1
    private var isRunning = false

    /// The port actually bound, which differs from the requested one when 0 was
    /// asked for — tests do that so they never collide with a real server.
    public private(set) var port: UInt16 = 0

    public init(port: UInt16, handler: @escaping Handler) {
        self.requestedPort = port
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        let descriptor = socket(AF_INET, streamSocketType, 0)
        guard descriptor >= 0 else { throw Failure.syscall("socket", errno) }

        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        // A phone that walks out of Wi-Fi range leaves half-closed sockets; a
        // write to one must return EPIPE, not kill the process with SIGPIPE.
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requestedPort.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.syscall("bind", code)
        }
        guard listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.syscall("listen", code)
        }

        var actual = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &size)
            }
        }
        port = UInt16(bigEndian: actual.sin_port)

        listenDescriptor = descriptor
        isRunning = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        // `close` alone wakes a blocked `accept` on macOS but not on Linux,
        // where the syscall holds its own reference to the file and keeps
        // waiting. `shutdown` first is what works on both; on macOS it returns
        // ENOTCONN for a listening socket, which is harmless.
        if listenDescriptor >= 0 {
            shutdown(listenDescriptor, Int32(SHUT_RDWR))
            close(listenDescriptor)
        }
        listenDescriptor = -1
    }

    private func acceptLoop() {
        while isRunning {
            let client = accept(listenDescriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                break   // the socket was closed by `stop`, or the kernel gave up
            }
            HTTPServer.applyTimeouts(client)
            connectionQueue.async { [weak self] in self?.serve(client) }
        }
    }

    /// Reads and writes on an accepted socket give up after `socketTimeout`, so
    /// one client that stops mid-request costs only its own connection.
    private static func applyTimeouts(_ descriptor: Int32) {
        var timeout = timeval(tv_sec: Int(socketTimeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private func serve(_ descriptor: Int32) {
        defer { close(descriptor) }
        guard let (head, body) = readRequest(descriptor), var request = HTTPServer.parse(head) else {
            write(descriptor, .text(400, "bad request"))
            return
        }
        request.body = body
        guard request.method == "GET" || request.method == "POST" else {
            write(descriptor, .text(405, "only GET and POST"))
            return
        }
        guard HTTPServer.isAllowedHost(request.host) else {
            write(descriptor, .text(403, "host not allowed"))
            return
        }
        // Only this hop is serialised: the socket is fully read by now and the
        // write happens after, both on the concurrent queue.
        let response = handlerQueue.sync { handler(request) }
        write(descriptor, response)
    }

    private func readRequest(_ descriptor: Int32) -> (head: String, body: Data)? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let separator = Data("\r\n\r\n".utf8)
        var headEnd: Int?
        var expected = 0

        while true {
            if headEnd == nil, let range = data.range(of: separator) {
                headEnd = range.upperBound
                let declared = HTTPServer.contentLength(String(decoding: data[..<range.lowerBound], as: UTF8.self)) ?? 0
                // A negative length is not "no body", it is a malformed
                // request, and building a range from it would trap.
                guard declared >= 0, declared <= HTTPServer.maximumBody else { return nil }
                expected = declared
            }
            if let end = headEnd, data.count - end >= expected {
                let head = String(decoding: data[..<(end - separator.count)], as: UTF8.self)
                return (head, Data(data[end..<(end + expected)]))
            }
            if data.count > HTTPServer.maximumBody + 16_384 { return nil }
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count <= 0 { return nil }   // hung up, or the socket timeout fired
            data.append(contentsOf: buffer[0..<count])
        }
    }

    static func contentLength(_ head: String) -> Int? {
        head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
    }

    private func write(_ descriptor: Int32, _ response: Response) {
        var head = "HTTP/1.1 \(response.status) \(HTTPServer.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        // Nothing here is worth a stale copy of, and the one number this serves
        // is wrong the moment it is old.
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        payload.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let sent = send(descriptor, pointer, remaining, sendFlags)
                if sent <= 0 { return }        // the phone went away mid-write
                pointer += sent
                remaining -= sent
            }
        }
    }

    static func parse(_ head: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let host = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("host:") }
            .map { String($0.dropFirst("host:".count)).trimmingCharacters(in: .whitespaces) }
        return Request(method: String(parts[0]).uppercased(), path: path, host: host)
    }

    /// A loopback HTTP server with no host check is readable by any web page
    /// you visit: the page resolves a name it controls to 127.0.0.1, and the
    /// browser then treats the response as same-origin. Project names, repo
    /// paths and session ids are exactly the kind of thing not to hand over
    /// that way. So: loopback names, or the `.ts.net` name Tailscale proxies
    /// under — an attacker cannot make a name in someone else's tailnet
    /// resolve to your loopback.
    static func isAllowedHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        var name = host
        if name.hasPrefix("[") {                       // [::1]:7878
            guard let end = name.firstIndex(of: "]") else { return false }
            name = String(name[name.index(after: name.startIndex)..<end])
        } else if let colon = name.lastIndex(of: ":"), name.filter({ $0 == ":" }).count == 1 {
            name = String(name[name.startIndex..<colon])
        }
        name = name.lowercased()
        return name == "localhost" || name == "127.0.0.1" || name == "::1" || name.hasSuffix(".ts.net")
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default: return "Error"
        }
    }
}
