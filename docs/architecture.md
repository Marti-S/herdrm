# Application architecture

HerdrM uses feature-first MVVM inside two application targets. Shared protocol and transport code remains in the existing Swift packages.

## Dependency direction

```text
App composition
  -> feature Views
  -> feature ViewModels
  -> process and session runtime
  -> infrastructure adapters
  -> HerdrKit, HerdrSSH, and HerdrTailcat
```

Views may depend on their feature ViewModels, shared UI, and small immutable model values. ViewModels may call runtime stores or injected service protocols. Infrastructure must not import feature presentation code.

Folders document ownership, but they do not create Swift module boundaries. Only the application targets and Swift packages enforce module visibility.

## macOS ownership

- `App/` is the composition root. `AppDependencies` owns the process-lifetime `FleetStore` through `AppDelegate`.
- `App/Navigation/AppNavigationState.swift` owns selection, sheets, alerts, and other window presentation state.
- `Runtime/Fleet/` owns live device snapshots, connection tasks, refresh coordination, and fleet actions.
- `Runtime/Terminal/` owns terminal identities and split-session runtime values.
- `Features/` contains SwiftUI screens and feature-specific ViewModels. Stateless components do not need ViewModels.
- `Infrastructure/Terminal/` owns Ghostty, AppKit, PTY, and process adapters.
- `Infrastructure/FleetBridge/` owns the Mac bridge server and authenticated connections. Its lifetime is tied to the process, not a window.

The fleet store keeps terminal attaches bounded to six recent panes. Moving presentation code must not change that lifecycle.

## iOS ownership

- `App/` creates the process model and owns scene activation handoff.
- `MobileNavigationState` owns navigation and transient presentation state.
- `Runtime/Fleet/` owns direct-device and Mac-bridge sessions across screen reconstruction.
- `Runtime/Conversation/ConversationReaderCache.swift` owns pane-scoped readers. Each reader still counts concurrent viewers before starting or cancelling work.
- `Runtime/Terminal/` owns Ghostty attach sessions and terminal command construction.
- `Features/Conversation/` separates transcript providers, the reader ViewModel, and rendering.
- `Features/Session/` composes terminal display, conversation display, composer state, and attachment actions.
- `Infrastructure/Transport/` owns the transport protocol and its SSH and Tailcat implementations.
- `Infrastructure/FleetBridge/` owns authenticated bridge clients and device transports.

Transport reconnection, drafts, attachments, cancellation, and main-actor isolation belong to their existing runtime owners rather than SwiftUI view identity.

## Shared packages

`HerdrKit` is grouped by capability: devices, agents, workspaces, files, attachments, transcripts, terminal sessions, fleet bridge wire types, RPC, configuration, and macOS platform adapters. Public names, JSON coding keys, storage locations, Keychain identities, and wire formats remain stable.

`HerdrSSH` and `HerdrTailcat` retain their package and artifact boundaries. They are implementation dependencies, not presentation layers.

## Tests

Application tests mirror feature or infrastructure ownership under `Tests/HerdrMTests`. HerdrKit tests remain in the package and mirror the package capability folders. The required gates are:

```sh
make kit-test
make build
make mobile-build
make uiux-test
make ssh-test
```

Live SSH and Tailcat tests still require their documented environment fixtures.

Mobile lifecycle regressions run without an application host or live devices:

```sh
scripts/verify-pr26-mobile-lifecycle.sh
```

The `MobileLifecycleTests` Xcode scheme compiles the production mobile session
owners and adapters with synthetic transport and clock boundaries. The gate
creates and deletes its own simulator, runs each scenario three times, checks a nonempty test selection, and
builds the full iOS app for arm64 Simulator. It requires Xcode with Swift 6.2+
and an installed iOS runtime supporting iPhone 17. Tests use bounded waits and
explicitly release delayed I/O during teardown. Simulator cleanup is also bounded.
Logs and the result bundle go under `.atomic/verification/`, or `PR26_OUTPUT_DIR` when set.

Fleet cache serialization regressions run without starting the Mac app or a listener:

```sh
scripts/verify-pr26-lazy-fleet-encoding.sh
```

The `FleetBridgeCacheTests` hostless macOS scheme compiles the production
`Infrastructure/FleetBridge/FleetBridgeSnapshotCache.swift` owner and reuses
HerdrKit's wire and authentication tests. It runs 11 cache scenarios covering
idle encode counts, semantic deduplication, device/topology invalidation,
request-before-publish freshness, subscriber envelopes, restart, and encoding
failure retry. Fixtures are synchronous and use synthetic device values and a
counting JSONEncoder closure. The gate repeats all 26 selected tests three times,
rejects an empty/incomplete selection, and builds the full macOS app without
launching it. Each command has a 900-second deadline; XCTest has a 60-second
per-test limit. Xcode with Swift 6.2+, the Metal toolchain, and arm64 macOS are
required. Evidence goes under `.atomic/verification/` or `PR26_OUTPUT_DIR`.

Concurrency fixture failure probes and Apple toolchain checks run through:

```sh
scripts/verify-pr26-validation-followup.sh
```

This reuses both hostless schemes, includes the mobile cleanup/deadline tests,
checks that deliberately failing fixture subprocesses terminate with nonzero
status, and compiles all three app destinations. See [PR26 validation](pr26-validation.md)
for scenarios, deadlines, requirements, historical CI evidence, and remaining limits.
