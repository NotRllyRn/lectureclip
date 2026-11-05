#!/bin/bash
# Builds a microphone-only, unsigned IPA for a sideloading tool to sign.
set -euo pipefail
cd "$(dirname "$0")/.."
"${XCODEGEN:-xcodegen}" generate
xcodebuild -quiet -project LectureClip.xcodeproj -scheme LectureClip \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedData-sideload CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS=FREE_SIDELOAD build

mkdir -p artifacts
output="$PWD/artifacts/LectureClip-Microphone-unsigned.ipa"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/Payload"
ditto DerivedData-sideload/Build/Products/Release-iphoneos/LectureClip.app "$staging/Payload/LectureClip.app"
# Free-account provisioning cannot supply the shared App Group for ReplayKit.
# Keep the Live Activity widget: background AudioRecordingIntent capture requires it.
rm -rf "$staging/Payload/LectureClip.app/PlugIns/LectureClipBroadcast.appex" "$staging/Payload/LectureClip.app/_CodeSignature"
rm -rf "$staging/Payload/LectureClip.app/PlugIns/LectureClipRecordingWidget.appex/_CodeSignature"
rm -f "$staging/Payload/LectureClip.app/PlugIns/LectureClipRecordingWidget.appex/embedded.mobileprovision"
rm -f "$staging/Payload/LectureClip.app/embedded.mobileprovision"
test -d "$staging/Payload/LectureClip.app/PlugIns/LectureClipRecordingWidget.appex"
rm -f "$output"
(cd "$staging" && /usr/bin/zip -qry "$output" Payload)
unzip -tq "$output"
(cd artifacts && shasum -a 256 LectureClip-Microphone-unsigned.ipa > SHA256SUMS)
cat artifacts/SHA256SUMS
