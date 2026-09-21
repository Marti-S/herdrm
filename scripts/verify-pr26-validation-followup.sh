#!/bin/bash
# Production-backed concurrency regressions, fault probes, and Apple compatibility.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/pr26-command.sh

OUTPUT_DIR="${PR26_OUTPUT_DIR:-$PWD/.atomic/verification/validation-followup-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
export OUTPUT_DIR

bounded xcodebuild -version | tee "$OUTPUT_DIR/toolchain.log"
bounded xcrun swift --version | tee -a "$OUTPUT_DIR/toolchain.log"
bounded xcrun metal --version | tee -a "$OUTPUT_DIR/toolchain.log"

# Verify that even an uncooperative subprocess is terminated, not merely cancelled.
status=0
PR26_COMMAND_TIMEOUT=0.1 bounded python3 -c 'import time; time.sleep(60)' \
  > "$OUTPUT_DIR/command-timeout.log" 2>&1 || status=$?
[[ "$status" == 124 ]] || { echo "Deadline probe returned $status, expected 124" >&2; exit 1; }
grep -q 'command exceeded 0.1 seconds' "$OUTPUT_DIR/command-timeout.log"

for iteration in 1 2 3; do
  bounded swift test --package-path Packages/HerdrKit \
    --filter 'TerminalInputQueueTests|TerminalOutputBatcherTests|FixtureDeadlineTests' \
    2>&1 | tee "$OUTPUT_DIR/kit-$iteration.log"
  python3 - "$OUTPUT_DIR/kit-$iteration.log" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
for suite, count in [('TerminalInputQueueTests', 6), ('TerminalOutputBatcherTests', 5), ('FixtureDeadlineTests', 7)]:
    pattern = rf"Test Suite '{suite}' passed[^\n]*\n\s*Executed (\d+) tests, with 0 failures"
    match = re.search(pattern, text)
    assert match and int(match[1]) >= count, f'Empty/incomplete/failed selection: {suite}'
PY
done

# Expected failures are checked individually. A compiler failure, crash, process
# deadline, missing test, wrong diagnostic, or accidental pass fails this gate.
for mode in poll expectation gate input output cleanup; do
  status=0
  PR26_FIXTURE_FAILURE="$mode" PR26_COMMAND_TIMEOUT=20 bounded swift test \
    --skip-build --package-path Packages/HerdrKit --filter FixtureDeadlineTests/testFailureProbe \
    > "$OUTPUT_DIR/failure-$mode.log" 2>&1 || status=$?
  printf '%s\n' "$status" > "$OUTPUT_DIR/failure-$mode.exit"
  python3 - "$mode" "$status" "$OUTPUT_DIR/failure-$mode.log" <<'PY'
import pathlib, re, sys
mode, status, path = sys.argv[1:]
text = pathlib.Path(path).read_text()
diagnostic = {
    'poll': 'Timed out: probe missing event',
    'expectation': 'unfulfilled expectations: "probe missing expectation"',
    'gate': 'Unreleased fixture: probe unreleased gate',
    'input': 'Timed out: probe input completion',
    'output': 'Timed out: probe output completion',
    'cleanup': 'Timed out: probe cleanup completion',
}[mode]
assert status == '1', f'{mode}: expected test failure exit 1, got {status}\n{text}'
assert diagnostic in text, f'{mode}: missing diagnostic\n{text}'
assert "FixtureDeadlineTests testFailureProbe]' failed" in text, text
assert re.search(r'Executed 1 test, with 1 failure', text), text
print(f'Verified {mode}: expected diagnostic, one failed test, exit 1, no process timeout')
PY
done

# Reuse the earlier hostless targets, including the mobile deadline/cleanup
# regressions and every permanent lifecycle boundary test. Both scripts also
# compile the full apps and reject empty test selection.
PR26_OUTPUT_DIR="$OUTPUT_DIR/mobile" scripts/verify-pr26-mobile-lifecycle.sh
PR26_OUTPUT_DIR="$OUTPUT_DIR/fleet" scripts/verify-pr26-lazy-fleet-encoding.sh
# Validate resolved manifests after the app gates have populated the cache.
bounded python3 scripts/verify-pr26-toolchains.py | tee "$OUTPUT_DIR/ci-compatibility.log"
bounded xcodebuild build \
  -project HerdrM.xcodeproj -scheme HerdrMobile \
  -configuration Debug -derivedDataPath build \
  -destination 'generic/platform=iOS' -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  2>&1 | tee "$OUTPUT_DIR/ios-device-build.log"
printf '\nValidation follow-up gate passed. Evidence: %s\n' "$OUTPUT_DIR"
