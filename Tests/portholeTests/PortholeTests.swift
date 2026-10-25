import Foundation
import XCTest
@testable import porthole

final class PortholeTests: XCTestCase {
    static let port = 17000 + Int(getpid() % 1000)
    static let token = Token.generate()
    static var started = false

    var host: porthole.Host { porthole.Host(name: "test", address: "127.0.0.1", port: Self.port, token: Self.token) }

    override class func setUp() {
        guard !started else { return }
        started = true
        Thread.detachNewThread { try? Server(port: port, token: token).run() }
        for _ in 0..<100 {
            if (try? Socket.connect(host: "127.0.0.1", port: port, timeout: 1)) != nil { break }
            usleep(20_000)
        }
    }

    func testPeerPolicy() {
        XCTAssertTrue(PeerPolicy.isTrusted(peer: "127.0.0.1", local: "127.0.0.1"))
        XCTAssertTrue(PeerPolicy.isTrusted(peer: "::1", local: "::1"))
        XCTAssertTrue(PeerPolicy.isTrusted(peer: "100.119.196.79", local: "100.71.113.126"))
        XCTAssertTrue(PeerPolicy.isTrusted(peer: "fd7a:115c:a1e0::1", local: "fd7a:115c:a1e0::2"))
        XCTAssertFalse(PeerPolicy.isTrusted(peer: "100.128.0.1", local: "100.71.113.126"))
        XCTAssertFalse(PeerPolicy.isTrusted(peer: "192.168.0.146", local: "192.168.0.10"))
        // A CGNAT-range peer that reached the LAN address didn't come over Tailscale.
        XCTAssertFalse(PeerPolicy.isTrusted(peer: "100.70.0.5", local: "192.168.0.10"))
        XCTAssertFalse(PeerPolicy.isTrusted(peer: "100.70.0.5", local: "127.0.0.1"))
    }

    func testSanitize() {
        XCTAssertEqual(Share.sanitize("Nates-Mac-mini"), "nates-mac-mini")
        XCTAssertEqual(Share.sanitize("a  b__c"), "a-b-c")
        XCTAssertEqual(Share.sanitize("--"), "remote")
    }

    func testBadTokenIsRefused() {
        var h = host
        h.token = Token.generate()
        XCTAssertThrowsError(try Remote.info(h)) { XCTAssertTrue("\($0)".contains("bad token")) }
    }

    func testInfo() throws {
        let info = try Remote.info(host)
        XCTAssertEqual(info.str("user"), NSUserName())
        XCTAssertEqual(info.str("porthole"), portholeVersion)
    }

    func testExecStreamsOutputAndExitCode() throws {
        let r = try Remote.exec(host, "echo out; echo err >&2; exit 3")
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: r.stderr, as: UTF8.self), "err\n")
        XCTAssertEqual(r.code, 3)
    }

    func testExecStdinAndCwd() throws {
        let r = try Remote.exec(host, "pwd; tr a-z A-Z", cwd: "/tmp", stdin: Data("hello".utf8))
        let out = String(decoding: r.stdout, as: UTF8.self)
        XCTAssertTrue(out.hasSuffix("HELLO"), out)
        XCTAssertTrue(out.hasPrefix("/tmp") || out.hasPrefix("/private/tmp"), out)
    }

    func testExecTimeoutKillsTheProcessGroup() throws {
        let start = Date()
        let r = try Remote.exec(host, "sleep 30 & sleep 30; echo never", timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertFalse(String(decoding: r.stdout, as: UTF8.self).contains("never"))
    }

    func testDetach() throws {
        let marker = NSTemporaryDirectory() + "porthole-detach-\(UUID().uuidString)"
        let reply = try Remote.detach(host, "sleep 0.2; echo done > \(marker)")
        XCTAssertNotNil(reply.int("pid"))
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: marker) { usleep(100_000) }
        XCTAssertEqual(try String(contentsOfFile: marker, encoding: .utf8), "done\n")
    }

    func testPushAndPullFile() throws {
        let dir = NSTemporaryDirectory() + "porthole-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let src = dir + "/src.bin"
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        try bytes.write(to: URL(fileURLWithPath: src))
        chmod(src, 0o755)
        _ = try Remote.push(host, local: src, remote: dir + "/remote/copy.bin")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/remote/copy.bin")), bytes)
        _ = try Remote.pull(host, remote: dir + "/remote/copy.bin", local: dir + "/back.bin")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/back.bin")), bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: dir + "/back.bin")[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755)
    }

    func testPushAndPullDirectorySkipsGit() throws {
        let dir = NSTemporaryDirectory() + "porthole-test-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/src/sub", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dir + "/src/.git", withIntermediateDirectories: true)
        try "a".write(toFile: dir + "/src/a.txt", atomically: true, encoding: .utf8)
        try "b".write(toFile: dir + "/src/sub/b.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: dir + "/src/.git/HEAD", atomically: true, encoding: .utf8)
        _ = try Remote.push(host, local: dir + "/src", remote: dir + "/dst")
        XCTAssertEqual(try String(contentsOfFile: dir + "/dst/sub/b.txt", encoding: .utf8), "b")
        XCTAssertFalse(fm.fileExists(atPath: dir + "/dst/.git"))
        _ = try Remote.pull(host, remote: dir + "/dst", local: dir + "/back")
        XCTAssertEqual(try String(contentsOfFile: dir + "/back/a.txt", encoding: .utf8), "a")
    }

    func testRunStagesRunsCopiesBackAndCleansUp() throws {
        let dir = NSTemporaryDirectory() + "porthole-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "in".write(toFile: dir + "/input.txt", atomically: true, encoding: .utf8)
        let r = try Remote.run(
            host, "pwd > where; cat in.txt > out/result.txt 2>/dev/null || { mkdir out; cat in.txt > out/result.txt; }; exit 3",
            puts: [dir + "/input.txt=in.txt"], gets: ["out=\(dir)/back", "where=\(dir)/where"])
        XCTAssertEqual(r.code, 3)
        XCTAssertEqual(try String(contentsOfFile: dir + "/back/result.txt", encoding: .utf8), "in")
        let ran = try String(contentsOfFile: dir + "/where", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ran.contains("/porthole/runs/"), ran)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran), "run folder should be removed")
    }

    func testPullMissingFileFails() {
        XCTAssertThrowsError(try Remote.pull(host, remote: "/nonexistent/\(UUID().uuidString)", local: "/tmp/x"))
    }
}
