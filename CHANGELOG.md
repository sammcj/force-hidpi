# Changelog

<!-- AI agents: add entries under the ## [Unreleased] header. Do NOT add version numbers or dates. Do NOT duplicate headings. The ## Known Bugs section must always stay pinned above ## [Unreleased]. Group entries under ### Added, ### Changed, ### Fixed, or ### Removed. Log only changes a reader would care about - new capability, changed or breaking behaviour, removals, real fixes. Skip cosmetic and housekeeping edits (wording, formatting, typos, refactors with no behaviour change, test-only churn); git history covers those. Combine or update items refined within the same session. Keep each entry to one terse line saying what changed - aim under 15 words. Write more only when the change is genuinely complex and the reasoning cannot be recovered from the code or git history. If the file exceeds 2000 lines, truncate the oldest releases. -->

## Known Bugs

## [Unreleased]

## [1.6.1] - 2026-10-16

### Added

- Steam Remote Play streaming pauses HiDPI by default, including for existing users

## [1.6.0] - 2026-10-16

### Added

- "Pause For Apps" menu: HiDPI turns off while listed apps run, resumes after
- Pauses for apps declaring a games category by default; Steam Link on, Steam listed but off
- `--pause-while <command>` wrapper pauses HiDPI before launch; menu copies a Steam launch option

### Fixed

- Display changes while the menu is open no longer risk an AppKit crash

## [1.5.0] - 2026-09-17

### Added

- Optional "Performance Logging" menu toggle sampling WindowServer, GPU and power to JSONL

## [1.4.3]
