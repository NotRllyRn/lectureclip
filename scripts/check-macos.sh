#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -version
swift test
xcodegen generate
xcodebuild -project LectureClip.xcodeproj -scheme LectureClip \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project LectureClip.xcodeproj -scheme LectureClip \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData-device \
  CODE_SIGNING_ALLOWED=NO build
