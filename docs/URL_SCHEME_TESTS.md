# B 站 Scheme 接入

注册 `bilibili` 和 `newbi`，入口由 RootView.onOpenURL 接收。需要重新生成 Xcode 工程、构建并安装；已有安装不会因源码改动自动更新 URL 注册。

## 范围

- `bilibili://root`、`bilibili://home`、空 host：回首页。
- `bilibili://video/170001`、`bilibili://video/av170001`、`bilibili://video/BV17x411w7KC`：打开视频。也接受 video 的 bvid / aid / avid 查询参数；路径 ID 优先。视频需先查询详情，网络失败提示错误。
- `cid` 或 `p` / `page` 可指定分 P；验证属于目标稿件再播放，不默默播错分 P。
- `bilibili://space/123`、`bilibili://live/123`：打开 UP 主页 / 直播间。
- `bilibili://search`：打开搜索页（本次不预填关键词）。
- `browser?url=`：仅解析其中可识别的 B 站视频 / 空间 / 直播链接及已支持的 Scheme；不打开任意网页。最多两层包装，拒绝重复路由参数、溢出数字和超长链接。
- `newbi` 支持相同路由，可用于不与官方客户端争用的测试。番剧、文章、动态详情、登录回调、支付等不在本次范围，收到后仅提示不支持，不转发原 Scheme，避免循环唤起。
- 不接管 bilibili.com / b23.tv 的 HTTPS 通用链接，不解析短链接。

## 查阅依据

- [B 站官方移动网页唤端实现](https://s1.hdslb.com/bfs/static/jinkela/mstation-video-h5-new/1.mstation-video.46025752bcb740f39598330ffbf3fe4dacab1068.js)：getScheme 生成 bilibili://video、space、root、search、browser 等地址。2026-11-08 查阅；不代表官方承诺第三方兼容。
- [Apple 自定义 Scheme](https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app)：多个 App 注册同一 Scheme 时，系统选择的目标未定义，不能靠安装顺序保证。

## 验证

解析回归（纯 Foundation，不访问账号或网络）：

```sh
swiftc NewBi/App/ExternalAppLink.swift Tests/ExternalAppLinkChecks.swift -o /tmp/newbi-link-checks
/tmp/newbi-link-checks
```

Windows 无 Swift 编译器，当前只能做 Swift 语法解析；以上可执行回归及 iOS 编译仍需在 Mac 执行。

真机使用快捷指令的 URL + 打开 URL，或从备忘录点击链接：

1. 先用 newbi://home / newbi://video/BV17x411w7KC 验证自己的入口，再测 bilibili://home / bilibili://video/170001。应打开 NewBi 对应页面；若 bilibili 进入官方客户端，说明系统选中了另一个注册者。
2. App 未启动、后台、前台各测试视频 / UP / 直播入口；未登录可浏览，登录态不应改变。
3. 视频正在全屏 / 胶囊播放时打开 UP 或直播；视频舞台应让出页面。快速连续打开不同视频链接，旧详情响应不得覆盖新目的地。
4. 测无效 BV、负数 UID、重复 cid / p、番剧和 browser 中的非 B 站地址：仅提示不支持，不崩溃，不循环拉起。
5. 用实际多 P 视频验证 p / cid；不存在或相互冲突时应提示，不切到错误分 P。
6. 同时安装官方客户端时，分别记录 bilibili 和 newbi 的唤起结果；不要将成功一次当作系统默认归属的保证。
