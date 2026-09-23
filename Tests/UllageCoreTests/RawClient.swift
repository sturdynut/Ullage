import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Speaks to the server at the byte level, for the requests URLSession refuses
/// to make: a malformed one, or half of one.
enum RawClient {
    static func open(port: UInt16) -> Int32 {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func send(_ fd: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        #if canImport(Darwin)
        _ = bytes.withUnsafeBufferPointer { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        #else
        _ = bytes.withUnsafeBufferPointer { Glibc.send(fd, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
        #endif
    }

    static func close(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }

    /// Sends, then reads until the server closes the connection.
    static func exchange(port: UInt16, _ text: String) -> String {
        let fd = open(port: port)
        defer { close(fd) }
        send(fd, text)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
