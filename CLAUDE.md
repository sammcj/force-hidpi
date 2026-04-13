# Force HiDPI

macOS menu bar app (Swift/SwiftPM) that creates a CGVirtualDisplay and hardware-mirrors a 4K panel from it to bypass the M4/M5 DCP pipe budget limitation.

## Project structure

- `Sources/ForceHiDPI/main.swift` - App entry point, AppDelegate, NSStatusItem menu
- `Sources/ForceHiDPI/DisplayManager.swift` - Display enumeration, virtual display lifecycle, mirror config, PQ gamma, colour profile matching, SkyLight dlopen bridge
- `Sources/CPrivateAPI/` - ObjC bridging module for CGVirtualDisplay private API declarations
- `Makefile` - build/install/uninstall targets
- `com.force-hidpi.plist` - LaunchAgent template (binary path substituted at install time)

## Versioning

Version is defined in `main.swift` as `appVersion`. Uses semantic versioning (major.minor.patch).

When to increment:

- **Patch** (1.0.x): Bug fixes, minor tweaks, no behaviour change
- **Minor** (1.x.0): New features, new menu options, non-breaking changes
- **Major** (x.0.0): Breaking changes, API changes to CGVirtualDisplay usage, major rewrites

You **MUST** update the version string in `main.swift` when you have completed making changes that warrant a version bump!

## Build

```bash
make build        # release
make build-debug  # debug
make install      # install + start (restarts if already running)
```

## Key technical details

- `CGVirtualDisplay` is a semi-public CoreGraphics API (used by DisplayLink). Declared via a Clang module in `Sources/CPrivateAPI/` since there are no public headers
- SkyLight framework functions (BitsPerSample, HDR status, colour space) are resolved at runtime via `dlopen`/`dlsym` with `@convention(c)` typed function pointers
- The virtual display mode uses `transferFunction: 1` (PQ/ST 2084) for 16-bit compositing. A PQ-to-SDR gamma correction table is applied via `CGSetDisplayTransferByTable`
- Mirror config uses `.forSession` (not `.permanently`) so a crash doesn't leave displays stuck
- Duplicate instance prevention uses `flock` on `/tmp/force-hidpi.lock`
- Settings persist via a plist file at `~/Library/Preferences/com.force-hidpi.plist` (UserDefaults suiteName silently fails for non-bundled executables on modern macOS)
- The "Start at Login" toggle generates a LaunchAgent plist pointing to the current binary path (not hardcoded)

## Dangerous APIs / what not to do

Hard-won lessons from SkyLight spelunking. Do not repeat these.

- **Never call `SLSConfigureDisplayIndependentOutput`.** Despite its name suggesting a runtime-only config call, it writes an `IndependentOutput: true` flag into `~/Library/Preferences/ByHost/com.apple.windowserver.displays.<UUID>.plist` that persists across reboots, logouts, and monitor power-cycles. Once set, affected displays refuse to participate in a hardware mirror set — they go black and disappear from device enumeration. There's no documented API to un-set it. Recovery requires editing the WindowServer plist by hand (walk `DisplaySets.Configs[*].DisplayConfig[*]` and delete the `IndependentOutput` key) and logging out. `.forSession` scope does NOT protect you here.

- **Do not reposition multiple displays in the same transaction that establishes a mirror set.** Specifically, calling `CGConfigureDisplayOrigin` on both the main-anchor display AND the mirror source inside one `CGBeginDisplayConfiguration`/`CGCompleteDisplayConfiguration` transaction has caused the entire mirror set to silently drop off the online display list on macOS 26.4, even when the individual origin values are valid. If you need to change origins, do it in a separate transaction AFTER the mirror is established.

- **NotificationCenter.app checks `CGDisplayIsInMirrorSet(CGMainDisplayID())` directly** to decide whether to suppress notification banners when mirroring is active. The check lives in NotificationCenter.app itself, not in DoNotDisturb/Focus frameworks. The `turnOnDNDWhenMirroring` preference gates the behaviour, and users can disable it manually via Focus → Do Not Disturb → Options → "When mirroring or sharing the display". There is no clean programmatic workaround: the SkyLight mirror-detection query functions read state the system sets atomically when the mirror transaction completes, and attempts to spoof or override that state (via `SLSConfigureDisplayIndependentOutput`, `SLSSetMagicMirrorProperties`, etc.) are either dead ends or actively destructive.

- **The `SLS*` mirror-manipulation family is untrusted territory.** `SLSSetMagicMirrorProperties`, `SLSSetPresentationDisplay`, and similar look attractive but have unknown/undocumented side-effects and may write to persistent storage. Before calling ANY of them, disassemble the function prologue (see the `ctx_execute` workflow in session history) and verify it's read-only or session-scoped.

## General guidelines

- Avoid over-complicating and over-engineering the codebase, there is elegance in simplicity
- Always use the makefile as the entrypoint to commands (lint, built, install, start, stop etc)

## Background

This project exists as a workaround for the issue described in this blog post: https://smcleod.net/2026/03/new-apple-silicon-m4-m5-hidpi-limitation-on-4k-external-displays/
