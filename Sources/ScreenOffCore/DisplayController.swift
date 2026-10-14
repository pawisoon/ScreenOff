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
        // CoreGraphics is the source of truth: NSScreen.screens is only refreshed when the run loop
        // handles the screen-change notification, so right after a toggle it can list a display
        // that is already off (or miss one that is back on). Use it for names only.
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[n.uint32Value] = screen.localizedName
            }
        }
        var store = DisabledStore.load()
        let mainID = CGMainDisplayID()
        let active: [Display] = activeIDs().map { id in
            let name = names[id] ?? store.first { $0.id == id }?.name ?? "Display \(id)"
            return Display(id: id, name: name, isBuiltin: CGDisplayIsBuiltin(id) != 0,
                           isMain: id == mainID, isEnabled: true)
        }
        .sorted { ($0.isMain ? 0 : 1, $0.id) < ($1.isMain ? 0 : 1, $1.id) }

        // A display that came back on its own (replugged, reboot) no longer counts as off.
        let activeSet = Set(active.map(\.id))
        let before = store.count
        store.removeAll { activeSet.contains($0.id) }
        if store.count != before { DisabledStore.save(store) }

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
        try configure(id: display.id, name: display.name, enabled: enabled)

        var store = DisabledStore.load()
        store.removeAll { $0.id == display.id }
        if !enabled {
            store.append(.init(id: display.id, name: display.name, isBuiltin: display.isBuiltin))
        }
        DisabledStore.save(store)
    }

    /// Turns every display ScreenOff disabled back on. Returns the ones that failed.
    ///
    /// Disabled displays vanish from every public CoreGraphics list, so if the record of what we
    /// turned off is lost, nothing could find them again. As a rescue, also try to enable every
    /// low display ID that isn't online (Apple Silicon numbers displays 1, 2, 3...).
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
        let online = Set(onlineIDs())
        for id in CGDirectDisplayID(1)...32 where !online.contains(id) {
            try? configure(id: id, name: "Display \(id)", enabled: true)
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

    private static func configure(id: CGDirectDisplayID, name: String, enabled: Bool) throws {
        guard let configureDisplayEnabled else { throw ScreenOffError.apiUnavailable }
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success else { throw ScreenOffError.configurationFailed(name, err.rawValue) }
        err = configureDisplayEnabled(config, id, enabled)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw ScreenOffError.configurationFailed(name, err.rawValue)
        }
        err = CGCompleteDisplayConfiguration(config, .permanently)
        guard err == .success else { throw ScreenOffError.configurationFailed(name, err.rawValue) }
    }

    private static func activeIDs() -> [CGDirectDisplayID] {
        displayList(CGGetActiveDisplayList)
    }

    private static func onlineIDs() -> [CGDirectDisplayID] {
        displayList(CGGetOnlineDisplayList)
    }

    private static func displayList(
        _ get: (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError
    ) -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard get(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
