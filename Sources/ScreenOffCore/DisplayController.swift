import AppKit

/// Turns displays on/off by software-disconnecting them: macOS stops sending a signal,
/// so the monitor drops into its own power-saving mode (backlight off, still powered).
@MainActor
public enum DisplayController {
    private typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    // Private SkyLight API, resolved at runtime so the binary still launches if Apple removes it.
    private static let configureDisplayEnabled: ConfigureEnabledFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(handle, "CGSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(sym, to: ConfigureEnabledFn.self)
    }()

    /// Active displays plus the ones ScreenOff has turned off. Main display first.
    public static func displays() -> [Display] {
        let mainID = CGMainDisplayID()
        let active: [Display] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = number.uint32Value
            return Display(id: id, name: screen.localizedName, isBuiltin: CGDisplayIsBuiltin(id) != 0,
                           isMain: id == mainID, isEnabled: true)
        }
        .sorted { ($0.isMain ? 0 : 1, $0.id) < ($1.isMain ? 0 : 1, $1.id) }

        // A display that came back on its own (replugged, reboot) no longer counts as off.
        let activeIDs = Set(active.map(\.id))
        var store = DisabledStore.load()
        store.removeAll { activeIDs.contains($0.id) }
        DisabledStore.save(store)

        let disabled = store.map {
            Display(id: $0.id, name: $0.name, isBuiltin: $0.isBuiltin, isMain: false, isEnabled: false)
        }
        return active + disabled
    }

    public static func setEnabled(_ display: Display, _ enabled: Bool) throws {
        guard display.isEnabled != enabled else { return }
        if !enabled, displays().filter(\.isEnabled).count <= 1 {
            throw ScreenOffError.lastActiveDisplay
        }
        try configure(display, enabled)

        var store = DisabledStore.load()
        store.removeAll { $0.id == display.id }
        if !enabled {
            store.append(.init(id: display.id, name: display.name, isBuiltin: display.isBuiltin))
        }
        DisabledStore.save(store)
    }

    /// Turns every display ScreenOff disabled back on. Returns the ones that failed.
    @discardableResult
    public static func enableAll() -> [(Display, Error)] {
        var failures: [(Display, Error)] = []
        for d in displays() where !d.isEnabled {
            do {
                try setEnabled(d, true)
            } catch {
                failures.append((d, error))
                // The ID is stale (display unplugged); forget it so it doesn't linger as "off".
                var store = DisabledStore.load()
                store.removeAll { $0.id == d.id }
                DisabledStore.save(store)
            }
        }
        return failures
    }

    /// Sleeps every display, like `pmset displaysleepnow`. Mouse or keyboard wakes them.
    public static func sleepAll() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
        p.waitUntilExit()
    }

    private static func configure(_ display: Display, _ enabled: Bool) throws {
        guard let configureDisplayEnabled else { throw ScreenOffError.apiUnavailable }
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success else { throw ScreenOffError.configurationFailed(display.name, err.rawValue) }
        err = configureDisplayEnabled(config, display.id, enabled)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw ScreenOffError.configurationFailed(display.name, err.rawValue)
        }
        err = CGCompleteDisplayConfiguration(config, .permanently)
        guard err == .success else { throw ScreenOffError.configurationFailed(display.name, err.rawValue) }
    }
}
