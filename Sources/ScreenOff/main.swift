import Foundation

// LaunchServices/Xcode can pass flags like -psn_0_123 or -NSDocumentRevisionsDebugMode; ignore those.
let cliArgs = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") }

if !cliArgs.isEmpty {
    exit(CLI.run(Array(cliArgs)))
} else if isatty(STDIN_FILENO) != 0 {
    // Bare `screenoff` in a terminal: show help rather than hijacking the shell with the menu bar app.
    exit(CLI.run(["help"]))
} else {
    ScreenOffApp.main()
}
