# v0.6.7 review repair validation

Verified on 2026-09-21 against the repaired merge candidate, not upstream historical results. HEAD remains `f903dd3872e19c7266cfa5fd7a11a3acf6fe0c95`; MERGE_HEAD remains `8dfc3739a3fb987778256226639eb3826d01e55f`. No commit, push, reset, abort, or PR was performed.

Local evidence directory: `.atomic/workflows/runs/herdrm-upstream-v067/review-repair/`. It contains complete command logs, command JSON, exit files, result bundles, summaries, and `tested-source-sha256.json`. These execution artifacts are retained locally, not added to the index.

## Repairs and regression evidence

- `SSHTunnel.ensureUp` checks cancellation immediately after platform probing, before computing or unlinking the shared socket pathname. Existing later spawn checks remain.
- `SSHRemoteAPIBridge.stopAndWait` waits for owned proxy process exits independently of byte-pump completion. It retains SIGTERM, one-second SIGKILL escalation, and a four-second deadline including launch-lock contention. A timeout returns false and retains ownership for retry. Service disconnect and FleetStore shutdown propagate the result; AppDelegate only replies affirmatively on success. FleetStore also retains services already removed from its live map until their shutdown succeeds.
- Only directly owned proxy children are tracked. Intentional ControlPersist masters and unrelated user SSH masters are not killed. Existing Unix-forward and Tailcat termination behavior is unchanged. The deadline is per bridge; fleet shutdown currently awaits services sequentially.
- Both terminal coordinators pass through the shared allowlist before an injectable URL opener. Tests observe exactly one accepted delivery and no rejected delivery for each coordinator and each Ghostty link kind, without opening a browser.

`python3 scripts/verify-owned-ssh-lifecycle.py` compiles the production bridge and tunnel lifecycle with substituted external probe/authentication and temporary-directory boundaries. It has compilation/execution deadlines and a self-expiring resistant child fixture.

1. It suspends an obsolete probe, cancels and tears down its owner, starts a replacement listener, releases the old probe, observes cancellation, and connects to the replacement socket. Before repair: connect FD `-1`. After repair: FD `4`.
2. It launches an owned child that ignores SIGTERM, awaits shutdown, and actually exits the owner subprocess. Before repair: owner exits successfully while the proxy survives. After repair: shutdown takes about 1.065 seconds and the proxy PID no longer exists after owner exit.

Both regressions were reproduced against the original index in a temporary fixture, without rolling back working files. `lifecycle-red.log` records exit 1; `lifecycle-green.log` records exit 0. The package bridge suite also covers cancelled callers, launch contention, timeout/retry, and late-launch teardown: 12 tests, zero failures or skips, exit 0 in `bridge-tests.log`.

## Final-candidate gates

| Gate | Result | Evidence |
| --- | --- | --- |
| Full `swift test --package-path Packages/HerdrKit` | 244 tests: 231 passed, 13 skipped, 0 failures; exit 0 | `herdrkit.log`, `.exit`, `.command.json` |
| Full HerdrSSH `xcodebuild test`, arm64 iPhone 17 Simulator | 26 tests: 9 passed, 17 skipped, 0 failures; exit 0 | `herdrssh.log`, `.exit`, `.command.json`, `.summary.json`, `.xcresult` |
| Hosted AppLanguage, TerminalLinkOpening, FleetStorePlatform selections | 18 tests: 11 language, 4 URL, 3 platform; 0 failures/skips; exit 0 | `app-tests.log`, `.exit`, `.command.json`, `.summary.json`, `.xcresult` |
| `scripts/verify-pr26-validation-followup.sh` | Exit 0 | `pr26.log`, `.exit`, `.command.json`, `pr26/` |

HerdrSSH's parameterized numeric-address test has two cases. Its summary reports 9 passed test declarations and 10 passed cases; neither count includes the 17 skipped declarations.

The PR26 gate reran 18 concurrency/deadline tests three times, verified six intentional failure probes each exited 1 with the expected diagnostic, passed 34 mobile lifecycle and 26 fleet cache/wire/auth tests without skips, and built macOS, arm64 iOS Simulator, and unsigned arm64 iOS device targets. Hostless suite iterations and result bundles are preserved under `pr26/mobile/` and `pr26/fleet/`. Successful builds are not substitutes for package or live acceptance tests.

### Fixture policy

No external Windows, Unix SSH, forwarded-agent, or Tailcat fixture was designated. All `HERDRM_E2E_*` and `HEELER_SSH_E2E_*` environment values were removed from package test invocations; `SIMCTL_CHILD_HEELER_SSH_E2E_*` values were also removed for HerdrSSH. HerdrKit ran without filters under a disposable empty `CFFIXED_USER_HOME`, preventing access to the user's live local herdr socket. Synthetic socket/process fixtures and random-UUID Keychain tests ran normally with their cleanup.

HerdrKit's 13 skips were six live LocalSocket tests, one local installation resolver check, five RemoteSSH tests, and one live Tailcat test. HerdrSSH's 17 session-driver E2E tests explicitly skipped because no disposable sshd fixture was designated. `PR26_FIXTURE_FAILURE` was unset for the full HerdrKit run.

## Still unverified

- Live Windows fresh-password authentication, CMD/PowerShell discovery, RPC/events, interactive/structured terminals, and Windows reconnect behavior.
- Live Unix SSH and Tailcat acceptance, and existing Unix forward behavior under a SIGTERM-resistant subprocess.
- Manual Command-click/browser delivery, English/Chinese settings layout, actual application relaunch and PID ordering, retained-pane retry, and same-ID host-edit UI behavior.
- Actual AppKit termination/relaunch and selected-terminal alert interaction remain unverified. The refused-quit fixture below now exercises the production fleet/service/tunnel/bridge shutdown chain and delegate decision with substituted UI and transport boundaries; it does not terminate the actual application.
- Forced parent SIGKILL or crashes bypass awaitable shutdown. Existing Tailcat macOS deployment-target warnings remain; builds do not prove minimum-OS runtime compatibility.

These gaps require authorized fixtures or manual interaction. They are not reported as passed.

## Refused-quit fleet recovery follow-up

`shutdownAllSessions` previously cancelled/removed session owners without changing connected snapshots. A bridge timeout correctly refused quit but left no fleet reconnect path. Shutdown now transitions retained sessions through the semantic connection setter, preserves monotonic task generations, and reports an actionable error. RootView's existing error alert offers the fleet Reconnect action even with a retained terminal selected. Reconnect drains that device's retiring owners before binding another listener; timeout uses the existing failure/backoff loop rather than discarding ownership.

Validation on 2026-09-21 (logs under `/tmp/refused-quit-*.log`):

- `python3 scripts/verify-refused-quit-recovery.py`: red exit 1 (`refused quit left stale connected state`); additional overlap red exit 1 (`reconnect raced unfinished retiring teardown`); final green exit 0. Compiles unchanged production `startSession`, reconnect/shutdown/state methods, `HerdrService.disconnect`, `SSHTunnel.tearDown`, bridge and delegate decision. A bounded launch-lock fixture forces the real four-second bridge timeout. The regression proves refusal, semantic failure/error, retained ownership, reconnect started while old teardown remains pending, recovered byte round-trip, old cleanup preserving the replacement socket, and successful subsequent quit. UI, persistence, RPC connect/payload/catalog/events are substituted; local `/bin/cat` replaces SSH. No live remote fixture is involved. Compilation, process execution, launch gate and socket reads have deadlines.
- `python3 scripts/verify-owned-ssh-lifecycle.py`: exit 0; replacement listener connects and resistant proxy exits before owner.
- `xcodebuild test -project HerdrM.xcodeproj -scheme HerdrM -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build -skipPackagePluginValidation -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 30 -maximum-test-execution-time-allowance 60 -only-testing:HerdrMTests/FleetStorePlatformTests CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`: exit 0, four tests, zero failures. Includes actual FleetStore semantic invalidation and scoped reconnectability after shutdown. Invoked with a 300-second subprocess deadline; final log `/tmp/refused-quit-app-tests-final.log`.
- `git diff --check` and `git diff --cached --check`: exit 0. The parent independently reran the recovery regression, exit 0, with output in `/tmp/refused-quit-parent-validation.log`.

The full matrix and source hashes above describe the earlier candidate, not this follow-up. This follow-up does not rerun the complete package/mobile matrix, claim live Windows recovery, or replace manual AppKit/selected-terminal UI acceptance.
