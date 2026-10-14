import Darwin
import Foundation

/// Read-only view of the process table, injected so local-agent discovery is testable with fixtures.
///
/// Every method is a point query that answers `nil`/`false` for a pid that has gone, never throws. No
/// implementation may spawn a subprocess (`ps`, `lsof`): the real one is `proc_*` and `sysctl` only.
public protocol ProcessInspecting: Sendable {
    /// Every pid currently in the process table.
    func allPids() -> [Int32]
    /// Whether `kill(pid, 0)` says the process exists. `EPERM` (exists, not ours) counts as alive, but
    /// such a pid has no readable ``startTime(of:)``, so callers that also need a start time never accept it.
    func isAlive(_ pid: Int32) -> Bool
    /// Process start time in whole seconds since the epoch (`pbi_start_tvsec`), `nil` when unreadable.
    func startTime(of pid: Int32) -> Int64?
    /// Executable name (`pbi_comm`, 16 chars max), `nil` when unreadable.
    func name(of pid: Int32) -> String?
    /// Command line argv, `nil` when unreadable. Only consulted for node-wrapped CLIs.
    func argv(of pid: Int32) -> [String]?
    func parentPid(of pid: Int32) -> Int32?
    func cwd(of pid: Int32) -> String?
    /// Controlling tty device name without `/dev/`, for example `ttys004`.
    func tty(of pid: Int32) -> String?
    /// Path of an open `rollout-*.jsonl` under `/.codex/sessions/`, if the process holds one open.
    func openRolloutPath(of pid: Int32) -> String?
    /// Whether any ancestor's executable name is `herdr`.
    func parentChainHasHerdr(of pid: Int32) -> Bool
    /// Full executable path (`proc_pidpath`), `nil` when unreadable.
    func executablePath(of pid: Int32) -> String?
}

extension ProcessInspecting {
    public func executablePath(of pid: Int32) -> String? { nil }

    /// Default ancestor walk, bounded so a ppid cycle cannot loop.
    public func parentChainHasHerdr(of pid: Int32) -> Bool {
        var current = parentPid(of: pid)
        var hops = 0
        while let p = current, p > 1, hops < 64 {
            if name(of: p) == "herdr" { return true }
            current = parentPid(of: p)
            hops += 1
        }
        return false
    }
}

/// The real process table, via `proc_pidinfo`, `proc_pidfdinfo` and `sysctl`.
///
/// Tty is cached by (pid, start time), so pid reuse cannot serve a stale answer, and pruned to live pids on
/// every ``allPids()``. Cwd is never cached (an agent that `cd`s would keep a stale one), nor is the parent
/// chain (it changes when an ancestor, herdr, exits and the agent is reparented).
public final class DarwinProcessInspector: ProcessInspecting, @unchecked Sendable {
    private struct Key: Hashable {
        let pid: Int32
        let start: Int64
    }

    private let lock = NSLock()
    private var ttys: [Key: String?] = [:]

    public init() {}

    public func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard got > 0 else { return [] }
        let live = pids.prefix(Int(got)).filter { $0 > 0 }
        let livePids = Set(live)
        lock.withLock { ttys = ttys.filter { livePids.contains($0.key.pid) } }
        return live
    }

    public func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    public func startTime(of pid: Int32) -> Int64? {
        bsdInfo(pid).map { Int64($0.pbi_start_tvsec) }
    }

    public func name(of pid: Int32) -> String? {
        guard var info = bsdInfo(pid) else { return nil }
        return withUnsafeBytes(of: &info.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    public func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
    }

    public func parentPid(of pid: Int32) -> Int32? {
        kinfo(pid).map { $0.kp_eproc.e_ppid }
    }

    private func kinfo(_ pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    public func argv(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return Self.parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Parses a `KERN_PROCARGS2` buffer: int32 argc, exec path, NUL padding, then argc NUL-terminated args.
    static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var i = 4
        while i < bytes.count, bytes[i] != 0 { i += 1 }   // exec path
        while i < bytes.count, bytes[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc, i < bytes.count {
            var j = i
            while j < bytes.count, bytes[j] != 0 { j += 1 }
            args.append(String(decoding: bytes[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args
    }

    private func cached<T>(_ store: ReferenceWritableKeyPath<DarwinProcessInspector, [Key: T]>, _ pid: Int32, compute: () -> T) -> T {
        guard let start = startTime(of: pid) else { return compute() }
        let key = Key(pid: pid, start: start)
        if let hit = lock.withLock({ self[keyPath: store][key] }) { return hit }
        let value = compute()
        lock.withLock { self[keyPath: store][key] = value }
        return value
    }

    public func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    public func tty(of pid: Int32) -> String? {
        cached(\.ttys, pid) {
            guard let info = kinfo(pid) else { return nil }
            let dev = info.kp_eproc.e_tdev
            guard dev != -1, let cname = devname(dev, mode_t(S_IFCHR)) else { return nil }
            return String(cString: cname)
        }
    }

    public func openRolloutPath(of pid: Int32) -> String? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return nil }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else { continue }
            let path = withUnsafeBytes(of: &vnode.pvip.vip_path) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            if path.contains("/.codex/sessions/"), path.contains("rollout-") { return path }
        }
        return nil
    }
}
