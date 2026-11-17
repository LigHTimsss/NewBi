#!/bin/bash
set -euo pipefail
resolved=NewBi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
# Keep the array nonempty: macOS Bash 3.2 treats empty arrays as unset with -u.
args=(-resolvePackageDependencies -project NewBi.xcodeproj -scheme NewBi)
if [[ -f ci/Package.resolved ]]; then
  mkdir -p "$(dirname "$resolved")"
  cp ci/Package.resolved "$resolved"
  args+=(-onlyUsePackageVersionsFromResolvedFile)
else
  echo '尚无提交的依赖锁文件；本次解析结果将导出为 Package.resolved，后续步骤固定使用它。'
fi
xcodebuild "${args[@]}"
test -s "$resolved"
cp "$resolved" Package.resolved
