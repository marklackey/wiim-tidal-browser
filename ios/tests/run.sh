#!/bin/bash
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/../.." && pwd)
run_dir=${WIIM_TEST_RUN_DIR:-$(mktemp -d /private/tmp/wiim-player-tests.XXXXXX)}
python3 "$repo_root/ios/tests/prepare_project.py" "$run_dir"
simulator=$(xcrun simctl create 'WiiM Player Tests' "${WIIM_TEST_DEVICE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}" "${WIIM_TEST_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}")
cleanup() {
    xcrun simctl shutdown "$simulator" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$simulator"
xcrun simctl bootstatus "$simulator" -b > "$run_dir/boot.log" 2>&1
result_bundle="$run_dir/Results-$(date +%s).xcresult"
set +e
xcodebuild -project "$run_dir/ios/WiiMTIDAL.xcodeproj" -scheme PlayerTests -configuration Debug -sdk iphonesimulator \
    -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$run_dir/build" \
    -resultBundlePath "$result_bundle" -parallel-testing-enabled NO -collect-test-diagnostics never \
    CODE_SIGNING_ALLOWED=NO ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES test "$@" > "$run_dir/test.log" 2>&1
test_status=$?
set -e
xcrun xcresulttool export attachments --path "$result_bundle" --output-path "$run_dir/screenshots-$(basename "$result_bundle" .xcresult)"
echo "Test exit status: $test_status. Results: $run_dir"
exit "$test_status"
