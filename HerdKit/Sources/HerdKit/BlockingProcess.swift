import Foundation

/// What a finished subprocess left behind. `succeeded` is false for a non-zero exit, a signal or a timeout kill.
public struct ProcessOutput: Sendable {
    public var status: Int32
    public var succeeded: Bool
    public var stdout: String
    public var stderr: String
}

/// Runs a subprocess from an argv array (never a shell string) and blocks until it exits.
///
/// Both pipes drain concurrently, so output past the 64 KB pipe buffer cannot deadlock the child. Call it
/// off the main thread. A `timeout` (seconds; `nil` = none) terminates the process (SIGKILL after a short grace)
/// and reports it as failed without waiting for a pipe a grandchild may still hold.
public enum BlockingProcess {
    /// Throws only when the executable cannot be launched.
    public static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval? = nil
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        try process.run()
        Thread.detachNewThread {
            process.waitUntilExit()
            exited.signal()
        }
        let outBox = DataBox()
        let errBox = DataBox()
        let drained = DispatchGroup()
        for (handle, box) in [(out.fileHandleForReading, outBox), (err.fileHandleForReading, errBox)] {
            drained.enter()
            Thread.detachNewThread {
                while case let chunk = handle.availableData, !chunk.isEmpty { box.append(chunk) }
                drained.leave()
            }
        }
        var timedOut = false
        if let timeout, exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        } else if timeout == nil {
            exited.wait()
        }
        // A grandchild can keep a pipe open past the kill; take what arrived and leave the readers to finish.
        if timedOut { _ = drained.wait(timeout: .now() + drainGrace) } else { drained.wait() }
        return ProcessOutput(
            status: process.terminationStatus,
            succeeded: !timedOut && process.terminationReason == .exit && process.terminationStatus == 0,
            stdout: String(decoding: outBox.snapshot(), as: UTF8.self),
            stderr: String(decoding: errBox.snapshot(), as: UTF8.self)
        )
    }

    private static let killGrace: TimeInterval = 0.5
    private static let drainGrace: TimeInterval = 0.2
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    func snapshot() -> Data { lock.withLock { data } }
}
