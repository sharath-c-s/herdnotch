import Foundation

/// Reassembles newline-delimited JSON messages from arbitrarily chopped byte chunks.
///
/// herdr's socket protocol is one JSON document per `\n`-terminated line, but a `recv()` boundary
/// has nothing to do with a line boundary: one read can return two whole responses, or half of one.
/// This type owns that bookkeeping and nothing else. It performs no I/O, which is precisely why it is
/// a separate value type: the awkward cases (coalesced reads, split lines, keep-alive blank lines)
/// are unit-testable without a socket.
///
/// Thread-safety: a mutable value type with no shared state. Each reader owns its own framer.
public struct NDJSONFramer: Sendable {
    /// Default ceiling on a single unterminated line, in bytes.
    ///
    /// The largest response observed from a real herdr server is roughly 1.5 KB, so 1 MB is about
    /// three orders of magnitude of headroom: large enough that no legitimate payload can trip it,
    /// small enough that a peer which connects and then never sends a newline cannot make the app
    /// allocate without limit for the whole timeout window.
    public static let defaultMaximumLineBytes = 1 << 20

    /// Ceiling on a single unterminated line, in bytes.
    private let maximumLineBytes: Int

    /// Bytes received but not yet terminated by a newline.
    private var buffer = Data()

    /// Creates an empty framer.
    ///
    /// - Parameter maximumLineBytes: Largest single line to accept before treating the peer as
    ///   broken. Defaults to ``defaultMaximumLineBytes``.
    public init(maximumLineBytes: Int = NDJSONFramer.defaultMaximumLineBytes) {
        self.maximumLineBytes = maximumLineBytes
    }

    /// Number of buffered bytes belonging to an as-yet incomplete line.
    ///
    /// Useful to distinguish "peer sent nothing" from "peer sent a truncated line then closed".
    public var pendingByteCount: Int { buffer.count }

    /// Appends a chunk of received bytes and returns every complete line it completed.
    ///
    /// Empty lines are dropped rather than returned: a bare `\n` carries no JSON document, and
    /// handing one to a decoder would turn a harmless keep-alive into a spurious protocol error.
    /// Trailing bytes with no newline stay buffered for the next call.
    ///
    /// - Parameter chunk: Bytes just read from the socket. May be empty, may contain any number of
    ///   newlines at any offset.
    /// - Returns: Complete lines in arrival order, newline stripped. Empty when the chunk only
    ///   extended an incomplete line.
    /// - Throws: ``HerdrError/protocolError(_:)`` when the unterminated remainder exceeds
    ///   ``maximumLineBytes``.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        // Checked after extraction, on the unterminated remainder only. Checking the whole buffer
        // would reject a legitimate burst of many small responses coalesced into one read, which is
        // exactly the case this framer exists to handle.
        guard buffer.count <= maximumLineBytes else {
            let overflow = buffer.count
            buffer = Data()
            throw HerdrError.protocolError(
                "line exceeded \(maximumLineBytes) bytes without a newline (\(overflow) buffered)"
            )
        }
        return lines
    }
}
