#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build-logs

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS compilation requires macOS and Xcode. Use the included GitHub Actions workflow from Windows." >&2
  exit 1
fi

for file in SelBrowser/Info.plist SelBrowser/Sources/AppDelegate.swift SelBrowser/Sources/SceneDelegate.swift SelBrowser/Sources/BrowserModels.swift SelBrowser/Sources/BrowserViewController.swift SelBrowser/Sources/BoundedIconRequest.swift SelBrowser/Sources/BrowserGlass.swift SelBrowser/Sources/BrowserWebView.swift SelBrowser/Sources/MobileBrowserChrome.swift SelBrowser/Sources/TabOverviewController.swift SelBrowser/Sources/MobileSettingsController.swift SelBrowser/Resources/Shell.html SelBrowser/Resources/tailwind.js SelBrowser/Resources/lucide.js; do
  if [[ ! -f "$file" ]]; then echo "Required source/resource is missing: $file" >&2; exit 1; fi
done

xcodebuild -version | tee build-logs/xcode-version.txt
sdk_version=$(xcrun --sdk iphoneos --show-sdk-version)
echo "iPhoneOS SDK: $sdk_version" | tee build-logs/ios-sdk-version.txt
if [[ "${sdk_version%%.*}" -lt 26 ]]; then
  echo 'Liquid Glass requires an iOS 26 or newer SDK. Select Xcode 26+ before building.' >&2
  exit 1
fi
plutil -lint SelBrowser/Info.plist SelBrowser.xcodeproj/project.pbxproj

if [[ "${1:-}" == "--simulator-only" ]]; then
  xcodebuild \
    -project SelBrowser.xcodeproj -scheme SelBrowser \
    -configuration Debug -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath .build/simulator \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
    build 2>&1 | tee build-logs/simulator-build.log
  echo "Simulator compile completed. This is a build check, not an on-device test."
  exit 0
fi

xcodebuild \
  -project SelBrowser.xcodeproj -scheme SelBrowser \
  -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  build 2>&1 | tee build-logs/device-build.log

app='.build/device/Build/Products/Release-iphoneos/SelBrowser.app'
if [[ ! -d "$app" ]]; then echo 'Build did not produce the expected iPhone application.' >&2; exit 1; fi

# An unsigned device app is packaged as an IPA. iLoader, AltStore Classic or Sideloadly
# signs it locally on the user's Windows computer with their own Apple Account.
# Apple credentials, certificates and provisioning profiles are never used here.
package_dir="$(mktemp -d "${TMPDIR:-/tmp}/sel-ipa.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
mkdir -p "$package_dir/Payload" dist
ditto "$app" "$package_dir/Payload/SelBrowser.app"
output="$PWD/dist/SelBrowser-unsigned.ipa"
(cd "$package_dir" && /usr/bin/zip -q -r "$package_dir/SelBrowser-unsigned.ipa" Payload)
mv -f "$package_dir/SelBrowser-unsigned.ipa" "$output"
unzip -t "$output"
(cd dist && shasum -a 256 SelBrowser-unsigned.ipa) | tee dist/SelBrowser-unsigned.ipa.sha256
echo 'Created dist/SelBrowser-unsigned.ipa. It must be locally signed before installation.'
