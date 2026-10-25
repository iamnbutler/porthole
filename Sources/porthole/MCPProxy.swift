import Foundation

/// A stdio MCP server that forwards to the desktop-tools MCP server on a remote Mac
/// and adds remote_* tools for commands, files, audio and screenshots there.
/// Messages it doesn't need to change pass through byte for byte.
final class MCPProxy {
    let host: Host
    private let outLock = NSLock()
    private let stateLock = NSLock()
    private var remote: Socket?
    private var lastError = ""
    private var initLine: String?
    private var listIds = Set<String>()
    private var initIds = Set<String>()
    private var inFlight = Set<String>()
    private var remoteHostname = ""
    private static let replayId = "porthole-replay-init"

    init(host: Host) { self.host = host }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        _ = connect(replay: false)
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let msg = try? JSON.decodeObject(line) else { forward(line, msg: [:]); continue }
            handle(line, msg)
        }
        stateLock.lock(); let r = remote; stateLock.unlock()
        r?.shutdownWrite()
        exit(0)
    }

    // MARK: client -> proxy

    private func handle(_ line: String, _ msg: [String: Any]) {
        let method = msg.str("method")
        let id = msg["id"].map(idKey)

        switch method {
        case "initialize":
            stateLock.lock(); initLine = line; stateLock.unlock()
            // The client's own initialize goes through, so connect without replaying it.
            if let id, currentRemote(reconnect: true, replay: false) != nil {
                stateLock.lock(); initIds.insert(id); stateLock.unlock()
                forward(line, msg: msg)
            } else {
                // Serve our own tools so the agent can see why the remote is unreachable.
                reply(msg["id"], result: [
                    "protocolVersion": (msg.obj("params")?.str("protocolVersion")) ?? "2025-06-18",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "porthole", "version": portholeVersion],
                    "instructions": instructions(),
                ])
            }
        case "tools/list":
            if let id, currentRemote(reconnect: true) != nil {
                stateLock.lock(); listIds.insert(id); stateLock.unlock()
                forward(line, msg: msg)
            } else {
                reply(msg["id"], result: ["tools": RemoteTools.definitions])
            }
        case "tools/call":
            let name = msg.obj("params")?.str("name") ?? ""
            if RemoteTools.names.contains(name) {
                let args = msg.obj("params")?.obj("arguments") ?? [:]
                let rawId = msg["id"]
                Thread.detachNewThread { [self] in
                    let result = RemoteTools.call(name, args, host: host)
                    reply(rawId, result: result)
                }
            } else {
                forward(line, msg: msg)
            }
        default:
            forward(line, msg: msg)
        }
    }

    private func forward(_ line: String, msg: [String: Any]) {
        let id = msg["method"] != nil ? msg["id"] : nil
        guard let sock = currentRemote(reconnect: true) else {
            if let id { replyError(id, "\(host.name) is unreachable: \(lastError)") }
            return
        }
        if let id { stateLock.lock(); inFlight.insert(idKey(id)); stateLock.unlock() }
        do {
            try sock.writeLine(line)
        } catch {
            dropRemote(sock, "\(error)")
            if let id { replyError(id, "lost connection to \(host.name): \(error)") }
        }
    }

    // MARK: remote -> client

    private func currentRemote(reconnect: Bool, replay: Bool = true) -> Socket? {
        stateLock.lock()
        if let r = remote { stateLock.unlock(); return r }
        stateLock.unlock()
        return reconnect ? connect(replay: replay) : nil
    }

    private func connect(replay: Bool) -> Socket? {
        do {
            let (sock, _) = try dial(host, ["op": "mcp"], timeout: 5)
            if let info = try? Remote.info(host) { remoteHostname = info.str("hostname") ?? "" }
            stateLock.lock()
            remote = sock
            let initLine = self.initLine
            stateLock.unlock()
            // A new connection is a new MCP server: replay the client's handshake.
            if replay, let initLine, var m = try? JSON.decodeObject(initLine) {
                m["id"] = MCPProxy.replayId
                try sock.send(json: m)
                try sock.send(json: ["jsonrpc": "2.0", "method": "notifications/initialized"])
            }
            Thread.detachNewThread { [self] in readRemote(sock) }
            return sock
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    private func readRemote(_ sock: Socket) {
        while let line = try? sock.readLine() {
            guard let msg = try? JSON.decodeObject(line), let rawId = msg["id"], msg["method"] == nil else {
                write(line)
                continue
            }
            let id = idKey(rawId)
            if id == idKey(MCPProxy.replayId) { continue }
            stateLock.lock()
            inFlight.remove(id)
            let isList = listIds.remove(id) != nil
            let isInit = initIds.remove(id) != nil
            stateLock.unlock()
            if isList, var result = msg.obj("result") {
                result["tools"] = ((result["tools"] as? [Any]) ?? []) + RemoteTools.definitions
                var m = msg; m["result"] = result
                write(JSON.encode(m))
            } else if isInit, var result = msg.obj("result") {
                result["instructions"] = instructions() + "\n\n" + (result.str("instructions") ?? "")
                var m = msg; m["result"] = result
                write(JSON.encode(m))
            } else {
                write(line)
            }
        }
        dropRemote(sock, "connection closed")
    }

    private func dropRemote(_ sock: Socket, _ why: String) {
        stateLock.lock()
        guard remote === sock else { stateLock.unlock(); return }
        remote = nil
        lastError = why
        let orphans = inFlight
        inFlight.removeAll()
        listIds.removeAll()
        initIds.removeAll()
        stateLock.unlock()
        sock.close()
        // Requests the old connection never answered would hang the client.
        for id in orphans {
            if let raw = try? JSON.decode(id) { replyError(raw, "lost connection to \(host.name) (\(why)); retry the call") }
        }
    }

    // MARK: output

    private func write(_ line: String) {
        outLock.lock(); defer { outLock.unlock() }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private func reply(_ id: Any?, result: [String: Any]) {
        write(JSON.encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]))
    }

    private func replyError(_ id: Any, _ message: String) {
        write(JSON.encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": message]]))
    }

    private func idKey(_ id: Any) -> String { JSON.encode([id]).dropFirst().dropLast().description }

    private func instructions() -> String {
        let where_ = remoteHostname.isEmpty ? "the remote Mac \"\(host.name)\"" : "the remote Mac \"\(host.name)\" (\(remoteHostname))"
        var s = """
        Every tool in this server acts on \(where_), not on the machine you are running on. \
        Use it for work that needs a real screen, windows, input or audio: building and running desktop apps, UI testing, checking sound.
        - remote_exec runs shell commands there (zsh login shell, cwd defaults to its home). GUI apps it launches appear on its screen.
        - remote_push and remote_pull copy files and directories between this machine and it. Paths that desktop_* tools return or accept (save_path) are on the remote Mac; pull them to view them here.
        - remote_screenshot returns a downscaled image of its whole screen; desktop_inspect gives a window snapshot with element IDs for input.
        - remote_audio records what it plays (all audio, or one app) and reports levels over time, so you can tell whether a sound played.
        """
        if !lastError.isEmpty && remote == nil {
            s += "\nThe remote is currently unreachable: \(lastError). Only remote_* tools are listed until it is back."
        }
        return s
    }
}

enum RemoteTools {
    static let names: Set<String> = Set(definitions.compactMap { $0["name"] as? String })

    static let definitions: [[String: Any]] = [
        tool("remote_info", "Describe the remote Mac: hostname, macOS version, user, home directory, and whether Desktop Tools and Screen Recording are ready.", [:], []),
        tool("remote_exec", "Run a shell command on the remote Mac and return its exit code, stdout and stderr (each truncated to the last 20,000 characters). Runs in a zsh login shell. Set detach to start a long-running process (a dev server, an app) and return at once with its pid and log path.", [
            "command": ["type": "string", "description": "Shell command line."],
            "cwd": ["type": "string", "description": "Working directory on the remote Mac; ~ is its home. Default ~."],
            "timeout_seconds": ["type": "number", "description": "Kill the command after this many seconds. Default 600."],
            "detach": ["type": "boolean", "description": "Start in the background and return immediately; output goes to a log file on the remote Mac."],
        ], ["command"]),
        tool("remote_push", "Copy a file or directory from this machine to the remote Mac. Directories are copied without .git, node_modules, .build, target and DerivedData. Overwrites files that exist.", [
            "local_path": ["type": "string", "description": "Absolute path on this machine."],
            "remote_path": ["type": "string", "description": "Destination path on the remote Mac (for a directory, the directory to fill). ~ is its home."],
        ], ["local_path", "remote_path"]),
        tool("remote_pull", "Copy a file or directory from the remote Mac to this machine.", [
            "remote_path": ["type": "string", "description": "Path on the remote Mac; ~ is its home."],
            "local_path": ["type": "string", "description": "Destination on this machine. An existing directory receives the file inside it."],
        ], ["remote_path", "local_path"]),
        tool("remote_screenshot", "Capture the remote Mac's whole screen and return it as an image, downscaled to fit 1600 px.", [
            "display": ["type": "integer", "description": "Display number, 1 for the main display. Default main."],
        ], []),
        tool("remote_audio", "Record the remote Mac's audio output for a few seconds and report whether sound played: peak level, when sound started and stopped, and a level per 0.1 s window in dBFS. Start the recording, then trigger the sound with another tool call in parallel, or record while something is already playing. The WAV stays on the remote Mac; pass pull_to to copy it here.", [
            "seconds": ["type": "number", "description": "How long to record, 0.5 to 300. Default 5."],
            "app": ["type": "string", "description": "Only this app's audio: a bundle ID or app name. Default: all audio."],
            "pull_to": ["type": "string", "description": "Copy the recording to this local path."],
        ], []),
    ]

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": desc, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    static func call(_ name: String, _ a: [String: Any], host: Host) -> [String: Any] {
        do {
            switch name {
            case "remote_info":
                return text(JSON.pretty(try Remote.info(host)))
            case "remote_exec":
                guard let cmd = a.str("command") else { throw NetError("command is required") }
                if a.bool("detach") == true {
                    return text(JSON.pretty(try Remote.detach(host, cmd, cwd: a.str("cwd"))))
                }
                let r = try Remote.exec(host, cmd, cwd: a.str("cwd"), timeout: a.double("timeout_seconds") ?? 600)
                var out = "exit code: \(r.code)\(r.timedOut ? " (timed out)" : "")\n"
                let so = tail(r.stdout), se = tail(r.stderr)
                if !so.isEmpty { out += "--- stdout ---\n\(so)\n" }
                if !se.isEmpty { out += "--- stderr ---\n\(se)\n" }
                return text(out, isError: r.code != 0)
            case "remote_push":
                guard let l = a.str("local_path"), let r = a.str("remote_path") else { throw NetError("local_path and remote_path are required") }
                return text("copied \(l) to \(host.name):\(try Remote.push(host, local: Paths.expand(l), remote: r))")
            case "remote_pull":
                guard let r = a.str("remote_path"), let l = a.str("local_path") else { throw NetError("remote_path and local_path are required") }
                return text("copied \(host.name):\(r) to \(try Remote.pull(host, remote: r, local: Paths.expand(l)))")
            case "remote_screenshot":
                let tmp = NSTemporaryDirectory() + "porthole-shot-\(UUID().uuidString).png"
                defer { try? FileManager.default.removeItem(atPath: tmp) }
                _ = try Remote.shot(host, to: tmp, display: a.int("display"))
                let small = tmp + ".jpg"
                defer { try? FileManager.default.removeItem(atPath: small) }
                let sips = try Child.spawn(["/usr/bin/sips", "-Z", "1600", "-s", "format", "jpeg", "-s", "formatOptions", "80", tmp, "--out", small],
                                           env: commandEnvironment(), stdin: false, stdout: .null, stderr: .null)
                let ok = sips.wait().0 == 0
                let data = try Data(contentsOf: URL(fileURLWithPath: ok ? small : tmp))
                return ["content": [["type": "image", "data": data.base64EncodedString(), "mimeType": ok ? "image/jpeg" : "image/png"]]]
            case "remote_audio":
                var summary = try Remote.audio(host, seconds: a.double("seconds") ?? 5, app: a.str("app"))
                if let dest = a.str("pull_to"), let path = summary.str("path") {
                    summary["pulled_to"] = try Remote.pull(host, remote: path, local: Paths.expand(dest))
                }
                return text(JSON.encode(summary))
            default:
                throw NetError("unknown tool \(name)")
            }
        } catch {
            return text("\(error)", isError: true)
        }
    }

    private static func text(_ s: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": s]], "isError": isError]
    }

    private static func tail(_ d: Data, limit: Int = 20000) -> String {
        let s = String(decoding: d, as: UTF8.self)
        guard s.count > limit else { return s }
        return "[… \(s.count - limit) characters cut …]\n" + s.suffix(limit)
    }
}
