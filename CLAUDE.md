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

## General guidelines

- Avoid over-complicating and over-engineering the codebase, there is elegance in simplicity
- Always use the makefile as the entrypoint to commands (lint, built, install, start, stop etc)

## Background

This project exists as a workaround for the issue described in this blog post: https://smcleod.net/2026/03/new-apple-silicon-m4-m5-hidpi-limitation-on-4k-external-displays/
