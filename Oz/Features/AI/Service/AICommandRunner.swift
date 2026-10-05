import Darwin
import Foundation

struct AICommandRunner: Sendable {
    let home: URL
    let environment: [String: String]
    private static let outputLimit = 12_288

    func run(_ command: String, directory: URL, timeout: TimeInterval) throws -> [String: Any] {
        if let reason = AICommandPolicy.refusal(command) { throw Failure(reason) }
        try Task.checkCancellation()
        let started = ContinuousClock.now
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw Failure("Command output could not be connected.") }
        defer { close(descriptors[0]) }
        var writerIsOpen = true
        defer { if writerIsOpen { close(descriptors[1]) } }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) != -1 else {
            throw Failure("Command output could not be configured.")
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw Failure("Command launch could not be prepared.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw Failure("Command launch could not be prepared.") }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(0)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        var mask = sigset_t(0)
        let setup = [
            posix_spawn_file_actions_addchdir(&actions, directory.path),
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, descriptors[0]),
            posix_spawn_file_actions_addclose(&actions, descriptors[1]),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setsigdefault(&attributes, &defaults),
            posix_spawnattr_setsigmask(&attributes, &mask),
            posix_spawnattr_setflags(&attributes,
                                    Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                          | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        ]
        guard setup.allSatisfy({ $0 == 0 }) else { throw Failure("Command launch could not be configured.") }
        let arguments: [UnsafeMutablePointer<CChar>?] = ["/bin/zsh", "-f", "-c", command]
            .map { $0.withCString { strdup($0) } } + [nil]
        let variables: [UnsafeMutablePointer<CChar>?] = childEnvironment
            .map { ($0.key + "=" + $0.value).withCString { strdup($0) } } + [nil]
        defer {
            for argument in arguments { free(argument) }
            for variable in variables { free(variable) }
        }
        var pid: pid_t = 0
        let launched = arguments.withUnsafeBufferPointer { arguments in
            variables.withUnsafeBufferPointer { variables in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes,
                            UnsafeMutablePointer(mutating: arguments.baseAddress!),
                            UnsafeMutablePointer(mutating: variables.baseAddress!))
            }
        }
        guard launched == 0 else { throw Failure("Command launch failed: \(String(cString: strerror(launched))).") }
        close(descriptors[1])
        writerIsOpen = false
        var reaped = false
        defer {
            kill(-pid, SIGKILL)
            if !reaped {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            }
        }
        var output = Data()
        var totalBytes = 0
        var status: Int32 = 0
        var timedOut = false
        var stopping: ContinuousClock.Instant?
        var killed = false
        var outputClosed = false
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            if Task.isCancelled || started.duration(to: .now) >= .seconds(timeout), stopping == nil {
                timedOut = !Task.isCancelled
                stopping = .now
                kill(-pid, SIGTERM)
            }
            if let stopping, !killed, stopping.duration(to: .now) >= .milliseconds(500) {
                kill(-pid, SIGKILL)
                killed = true
            }
            outputClosed = try capture(descriptors[0], buffer: &buffer, output: &output, totalBytes: &totalBytes)
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { reaped = true; break }
            if waited < 0, errno != EINTR { throw Failure("The command's exit status could not be read.") }
            var descriptor = pollfd(fd: outputClosed ? -1 : descriptors[0], events: Int16(POLLIN), revents: 0)
            _ = poll(&descriptor, 1, 50)
        }
        kill(-pid, SIGKILL)
        _ = try capture(descriptors[0], buffer: &buffer, output: &output, totalBytes: &totalBytes)
        try Task.checkCancellation()
        let signal = status & 0x7F
        let exitCode = signal == 0 ? Int((status >> 8) & 0xFF) : 128 + Int(signal)
        let elapsed = started.duration(to: .now).components
        return ["command": String(command.prefix(512)), "working_directory": directory.path, "exit_code": exitCode,
                "output": outputText(output),
                "output_bytes": totalBytes,
                "truncated": totalBytes > Self.outputLimit, "timed_out": timedOut,
                "duration_seconds": Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18]
    }

    private func outputText(_ data: Data) -> String {
        for offset in 0...min(3, data.count) {
            if let text = String(bytes: data.dropFirst(offset), encoding: .utf8) { return text }
        }
        return String(bytes: data, encoding: .isoLatin1) ?? "[Output is not text]"
    }

    private var childEnvironment: [String: String] {
        var values = environment.filter { key, _ in
            ["PATH", "LANG", "USER", "LOGNAME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT"].contains(key)
                || key.hasPrefix("LC_")
        }
        values["HOME"] = home.path
        values["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", values["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]
            .joined(separator: ":")
        values["TERM"] = "dumb"
        values["NO_COLOR"] = "1"
        values["CI"] = "1"
        values["OZ"] = "1"
        return values
    }

    private func capture(
        _ descriptor: Int32, buffer: inout [UInt8], output: inout Data, totalBytes: inout Int
    ) throws -> Bool {
        for _ in 0..<32 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return true }
            if count < 0, [EAGAIN, EWOULDBLOCK].contains(errno) { return false }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure("Command output could not be read.")
            }
            totalBytes += count
            output.append(contentsOf: buffer.prefix(count))
            if output.count > Self.outputLimit { output = Data(output.suffix(Self.outputLimit)) }
        }
        return false
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
