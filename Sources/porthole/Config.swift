import Foundation
import Security

let portholeVersion = "0.1.0"
let defaultPort = 7878

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let configDir = home.appendingPathComponent(".config/porthole")
    static let tokenFile = configDir.appendingPathComponent("token")
    static let hostsFile = configDir.appendingPathComponent("hosts.json")
    static let stateDir = home.appendingPathComponent(".local/state/porthole")
    static let logFile = stateDir.appendingPathComponent("serve.log")
    static let workDir = home.appendingPathComponent("porthole")
    static let launchAgent = home.appendingPathComponent("Library/LaunchAgents/win.porthole.serve.plist")
    static let desktopToolsMCP = "/Applications/Desktop Tools.app/Contents/MacOS/desktop-tools-mcp"

    static func ensure(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Expands a leading ~ against this machine's home directory.
    static func expand(_ path: String) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }
}

enum Token {
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The server's token, created on first use.
    static func load(create: Bool = true) -> String? {
        if let t = try? String(contentsOf: Paths.tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        guard create else { return nil }
        Paths.ensure(Paths.configDir)
        let t = generate()
        FileManager.default.createFile(atPath: Paths.tokenFile.path, contents: Data((t + "\n").utf8), attributes: [.posixPermissions: 0o600])
        return t
    }

    static func matches(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

struct Host: Codable {
    var name: String
    var address: String
    var port: Int
    var token: String
}

enum Hosts {
    static func all() -> [Host] {
        guard let data = try? Data(contentsOf: Paths.hostsFile) else { return [] }
        return (try? JSONDecoder().decode([Host].self, from: data)) ?? []
    }

    static func save(_ hosts: [Host]) throws {
        Paths.ensure(Paths.configDir)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(hosts.sorted { $0.name < $1.name })
        try data.write(to: Paths.hostsFile, options: .atomic)
        chmod(Paths.hostsFile.path, 0o600)
    }

    static func upsert(_ host: Host) throws {
        var hosts = all().filter { $0.name != host.name }
        hosts.append(host)
        try save(hosts)
    }

    static func remove(_ name: String) throws {
        try save(all().filter { $0.name != name })
    }

    /// Resolves a host by name. With one host configured, nil or "" picks it.
    static func resolve(_ name: String?) throws -> Host {
        let hosts = all()
        if let name, !name.isEmpty {
            if let h = hosts.first(where: { $0.name == name }) { return h }
            throw NetError("no host named \(name); known: \(hosts.map(\.name).joined(separator: ", "))")
        }
        if hosts.count == 1 { return hosts[0] }
        if hosts.isEmpty { throw NetError("no hosts paired; run `porthole pair` or `porthole hosts add`") }
        throw NetError("several hosts paired; name one of: \(hosts.map(\.name).joined(separator: ", "))")
    }
}
