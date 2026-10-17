import AppKit
import Darwin
import Foundation

let bundleIDs = Set(CommandLine.arguments.dropFirst())
guard !bundleIDs.isEmpty else {
    fputs("Pass one or more app bundle IDs to stop.\n", stderr)
    exit(EXIT_FAILURE)
}

func matchingApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { app in
        guard let bundleID = app.bundleIdentifier else { return false }
        return bundleIDs.contains(bundleID)
    }
}

let running = matchingApps()
for app in running where !app.terminate() {
    fputs("Could not ask \(app.localizedName ?? app.bundleIdentifier ?? "app") to quit.\n", stderr)
    exit(EXIT_FAILURE)
}

let deadline = Date().addingTimeInterval(8)
while Date() < deadline {
    let remaining = matchingApps()
    if remaining.isEmpty { exit(EXIT_SUCCESS) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}

let names = matchingApps().map { $0.localizedName ?? $0.bundleIdentifier ?? "app" }.joined(separator: ", ")
fputs("Still running: \(names). Refusing to launch a second HID client.\n", stderr)
exit(EXIT_FAILURE)
