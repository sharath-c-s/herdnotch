import Foundation

/// Runs `/usr/bin/perl mediaremote-adapter.pl <framework> stream --micros` (ungive/mediaremote-adapter,
/// vendored under `Vendor/`) as a long-lived child and restarts it with a bounded backoff.
///
/// Why perl: `/usr/bin/perl` is Apple-signed (`com.apple.perl5`), so MediaRemote answers it where it answers
/// nothing to this ad-hoc-signed app, and unlike the `xcrun swift` helper it needs no Xcode CLT.
///
/// Restart policy: the first two restarts wait 1 s then 2 s, later ones 30 s; the counter resets once a run
/// stayed alive for ``healthyRunSeconds``.
@MainActor
final class NowPlayingAdapterProcess {
    struct Paths {
        let script: String
        let framework: String
    }

    /// Longest single stdout line accepted. Artwork is base64 inside one JSON line, so this has to clear a
    /// few MB; anything longer is dropped rather than buffered without bound.
    nonisolated static let maxLineBytes = 16 * 1024 * 1024
    private static let healthyRunSeconds: TimeInterval = 60
    private static let perlPath = "/usr/bin/perl"

    /// One complete stdout line (no trailing newline), delivered on the main actor.
    var onLine: ((Data) -> Void)?
    /// The child exited (or never launched). `producedOutput` is whether this run emitted any line.
    var onExit: ((_ producedOutput: Bool) -> Void)?

    private let paths: Paths
    private var process: Process?
    private var restartTimer: DispatchSourceTimer?
    private var restartCount = 0
    private var startedAt = Date()
    private var producedOutput = false
    private var stopped = true

    init(paths: Paths) {
        self.paths = paths
    }

    /// The bundled script and framework, or `nil` when perl, the script or the framework is missing (for
    /// example under `swift run`, which has no app bundle).
    static func resolvePaths() -> Paths? {
        guard FileManager.default.isExecutableFile(atPath: perlPath),
            let resources = Bundle.main.resourceURL,
            let frameworks = Bundle.main.privateFrameworksURL
        else { return nil }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl").path
        let framework = frameworks.appendingPathComponent("MediaRemoteAdapter.framework")
        let binary = framework.appendingPathComponent("MediaRemoteAdapter").path
        let fm = FileManager.default
        guard fm.fileExists(atPath: script), fm.fileExists(atPath: binary) else { return nil }
        return Paths(script: script, framework: framework.path)
    }

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        restartTimer?.cancel()
        restartTimer = nil
        process?.terminationHandler = nil
        // Reading `standardOutput` is fine after launch; assigning it raises "task already launched".
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
    }

    /// Fire-and-forget adapter command (`seek <micros>`, `send <id>`); output and failures are ignored.
    func runOneShot(_ arguments: [String]) {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: Self.perlPath)
        child.arguments = [paths.script, paths.framework] + arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try? child.run()
    }

    private func launch() {
        guard !stopped else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: Self.perlPath)
        child.arguments = [paths.script, paths.framework, "stream", "--micros"]
        let stdout = Pipe()
        child.standardOutput = stdout
        child.standardInput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self, weak child] _ in
            Task { @MainActor in
                guard let self, let child, self.process === child else { return }
                self.handleExit()
            }
        }

        let buffer = LineBuffer(maxLineBytes: Self.maxLineBytes)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = buffer.appendingAndSplittingLines(chunk)
            guard !lines.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.producedOutput = true
                for line in lines { self.onLine?(line) }
            }
        }

        startedAt = Date()
        producedOutput = false
        process = child
        do {
            try child.run()
        } catch {
            process = nil
            handleExit()
        }
    }

    private func handleExit() {
        process = nil
        let produced = producedOutput
        if Date().timeIntervalSince(startedAt) >= Self.healthyRunSeconds { restartCount = 0 }
        let delay: TimeInterval = restartCount == 0 ? 1 : (restartCount == 1 ? 2 : 30)
        restartCount += 1
        onExit?(produced)
        guard !stopped else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
        restartTimer?.cancel()
        restartTimer = timer
        timer.resume()
    }
}
