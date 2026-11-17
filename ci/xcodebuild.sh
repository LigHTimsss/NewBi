#!/bin/bash
set -euo pipefail
resolved=NewBi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
test -s Package.resolved
mkdir -p "$(dirname "$resolved")"
cp Package.resolved "$resolved"
xcodebuild "$@" -onlyUsePackageVersionsFromResolvedFile
