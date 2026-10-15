import Foundation
import ScreenOffCore

@MainActor
enum CLI {
    static let usage = """
        usage: screenoff <command> [display...]

        commands:
          list                  show displays and whether they are on or off
          off <name|id>...      turn displays off (no signal, monitor sleeps)
          on [name|id]...       turn displays back on (no argument = all)
          toggle <name|id>...   flip displays on/off
          sleep                 sleep all displays (mouse/keyboard wakes them)
          volume <name|id> [N|+N|-N]
                                get or set monitor speaker volume over DDC
          help                  show this help

        Names match case-insensitively on any part, e.g. `screenoff off lg`.
        """

    static func run(_ args: [String]) -> Int32 {
        let command = args[0]
        let targets = Array(args.dropFirst())

        do {
            switch command {
            case "list", "ls":
                list()
            case "off":
                try requireTargets(targets)
                try apply(targets, enabled: { _ in false })
            case "on":
                if targets.isEmpty {
                    let failures = DisplayController.enableAll()
                    for (d, error) in failures { printErr("\(d.name): \(error.localizedDescription)") }
                    if failures.isEmpty { print("All displays are on.") }
                    return failures.isEmpty ? 0 : 1
                }
                try apply(targets, enabled: { _ in true })
            case "toggle":
                try requireTargets(targets)
                try apply(targets, enabled: { !$0.isEnabled })
            case "sleep":
                DisplayController.sleepAll()
            case "volume", "vol":
                return try volume(targets)
            case "help", "-h", "--help":
                print(usage)
            default:
                printErr("unknown command '\(command)'\n")
                printErr(usage)
                return 2
            }
        } catch {
            printErr(error.localizedDescription)
            return 1
        }
        return 0
    }

    private static func list() {
        let displays = DisplayController.displays()
        let idWidth = max(2, displays.map { String($0.id).count }.max() ?? 0)
        print("ID".padding(toLength: idWidth, withPad: " ", startingAt: 0) + "  STATE  NAME")
        for d in displays {
            var tags: [String] = []
            if d.isMain { tags.append("main") }
            if d.isBuiltin { tags.append("built-in") }
            let id = String(d.id).padding(toLength: idWidth, withPad: " ", startingAt: 0)
            let state = (d.isEnabled ? "on" : "off").padding(toLength: 5, withPad: " ", startingAt: 0)
            print("\(id)  \(state)  \(d.name)" + (tags.isEmpty ? "" : "  [\(tags.joined(separator: ", "))]"))
        }
    }

    private static func volume(_ args: [String]) throws -> Int32 {
        guard (1...2).contains(args.count) else { throw CLIError("usage: screenoff volume <name|id> [N|+N|-N]") }
        let display = try DisplayController.displays().match(args[0])
        guard display.isEnabled else { throw CLIError("\(display.name) is off.") }
        guard let vol = DDC.shared.volumeAndWait(for: display.id) else {
            throw CLIError("\(display.name) doesn't support DDC volume control.")
        }
        guard args.count == 2 else {
            print("\(display.name): \(vol.current)/\(vol.max)")
            return 0
        }
        let arg = args[1]
        guard let n = Int(arg) else { throw CLIError("volume must be a number, +N or -N") }
        let target = min(max(arg.hasPrefix("+") || arg.hasPrefix("-") ? vol.current + n : n, 0), vol.max)
        guard DDC.shared.setVolumeAndWait(target, for: display.id) else {
            throw CLIError("Could not set volume on \(display.name).")
        }
        print("\(display.name): \(target)/\(vol.max)")
        return 0
    }

    private static func requireTargets(_ targets: [String]) throws {
        if targets.isEmpty { throw CLIError("missing display name or id (see `screenoff list`)") }
    }

    private static func apply(_ targets: [String], enabled: (Display) -> Bool) throws {
        // Resolve everything first so a typo doesn't leave a half-applied change.
        let displays = DisplayController.displays()
        let resolved = try targets.map { try displays.match($0) }
        for d in resolved {
            let want = enabled(d)
            try DisplayController.setEnabled(d, want)
            print("\(d.name) -> \(want ? "on" : "off")")
        }
    }

    private static func printErr(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

struct CLIError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
