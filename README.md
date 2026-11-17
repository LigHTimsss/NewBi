# NewBi

第三方 Bilibili iOS 客户端，使用 SwiftUI 与 Swift 6，最低系统版本 iOS 26。

## 编译

需要 macOS、支持 iOS 26 的 Xcode 和 XcodeGen。模拟器构建使用 Apple 芯片 Mac。

```sh
brew install xcodegen
xcodegen generate
bash ci/prepare-metal.sh
bash ci/resolve-packages.sh
bash ci/xcodebuild.sh build -project NewBi.xcodeproj -scheme NewBi -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

真机安装需自行配置签名；仓库不提供证书、私钥或开发者账号。

GitHub Actions 与 Codemagic 配置提供手动构建入口，产出未签名 IPA。构建版本及环境要求见相应配置。

## 依赖

依赖由 `project.yml` 声明。若存在 `ci/Package.resolved`，构建使用该锁文件；否则首次解析并导出 `Package.resolved`。后续应将实际生成的锁文件保存至 `ci/Package.resolved` 并提交。

KSPlayer 使用声明版本 2.3.4；第三方依赖的许可证以各自对应版本提供的许可证及声明为准。本仓库当前未提供项目自身的 LICENSE 文件，不代表授予任意使用、修改或再分发权限。

本公开目录包含应用源码、资源与编译配置，不包含内部设计文档、审查资料和私有测试。
