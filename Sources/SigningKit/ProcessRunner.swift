import Foundation

/// A thin, safe wrapper around `Process` that captures stdout/stderr and exit code.
/// Arguments are passed as an array (never shell-interpolated), avoiding the
/// path-quoting bugs of the legacy shell pipeline.
public struct ProcessRunner {
    public struct Result {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
    }

    public enum ProcessError: Error, LocalizedError {
        case failed(command: String, exitCode: Int32, stderr: String)
        public var errorDescription: String? {
            switch self {
            case .failed(let cmd, let code, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "`\(cmd)` failed (exit \(code))" + (detail.isEmpty ? "" : ": \(detail)")
            }
        }
    }

    public init() {}

    @discardableResult
    public func run(_ launchPath: String, _ arguments: [String], cwd: URL? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        // Read before waiting to avoid deadlock on large output.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Runs a process, invoking `onLine` for each line of combined stdout+stderr as it arrives.
    /// Returns the exit code. Runs synchronously on the calling thread.
    @discardableResult
    public func runStreaming(_ launchPath: String, _ arguments: [String], cwd: URL? = nil,
                             onLine: (String) -> Void) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let handle = pipe.fileHandleForReading
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }          // EOF
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                onLine(String(decoding: line, as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        if !buffer.isEmpty { onLine(String(decoding: buffer, as: UTF8.self)) }

        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs and throws `ProcessError.failed` if the exit code is non-zero.
    @discardableResult
    public func runThrowing(_ launchPath: String, _ arguments: [String], cwd: URL? = nil) throws -> Result {
        let result = try run(launchPath, arguments, cwd: cwd)
        guard result.exitCode == 0 else {
            let cmd = ([launchPath] + arguments).joined(separator: " ")
            throw ProcessError.failed(command: cmd, exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }
}
