#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -version
swift test
xcodegen generate
/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' Sources/Info.plist
/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes:0' Sources/Info.plist
/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPrincipalClass' BroadcastExtension/Info.plist
xcodebuild -project LectureClip.xcodeproj -scheme LectureClip \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project LectureClip.xcodeproj -scheme LectureClip \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData-device \
  CODE_SIGNING_ALLOWED=NO build
