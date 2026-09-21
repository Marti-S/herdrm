#!/bin/bash
# Production-backed, hostless iOS lifecycle regressions + full mobile compile.
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT_DIR="${PR26_OUTPUT_DIR:-$PWD/.atomic/verification/mobile-lifecycle-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
export OUTPUT_DIR

# Use the shared process-group deadline for build, observation and cleanup.
source scripts/pr26-command.sh

bounded xcodebuild -version | tee "$OUTPUT_DIR/toolchain.log"
bounded xcrun swift --version | tee -a "$OUTPUT_DIR/toolchain.log"
bounded xcodegen generate
runtime="$(PR26_COMMAND_TIMEOUT=30 bounded xcrun simctl list runtimes -j | python3 -c '
import json, sys
r = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and ".iOS-" in r["identifier"]]
assert r, "No available iOS simulator runtime"
print(max(r, key=lambda r: tuple(map(int, r["version"].split("."))))["identifier"])
')"
simulator="$(PR26_COMMAND_TIMEOUT=30 bounded xcrun simctl create "PR26-lifecycle-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$runtime")"
cleanup() {
  local status=$?
  trap - EXIT
  local cleanup_status=0
  PR26_COMMAND_TIMEOUT=30 bounded xcrun simctl delete "$simulator" || cleanup_status=$?
  if (( status == 0 )); then status=$cleanup_status; fi
  exit "$status"
}
trap cleanup EXIT

bounded xcodebuild test \
  -project HerdrM.xcodeproj -scheme MobileLifecycleTests \
  -configuration Debug -derivedDataPath build \
  -destination "platform=iOS Simulator,id=$simulator,arch=arm64" \
  -destination-timeout 120 -skipPackagePluginValidation \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 30 \
  -maximum-test-execution-time-allowance 60 -collect-test-diagnostics never \
  -only-testing:MobileLifecycleTests/MobileLifecycleTests \
  -only-testing:MobileLifecycleTests/LifecycleFixtureDeadlineTests \
  -test-iterations 3 \
  -resultBundlePath "$OUTPUT_DIR/MobileLifecycle.xcresult" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  2>&1 | tee "$OUTPUT_DIR/tests.log"

bounded xcrun xcresulttool get test-results summary \
  --path "$OUTPUT_DIR/MobileLifecycle.xcresult" --format json > "$OUTPUT_DIR/summary.json"
python3 - <<'PY'
import json, os
s = json.load(open(os.path.join(os.environ['OUTPUT_DIR'], 'summary.json')))
assert s['totalTestCount'] >= 34, f'Empty or incomplete lifecycle selection: {s}'
assert s['passedTests'] == s['totalTestCount'] and s['failedTests'] == 0, s
print(f"Verified {s['passedTests']} lifecycle tests, zero failures/skips")
PY

bounded xcodebuild build \
  -project HerdrM.xcodeproj -scheme HerdrMobile \
  -configuration Debug -derivedDataPath build \
  -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  2>&1 | tee "$OUTPUT_DIR/mobile-build.log"
printf '\nMobile lifecycle gate passed. Evidence: %s\n' "$OUTPUT_DIR"
