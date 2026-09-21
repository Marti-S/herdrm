#!/usr/bin/env python3
"""Validate the reviewed Apple CI selections against current package requirements.

Uses macOS's Ruby/Psych YAML parser, not a regex approximation of workflow jobs.
This is a compatibility check, not a claim that a hosted runner image was built.
"""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def tools_version(path):
    match = re.search(r"swift-tools-version:\s*(\d+)\.(\d+)", path.read_text())
    assert match, f"Missing tools version: {path}"
    return tuple(map(int, match.groups()))


def workflow(name):
    result = subprocess.run(
        ["ruby", "-rjson", "-ryaml", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))",
         str(ROOT / ".github/workflows" / name)],
        capture_output=True, text=True, check=True, timeout=15,
    )
    return json.loads(result.stdout)["jobs"]


packages = {p.parent.name: tools_version(p) for p in (ROOT / "Packages").glob("*/Package.swift")}
assert set(packages) == {"HerdrKit", "HerdrSSH", "HerdrTailcat"}, packages
# The app build resolves every local package, even for a macOS-only scheme.
app_requirement = max(packages.values())
kit_requirement = max(packages[p] for p in ("HerdrKit", "HerdrTailcat"))
print(f"Local package tools requirements: {packages}")

apple = workflow("apple-builds.yml")
assert set(apple) == {"herdrkit-tests", "xcode-builds"}, "Review newly added Apple jobs"
kit = apple["herdrkit-tests"]
assert kit["runs-on"] == "macos-15"
assert any("--switch /Applications/Xcode.app" in s.get("run", "") for s in kit["steps"])
assert kit_requirement <= (6, 1), "macos-15 default Swift 6.1 is too old for HerdrKit"
print("apple-builds/herdrkit-tests: macos-15 default Swift 6.1 >=", kit_requirement)

apps = apple["xcode-builds"]
assert apps["runs-on"] == "macos-26", "Asset compilation requires the reviewed macOS 26 runner"
assert not any("xcode-select" in s.get("run", "") for s in apps["steps"]), "Use the same default Xcode as Validate"
assert app_requirement <= (6, 2), "Recheck macos-26 default for a new tools requirement"
assert {m["destination"] for m in apps["strategy"]["matrix"]["include"]} == {
    "generic/platform=macOS", "generic/platform=iOS", "generic/platform=iOS Simulator"
}
print("apple-builds/xcode-builds: all three matrix destinations use macos-26 default Xcode 26.x Swift >= 6.2 meets", app_requirement)

for name, job in (("validate.yml", "build-and-test"), ("release.yml", "release")):
    jobs = workflow(name)
    assert set(jobs) == {job}, f"Review newly added jobs in {name}"
    assert jobs[job]["runs-on"] == "macos-26"
    assert not any("xcode-select" in s.get("run", "") for s in jobs[job]["steps"]), "Review toolchain override"
    assert app_requirement <= (6, 2), "Recheck macos-26 default for a new tools requirement"
    print(f"{name}/{job}: macos-26 default Xcode 26.x Swift >= 6.2 meets {app_requirement}")

swift = subprocess.run(["xcrun", "swift", "--version"], capture_output=True, text=True,
                       check=True, timeout=15).stdout
match = re.search(r"Swift version (\d+)\.(\d+)", swift)
assert match, swift
installed = tuple(map(int, match.groups()))
assert installed >= app_requirement, swift
print(swift.strip())
# Cached dependencies can impose a higher requirement than the local packages.
checkouts = ROOT / "build/SourcePackages/checkouts"
assert checkouts.is_dir(), "Run an app gate to resolve its package cache first"
cached = {p.parent.name: tools_version(p) for p in checkouts.glob("*/Package.swift")}
assert cached, "Empty resolved package cache"
assert max(cached.values()) <= (6, 2), f"Recheck macos-26 default compatibility: {cached}"
assert installed >= max(cached.values()), cached
print(f"Resolved app package cache requirements: {cached}")
print("Apple job configuration and package tools requirements checked; hosted asset compilation still requires CI validation.")
