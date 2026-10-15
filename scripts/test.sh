#!/bin/sh
# Run the account-free simulator suite. Override the selected destination with:
# STORIES_TEST_DESTINATION='platform=iOS Simulator,id=<UUID>' sh scripts/test.sh
set -eu
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
/bin/sh "$task_root/scripts/check-main.sh"
/bin/sh "$task_root/scripts/test-build-source.sh"

task_destination=${STORIES_TEST_DESTINATION:-}
if [ -z "$task_destination" ]; then
    task_devices=$(xcrun simctl list devices available --json)
    task_device_id=$(printf '%s\n' "$task_devices" | python3 -c '
import json
import re
import sys

devices = json.load(sys.stdin).get("devices", {})
candidates = []
for runtime, entries in devices.items():
    version = re.search(r"\.iOS-(\d+)(?:-(\d+))?(?:-(\d+))?$", runtime)
    if not version:
        continue
    number = tuple(int(part or 0) for part in version.groups())
    if number < (17, 0, 0):
        continue
    for device in entries:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            candidates.append((number, device["name"], device["udid"]))
if not candidates:
    sys.exit("error: Install an iOS 17+ iPhone Simulator runtime in Xcode, or set STORIES_TEST_DESTINATION.")
print(max(candidates)[2])
')
    task_destination="platform=iOS Simulator,id=$task_device_id"
fi

mkdir -p "$task_root/artifacts"
task_results=$(mktemp -d "$task_root/artifacts/tests.XXXXXX")
printf 'Stories test destination: %s\nResults: %s/StoriesTests.xcresult\n' "$task_destination" "$task_results"
# The optional public-login smoke test remains disabled in this offline suite.
TEST_RUNNER_STORIES_LIVE_SMOKE=0 xcodebuild \
    -project "$task_root/Stories.xcodeproj" -scheme Stories \
    -configuration Debug -sdk iphonesimulator \
    -destination "$task_destination" \
    -derivedDataPath "$task_root/DerivedData" \
    -resultBundlePath "$task_results/StoriesTests.xcresult" \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 120 \
    CODE_SIGNING_ALLOWED=NO test
