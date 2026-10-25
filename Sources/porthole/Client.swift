import Foundation

/// Opens a connection to a paired host and performs the hello handshake.
func dial(_ host: Host, _ hello: [String: Any], timeout: TimeInterval = 10) throws -> (Socket, [String: Any]) {
    let sock = try Socket.connect(host: host.address, port: host.port, timeout: timeout)
    var h = hello
    h["v"] = 1
    h["token"] = host.token
    try sock.send(json: h)
    let reply = try sock.receiveJSON()
    guard reply.bool("ok") == true else {
        throw NetError("\(host.name): \(reply.str("error") ?? "refused")")
    }
    return (sock, reply)
}

struct ExecResult {
    var stdout = Data()
    var stderr = Data()
    var code: Int = -1
    var timedOut = false
}

enum Remote {
    static func info(_ host: Host) throws -> [String: Any] {
        let (sock, reply) = try dial(host, ["op": "info"])
        sock.close()
        return reply.obj("info") ?? [:]
    }

    /// Runs a shell command on the host. Output is streamed to the callbacks as it arrives.
    static func exec(
        _ host: Host, _ cmd: String, cwd: String? = nil, timeout: Double = 0, stdin: Data? = nil,
        forwardStdin: Bool = false,
        onOut: ((Data) -> Void)? = nil, onErr: ((Data) -> Void)? = nil
    ) throws -> ExecResult {
        var hello: [String: Any] = ["op": "exec", "cmd": cmd, "timeout": timeout]
        if let cwd { hello["cwd"] = cwd }
        let (sock, _) = try dial(host, hello)
        defer { sock.close() }

        if let stdin {
            try sock.send(json: ["t": "i", "d": stdin.base64EncodedString()])
            try sock.send(json: ["t": "c"])
        } else if forwardStdin {
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(0, &buf, buf.count)
                    if n > 0 { try? sock.send(json: ["t": "i", "d": Data(buf[0..<n]).base64EncodedString()]); continue }
                    if n < 0 && errno == EINTR { continue }
                    break
                }
                try? sock.send(json: ["t": "c"])
            }
        } else {
            try sock.send(json: ["t": "c"])
        }

        var r = ExecResult()
        while let line = try sock.readLine() {
            let f = try JSON.decodeObject(line)
            switch f.str("t") {
            case "o":
                let d = Data(base64Encoded: f.str("d") ?? "") ?? Data()
                r.stdout.append(d); onOut?(d)
            case "e":
                let d = Data(base64Encoded: f.str("d") ?? "") ?? Data()
                r.stderr.append(d); onErr?(d)
            case "x":
                r.code = f.int("code") ?? -1
                r.timedOut = f.bool("timed_out") ?? false
                return r
            default:
                if f.bool("ok") == false { throw NetError(f.str("error") ?? "exec failed") }
            }
        }
        throw NetError("connection to \(host.name) closed before the command finished")
    }

    static func detach(_ host: Host, _ cmd: String, cwd: String? = nil, log: String? = nil) throws -> [String: Any] {
        var hello: [String: Any] = ["op": "exec", "cmd": cmd, "detach": true]
        if let cwd { hello["cwd"] = cwd }
        if let log { hello["log"] = log }
        let (sock, reply) = try dial(host, hello)
        sock.close()
        return reply
    }

    /// Copies a local file or directory to the host. Directories travel as tar.
    static func push(_ host: Host, local: String, remote: String) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local, isDirectory: &isDir) else { throw NetError("no such file: \(local)") }
        var file = local
        var kind = "file"
        var tmp: String?
        if isDir.boolValue {
            let t = NSTemporaryDirectory() + "porthole-push-\(UUID().uuidString).tar"
            // Skip VCS internals and build products; COPYFILE_DISABLE keeps AppleDouble files out.
            let excludes = [".git", "node_modules", ".build", "target", "DerivedData"].flatMap { ["--exclude", $0] }
            let tar = try Child.spawn(["/usr/bin/tar", "-cf", t] + excludes + ["-C", local, "."],
                                      env: commandEnvironment(extra: ["COPYFILE_DISABLE": "1"]), stdin: false, stdout: .null, stderr: .null)
            guard tar.wait().0 == 0 else { throw NetError("tar failed for \(local)") }
            file = t; kind = "tar"; tmp = t
        }
        defer { if let tmp { try? FileManager.default.removeItem(atPath: tmp) } }

        let attrs = try FileManager.default.attributesOfItem(atPath: file)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        let (sock, _) = try dial(host, ["op": "put", "path": remote, "size": size, "kind": kind, "mode": mode])
        defer { sock.close() }
        let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
        defer { try? fh.close() }
        while let d = try fh.read(upToCount: 1 << 20), !d.isEmpty { try sock.write(d) }
        let done = try sock.receiveJSON()
        guard done.bool("ok") == true else { throw NetError(done.str("error") ?? "push failed") }
        return done.str("path") ?? remote
    }

    /// A local path made absolute against the working directory, so a bare file name
    /// has a parent to create.
    static func localPath(_ p: String) -> String {
        let e = Paths.expand(p)
        return e.hasPrefix("/") ? e : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(e)
    }

    /// Copies a remote file or directory here.
    static func pull(_ host: Host, remote: String, local: String) throws -> String {
        let local = localPath(local)
        let (sock, header) = try dial(host, ["op": "get", "path": remote])
        defer { sock.close() }
        let size = header.int("size") ?? 0
        let kind = header.str("kind") ?? "file"
        let fm = FileManager.default
        if kind == "tar" {
            try fm.createDirectory(atPath: local, withIntermediateDirectories: true)
            let tar = try Child.spawn(["/usr/bin/tar", "-xf", "-", "-C", local], env: commandEnvironment(), stdin: true, stdout: .null, stderr: .null)
            try receive(sock, size) { _ = writeAll(tar.stdin!, $0) }
            close(tar.stdin!)
            guard tar.wait().0 == 0 else { throw NetError("tar failed extracting into \(local)") }
        } else {
            var dest = local
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: local, isDirectory: &isDir), isDir.boolValue {
                dest = (local as NSString).appendingPathComponent(((header.str("path") ?? remote) as NSString).lastPathComponent)
            }
            try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: dest, contents: nil)
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: dest))
            try receive(sock, size) { fh.write($0) }
            try fh.close()
            if let mode = header.int("mode") { chmod(dest, mode_t(mode)) }
            return dest
        }
        return local
    }

    static func audio(_ host: Host, seconds: Double, app: String?) throws -> [String: Any] {
        var hello: [String: Any] = ["op": "audio", "seconds": seconds]
        if let app { hello["app"] = app }
        let (sock, reply) = try dial(host, hello, timeout: 10)
        sock.close()
        return reply.obj("audio") ?? [:]
    }

    /// Captures the host's screen to a local PNG.
    static func shot(_ host: Host, to local: String, display: Int? = nil) throws -> String {
        let local = localPath(local)
        var hello: [String: Any] = ["op": "shot"]
        if let display { hello["display"] = display }
        let (sock, header) = try dial(host, hello)
        defer { sock.close() }
        try FileManager.default.createDirectory(atPath: (local as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: local, contents: nil)
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: local))
        try receive(sock, header.int("size") ?? 0) { fh.write($0) }
        try fh.close()
        return local
    }

    private static func receive(_ sock: Socket, _ size: Int, _ sink: (Data) -> Void) throws {
        var left = size
        while left > 0 {
            let d = try sock.readSome(max: min(1 << 20, left))
            if d.isEmpty { throw NetError("connection closed with \(left) bytes left") }
            sink(d)
            left -= d.count
        }
    }
}
