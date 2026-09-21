#!/bin/bash
# Hostless production cache + existing wire/auth regressions, then full macOS compile.
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT_DIR="${PR26_OUTPUT_DIR:-$PWD/.atomic/verification/lazy-fleet-encoding-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
export OUTPUT_DIR

source scripts/pr26-command.sh

bounded xcodebuild -version | tee "$OUTPUT_DIR/toolchain.log"
bounded xcrun swift --version | tee -a "$OUTPUT_DIR/toolchain.log"
bounded xcodegen generate
bounded xcodebuild test \
  -project HerdrM.xcodeproj -scheme FleetBridgeCacheTests \
  -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' -destination-timeout 60 \
  -skipPackagePluginValidation -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 30 \
  -maximum-test-execution-time-allowance 60 -collect-test-diagnostics never \
  -only-testing:FleetBridgeCacheTests/FleetBridgeSnapshotCacheTests \
  -only-testing:FleetBridgeCacheTests/FleetBridgeWireTests \
  -only-testing:FleetBridgeCacheTests/FleetBridgeAuthenticationTests \
  -test-iterations 3 \
  -resultBundlePath "$OUTPUT_DIR/FleetBridgeCache.xcresult" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  2>&1 | tee "$OUTPUT_DIR/tests.log"

bounded xcrun xcresulttool get test-results summary \
  --path "$OUTPUT_DIR/FleetBridgeCache.xcresult" --format json > "$OUTPUT_DIR/summary.json"
python3 - <<'PY'
import json, os
s = json.load(open(os.path.join(os.environ['OUTPUT_DIR'], 'summary.json')))
assert s['totalTestCount'] >= 26, f'Empty or incomplete fleet cache/wire/auth selection: {s}'
assert s['passedTests'] == s['totalTestCount'] and s['failedTests'] == 0, s
print(f"Verified {s['passedTests']} fleet cache/wire/auth tests, zero failures/skips")
PY

bounded xcodebuild build \
  -project HerdrM.xcodeproj -scheme HerdrM \
  -configuration Debug -derivedDataPath build \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  2>&1 | tee "$OUTPUT_DIR/macos-build.log"
printf '\nLazy fleet encoding gate passed. Evidence: %s\n' "$OUTPUT_DIR"
