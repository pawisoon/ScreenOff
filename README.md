# ScreenOff

Menu bar app + CLI for turning individual displays off on macOS — no backlight, no power cut.

ScreenOff software-disconnects a display: macOS stops sending it a signal, so the monitor drops into its own power-saving mode. This works on any monitor, including ones without DDC power control (Apple Studio Display, built-in panels) and ones that fall off the bus when powered off over DDC (some LG UltraFine models).

While a display is off, macOS treats it as unplugged, so windows move to your other screens and come back when it is turned on again. Mouse movement does not wake it; use the menu or `screenoff on`.

## Install

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

```bash
./scripts/install.sh
```

This builds `ScreenOff.app`, copies it to `/Applications`, links `screenoff` into `/opt/homebrew/bin` (or `/usr/local/bin`), and launches it.

Remove with `./scripts/uninstall.sh`.

## Menu bar

- Toggle each display on/off (the last active display can't be turned off).
- Turn off all external displays / turn everything back on.
- Sleep all displays (same as `pmset displaysleepnow`).
- Launch at login.

Quitting the app turns every display it disabled back on.

## CLI

```
screenoff list                 # show displays and state
screenoff off lg               # name match is case-insensitive, any part
screenoff off lg studio        # several at once
screenoff on                   # everything back on
screenoff toggle 3             # by ID from `list`
screenoff sleep                # sleep all displays
```

The CLI and the menu bar app share state (`~/Library/Application Support/ScreenOff/disabled.json`), so either can turn back on what the other turned off.

## Development

```bash
swift build
swift test
.build/debug/ScreenOff list
./scripts/build-app.sh         # -> build/ScreenOff.app
```

## Release

Builds a universal, Developer ID-signed, notarized DMG and publishes it as a GitHub release tagged from `CFBundleShortVersionString`.

```bash
# one-time: store notarization credentials (app-specific password from appleid.apple.com)
xcrun notarytool store-credentials ScreenOff --apple-id <apple-id> --team-id 297W77MNZY

./scripts/release.sh
```

`SKIP_NOTARIZE=1 PUBLISH=0 ./scripts/release.sh` builds and signs the DMG locally without notarizing or publishing.

Not App Store eligible: there is no public API for disabling a display.

## Notes

Display control uses the private `CGSConfigureDisplayEnabled` (SkyLight), resolved at runtime.
