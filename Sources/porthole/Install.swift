import Foundation

enum Install {
    static let label = "win.porthole.serve"

    /// The running executable, resolved through symlinks.
    static var executable: String {
        let p = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return (p as NSString).resolvingSymlinksInPath
    }

    /// Installs the LaunchAgent that serves this Mac, and links the CLI into ~/.local/bin.
    static func install(port: Int, allowAny: Bool) throws {
        let exe = executable
        if !exe.contains(".app/Contents/MacOS/") {
            print("warning: \(exe) is not inside Porthole.app; macOS ties Screen Recording to the app, so grants won't survive a rebuild")
        }
        _ = Token.load()
        Paths.ensure(Paths.stateDir)
        linkCLI(exe)

        var args = [exe, "serve", "--port", String(port)]
        if allowAny { args.append("--any") }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": args,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": Paths.logFile.path,
            "StandardErrorPath": Paths.logFile.path,
        ]
        try FileManager.default.createDirectory(at: Paths.launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: Paths.launchAgent)

        let domain = "gui/\(getuid())"
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        let (code, out) = launchctl(["bootstrap", domain, Paths.launchAgent.path])
        guard code == 0 else { throw NetError("launchctl bootstrap failed: \(out)") }
        // Pairing right after install needs the server to be listening.
        for _ in 0..<50 {
            if let s = try? Socket.connect(host: "127.0.0.1", port: port, timeout: 1) { s.close(); break }
            usleep(100_000)
        }
        print("porthole is serving this Mac on port \(port) (log: \(Paths.logFile.path))")
    }

    static func uninstall() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: Paths.launchAgent)
        print("removed the porthole LaunchAgent")
    }

    static func linkCLI(_ exe: String) {
        let bin = Paths.home.appendingPathComponent(".local/bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("porthole").path
        try? FileManager.default.removeItem(atPath: link)
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: exe)
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> (Int32, String) {
        guard let c = try? Child.spawn(["/bin/launchctl"] + args, stdin: false) else { return (-1, "") }
        var out = Data()
        let t1 = pump(c.stdout!) { out.append($0) }
        let t2 = pump(c.stderr!) { out.append($0) }
        let (code, _) = c.wait()
        while t1.isExecuting || t2.isExecuting { usleep(1000) }
        return (code, String(decoding: out, as: UTF8.self))
    }

    /// The app bundle the running binary lives in, if any.
    static var appBundle: String? {
        guard let r = executable.range(of: ".app/Contents/MacOS/") else { return nil }
        return String(executable[..<r.lowerBound]) + ".app"
    }
}

/// A one-shot HTTP server that hands Porthole.app to another Mac and pairs with it:
/// on the other Mac, `curl -fsSL http://<this mac>:7879/install | sh`.
final class Share {
    let port: Int
    let mcpScope: String?
    let once: Bool
    private let zip: String

    init(port: Int, mcpScope: String?, once: Bool = false) throws {
        self.port = port
        self.mcpScope = mcpScope
        self.once = once
        guard let app = Install.appBundle else { throw NetError("run share from the porthole inside Porthole.app") }
        zip = NSTemporaryDirectory() + "Porthole-\(getpid()).zip"
        try? FileManager.default.removeItem(atPath: zip)
        let ditto = try Child.spawn(["/usr/bin/ditto", "-c", "-k", "--keepParent", app, zip], stdin: false, stdout: .null, stderr: .null)
        guard ditto.wait().0 == 0 else { throw NetError("could not zip \(app)") }
    }

    func run() throws -> Never {
        signal(SIGPIPE, SIG_IGN)
        let listener = try Listener(port: port)
        let ips = tailscaleIPs()
        print("Serving the porthole installer. On the other Mac, run:\n")
        for ip in ips.isEmpty ? ["<this-mac-tailscale-ip>"] : ips {
            print("    curl -fsSL http://\(ip):\(port)/install | sh\n")
        }
        print("It installs Porthole and Desktop Tools there, starts the server and pairs back here. Ctrl-C to stop.")
        while true {
            let sock = try listener.accept()
            Thread.detachNewThread { [self] in
                handle(sock)
                sock.close()
            }
        }
    }

    private func handle(_ sock: Socket) {
        guard PeerPolicy.isTrusted(sock.peer) else {
            respond(sock, 403, "only loopback and tailnet peers\n")
            return
        }
        guard let requestLine = try? sock.readLine() else { return }
        var headers: [String: String] = [:]
        while let h = try? sock.readLine(), !h.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let colon = h.firstIndex(of: ":") {
                headers[h[..<colon].lowercased()] = h[h.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let comps = URLComponents(string: String(parts[1]))
        let path = comps?.path ?? "/"
        let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let base = "http://\(headers["host"] ?? "localhost:\(port)")"
        print("\(sock.peer) \(method) \(path)")

        switch (method, path) {
        case ("GET", "/install"):
            respond(sock, 200, Share.script(base: base), type: "text/x-shellscript")
        case ("GET", "/Porthole.zip"):
            if let data = FileManager.default.contents(atPath: zip) {
                respond(sock, 200, data, type: "application/zip")
            } else {
                respond(sock, 500, "zip missing\n")
            }
        case ("POST", "/pair"):
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let body = (try? sock.readExact(length)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let token = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = Share.sanitize(query["name"] ?? "remote")
            let port = Int(query["port"] ?? "") ?? defaultPort
            guard token.count == 64 else { respond(sock, 400, "bad token\n"); return }
            let host = Host(name: name, address: sock.peer, port: port, token: token)
            do {
                try Hosts.upsert(host)
                let reach = (try? Remote.info(host)).map { "reachable: \($0.str("hostname") ?? "?")" } ?? "not reachable yet"
                var msg = "paired \(name) at \(sock.peer):\(port) (\(reach))"
                if let scope = mcpScope { msg += "\n" + Share.registerMCP(name: name, scope: scope) }
                print(msg)
                respond(sock, 200, msg + "\n")
                if once { sock.close(); exit(0) }
            } catch {
                respond(sock, 500, "\(error)\n")
            }
        default:
            respond(sock, 404, "not found\n")
        }
    }

    /// Adds `porthole mcp <name>` to Claude Code as an MCP server named porthole-<name>.
    static func registerMCP(name: String, scope: String) -> String {
        let claude = ["\(Paths.home.path)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let claude else { return "claude not found; add the MCP server with: claude mcp add -s user porthole-\(name) -- porthole mcp \(name)" }
        let exe = Install.executable
        _ = run([claude, "mcp", "remove", "-s", scope, "porthole-\(name)"])
        let (code, out) = run([claude, "mcp", "add", "-s", scope, "porthole-\(name)", "--", exe, "mcp", name])
        return code == 0 ? "added MCP server porthole-\(name) to Claude Code (\(scope) scope)" : "claude mcp add failed: \(out)"
    }

    static func run(_ argv: [String]) -> (Int32, String) {
        guard let c = try? Child.spawn(argv, env: commandEnvironment(), stdin: false) else { return (-1, "") }
        var out = Data()
        let t1 = pump(c.stdout!) { out.append($0) }
        let t2 = pump(c.stderr!) { out.append($0) }
        let (code, _) = c.wait()
        while t1.isExecuting || t2.isExecuting { usleep(1000) }
        return (code, String(decoding: out, as: UTF8.self))
    }

    static func sanitize(_ s: String) -> String {
        let lowered = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "remote" : collapsed
    }

    private func respond(_ sock: Socket, _ status: Int, _ body: String, type: String = "text/plain") {
        respond(sock, status, Data(body.utf8), type: type)
    }

    private func respond(_ sock: Socket, _ status: Int, _ body: Data, type: String) {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try? sock.write(Data(head.utf8) + body)
    }

    func tailscaleIPs() -> [String] {
        let candidates = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let ts = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let (code, out) = Share.run([ts, "ip", "-4"])
        guard code == 0 else { return [] }
        return out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func script(base: String) -> String {
        """
        #!/bin/sh
        # Installs Porthole (and Desktop Tools, if missing) on this Mac, starts its
        # server, and pairs it with the Mac at \(base).
        set -eu
        BASE='\(base)'
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT

        apps=/Applications
        [ -w "$apps" ] || { apps="$HOME/Applications"; mkdir -p "$apps"; }

        echo "==> Porthole"
        curl -fsSL "$BASE/Porthole.zip" -o "$tmp/Porthole.zip"
        ditto -x -k "$tmp/Porthole.zip" "$tmp/app"
        rm -rf "$apps/Porthole.app"
        ditto "$tmp/app/Porthole.app" "$apps/Porthole.app"

        if [ ! -d "/Applications/Desktop Tools.app" ]; then
          echo "==> Desktop Tools"
          urls=$(curl -fsSL https://api.github.com/repos/githubnext/desktop-tools/releases/latest \\
            | grep -o '"browser_download_url": *"[^"]*\\.dmg"' | sed 's/.*"\\(http[^"]*\\)"/\\1/')
          url=$(echo "$urls" | grep -- "$(uname -m)" | head -1)
          [ -n "$url" ] || url=$(echo "$urls" | head -1)
          if [ -n "$url" ]; then
            curl -fsSL "$url" -o "$tmp/dt.dmg"
            hdiutil attach -nobrowse -quiet -mountpoint "$tmp/dt" "$tmp/dt.dmg"
            ditto "$tmp/dt/Desktop Tools.app" "/Applications/Desktop Tools.app" || ditto "$tmp/dt/Desktop Tools.app" "$apps/Desktop Tools.app"
            hdiutil detach -quiet "$tmp/dt" || true
          else
            echo "    could not find the Desktop Tools DMG; install it from https://github.com/githubnext/desktop-tools/releases"
          fi
        fi
        open -a "Desktop Tools" || true

        echo "==> Starting the server"
        "$apps/Porthole.app/Contents/MacOS/porthole" install
        token=$(cat "$HOME/.config/porthole/token")
        name=$(scutil --get LocalHostName 2>/dev/null || hostname -s)

        echo "==> Pairing with $BASE"
        curl -fsS -X POST "$BASE/pair?name=$name&port=\(defaultPort)" --data "$token"

        cat <<'EOF'

        Done. Two things only you can do on this Mac:
          1. In the Desktop Tools menu bar app, grant Accessibility, Screen Recording and Keyboard input,
             and choose Allow when it asks about "porthole".
          2. Allow Porthole when macOS asks for Screen Recording (used for screenshots and audio).
             Or: System Settings > Privacy & Security > Screen & System Audio Recording.
        EOF

        """
    }
}
