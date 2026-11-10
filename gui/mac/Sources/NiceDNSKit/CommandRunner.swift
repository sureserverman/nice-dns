// Run a command without blocking the caller, delivering its output line by
// line. AppKit-free, so it tests headless.
import Foundation

/// How the command ended.
public enum CommandExit: Equatable, CustomStringConvertible {
    case code(Int32)
    case signal(Int32)

    public var description: String {
        switch self {
        case .code(let c): return "exit \(c)"
        case .signal(let s): return "killed by signal \(s)"
        }
    }
}

/// What the handler receives: lines in order within each stream, then
/// exactly one `exit` (or `failed`), last.
public enum CommandEvent: Equatable {
    public enum Source: Equatable { case stdout, stderr }
    case line(Source, String)
    case exit(CommandExit)
    case failed(String)
}

/// A command that could not be started.
public struct CommandStartError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

/// A started command.
public final class RunningCommand {
    private let process: Process
    init(_ process: Process) { self.process = process }
    public var pid: Int32 { process.processIdentifier }
    /// Send SIGTERM; the `exit` event still follows.
    public func terminate() { if process.isRunning { process.terminate() } }
}

public enum CommandRunner {
    /// How long the output readers get after the child exits: a process it
    /// left behind that still holds a pipe would otherwise hold back the exit
    /// for ever.
    static let drain: DispatchTimeInterval = .seconds(1)

    /// Start `argv[0]` with `argv[1...]`, stdin closed, and return at once.
    /// A bare program name is looked up on `PATH` (of `environment` when
    /// given, which then replaces the inherited environment). Events are
    /// delivered in order on `queue` (a private serial queue by default).
    /// A program that cannot be started throws; it never crashes.
    @discardableResult
    public static func spawn(
        _ argv: [String],
        environment: [String: String]? = nil,
        queue: DispatchQueue? = nil,
        onEvent: @escaping (CommandEvent) -> Void
    ) throws -> RunningCommand {
        guard let program = argv.first, !program.isEmpty else {
            throw CommandStartError(message: "empty command")
        }
        let env = environment ?? ProcessInfo.processInfo.environment
        let path = try locate(program, path: env["PATH"] ?? "/usr/bin:/bin")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = Array(argv.dropFirst())
        if let environment { p.environment = environment }
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let deliver = queue ?? DispatchQueue(label: "nice-dns.command-runner")
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do {
            try p.run()
        } catch {
            throw CommandStartError(message: "\(program): \(error.localizedDescription)")
        }
        // The child holds its own ends; ours must close for the readers to
        // see end of file.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()

        let readers = DispatchGroup()
        pump(out.fileHandleForReading, .stdout, readers, deliver, onEvent)
        pump(err.fileHandleForReading, .stderr, readers, deliver, onEvent)

        DispatchQueue.global().async {
            exited.wait()
            _ = readers.wait(timeout: .now() + drain)
            let ev: CommandEvent
            switch p.terminationReason {
            case .exit: ev = .exit(.code(p.terminationStatus))
            case .uncaughtSignal: ev = .exit(.signal(p.terminationStatus))
            @unknown default: ev = .failed("no exit code and no signal")
            }
            deliver.async { onEvent(ev) }
        }
        return RunningCommand(p)
    }

    /// The whole run of one command, for callers that wait for it.
    public struct Collected {
        public var events: [CommandEvent] = []
        public var stdout: [String] = []
        public var stderr: [String] = []
        /// `nil` when waiting on the child failed (`events` says why).
        public var exit: CommandExit?
    }

    /// Run `argv` to its end and return what it printed and how it ended.
    public static func collect(_ argv: [String], environment: [String: String]? = nil) throws -> Collected {
        var r = Collected()
        let done = DispatchSemaphore(value: 0)
        try spawn(argv, environment: environment) { ev in
            r.events.append(ev)
            switch ev {
            case .line(.stdout, let l): r.stdout.append(l)
            case .line(.stderr, let l): r.stderr.append(l)
            case .exit(let e): r.exit = e; done.signal()
            case .failed: done.signal()
            }
        }
        done.wait()
        return r
    }

    /// The executable `program` names: itself when it has a slash, else the
    /// first executable file of that name on `path`.
    static func locate(_ program: String, path: String) throws -> String {
        if program.contains("/") { return program }
        for dir in path.split(separator: ":") where !dir.isEmpty {
            let candidate = String(dir) + "/" + program
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw CommandStartError(message: "\(program): not found on PATH")
    }

    /// Read `handle` to its end on a background thread, delivering each line
    /// (its `\n` dropped, invalid UTF-8 replaced) and a last unterminated one.
    private static func pump(
        _ handle: FileHandle,
        _ source: CommandEvent.Source,
        _ group: DispatchGroup,
        _ deliver: DispatchQueue,
        _ onEvent: @escaping (CommandEvent) -> Void
    ) {
        group.enter()
        let fd = handle.fileDescriptor
        Thread.detachNewThread {
            var pending: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 4096)
            func send(_ bytes: ArraySlice<UInt8>) {
                let line = String(decoding: bytes, as: UTF8.self)
                deliver.async { onEvent(.line(source, line)) }
            }
            while true {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                pending.append(contentsOf: buf[0..<n])
                while let nl = pending.firstIndex(of: 0x0A) {
                    send(pending[..<nl])
                    pending.removeSubrange(...nl)
                }
            }
            if !pending.isEmpty { send(pending[...]) }
            try? handle.close()
            group.leave()
        }
    }
}
