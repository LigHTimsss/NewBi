# NewBi

第三方 Bilibili iOS 客户端草案。iOS 26+，iPhone 15 Pro 及以上，SwiftUI + Liquid Glass。播放为双引擎：系统 AVPlayer 为主，FFmpeg（KSPlayer，可选依赖）兜底。

- 设计文档：[docs/DESIGN.md](docs/DESIGN.md)
- UI 设计稿：claude.ai Artifact「视频 App · Liquid Glass UI」

## 构建（需要 macOS + Xcode 26）

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open NewBi.xcodeproj
```

在 Signing & Capabilities 里选择自己的开发者团队，连接 iPhone 运行。

## 没有 Mac：云端编译

推送提交**不会**自动编译，两个云端入口都要手动触发：

- **Codemagic（日常）**：`codemagic.yaml` 的「未签名 ipa」工作流。在 Codemagic 里选这个仓库和分支，手动 Start new build；产物有 `NewBi-unsigned.ipa`、这次实际解析出的 `Package.resolved` 和完整编译日志（`build-device.log`、`build-toolchain.log` 里记着 Xcode 版本）。每次构建记录都标着对应的提交，按提交号就能找到它的产物。
  - Xcode 版本在 `codemagic.yaml` 里固定，不跟 latest 漂移；升级时改那里
  - 依赖锁：把某次构建产物里的 `Package.resolved` 放到 `ci/Package.resolved` 提交，之后的构建只用锁住的确切版本（含 KSPlayer 间接带进来的 FFmpeg 二进制包）
- **GitHub Actions（备用）**：`.github/workflows/build.yml` 只能手动运行（Actions → Build → Run workflow，可选虚拟机），会先编模拟器版查错，再打未签名 ipa（`NewBi-unsigned-ipa` 产物保留 7 天，日志在 `build-logs`）

未签名的 ipa 需要自签后才能装到 iPhone：用 AltStore / SideStore / 爱思助手等工具配合 Apple ID 签名（免费 Apple ID 签的 7 天后过期，需要重签）。注意免费账号不支持部分能力，实况活动、后台下载等可能受限。

> FFmpeg 兜底引擎固定使用 KSPlayer 2.3.4（最后的开源版，GPL-3.0）。5.x 起改为闭源二进制，不含 iOS 真机切片，请勿升级。

> 仅供个人学习自用，请遵守哔哩哔哩用户协议，不要分发或用于商业用途。
