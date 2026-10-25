#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
app="$PWD/.build/simulator/Build/Products/Debug-iphonesimulator/SelBrowser.app"
output="$PWD/build-logs/previews"
if [[ ! -d "$app" ]]; then
  echo 'Compile the Debug simulator application before capturing previews.' >&2
  exit 1
fi
mkdir -p "$output"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
runtime=$(xcrun simctl list runtimes --json | python3 -c '
import json,sys
runtimes=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
if not runtimes: raise SystemExit("No available iOS Simulator runtime")
print(max(runtimes,key=lambda r:tuple(map(int,r["version"].split("."))))["identifier"])
')
compat_runtime=$(xcrun simctl list runtimes --json | python3 -c '
import json,sys
runtimes=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-") and 16 <= int(r["version"].split(".")[0]) < 26]
print(max(runtimes,key=lambda r:tuple(map(int,r["version"].split("."))))["identifier"] if runtimes else "")
')
current_device=''
cleanup() {
  if [[ "$current_device" =~ ^[A-Fa-f0-9-]{36}$ ]]; then
    xcrun simctl shutdown "$current_device" >/dev/null 2>&1 || true
    xcrun simctl delete "$current_device" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

for family in iPhone iPad iPhone-compat; do
  selected_runtime="$runtime"
  if [[ "$family" == 'iPhone-compat' ]]; then
    if [[ -z "$compat_runtime" ]]; then echo 'No pre-iOS 26 runtime is installed; compatibility runtime capture is unavailable.'; continue; fi
    selected_runtime="$compat_runtime"
  fi
  device_type=$(xcrun simctl list devicetypes --json | python3 -c '
import json,sys
family=sys.argv[1]
types=[d for d in json.load(sys.stdin)["devicetypes"] if d["name"].startswith(family)]
preferred="iPhone 16 Pro" if family=="iPhone" else "iPad Pro 11-inch (M4)"
if not types: raise SystemExit("No compatible device type for "+family)
print(next((d for d in types if d["name"]==preferred),types[-1])["identifier"])
' "${family%%-*}")
  current_device=$(xcrun simctl create "Sel preview $family" "$device_type" "$selected_runtime")
  xcrun simctl boot "$current_device"
  xcrun simctl bootstatus "$current_device" -b
  xcrun simctl status_bar "$current_device" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  xcrun simctl ui "$current_device" appearance light
  xcrun simctl install "$current_device" "$app"
  xcrun simctl launch "$current_device" "$bundle_id" --sel-ui-smoke
  data_container=$(xcrun simctl get_app_container "$current_device" "$bundle_id" data)
  for attempt in {1..100}; do
    [[ -f "$data_container/tmp/sel-ui-smoke.json" ]] && break
    sleep 0.4
  done
  if [[ ! -f "$data_container/tmp/sel-ui-smoke.json" ]]; then
    xcrun simctl io "$current_device" screenshot "$output/$family-smoke-timeout.png"
    echo 'The simulator application did not finish its native UI smoke checks.' >&2
    exit 1
  fi
  cp "$data_container/tmp/sel-ui-smoke.json" "$output/$family-smoke.json"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(json.dumps(r,ensure_ascii=False,indent=2)); assert r["passed"], "Native iOS UI smoke checks failed"' "$output/$family-smoke.json"
  for screen in home tabs settings search home-dark; do
    xcrun simctl terminate "$current_device" "$bundle_id" >/dev/null 2>&1 || true
    xcrun simctl launch "$current_device" "$bundle_id" --sel-ui-preview "$screen" | tee "$output/$family-$screen-launch.txt"
    # The local shell and the native presentation need to complete their first layout.
    sleep 4
    xcrun simctl io "$current_device" screenshot "$output/$family-$screen.png"
  done
  cleanup
  current_device=''
done
echo 'Captured the running Debug app on iPhone and iPad simulators. These images do not verify physical-device behavior.'
