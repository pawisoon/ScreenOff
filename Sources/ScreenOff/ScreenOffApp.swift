import ScreenOffCore
import ServiceManagement
import SwiftUI

struct ScreenOffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DisplayModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: model.anyOff ? "display.trianglebadge.exclamationmark" : "display")
        }
        // Window style so the panel can host volume sliders.
        .menuBarExtraStyle(.window)
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
    @Published private(set) var volumes: [CGDirectDisplayID: DDC.Volume] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var observer: NSObjectProtocol?
    /// Displays already probed for DDC volume since the last display change (supported or not).
    private var probed: Set<CGDirectDisplayID> = []
    /// Volume to restore when unmuting.
    private var volumeBeforeMute: [CGDirectDisplayID: Int] = [:]

    init() {
        refresh()
        // Fires for our own changes, the CLI's, and plugging/unplugging monitors.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
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

    private func displaysChanged() {
        refresh()
        DDC.shared.invalidate()
        probed.removeAll()
        volumes = volumes.filter { id, _ in displays.contains { $0.id == id && $0.isEnabled } }
        loadVolumes()
    }

    /// Probe new displays for DDC volume and re-read known ones (the monitor's own buttons may have changed it).
    func loadVolumes() {
        for d in activeExternals where !probed.contains(d.id) || volumes[d.id] != nil {
            probed.insert(d.id)
            Task {
                let vol = await DDC.shared.volume(for: d.id)
                // Ignore late replies for displays that were turned off meanwhile.
                guard displays.contains(where: { $0.id == d.id && $0.isEnabled }) else { return }
                volumes[d.id] = vol
            }
        }
    }

    func setVolume(_ value: Int, for display: Display) {
        guard let vol = volumes[display.id], value != vol.current else { return }
        volumes[display.id] = DDC.Volume(current: value, max: vol.max)
        if value > 0 { volumeBeforeMute[display.id] = nil }
        DDC.shared.setVolume(value, for: display.id)
    }

    func toggleMute(_ display: Display) {
        guard let vol = volumes[display.id] else { return }
        if vol.current > 0 {
            volumeBeforeMute[display.id] = vol.current
            setVolume(0, for: display)
        } else {
            setVolume(volumeBeforeMute[display.id] ?? vol.max / 4, for: display)
        }
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

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var model: DisplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 4)
            }

            Text("Displays")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)

            ForEach(model.displays) { display in
                DisplayRow(display: display, model: model)
            }

            Divider().padding(.vertical, 6)

            ActionRow(title: "Turn Off External Displays", systemImage: "display.2",
                      disabled: model.activeExternals.isEmpty || !model.hasActiveBuiltin) {
                model.turnOffExternals()
            }
            // Always enabled: it also rescues displays that are off but no longer tracked.
            ActionRow(title: "Turn All Displays On", systemImage: "power") { model.turnAllOn() }
            ActionRow(title: "Sleep All Displays", systemImage: "moon.zzz") { model.sleepAll() }

            Divider().padding(.vertical, 6)

            HStack {
                Image(systemName: "arrow.right.circle")
                    .frame(width: 20)
                Text("Launch at Login")
                Spacer()
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            ActionRow(title: "Quit ScreenOff", systemImage: "xmark.circle", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(10)
        .frame(width: 300)
        .onAppear { model.loadVolumes() }
    }
}

struct DisplayRow: View {
    let display: Display
    @ObservedObject var model: DisplayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(display.isEnabled ? .white : .secondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(display.isEnabled ? Color.accentColor : Color.secondary.opacity(0.2)))

                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Toggle(display.name, isOn: Binding(
                    get: { display.isEnabled },
                    set: { model.set(display, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                // Keep at least one screen alive.
                .disabled(display.isEnabled && model.activeCount <= 1)
            }

            if display.isEnabled, let vol = model.volumes[display.id] {
                HStack(spacing: 8) {
                    Button { model.toggleMute(display) } label: {
                        Image(systemName: speakerSymbol(vol))
                            .frame(width: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(vol.current == 0 ? "Unmute" : "Mute")

                    Slider(value: Binding(
                        get: { Double(vol.current) },
                        set: { model.setVolume(Int($0.rounded()), for: display) }
                    ), in: 0...Double(vol.max))
                    .controlSize(.small)

                    Text("\(vol.current)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 24, alignment: .trailing)
                }
                .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var subtitle: String {
        guard display.isEnabled else { return "Off" }
        var parts = [display.isBuiltin ? "Built-in" : "External"]
        if display.isMain { parts.append("Main") }
        return parts.joined(separator: " · ")
    }

    private func speakerSymbol(_ vol: DDC.Volume) -> String {
        let level = Double(vol.current) / Double(max(vol.max, 1))
        switch level {
        case 0: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

struct ActionRow: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .frame(width: 20)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering && !disabled ? Color.primary.opacity(0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
    }
}
