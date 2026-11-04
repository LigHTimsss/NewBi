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

> 仅供个人学习自用，请遵守哔哩哔哩用户协议，不要分发或用于商业用途。
