import AppKit

// NSRunningApplication avoids Apple Events / Automation permission and targets
// only the executable at the installation path, not other development copies.
let args = CommandLine.arguments
guard args.count == 3, ["quit", "require-stopped"].contains(args[1]) else { exit(2) }
let executable = URL(fileURLWithPath: args[2])
    .appendingPathComponent("Contents/MacOS/TouchBridge Dev").standardizedFileURL
let apps = NSWorkspace.shared.runningApplications.filter {
    $0.executableURL?.standardizedFileURL == executable
}
if args[1] == "require-stopped" {
    if !apps.isEmpty {
        fputs("Quit TouchBridge Dev first, or use --install --restart. Installed app is untouched.\n", stderr)
        exit(1)
    }
} else {
    for app in apps {
        guard app.terminate() else {
            fputs("TouchBridge declined to quit; installed app is untouched.\n", stderr)
            exit(1)
        }
    }
    let deadline = Date().addingTimeInterval(10)
    while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard apps.allSatisfy({ $0.isTerminated }) else {
        fputs("TouchBridge did not exit within 10 seconds; installed app is untouched.\n", stderr)
        exit(1)
    }
}
