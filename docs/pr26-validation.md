# PR26 validation follow-up

Run the bounded, synthetic regression gate from the repository root:

```sh
scripts/verify-pr26-validation-followup.sh
```

It runs 18 HerdrKit concurrency/fixture tests three times, six deliberately
failing subprocess probes, 28 mobile lifecycle/fixture tests three times, and
26 fleet cache/wire/authentication tests three times. It reuses the hostless
`MobileLifecycleTests` and `FleetBridgeCacheTests` schemes, then compiles the
macOS, arm64 iOS Simulator, and unsigned arm64 iOS device apps. It never launches
the apps or connects to a real SSH device or bridge.

Requirements: Apple Silicon, Xcode with Swift 6.2+, Metal toolchain, XcodeGen,
Python 3, macOS Ruby with its standard YAML/JSON libraries, and an available iOS
runtime supporting iPhone 17. App gates resolve packages into `build/SourcePackages`.
`PR26_OUTPUT_DIR` can select a fresh evidence directory. Otherwise logs and result
bundles go under `.atomic/verification/`. Existing result bundles are not overwritten.

## Deadlines and failure evidence

- Queue and batcher expectations, polling, and completion observations have
  three-second deadlines with named diagnostics. Delivery gates fail and release
  themselves after three seconds, and teardown also releases them synchronously.
- Mobile synthetic I/O fails and releases after five seconds. Observation and
  operation joins default to three seconds. The two foreground retry tests retain
  their explicit 12-second observation across the production failure-grace period.
- Task observations do not use a task-group timeout. A task group must join its
  children, which can hang when the simulated transport ignores cancellation.
  Cleanup cancels work, releases its pending I/O, and uses bounded completion
  observations rather than an unconditional `Task.value` join.
- Fixtures test cancellation-insensitive semantic tickets and output delivery,
  impossible observations, repeated gate release, original error propagation,
  diagnostic source locations, bridge/direct cleanup timeouts, and release of
  pending production refreshes during cleanup.
- Fault probes deliberately omit an event, expectation, gate release, input
  completion, output completion, or teardown completion. Each must execute exactly
  one failed XCTest, emit the expected diagnostic, and exit 1 within 20 seconds.
  A process timeout, crash, compiler failure, empty selection, or accidental pass
  fails the gate. These expected failures are saved in `failure-*.log` and `.exit`.
- The process wrapper has a 900-second default deadline and kills its process
  group on expiry. A separate sleep probe must exit 124 after a 0.1-second deadline.
  Simulator discovery, creation, and deletion each have a 30-second bound.
  Deletion only targets the simulator created by this run. Cleanup preserves a
  preceding failure and turns an otherwise successful run into failure if deletion fails.
- XCTest also has a 60-second per-test execution limit. Scripts use `pipefail`,
  validate nonempty suite counts and result bundles, and do not filter out compiler errors.

## Apple CI compatibility

The historical tools-version mismatch is already addressed in the current tree.
No `.github/workflows` change was needed for this slice. All three workflow files
match the workflow baseline captured before the repairs.

| Job | Current selection | Requirement | Assessment |
| --- | --- | --- | --- |
| `apple-builds.yml` HerdrKit | `macos-15`, default Xcode | HerdrKit and HerdrTailcat tools 6.0 | Historical Swift 6.1 default meets this requirement; this job does not resolve HerdrSSH. |
| `apple-builds.yml` app matrix | Explicit `/Applications/Xcode_26.3.app` | HerdrSSH tools 6.2; other local packages 6.0 | Xcode 26.3 supplies Swift 6.2.x for all three destinations. |
| `validate.yml` build/test | `macos-26` default Xcode 26.x | Tools 6.2 | Historical successful run used Xcode 26.6 and Swift 6.3.3. |
| `release.yml` release build | `macos-26` default Xcode 26.x | Tools 6.2 during project resolution | Compatible tools selection; signing/notarization was not exercised. |

Evidence:

- `git show 342c08d539d9c7d7b2d5ffc909205663d8c82149 -- .github/workflows/apple-builds.yml`
  shows the existing change from default `Xcode.app` to `Xcode_26.3.app` for the app
  matrix, plus package-plugin validation flags. It was merged through PR #25.
- [Historical failing Apple run 33549034062](https://github.com/Marti-S/herdrm/actions/runs/33549034062)
  says `package 'herdrssh' is using Swift tools version 6.2.0 but the installed
  version is 6.1.0`. All three app jobs failed; HerdrKit passed.
- [Historical successful Validate run 33549033797](https://github.com/Marti-S/herdrm/actions/runs/33549033797)
  records Xcode 26.6 build 17F113, Swift 6.3.3, 176 tests with 11 skipped and zero
  failures, and three successful app builds. Both historical runs targeted
  `97a9d2ce12d33a1df6bb8dea20b6cc993f6933a7`.
- [Apple's Xcode 26.3 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_3-release-notes)
  place its compiler in the Swift 6.2 family.
- Local checks on 2026-09-21 used the existing system selection, Xcode 26.5 build
  17F42 and Swift 6.3.2. Xcode 26.6 build 17F113 with Swift 6.3.3 was also installed,
  but no global Xcode selection was changed. Metal 32023.883 was available, as
  were the SSH/Tailcat xcframeworks and cached Ghostty/Sparkle artifacts.
- Current cached manifests require tools 6.0 for libghostty-spm and MSDisplayLink,
  5.9 for StickySectionHeaders, and 5.3 for Sparkle. The gate checks these resolved
  manifests and every Apple job using `scripts/verify-pr26-toolchains.py`.

These are current configuration checks and local build results, not a claim that
hosted CI was rerun or Xcode 26.3 was installed locally. No release signing,
notarization, live device, network race-frequency, UI, or minimum-OS runtime testing
is implied. Existing Tailcat binary linker warnings report macOS 27.0 objects
against a macOS 14.0 deployment target. The selected tests and current local builds
pass, but they do not establish deployment compatibility for that prebuilt binary.
