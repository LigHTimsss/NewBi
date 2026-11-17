#!/bin/bash
set -euo pipefail
resolved=NewBi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
args=()
if [[ -f ci/Package.resolved ]]; then
  mkdir -p "$(dirname "$resolved")"
  cp ci/Package.resolved "$resolved"
  args+=(-onlyUsePackageVersionsFromResolvedFile)
else
  echo '尚无提交的依赖锁文件；本次解析结果将导出为 Package.resolved，后续步骤固定使用它。'
fi
xcodebuild -resolvePackageDependencies -project NewBi.xcodeproj -scheme NewBi "${args[@]}"
test -s "$resolved"
cp "$resolved" Package.resolved
