import Foundation

/// Runs CLI tools with streamed stdout/stderr and cooperative cancellation.
final class ProcessRunner: @unchecked Sendable {
    struct RunError: LocalizedError {
        let command: String
        let exitCode: Int32
        let combinedOutput: String

        var errorDescription: String? {
            "Command failed (\(exitCode)): \(command)\n\(combinedOutput)"
        }
    }

    private let processQueue = DispatchQueue(label: "BDXLBackupApp.ProcessRunner")
    private var currentProcess: Process?

    /// Grace period after SIGTERM before a cancelled child is force-killed.
    static let killGraceSeconds: Double = 20

    nonisolated init() {}

    /// SIGTERM the running child; SIGKILL only if it is still alive after `killGraceSeconds`.
    func cancel() {
        let process: Process? = processQueue.sync {
            let p = currentProcess
            currentProcess = nil
            return p
        }
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGraceSeconds) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    /// Runs process; invokes `onLine` on the main actor for each output line (split on "\n" and "\r",
    /// so progress counters like "Processing: 42%\r" arrive as separate lines).
    @MainActor
    func runStreaming(
        launchPath: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onLine: @escaping @MainActor (String) -> Void
    ) async throws -> Int32 {
        var continuation: AsyncStream<[String]>.Continuation!
        let batches = AsyncStream<[String]>(bufferingPolicy: .unbounded) { continuation = $0 }
        let sink = continuation!

        let outSplitter = LineSplitter()
        let errSplitter = LineSplitter()
        async let status = execute(
            launchPath: launchPath,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            onStdout: { sink.yield(outSplitter.feed($0)) },
            onStderr: { sink.yield(errSplitter.feed($0)) },
            onFinish: {
                sink.yield(outSplitter.flush() + errSplitter.flush())
                sink.finish()
            }
        )
        for await batch in batches {
            batch.forEach(onLine)
        }
        return try await status
    }

    /// Non-streaming run (stdout + stderr combined, raw text).
    func runCollecting(
        launchPath: String,
        arguments: [String],
        currentDirectory: URL? = nil
    ) async throws -> (exitCode: Int32, output: String) {
        let collected = DataBox()
        let code = try await execute(
            launchPath: launchPath,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: nil,
            onStdout: { collected.append($0) },
            onStderr: { collected.append($0) },
            onFinish: {}
        )
        return (code, String(decoding: collected.data, as: UTF8.self))
    }

    /// Launches the process and drains both pipes from GCD `readabilityHandler`s.
    ///
    /// The pipes are always read as fast as the child writes, independent of the Swift concurrency
    /// pool and of the consumer: a child (e.g. par2, which prints one line per source file) can never
    /// block on a full 64 KiB pipe buffer. Blocking reads on the cooperative pool caused exactly that
    /// deadlock before (par2 stuck in write() while its other threads spin at 100% CPU).
    private func execute(
        launchPath: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment {
                env[k] = v
            }
            process.environment = env
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let drained = DispatchGroup()
        for (pipe, handler) in [(outPipe, onStdout), (errPipe, onStderr)] {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    drained.leave()
                } else {
                    handler(data)
                }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    // Wait for EOF on both pipes so no trailing output is lost; bounded in case a
                    // grandchild keeps a pipe open.
                    DispatchQueue.global().async {
                        _ = drained.wait(timeout: .now() + 10)
                        self.unregister(finished)
                        onFinish()
                        cont.resume(returning: finished.terminationStatus)
                    }
                }
                processQueue.sync { currentProcess = process }
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    unregister(process)
                    onFinish()
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func unregister(_ process: Process) {
        processQueue.sync {
            if currentProcess === process {
                currentProcess = nil
            }
        }
    }
}

/// Splits a byte stream into lines on "\n", "\r" or "\r\n"; thread-safe.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func feed(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        var start = pending.startIndex
        var i = start
        while i < pending.endIndex {
            let byte = pending[i]
            if byte == 0x0A || byte == 0x0D {
                lines.append(String(decoding: pending[start..<i], as: UTF8.self))
                if byte == 0x0D, pending.index(after: i) < pending.endIndex, pending[pending.index(after: i)] == 0x0A {
                    i = pending.index(after: i)
                }
                start = pending.index(after: i)
            }
            i = pending.index(after: i)
        }
        pending = Data(pending[start...])
        return lines.filter { !$0.isEmpty }
    }

    func flush() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let rest = String(decoding: pending, as: UTF8.self)
        pending = Data()
        return rest.isEmpty ? [] : [rest]
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

enum ToolResolver {
    /// PATH used when resolving `which`.
    static var enrichedPATH: String {
        let homebrew = "/opt/homebrew/bin:/usr/local/bin"
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return "\(homebrew):\(existing)"
    }

    static func par2Executable() async -> String? {
        let candidates = [
            "/opt/homebrew/bin/par2",
            "/usr/local/bin/par2"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        do {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = enrichedPATH
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["bash", "-lc", "which par2"]
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let trimmed = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0,
               !trimmed.isEmpty,
               FileManager.default.isExecutableFile(atPath: trimmed) {
                return trimmed
            }
        } catch {
            return nil
        }
        return nil
    }

    static func shasumExecutable() -> String {
        "/usr/bin/shasum"
    }

    static func tarExecutable() -> String {
        "/usr/bin/tar"
    }

    static func hdiutilExecutable() -> String {
        resolveExecutable(
            named: "hdiutil",
            preferred: ["/usr/bin/hdiutil", "/usr/sbin/hdiutil"],
            defaultPath: "/usr/bin/hdiutil"
        )
    }

    static func drutilExecutable() -> String {
        "/usr/bin/drutil"
    }

    static func diskutilExecutable() -> String {
        resolveExecutable(
            named: "diskutil",
            preferred: ["/usr/sbin/diskutil", "/sbin/diskutil"],
            defaultPath: "/usr/sbin/diskutil"
        )
    }

    static func duExecutable() -> String {
        "/usr/bin/du"
    }

    private static func resolveExecutable(
        named name: String,
        preferred: [String],
        defaultPath: String
    ) -> String {
        if let direct = firstExecutable(from: preferred) {
            return direct
        }
        if let fromPATH = executableInPATH(named: name) {
            return fromPATH
        }
        return defaultPath
    }

    private static func firstExecutable(from paths: [String]) -> String? {
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func executableInPATH(named name: String) -> String? {
        let pathValue = enrichedPATH
        for directory in pathValue.split(separator: ":") {
            let candidate = String(directory) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
