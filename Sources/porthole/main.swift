import CoreGraphics
import Foundation

let usage = """
porthole \(portholeVersion): let agents work on another Mac's screen, apps and audio

On the Mac that does the work:
  porthole install [--port N] [--any]   serve this Mac (LaunchAgent), linking the CLI into ~/.local/bin
  porthole uninstall                    stop serving this Mac
  porthole serve [--port N] [--any]     serve in the foreground (--any: accept peers off the tailnet)
  porthole token                        print this Mac's token

On the Mac the agent runs on:
  porthole share [--port N] [--mcp-scope user|local|project|none] [--once]
                                        serve an installer; the other Mac runs `curl …/install | sh` and pairs back
                                        (--once: exit after the first pairing)
  porthole pair <name> <address[:port]> <token>
  porthole hosts [rm <name>]            list or remove paired hosts
  porthole mcp [host]                   stdio MCP server: desktop-tools on the host plus remote_* tools

  porthole info  [-H host]
  porthole exec  [-H host] [--cwd dir] [--timeout s] [--detach] -- command…
  porthole push  [-H host] <local> <remote>
  porthole pull  [-H host] <remote> <local>
  porthole shot  [-H host] [--display n] [out.png]
  porthole audio [-H host] [--seconds n] [--app name] [--pull path]

-H defaults to $PORTHOLE_HOST, or the only paired host.
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("porthole: \(msg)\n".utf8))
    exit(1)
}

struct Args {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var rest: [String] = []

    init(_ argv: ArraySlice<String>, valued: Set<String>) {
        var it = argv.makeIterator()
        while let a = it.next() {
            if a == "--" { rest = Array(it); break }
            if a.hasPrefix("-"), a.count > 1 {
                let key = a.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                if valued.contains(key) {
                    guard let v = it.next() else { fail("\(a) needs a value") }
                    flags[key] = v
                } else {
                    flags[key] = "true"
                }
            } else {
                positional.append(a)
            }
        }
    }

    func host() throws -> Host {
        try Hosts.resolve(flags["H"] ?? flags["host"] ?? ProcessInfo.processInfo.environment["PORTHOLE_HOST"])
    }
}

func run() throws {
    let argv = CommandLine.arguments
    guard argv.count > 1 else { print(usage); return }
    let cmd = argv[1]
    let a = Args(argv.dropFirst(2), valued: ["port", "H", "host", "cwd", "timeout", "seconds", "app", "pull", "display", "mcp-scope"])

    switch cmd {
    case "serve":
        let token = Token.load()!
        if !CGPreflightScreenCaptureAccess() {
            // Asks once, attributed to Porthole.app; screenshots and audio need it.
            Log.info("Screen Recording not granted; requesting it")
            _ = CGRequestScreenCaptureAccess()
        }
        try Server(port: Int(a.flags["port"] ?? "") ?? defaultPort, token: token, allowAny: a.flags["any"] != nil).run()

    case "install":
        try Install.install(port: Int(a.flags["port"] ?? "") ?? defaultPort, allowAny: a.flags["any"] != nil)

    case "uninstall":
        Install.uninstall()

    case "token":
        print(Token.load()!)

    case "share":
        let scope = a.flags["mcp-scope"] ?? "user"
        try Share(port: Int(a.flags["port"] ?? "") ?? 7879, mcpScope: scope == "none" ? nil : scope, once: a.flags["once"] != nil).run()

    case "pair":
        guard a.positional.count == 3 else { fail("usage: porthole pair <name> <address[:port]> <token>") }
        var address = a.positional[1]
        var port = defaultPort
        if let colon = address.lastIndex(of: ":"), !address.contains("]"), address.filter({ $0 == ":" }).count == 1 {
            port = Int(address[address.index(after: colon)...]) ?? defaultPort
            address = String(address[..<colon])
        }
        let host = Host(name: Share.sanitize(a.positional[0]), address: address, port: port, token: a.positional[2])
        try Hosts.upsert(host)
        print("paired \(host.name) at \(address):\(port)")

    case "hosts":
        if a.positional.first == "rm", a.positional.count == 2 {
            try Hosts.remove(a.positional[1])
            return
        }
        for h in Hosts.all() { print("\(h.name)\t\(h.address):\(h.port)") }

    case "mcp":
        let host = try Hosts.resolve(a.positional.first ?? a.flags["H"] ?? ProcessInfo.processInfo.environment["PORTHOLE_HOST"])
        MCPProxy(host: host).run()

    case "info":
        print(JSON.pretty(try Remote.info(try a.host())))

    case "exec":
        let host = try a.host()
        let command = (a.rest.isEmpty ? a.positional : a.rest).joined(separator: " ")
        guard !command.isEmpty else { fail("usage: porthole exec [-H host] -- command") }
        if a.flags["detach"] != nil {
            print(JSON.pretty(try Remote.detach(host, command, cwd: a.flags["cwd"])))
            return
        }
        signal(SIGPIPE, SIG_IGN)
        let r = try Remote.exec(
            host, command, cwd: a.flags["cwd"], timeout: Double(a.flags["timeout"] ?? "") ?? 0,
            forwardStdin: isatty(0) == 0,
            onOut: { FileHandle.standardOutput.write($0) },
            onErr: { FileHandle.standardError.write($0) }
        )
        if r.timedOut { FileHandle.standardError.write(Data("porthole: timed out\n".utf8)) }
        exit(Int32(truncatingIfNeeded: r.code))

    case "push":
        guard a.positional.count == 2 else { fail("usage: porthole push [-H host] <local> <remote>") }
        print(try Remote.push(try a.host(), local: a.positional[0], remote: a.positional[1]))

    case "pull":
        guard a.positional.count == 2 else { fail("usage: porthole pull [-H host] <remote> <local>") }
        print(try Remote.pull(try a.host(), remote: a.positional[0], local: a.positional[1]))

    case "shot":
        let out = a.positional.first ?? "porthole-\(Int(Date().timeIntervalSince1970)).png"
        print(try Remote.shot(try a.host(), to: out, display: a.flags["display"].flatMap { Int($0) }))

    case "audio":
        let host = try a.host()
        var summary = try Remote.audio(host, seconds: Double(a.flags["seconds"] ?? "") ?? 5, app: a.flags["app"])
        if let dest = a.flags["pull"], let path = summary.str("path") {
            summary["pulled_to"] = try Remote.pull(host, remote: path, local: dest)
        }
        print(JSON.pretty(summary))

    case "record":
        // Records locally, for running under `open` so macOS can show the audio permission prompt.
        let seconds = Double(a.flags["seconds"] ?? "") ?? 3
        let out = a.positional.first ?? NSTemporaryDirectory() + "porthole-record.wav"
        print(JSON.pretty(try AudioRecorder.record(seconds: seconds, app: a.flags["app"], to: out)))

    case "version", "--version", "-v":
        print(portholeVersion)

    case "help", "--help", "-h":
        print(usage)

    default:
        fail("unknown command \(cmd)\n\n\(usage)")
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
do {
    try run()
} catch {
    fail("\(error)")
}
