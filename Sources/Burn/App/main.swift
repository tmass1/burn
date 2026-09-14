import AppKit

// `Burn cli …` is the command-line tool: the same binary, reading what the app last wrote, never starting the app.
if CommandLine.arguments.dropFirst().first == "cli" {
    Log.quiet = true
    exit(BurnCLI.run(Array(CommandLine.arguments.dropFirst(2))))
}

// AppKit-driven accessory app: no SwiftUI scenes, so nothing tries to open a main window or fight the panel.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
