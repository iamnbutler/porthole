import Foundation

/// A child process in its own process group, so killing it takes its children too.
final class Child {
    let pid: pid_t
    let stdin: Int32?
    let stdout: Int32?
    let stderr: Int32?

    private init(pid: pid_t, stdin: Int32?, stdout: Int32?, stderr: Int32?) {
        self.pid = pid
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    enum Output {
        case pipe
        case file(String)
        case null
    }

    static func spawn(
        _ argv: [String],
        cwd: String? = nil,
        env: [String: String]? = nil,
        stdin wantStdin: Bool = true,
        stdout out: Output = .pipe,
        stderr err: Output = .pipe
    ) throws -> Child {
        var actions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        var parentEnds: [Int32] = []
        var childEnds: [Int32] = []
        func pipePair() throws -> (Int32, Int32) {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw NetError("pipe: \(String(cString: strerror(errno)))") }
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
            return (fds[0], fds[1])
        }

        var inFd: Int32?
        if wantStdin {
            let (r, w) = try pipePair()
            posix_spawn_file_actions_adddup2(&actions, r, 0)
            inFd = w
            parentEnds.append(w); childEnds.append(r)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }

        func wire(_ o: Output, _ target: Int32) throws -> Int32? {
            switch o {
            case .pipe:
                let (r, w) = try pipePair()
                posix_spawn_file_actions_adddup2(&actions, w, target)
                parentEnds.append(r); childEnds.append(w)
                return r
            case .file(let path):
                posix_spawn_file_actions_addopen(&actions, target, path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                return nil
            case .null:
                posix_spawn_file_actions_addopen(&actions, target, "/dev/null", O_WRONLY, 0)
                return nil
            }
        }
        let outFd = try wire(out, 1)
        let errFd = try wire(err, 2)

        if let cwd {
            posix_spawn_file_actions_addchdir_np(&actions, cwd)
        }

        var attr = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setpgroup(&attr, 0)
        // Reset signal dispositions and masks the daemon may have changed.
        var all = sigset_t()
        sigfillset(&all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let environment = env ?? ProcessInfo.processInfo.environment
        let envp = environment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let rc = withCStrings(argv) { cargv in
            withCStrings(envp) { cenv in
                posix_spawn(&pid, argv[0], &actions, &attr, cargv, cenv)
            }
        }
        for fd in childEnds { close(fd) }
        guard rc == 0 else {
            for fd in parentEnds { close(fd) }
            throw NetError("spawn \(argv[0]): \(String(cString: strerror(rc)))")
        }
        return Child(pid: pid, stdin: inFd, stdout: outFd, stderr: errFd)
    }

    /// Kills the whole process group.
    func kill(_ sig: Int32 = SIGTERM) {
        Darwin.kill(-pid, sig)
        Darwin.kill(pid, sig)
    }

    /// Waits for exit; returns (exit code, signal number or 0).
    func wait() -> (Int32, Int32) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let sig = status & 0x7f
        if sig == 0 { return ((status >> 8) & 0xff, 0) }
        return (128 + sig, sig)
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    ptrs.append(nil)
    defer { for p in ptrs { free(p) } }
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// Reads an fd to EOF on a background thread, calling `chunk` for each read.
func pump(_ fd: Int32, _ chunk: @escaping (Data) -> Void, done: @escaping () -> Void = {}) -> Thread {
    let t = Thread {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { chunk(Data(buf[0..<n])); continue }
            if n < 0 && errno == EINTR { continue }
            break
        }
        close(fd)
        done()
    }
    t.start()
    return t
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard var p = raw.baseAddress else { return true }
        var left = raw.count
        while left > 0 {
            let n = Darwin.write(fd, p, left)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            p = p.advanced(by: n)
            left -= n
        }
        return true
    }
}

/// The environment a remote command runs with: the daemon's environment plus the
/// usual tool directories, since launchd starts agents with a bare PATH.
func commandEnvironment(extra: [String: String] = [:]) -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let home = Paths.home.path
    let dirs = [
        "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/.bun/bin",
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    var path = (env["PATH"] ?? "").split(separator: ":").map(String.init)
    for d in dirs.reversed() where !path.contains(d) { path.insert(d, at: 0) }
    env["PATH"] = path.joined(separator: ":")
    env["HOME"] = home
    env["PORTHOLE"] = "1"
    if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
    for (k, v) in extra { env[k] = v }
    return env
}
