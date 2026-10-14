import AppKit
import Foundation
import HerdKit

/// Finds which terminal or IDE hosts a local agent. Runs at click time only, so the process walk and the
/// `NSRunningApplication` lookups never touch the poll path. Spawns no subprocess.
struct AgentHostDetector {
    let resolver: AgentHostResolver

    init() {
        resolver = AgentHostResolver { pid, appPath in
            let wanted = URL(fileURLWithPath: appPath).resolvingSymlinksInPath().path
            func matches(_ app: NSRunningApplication) -> Bool {
                app.bundleURL?.resolvingSymlinksInPath().path == wanted
            }
            // The process may be a helper inside the bundle, so fall back to scanning by bundle path.
            let app = NSRunningApplication(processIdentifier: pid).flatMap { matches($0) ? $0 : nil }
                ?? NSWorkspace.shared.runningApplications.first(where: matches)
            // Background-only helpers cannot be raised, so let the walk continue to a real ancestor.
            guard let app, app.activationPolicy != .prohibited, let bundleId = app.bundleIdentifier else { return nil }
            return (bundleId, app.processIdentifier)
        }
    }

    func detect(_ agent: HerdAgent) -> AgentHost {
        resolver.resolve(pid: agent.pid, tty: agent.tty, cwd: agent.cwd)
    }
}
