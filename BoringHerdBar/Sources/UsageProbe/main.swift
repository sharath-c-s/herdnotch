import Foundation
import UsageKit

// Debug entry: prints each provider's state and windows. Never prints tokens or account ids.
let fetcher = UsageFetcher()
for provider in UsageProvider.allCases {
    let snapshot = await fetcher.fetch(provider)
    let plan = snapshot.plan.map { " plan=\($0)" } ?? ""
    print("\(provider): \(snapshot.state)\(plan)")
    for window in snapshot.windows {
        let reset = window.resetsAt.map { " resets=\(ISO8601DateFormatter().string(from: $0))" } ?? ""
        print("  \(window.label): \(window.usedPercent)%\(reset)")
    }
    if let extra = snapshot.extra { print("  extra: \(extra)") }
}
