import Foundation
import CoreGraphics
import SystemConfiguration

enum Log {
    private static let lock = NSLock()
    static func info(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
    }
}

final class Server {
    let port: Int
    let token: String
    let allowAny: Bool

    init(port: Int, token: String, allowAny: Bool) {
        self.port = port
        self.token = token
        self.allowAny = allowAny
    }

    func run() throws -> Never {
        signal(SIGPIPE, SIG_IGN)
        Paths.ensure(Paths.workDir)
        let listener = try Listener(port: port)
        Log.info("porthole \(portholeVersion) serving on :\(port)\(allowAny ? " (any peer)" : " (loopback and tailnet peers)")")
        // Accept on a background thread and keep the main run loop free for the
        // system frameworks (Core Audio, TCC) that call back on it.
        let acceptLoop: () -> Never = { [self] in
            while true {
                guard let sock = try? listener.accept() else { continue }
                Thread.detachNewThread { [self] in
                    self.handle(sock)
                    sock.close()
                }
            }
        }
        guard Thread.isMainThread else { acceptLoop() }
        Thread.detachNewThread { acceptLoop() }
        RunLoop.main.run()
        exit(0)
    }

    private func handle(_ sock: Socket) {
        guard allowAny || PeerPolicy.isTrusted(sock.peer) else {
            Log.info("refused \(sock.peer): not loopback or tailnet")
            try? sock.send(json: ["ok": false, "error": "peer \(sock.peer) is not on the tailnet; start the server with --any to allow it"])
            return
        }
        do {
            let hello = try sock.receiveJSON()
            guard let t = hello.str("token"), Token.matches(t, token) else {
                Log.info("refused \(sock.peer): bad token")
                try sock.send(json: ["ok": false, "error": "bad token"])
                return
            }
            let op = hello.str("op") ?? ""
            Log.info("\(sock.peer) \(op)")
            switch op {
            case "info": try sock.send(json: ["ok": true, "info": info()])
            case "mcp": try serveMCP(sock, hello)
            case "exec": try serveExec(sock, hello)
            case "put": try servePut(sock, hello)
            case "get": try serveGet(sock, hello)
            case "audio": try serveAudio(sock, hello)
            case "shot": try serveShot(sock, hello)
            default: try sock.send(json: ["ok": false, "error": "unknown op \(op)"])
            }
        } catch {
            Log.info("\(sock.peer) error: \(error)")
            try? sock.send(json: ["ok": false, "error": "\(error)"])
        }
    }

    // MARK: info

    func info() -> [String: Any] {
        let p = ProcessInfo.processInfo
        var dt: [String: Any] = ["installed": FileManager.default.fileExists(atPath: Paths.desktopToolsMCP)]
        if let plist = NSDictionary(contentsOfFile: "/Applications/Desktop Tools.app/Contents/Info.plist") {
            dt["version"] = plist["CFBundleShortVersionString"] ?? "?"
        }
        dt["running"] = FileManager.default.fileExists(atPath: Paths.home.appendingPathComponent(".local/state/desktop-tools/desktop.sock").path)
        return [
            "hostname": computerName(),
            "user": NSUserName(),
            "home": Paths.home.path,
            "os": p.operatingSystemVersionString,
            "porthole": portholeVersion,
            "desktop_tools": dt,
            "work_dir": Paths.workDir.path,
            "screen_recording": CGPreflightScreenCaptureAccess(),
        ]
    }

    // MARK: mcp

    /// Bridges the connection to a fresh desktop-tools MCP server on this Mac.
    private func serveMCP(_ sock: Socket, _ hello: [String: Any]) throws {
        guard FileManager.default.fileExists(atPath: Paths.desktopToolsMCP) else {
            try sock.send(json: ["ok": false, "error": "Desktop Tools is not installed in /Applications on this Mac"])
            return
        }
        let child = try Child.spawn([Paths.desktopToolsMCP], env: commandEnvironment())
        try sock.send(json: ["ok": true])
        let errThread = pump(child.stderr!) { d in Log.info("desktop-tools-mcp: \(String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))") }
        let outThread = pump(child.stdout!, { d in try? sock.write(d) }, done: { sock.shutdownWrite() })
        // Socket -> child stdin until the client hangs up.
        while let d = try? sock.readSome(), !d.isEmpty {
            if !writeAll(child.stdin!, d) { break }
        }
        close(child.stdin!)
        // Give the server a moment to exit on EOF, then make sure.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { child.kill() }
        _ = child.wait()
        _ = (errThread, outThread)
    }

    // MARK: exec

    private func serveExec(_ sock: Socket, _ hello: [String: Any]) throws {
        guard let cmd = hello.str("cmd") else { throw NetError("exec needs cmd") }
        let cwd = Paths.expand(hello.str("cwd") ?? "~")
        let env = commandEnvironment(extra: (hello["env"] as? [String: String]) ?? [:])
        let argv = ["/bin/zsh", "-lc", cmd]

        if hello.bool("detach") == true {
            let logs = Paths.workDir.appendingPathComponent("logs")
            Paths.ensure(logs)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let logPath = hello.str("log").map(Paths.expand) ?? logs.appendingPathComponent("\(stamp).log").path
            let child = try Child.spawn(argv, cwd: cwd, env: env, stdin: false, stdout: .file(logPath), stderr: .file(logPath))
            Thread.detachNewThread { _ = child.wait() }
            try sock.send(json: ["ok": true, "pid": Int(child.pid), "log": logPath])
            return
        }

        let child = try Child.spawn(argv, cwd: cwd, env: env, stdin: true)
        try sock.send(json: ["ok": true, "pid": Int(child.pid)])

        let group = DispatchGroup()
        for (fd, tag) in [(child.stdout!, "o"), (child.stderr!, "e")] {
            group.enter()
            _ = pump(fd, { d in try? sock.send(json: ["t": tag, "d": d.base64EncodedString()]) }, done: { group.leave() })
        }

        var timedOut = false
        let timeout = hello.double("timeout") ?? 0
        var timer: DispatchWorkItem?
        if timeout > 0 {
            let item = DispatchWorkItem { timedOut = true; child.kill(SIGTERM); DispatchQueue.global().asyncAfter(deadline: .now() + 3) { child.kill(SIGKILL) } }
            timer = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        }

        // Client frames: stdin data, stdin close, kill. A hangup kills the command.
        let exited = DispatchSemaphore(value: 0)
        var finished = false
        let control = Thread {
            var stdinOpen = true
            while true {
                guard let line = try? sock.readLine() else {
                    if !finished { child.kill(SIGTERM) }
                    break
                }
                guard let frame = try? JSON.decodeObject(line) else { continue }
                switch frame.str("t") {
                case "i":
                    if stdinOpen, let d = frame.str("d").flatMap({ Data(base64Encoded: $0) }) { _ = writeAll(child.stdin!, d) }
                case "c":
                    if stdinOpen { close(child.stdin!); stdinOpen = false }
                case "k":
                    child.kill(SIGTERM)
                default: break
                }
            }
            if stdinOpen { close(child.stdin!) }
            exited.signal()
        }
        control.start()

        let (code, sig) = child.wait()
        finished = true
        timer?.cancel()
        // A backgrounded grandchild can hold the pipes open; don't wait on it forever.
        _ = group.wait(timeout: .now() + 2)
        try sock.send(json: ["t": "x", "code": Int(code), "signal": Int(sig), "timed_out": timedOut])
        sock.shutdownWrite()
        _ = exited.wait(timeout: .now() + 5)
    }

    // MARK: files

    private func servePut(_ sock: Socket, _ hello: [String: Any]) throws {
        guard let rawPath = hello.str("path"), let size = hello.int("size") else { throw NetError("put needs path and size") }
        let path = absolute(rawPath)
        let kind = hello.str("kind") ?? "file"
        let fm = FileManager.default

        if kind == "tar" {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            let tar = try Child.spawn(["/usr/bin/tar", "-xf", "-", "-C", path], env: commandEnvironment(), stdin: true, stdout: .null, stderr: .pipe)
            var errText = Data()
            let errThread = pump(tar.stderr!) { errText.append($0) }
            try sock.send(json: ["ok": true])
            try copy(from: sock, count: size) { _ = writeAll(tar.stdin!, $0) }
            close(tar.stdin!)
            let (code, _) = tar.wait()
            while errThread.isExecuting { usleep(1000) }
            guard code == 0 else { throw NetError("tar failed: \(String(decoding: errText, as: UTF8.self))") }
        } else {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let tmp = path + ".porthole-\(getpid())-\(Int.random(in: 0..<1_000_000))"
            guard fm.createFile(atPath: tmp, contents: nil) else { throw NetError("cannot write \(tmp)") }
            let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: tmp))
            try sock.send(json: ["ok": true])
            do {
                try copy(from: sock, count: size) { fh.write($0) }
                try fh.close()
                if let mode = hello.int("mode") { chmod(tmp, mode_t(mode)) }
                _ = try? fm.removeItem(atPath: path)
                try fm.moveItem(atPath: tmp, toPath: path)
            } catch {
                try? fm.removeItem(atPath: tmp)
                throw error
            }
        }
        try sock.send(json: ["ok": true, "path": path])
    }

    private func serveGet(_ sock: Socket, _ hello: [String: Any]) throws {
        guard let rawPath = hello.str("path") else { throw NetError("get needs path") }
        let path = absolute(rawPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { throw NetError("no such file: \(path)") }
        if isDir.boolValue {
            let tmp = NSTemporaryDirectory() + "porthole-get-\(UUID().uuidString).tar"
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            let tar = try Child.spawn(["/usr/bin/tar", "-cf", tmp, "-C", path, "."], env: commandEnvironment(), stdin: false, stdout: .null, stderr: .null)
            guard tar.wait().0 == 0 else { throw NetError("tar failed for \(path)") }
            try sendFile(sock, tmp, kind: "tar", path: path)
        } else {
            try sendFile(sock, path, kind: "file", path: path)
        }
    }

    private func sendFile(_ sock: Socket, _ file: String, kind: String, path: String) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: file)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        try sock.send(json: ["ok": true, "kind": kind, "size": size, "mode": mode, "path": path])
        let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
        defer { try? fh.close() }
        var sent = 0
        while sent < size {
            guard let d = try fh.read(upToCount: 1 << 20), !d.isEmpty else { break }
            try sock.write(d)
            sent += d.count
        }
    }

    private func copy(from sock: Socket, count: Int, _ sink: (Data) -> Void) throws {
        var left = count
        while left > 0 {
            let d = try sock.readSome(max: min(1 << 20, left))
            if d.isEmpty { throw NetError("connection closed with \(left) bytes left") }
            sink(d)
            left -= d.count
        }
    }

    private func absolute(_ p: String) -> String {
        let e = Paths.expand(p)
        return e.hasPrefix("/") ? e : Paths.home.appendingPathComponent(e).path
    }

    // MARK: audio and screen

    private func serveAudio(_ sock: Socket, _ hello: [String: Any]) throws {
        let seconds = min(max(hello.double("seconds") ?? 5, 0.5), 300)
        let dir = Paths.workDir.appendingPathComponent("audio")
        Paths.ensure(dir)
        let out = hello.str("path").map(absolute) ?? dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970)).wav").path
        var triggered: [String: Any]?
        let trigger = hello.str("trigger")
        var result = try AudioRecorder.record(seconds: seconds, app: hello.str("app"), to: out, onStart: trigger.map { cmd in {
            let logs = Paths.workDir.appendingPathComponent("logs")
            Paths.ensure(logs)
            let log = logs.appendingPathComponent("trigger-\(Int(Date().timeIntervalSince1970 * 1000)).log").path
            do {
                let child = try Child.spawn(["/bin/zsh", "-lc", cmd], cwd: Paths.home.path, env: commandEnvironment(), stdin: false, stdout: .file(log), stderr: .file(log))
                Thread.detachNewThread { _ = child.wait() }
                triggered = ["command": cmd, "pid": Int(child.pid), "log": log]
            } catch {
                triggered = ["command": cmd, "error": "\(error)"]
            }
        } })
        if let triggered { result["trigger"] = triggered }
        try sock.send(json: ["ok": true, "audio": result])
    }

    private func serveShot(_ sock: Socket, _ hello: [String: Any]) throws {
        let dir = Paths.workDir.appendingPathComponent("shots")
        Paths.ensure(dir)
        let out = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).png").path
        var argv = ["/usr/sbin/screencapture", "-x", "-t", "png"]
        if let display = hello.int("display") { argv += ["-D", String(display)] }
        argv.append(out)
        let child = try Child.spawn(argv, env: commandEnvironment(), stdin: false, stdout: .null, stderr: .null)
        let (code, _) = child.wait()
        guard code == 0, FileManager.default.fileExists(atPath: out) else {
            throw NetError("screencapture failed (\(code)); grant Porthole Screen Recording in System Settings on \(computerName())")
        }
        try sendFile(sock, out, kind: "file", path: out)
    }
}

/// The name shown in Sharing settings, such as "Nate's Mac mini".
func computerName() -> String {
    if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? { return name }
    var buf = [CChar](repeating: 0, count: 256)
    gethostname(&buf, buf.count)
    return String(cString: buf)
}
