import Foundation

struct NetError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// A blocking TCP socket. Each connection is handled on its own thread, so
/// blocking reads keep the protocol code straight-line.
final class Socket {
    let fd: Int32
    private var buffer = Data()
    private let writeLock = NSLock()
    private(set) var peer: String = ""

    init(fd: Int32, peer: String = "") {
        self.fd = fd
        self.peer = peer
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    private var closed = false
    func close() {
        if closed { return }
        closed = true
        Darwin.close(fd)
    }

    func shutdownWrite() { Darwin.shutdown(fd, SHUT_WR) }

    static func connect(host: String, port: Int, timeout: TimeInterval = 10) throws -> Socket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else {
            throw NetError("cannot resolve \(host): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(res) }
        var lastError = "no addresses"
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                if connectWithTimeout(fd, a.pointee.ai_addr, a.pointee.ai_addrlen, timeout) {
                    return Socket(fd: fd, peer: host)
                }
                lastError = String(cString: strerror(errno))
                Darwin.close(fd)
            }
            ai = a.pointee.ai_next
        }
        throw NetError("cannot connect to \(host):\(port): \(lastError)")
    }

    private static func connectWithTimeout(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>, _ len: socklen_t, _ timeout: TimeInterval) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        if Darwin.connect(fd, addr, len) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else {
            errno = ETIMEDOUT
            return false
        }
        var err: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errLen)
        if err != 0 { errno = err; return false }
        return true
    }

    // MARK: reading

    /// Reads up to `max` bytes, draining the line buffer first. Returns empty Data at EOF.
    func readSome(max: Int = 65536) throws -> Data {
        if !buffer.isEmpty {
            let n = min(max, buffer.count)
            let out = buffer.prefix(n)
            buffer.removeFirst(n)
            return Data(out)
        }
        var chunk = [UInt8](repeating: 0, count: max)
        while true {
            let n = read(fd, &chunk, max)
            if n > 0 { return Data(chunk[0..<n]) }
            if n == 0 { return Data() }
            if errno == EINTR { continue }
            throw NetError("read: \(String(cString: strerror(errno)))")
        }
    }

    /// Reads one newline-terminated line (without the newline). Nil at EOF.
    func readLine(limit: Int = 64 << 20) throws -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(decoding: line, as: UTF8.self)
            }
            if buffer.count > limit { throw NetError("line too long") }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 {
                if buffer.isEmpty { return nil }
                let rest = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll()
                return rest
            }
            if errno == EINTR { continue }
            throw NetError("read: \(String(cString: strerror(errno)))")
        }
    }

    func readExact(_ count: Int) throws -> Data {
        var out = Data()
        while out.count < count {
            let d = try readSome(max: min(65536, count - out.count))
            if d.isEmpty { throw NetError("connection closed after \(out.count) of \(count) bytes") }
            out.append(d)
        }
        return out
    }

    // MARK: writing

    func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw NetError("write: \(String(cString: strerror(errno)))")
                }
                p = p.advanced(by: n)
                left -= n
            }
        }
    }

    func writeLine(_ s: String) throws { try write(Data((s + "\n").utf8)) }

    func send(json: [String: Any]) throws { try writeLine(JSON.encode(json)) }

    func receiveJSON() throws -> [String: Any] {
        guard let line = try readLine() else { throw NetError("connection closed") }
        return try JSON.decodeObject(line)
    }
}

final class Listener {
    let fd: Int32

    init(port: Int) throws {
        fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NetError("socket: \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        var off: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(UInt16(port).bigEndian)
        addr.sin6_addr = in6addr_any
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard rc == 0 else { throw NetError("bind :\(port): \(String(cString: strerror(errno)))") }
        guard listen(fd, 64) == 0 else { throw NetError("listen: \(String(cString: strerror(errno)))") }
    }

    func accept() throws -> Socket {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        while true {
            let c = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &len) }
            }
            if c >= 0 { return Socket(fd: c, peer: Listener.describe(&storage)) }
            if errno == EINTR || errno == ECONNABORTED { continue }
            throw NetError("accept: \(String(cString: strerror(errno)))")
        }
    }

    static func describe(_ s: inout sockaddr_storage) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(s.ss_len)
        let rc = withUnsafePointer(to: &s) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard rc == 0 else { return "?" }
        let str = String(cString: host)
        // Unwrap IPv4-mapped IPv6 addresses.
        return str.hasPrefix("::ffff:") ? String(str.dropFirst(7)) : str
    }
}

enum PeerPolicy {
    /// Loopback, Tailscale's CGNAT range (100.64.0.0/10) and Tailscale's IPv6 ULA prefix.
    static func isTrusted(_ addr: String) -> Bool {
        if addr == "127.0.0.1" || addr == "::1" { return true }
        if addr.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = addr.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return true }
        return false
    }
}
