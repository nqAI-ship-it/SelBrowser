#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
device_id="${1:?Pass the UUID of the simulator created for this run}"
family="${2:-iPhone}"
if [[ ! "$device_id" =~ ^[A-Fa-f0-9-]{36}$ ]] || [[ ! "$family" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo 'Invalid simulator UUID or preview family.' >&2
  exit 1
fi
result="$PWD/build-logs/keyboard-$family.xcresult"
attachments="$PWD/build-logs/previews/keyboard-$family"
mkdir -p "$PWD/build-logs" "$attachments"
if [[ -e "$result" ]]; then
  echo "A keyboard result bundle already exists at $result; preserve it or select a new family name." >&2
  exit 1
fi

set +e
xcodebuild test \
  -project SelBrowser.xcodeproj -scheme SelBrowser \
  -configuration Debug -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$device_id" \
  -derivedDataPath .build/keyboard-tests \
  -resultBundlePath "$result" \
  -parallel-testing-enabled NO \
  -only-testing:SelBrowserUITests/BrowserKeyboardTests \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 90 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  2>&1 | tee "build-logs/keyboard-$family.log"
test_status=${PIPESTATUS[0]}
set -e

if [[ -d "$result" ]]; then
  # Public Xcode command, introduced in Xcode 16. Preserve evidence even if a UI assertion failed.
  xcrun xcresulttool export attachments --path "$result" --output-path "$attachments"
  xcrun xcresulttool get test-results summary --path "$result" --compact > "build-logs/keyboard-$family-summary.json"
fi
exit "$test_status"
