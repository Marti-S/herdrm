# Changelog

All notable changes to herdrm are documented in this file. The format is based
on [Keep a Changelog](https://keepachangelog.com); versions follow semver.
Release automation extracts the matching section for GitHub release notes and
the Sparkle update description — a release without a section here fails CI.

## [Unreleased]

## [0.2.0] - 2026-08-19

### Added
- All devices now stay connected in parallel: the sidebar aggregates spaces and
  agents across every machine, with a small OS badge marking where each row
  lives. The bottom-left switcher became a filter (All Devices by default).
- Notifications now watch every connected device, not just the selected one;
  clicking a notification jumps straight to that agent.
- New Agent and New Space gained a device picker; installed-agent sniffing is
  cached per device.
- Per-device connection health with automatic reconnect (1s → 30s backoff).

### Changed
- Search results show device badges and search across all devices.

## [0.1.2] - 2026-08-19

### Added
- New Space now has a directory picker (Browse… locally, `~`-expansion on
  remote devices) and an optional name field.

## [0.1.1] - 2026-08-19

### Fixed
- Crash when opening the device switcher on macOS 26+ betas: replaced the
  NSPopover with an in-window panel (uncaught NSRemoteView exception in
  ViewBridge).

## [0.1.0] - 2026-08-19

### Added
- Initial release: waku-style sidebar with spaces and agents, device switcher
  with SSH remotes, SwiftTerm PTY attach, agent sniffing with bypass-mode
  flags, ⌘K search, Sparkle auto-updates, signed and notarized releases.
