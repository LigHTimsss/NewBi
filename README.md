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

## 没有 Mac：GitHub Actions 云端编译

每次推送都会在 GitHub 的 macOS 虚拟机（Xcode 26）上自动编译（`.github/workflows/build.yml`）：

1. 模拟器版编译：查编译错误，完整日志在运行页的 `build-logs` 产物里
2. 真机 Release 版：打成**未签名**的 `NewBi-unsigned-ipa` 产物（保留 7 天）

未签名的 ipa 需要自签后才能装到 iPhone：用 AltStore / SideStore / 爱思助手等工具配合 Apple ID 签名（免费 Apple ID 签的 7 天后过期，需要重签）。注意免费账号不支持部分能力，实况活动、后台下载等可能受限。

> FFmpeg 兜底引擎固定使用 KSPlayer 2.3.4（最后的开源版，GPL-3.0）。5.x 起改为闭源二进制，不含 iOS 真机切片，请勿升级。

> 仅供个人学习自用，请遵守哔哩哔哩用户协议，不要分发或用于商业用途。
