import ScreenOffCore
import ServiceManagement
import SwiftUI

struct ScreenOffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DisplayModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.anyOff ? "display.trianglebadge.exclamationmark" : "display")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Never leave a monitor dark with no menu bar item to bring it back.
        MainActor.assumeIsolated { _ = DisplayController.enableAll() }
    }
}

@MainActor
final class DisplayModel: ObservableObject {
    @Published private(set) var displays: [Display] = []
    @Published private(set) var lastError: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var observer: NSObjectProtocol?

    init() {
        refresh()
        // Fires for our own changes, the CLI's, and plugging/unplugging monitors.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var anyOff: Bool { displays.contains { !$0.isEnabled } }
    var activeCount: Int { displays.filter(\.isEnabled).count }
    var hasActiveBuiltin: Bool { displays.contains { $0.isBuiltin && $0.isEnabled } }
    var activeExternals: [Display] { displays.filter { !$0.isBuiltin && $0.isEnabled } }

    func refresh() {
        displays = DisplayController.displays()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func set(_ display: Display, enabled: Bool) {
        perform { try DisplayController.setEnabled(display, enabled) }
    }

    func turnOffExternals() {
        perform {
            for d in activeExternals { try DisplayController.setEnabled(d, false) }
        }
    }

    func turnAllOn() {
        perform {
            if let (d, error) = DisplayController.enableAll().first {
                throw CLIError("\(d.name): \(error.localizedDescription)")
            }
        }
    }

    func sleepAll() {
        DisplayController.sleepAll()
    }

    func setLaunchAtLogin(_ on: Bool) {
        perform {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}

struct MenuContent: View {
    @ObservedObject var model: DisplayModel

    var body: some View {
        if let error = model.lastError {
            Text("⚠︎ \(error)")
            Divider()
        }

        Section("Displays") {
            ForEach(model.displays) { display in
                Toggle(label(for: display), isOn: Binding(
                    get: { display.isEnabled },
                    set: { model.set(display, enabled: $0) }
                ))
                // Keep at least one screen alive.
                .disabled(display.isEnabled && model.activeCount <= 1)
            }
        }

        Divider()

        Button("Turn Off External Displays") { model.turnOffExternals() }
            .disabled(model.activeExternals.isEmpty || !model.hasActiveBuiltin)
        // Always enabled: it also rescues displays that are off but no longer tracked.
        Button("Turn All Displays On") { model.turnAllOn() }
        Button("Sleep All Displays") { model.sleepAll() }

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))
        Button("Quit ScreenOff") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func label(for d: Display) -> String {
        var tags: [String] = []
        if d.isMain { tags.append("main") }
        if d.isBuiltin { tags.append("built-in") }
        return tags.isEmpty ? d.name : "\(d.name)  (\(tags.joined(separator: ", ")))"
    }
}
