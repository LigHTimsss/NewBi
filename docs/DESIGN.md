# NewBi —— 第三方 Bilibili iOS 客户端 设计草案

> 版本：v0.2 草案 · 2026-11-03
> 目标平台：iOS 26.0+ · iPhone 15 Pro / 15 Pro Max 及以后机型（A17 Pro+）
> 技术栈：Swift 6.2 · SwiftUI · Observation · AVKit · Core Animation · Foundation Models
> UI 设计稿：claude.ai Artifact「视频 App · Liquid Glass UI」（https://claude.ai/artifact/CJtg64GoF5oZdEVvGMnCq8）

**两条总原则**
1. **轻**：除可选的 FFmpeg 兜底引擎外零第三方依赖，低内存、低 CPU，长时间播放不发热。
2. **UI / 动效优先**：设计稿里的效果要做到；做法上优先选系统原生、GPU 合成的实现，把开销压到最低，而不是砍效果。

---

## 1. 定位与约束

| 项 | 说明 |
|---|---|
| 定位 | 轻量、无广告、原生 iOS 26 Liquid Glass 风格的 B 站客户端，专注"看视频 + 弹幕 + 关注动态" |
| 分发 | **个人自用 / 侧载 / TestFlight 小范围**。使用 B 站非公开接口和 B 站内容，基本无法通过 App Store 审核（Guideline 5.2 知识产权、4.1 仿冒） |
| 合规底线 | 不破解付费/大会员内容、不绕过地区限制、不批量抓取、不二次分发视频；请求频率贴近正常用户 |
| 接口来源 | 社区整理的 Web 端接口（参考 GitHub `SocialSisterYi/bilibili-API-collect`），随时可能变更，需做好容错 |

### 为什么限定 iOS 26 + iPhone 15 Pro 及以上

| 能力 | 用途 |
|---|---|
| **Liquid Glass**（`glassEffect` / `GlassEffectContainer`） | 导航、频道条、播放器按钮用系统玻璃，系统级 GPU 实现，比 CSS 式手绘模糊便宜 |
| **Foundation Models**（端侧大模型，A17 Pro+） | 视频摘要、弹幕/评论过滤，不需要服务器 |
| **AV1 硬解**（A17 Pro 起） | 同码率下画质更好、更省流量和电 |
| ProMotion 120Hz | 弹幕、转场按 120Hz 合成 |
| Swift 6.2 `isolated deinit` 等 | 并发安全地释放播放器资源 |

> 系统没有能精确限定"A17 Pro 及以上"的 `UIRequiredDeviceCapabilities`。侧载场景影响不大；功能上用运行时检测（如 `SystemLanguageModel.default.availability`）降级。

---

## 2. 功能规划

### MVP（约 4–6 周）
- [x] 骨架：Liquid Glass 导航、频道横滑、深/浅色、4 种强调色
- [x] 扫码登录 + 游客模式（含同机"保存二维码"方案）
- [x] 首页推荐、热门（双列卡片、下拉刷新、无限加载）
- [x] 视频详情：UP 主、三连统计、相关推荐
- [x] 播放：MP4 直链、进度拖动、双击暂停、弹幕开关
- [x] 弹幕：分段懒加载、滚动/顶部/底部轨道、屏蔽规则
- [x] 横屏全屏播放器：手势、锁屏、右侧玻璃抽屉（弹幕设置 / 画质 / 倍速 / 更多）、发弹幕
- [x] 画中画、后台播放开关、定时关闭、投屏（AirPlay）
- [x] 搜索：历史、热搜、联想词、视频 / UP 主结果、排序、关键词高亮
- [x] 评论：热度 / 时间排序、置顶、表情图文混排、楼中楼、点赞、发评论与回复
- [x] UP 主空间：头图、资料、认证、粉丝/关注/获赞、关注与取关、主页（置顶/代表作/最近投稿）、投稿（排序 + 分页）
- [x] 历史记录：按日期分组、观看进度、设备图标、左滑删除、清空；跨设备续播与进度上报
- [x] 收藏：收藏夹网格、收藏夹详情（三种排序、失效视频、长按取消收藏）、详情页「收藏到…」多选
- [x] 稍后再看：列表（进度、左滑删除、移除已看完、清空、开始播放）；首页 / 搜索 / 相关推荐 / 空间长按卡片添加，详情「更多」添加
- [x] 离线缓存：后台下载、断点续传、地址过期自动换、本地播放（含弹幕）、灵动岛进度、断网可看
- [x] 控制中心 / 锁屏的播放信息与远程控制（播放暂停、±10 秒、拖动、倍速、上一 P / 下一 P）
- [x] 多 P：选集（横向胶囊 / 展开网格）、续播回到上次那一 P、播完自动连播、缓存当前 P

### v1
- [x] DASH 高画质（1080P+ / 4K / HDR / 杜比视界，AV1 > HEVC > AVC），失败自动降级
- [x] 动态流：关注 UP 主头像条、全部 / 视频、视频 / 图文 / 文字 / 转发 / 专栏卡片、点赞、评论面板、大图查看、底栏新动态红点
- [x] 点赞（真实接口）、投币（1 / 2 枚、同时点赞）、长按点赞一键三连
- [x] 零散项：评论 @ / 链接 / 时间点、收藏夹增删改、空间页动态 / 合集 / 收藏、稍后再看与合集连播、全屏选集
- [x] 消息中心：回复我的 / @我 / 收到的赞 / 系统通知、私信会话与聊天（收发文字、图片 / 卡片显示、撤回）、首页信封未读角标
- [x] 首页左上角显示登录用户头像
- [x] 视频页简介 / 评论左右滑动切换，加载过不再重新淡入
- [x] 连贯过渡：卡片封面展开成视频页、返回收回卡片；播放中返回整页连续收成迷你胶囊，胶囊展开铺满屏幕的同时变成视频页；侧滑 / 下拉跟手
- [x] 迷你播放条：播放中返回自动缩小、点 / 上滑展开不断播、横滑关闭（设计稿资料库页底部）
- [ ] 端侧 AI：视频摘要、弹幕语义过滤

### v2
- [ ] 小组件（关注 UP 更新、稍后再看）、App Intents

---

## 3. 总体架构

```
┌──────────────────────────── Features (SwiftUI, @MainActor @Observable) ───────────────────────────┐
│  Home(频道分页) · VideoDetail · Player · Mine · Settings · Login                                  │
├──────────────────────────────── DesignSystem ─────────────────────────────────────────────────────┤
│  Theme(颜色/字体令牌) · Motion(动效令牌) · GlassTabBar · LiquidSelector · RemoteImage   │
├───────────────────────────────────────────────────────────────────────────────────────────────────┤
│  Player：AVPlayer + AVPlayerLayer        │  Danmaku：Protobuf 手写解析 + CALayer 引擎              │
├───────────────────────────────────────────────────────────────────────────────────────────────────┤
│  Core：actor BiliClient · Endpoint · WBISigner · Models · QRLoginModel                            │
├───────────────────────────────────────────────────────────────────────────────────────────────────┤
│  系统：URLSession · URLCache · HTTPCookieStorage · ImageIO · Keychain                              │
└───────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- **依赖极少**：图片缓存、Protobuf 解析都手写（各约 100 行），省掉 Nuke / SwiftProtobuf 约 3–4 MB 体积和启动时的动态库加载。唯一的第三方依赖是可选的 KSPlayer（FFmpeg 兜底引擎，见 §5.2），代码用 `canImport` 隔离，去掉它照常编译。
- **并发**：Swift 6 严格并发。网络层 `actor`；图片解码、弹幕解析放到 `Task.detached` 后台执行；UI 模型 `@MainActor`。

---

## 4. B 站接口要点

### 4.1 通用
- 请求头：桌面 Safari `User-Agent` + `Referer: https://www.bilibili.com/`（视频 CDN 也校验）
- 返回 `{ code, message, data }`；常见错误码：`-101` 未登录 · `-352` 风控 · `-412` 拦截
- **buvid3**：首次启动调 `/x/frontend/finger/spi` 写 Cookie，否则很多接口直接返回 -352

### 4.2 WBI 签名
`/x/web-interface/nav` 取 `img_key/sub_key` → 置换表得 `mixin_key` → 参数加 `wts`、排序、过滤 `!'()*`、编码 → `w_rid = md5(query + mixin_key)`。key 按自然日缓存，遇 -352 刷新后重试一次。见 `Core/Network/WBISigner.swift`。

### 4.3 扫码登录
`qrcode/generate` → 每 2 秒 `qrcode/poll`（`0` 成功 / `86101` 未扫 / `86090` 已扫待确认 / `86038` 过期）→ Set-Cookie 下发 `SESSDATA`、`bili_jct`。
**同一台 iPhone 的问题**：提供"保存二维码"，再到官方 App「扫一扫 → 相册」识别。

### 4.4 接口清单

| 功能 | 接口 | 签名 |
|---|---|---|
| 推荐流 | `/x/web-interface/wbi/index/top/feed/rcmd` | WBI |
| 热门 | `/x/web-interface/popular` | - |
| 视频信息 / 相关 | `/x/web-interface/view` · `/x/web-interface/archive/related` | - |
| 播放地址 | `/x/player/wbi/playurl` | WBI |
| 弹幕分段 | `/x/v2/dm/web/seg.so`（Protobuf，6 分钟一段） | - |
| 用户 / 统计 | `/x/web-interface/nav` · `/x/web-interface/nav/stat` | - |
| 搜索结果 / 热搜 | `/x/web-interface/wbi/search/type` · `/x/web-interface/wbi/search/square` | WBI |
| 搜索联想 | `s.search.bilibili.com/main/suggest`（不是 `{code,data}` 格式） | - |
| 评论 / 楼中楼 | `/x/v2/reply/wbi/main`（游标分页 `pagination_str`）· `/x/v2/reply/reply` | WBI / - |
| 点赞评论 / 发评论 | `POST /x/v2/reply/action` · `POST /x/v2/reply/add` | csrf |
| 发弹幕 | `POST /x/v2/dm/post` | csrf |
| 历史记录 | `/x/web-interface/history/cursor`（游标分页）· `POST /x/v2/history/delete` · `POST /x/v2/history/clear` | 登录 |
| 续播 / 上报进度 | `/x/player/wbi/v2`（`last_play_time`）· `POST /x/v2/history/report` | WBI / csrf |
| 收藏夹 | `/x/v3/fav/folder/created/list` · `/x/v3/fav/folder/created/list-all`（带 `rid` 返回 `fav_state`）· `/x/v3/fav/resource/list` | 登录 |
| 收藏 / 取消收藏 | `POST /x/v3/fav/resource/deal` · `/x/v2/fav/video/favoured` | csrf |
| 动态 | `/x/polymer/web-dynamic/v1/feed/all`（`features=itemOpusStyle`，offset 分页）· `/portal`（UP 头像条）· `/feed/all/update`（新动态数） | 登录 |
| 动态点赞 | `POST /x/dynamic/feed/dyn/thumb?csrf=`（JSON 正文） | csrf |
| 稍后再看 | `/x/v2/history/toview` · `POST …/toview/add` · `POST …/toview/del`（`viewed=true` 删已看完）· `POST …/toview/clear` | 登录 / csrf |
| 未读数 | `/x/msgfeed/unread` · `api.vc.bilibili.com/session_svr/v1/session_svr/single_unread` | 登录 |
| 回复 / @ / 赞 | `/x/msgfeed/reply` · `/at` · `/like`（游标 `id` + `reply_time` / `at_time` / `like_time`） | 登录 |
| 系统通知 | `message.bilibili.com/x/sys-msg/query_user_notify`（首页）· `query_notify_list?data_type=1&cursor=`（更多）· `update_cursor`（已读） | csrf |
| 私信会话 | `api.vc …/session_svr/v1/session_svr/get_sessions`（`end_ts` 分页）· `api.vc …/account/v1/user/cards?uids=`（头像昵称） | 登录 |
| 私信消息 | `api.vc …/svr_sync/v1/svr_sync/fetch_session_msgs`（`begin_seqno` / `end_seqno`）· `POST …/update_ack`（已读） | 登录 / csrf |
| 发私信 | `POST api.vc …/web_im/v1/web_im/send_msg`（query 带 `w_sender_uid` 等，表单 `msg[...]`） | WBI / csrf |

---

## 5. 播放器

AVPlayer 不支持 DASH，分三步走：

| 阶段 | 方案 |
|---|---|
| **主路径（已写）** | **DASH → 本地 HLS**：`fnval=4048` 取 DASH，解析每路流的 sidx，生成带 `EXT-X-BYTERANGE` 的 m3u8，由 127.0.0.1 上的本地服务交给 AVPlayer。画中画、AirPlay、HDR、硬解、系统控制中心都照常可用，**不引入 FFmpeg** |
| 兜底（已写） | `fnval=1` 取 MP4 直链，`AVURLAsset` 注入 Referer/UA |
| **FFmpeg 兜底（已写）** | KSPlayer 的 KSMEPlayer，吃同一个本地 HLS 地址；系统播放器播不了时自动切换，见 §5.2 |

### 5.0 DASH → HLS 细节（`Features/Player/DashHLS.swift`、`Core/Media/LocalMediaServer.swift`）

```
playurl(fnval=4048) ─▶ 选流：不超过目标画质的最高档 × 编码优先级（AV1 硬解 → HEVC → AVC）
                       音频取码率最高的一路
        │
        ├─ 每路流一次 Range 请求取 init + sidx（通常 < 10KB）→ 解析出分段偏移 / 长度 / 时长
        ├─ init 段把 hev1 / dvhe 改成 hvc1 / dvh1（Apple 只认后者）
        └─ 生成 master / video / audio 三个 m3u8，注册到本地服务
                       │
AVPlayer ── http://127.0.0.1:端口/<会话>/master.m3u8
              ├─ m3u8、init 段：内存数据
              └─ 媒体分段：按 Range 转发到 CDN（加 Referer / UA，主备地址依次尝试）
```

- **为什么要本地服务**：`AVAssetResourceLoaderDelegate` 只接管 HLS 的播放列表和密钥，不接管媒体分段；CDN 又校验 Referer，所以分段必须走一个能加请求头的 http 地址。服务只监听 127.0.0.1，一个连接处理一个请求，用 Network.framework 写，约 200 行。Info.plist 需要 `NSAllowsLocalNetworking`
- **HDR / 杜比视界**：master 里标 `VIDEO-RANGE=PQ`，iPhone 15 Pro 的屏幕可直接显示
- **自动降级**：播放项失败时按 AV1 / HEVC → AVC → MP4 逐级回退，并从当前位置继续
- **地址过期自动刷新**（B 站播放地址带 `deadline`，约 2 小时失效）：
  - **DASH**：本地代理里每路流是一个 `UpstreamSource`。距 deadline 不到 60 秒、或 CDN 返回 403 / 404 / 410 时，按同一画质重新请求 playurl，找到同画质、同编码的那路流换上新地址再请求一次。同画质同编码就是同一个文件，分段偏移不变，播放器完全无感、不会中断
  - 视频、音频两路往往同时过期：`DashRefresher` 让 30 秒内的刷新共用一次 playurl 结果；同一路流并发的多个分段请求只触发一次刷新；15 秒内不重复刷新，防止地址本身有问题时反复请求
  - **MP4 兜底 / 其它中途出错**：播放项开始播放后才出错的（多半是地址过期、网络抖动、App 长时间在后台导致本地代理被系统回收），先在同一级重新取流、从当前位置续播，不降级；60 秒内再次出错才走降级链
- **画质列表**：接口在 `accept_quality` 里列出全部档位，DASH 里拿不到流的档位（未登录 / 非大会员）显示为灰色不可选
- **设置**：「默认画质」（默认 1080P）、「视频编码」（自动 / 兼容优先）
- **待处理**：
  - 无损音轨（flac）、杜比全景声（ec-3）暂未接入，目前只用 AAC
  - hev1 改 hvc1 依赖流里带完整参数集，需要真机验证更多视频；不行时会自动降到 AVC

### 5.1 横屏全屏（「播放器 · 横屏全屏」画板）

**实现方式**：不另开页面。详情页里的同一个播放器视图原地放大到整屏，同时把界面方向放开到横屏（`AppDelegate` 默认只允许竖屏，`Orientation.lock` 临时放开）。AVPlayerLayer 和弹幕图层都不重建，不会黑屏一下，也没有第二路视频渲染。

| 区域 | 内容 |
|---|---|
| 左上 | 返回、标题（宋体）、「N 人正在观看」（`/x/player/online/total`）、UP 主玻璃胶囊 |
| 右上 | 点赞 / 评论 / 收藏（带数字）、分享、更多 |
| 中右 | 锁屏按钮（锁定后只保留它） |
| 底部 | 时间、进度条（已播 / 已缓冲 / 呼吸光点）、播放、弹幕开关、弹幕设置、发弹幕输入框、倍速、画质 |
| 右侧抽屉 | 宽 384pt，Material 背景，420ms 滑入；点抽屉外关闭 |

**手势**（与 B 站一致）：单击显隐控件 · 双击暂停/播放 · 长按临时 2 倍速（已在 2 倍时为 3 倍，弹幕同步加速）· 左右滑拖进度（满屏 ≈ 90 秒）· 左半屏上下滑调亮度 · 右半屏上下滑调音量 · 锁屏后所有手势失效。
**自动横竖屏**：横过手机自动进入全屏，竖回来退出；锁屏时不跟随。系统方向锁打开时不会触发。

**抽屉面板**
- 弹幕设置：显示区域、不透明度、字体大小、速度；按类型屏蔽（固定 / 滚动 / 彩色）；重复弹幕隐藏、底部字幕区域防挡；屏蔽词；一键重置。设置保存在本地，下次打开沿用
- 画质：列出接口返回的清晰度，大会员档位有标记；切换后从当前位置继续
- 倍速：0.5–2.0x
- 更多：定时关闭、画面尺寸（适应 / 铺满）、镜像翻转（只翻转视频，弹幕不受影响）、后台播放、画中画、投屏

**与设计稿的差异**
- 「人像防挡」需要 B 站下发的人像蒙版数据，先显示为不可用
- 类型屏蔽里的「高级」「计数」没有做：引擎目前不渲染高级弹幕
- 拖动进度时只显示时间，不显示预览缩略图（需接 `/x/player/videoshot`）
- 设计稿中的背景音乐胶囊（「发现《…》」）没有对应数据，未做
- 播放方式、举报为占位
- 音量调节的是 App 内音量，不是系统音量（iOS 没有公开调系统音量的接口）

### 5.2 双引擎（`Features/Player/Engine/`）

B 站官方 App 用的是自研播放器，未开源；它早年开源的 ijkplayer 已多年未维护。B 站视频本身是标准的 H.264 / HEVC / AV1 + AAC，系统播放器都能硬解，所以采用「系统为主、FFmpeg 兜底」：

| | 系统引擎 AVPlayerEngine | FFmpeg 引擎 FFmpegEngine（KSPlayer） |
|---|---|---|
| 定位 | 默认 | 系统引擎播不了时自动切换，或在设置里固定使用 |
| 解码 | VideoToolbox 硬解 | FFmpeg 解析封装 + VideoToolbox 硬解 |
| 优势 | 最省电；系统画中画、AirPlay、HDR / 杜比视界、控制中心 | hev1 标记、少见封装、FLAC 等都能播 |
| 限制 | 只认标准 HLS / MP4 | 暂不支持系统画中画；AirPlay 仅音频；安装包约 +20MB |

- **统一接口** `PlaybackEngine`：加载、播放、暂停、跳转、倍速、画面填充、画中画。`PlayerController` 只依赖这个接口；弹幕、手势、玻璃抽屉都不用改
- **共用取流**：两个引擎都播本地 HLS 地址，选流、sidx 解析、Referer 代理完全复用
- **降级链**（设置 → 播放引擎 = 自动）：系统 · DASH（AV1 / HEVC）→ 系统 · DASH（AVC）→ FFmpeg · DASH → 系统 · MP4，每一级都从当前进度续播
- **切换画面**：`PlayerSurface` 观察当前引擎，切换时把新引擎的画面放到弹幕图层下面
- **时钟**：统一用 4 Hz 轮询引擎的播放时间，驱动进度条和弹幕；只在数值变化时写入，暂停时不触发界面刷新
- **许可证**：KSPlayer 开源版为 GPL-3.0（以仓库 LICENSE 为准），个人自用没问题，对外分发前需评估
- **版本固定 2.3.4**：最后一个源码发布的开源版。5.x 起 `KSPlayer` 产品变成闭源 xcframework，只含模拟器 / macOS / tvOS 切片，真机无法链接，所以不能升级
- **可选**：在 `project.yml` 删掉 KSPlayer 依赖也能编译，设置里不再出现「始终 FFmpeg」，降级链跳过 FFmpeg

### 5.3 其他

- `preferredForwardBufferDuration = 20`：限制预缓冲，内存可控
- 进度回调 4Hz，只驱动进度条和弹幕生成；进度条是单独的子视图，只有它会随时间刷新
- 释放：用 `isolated deinit` 在详情页出栈时移除观察者、释放播放项

---

## 6. 弹幕引擎（性能核心）

```
seg.so ──▶ 手写 Protobuf 解析（后台线程）──▶ 按时间排序数组 + 二分定位游标
                                                     │ 4Hz tick
                                                     ▼
              过滤：类型 / 彩色 / 屏蔽词 / 同屏上限 80
                                                     ▼
              轨道分配：滚动轨道看"上一条尾部是否已进场"，顶/底部轨道停留 4s
                                                     ▼
   文字 + 描边一次性画成位图 → CALayer.contents → CABasicAnimation(position.x)
```

**为什么用 CALayer，不用 SwiftUI Canvas**
- Canvas + TimelineView 每帧都要在主线程重排、重画所有可见文字；120Hz 下就是每秒 120 次全量绘制
- CALayer 方案每条弹幕只在**出现时画一次**，运动由 Core Animation 渲染服务完成，播放中主线程每帧开销接近 0
- 暂停 / 倍速：只改宿主图层的 `speed` 和 `timeOffset`（Apple QA1673），所有弹幕一起停、一起变速
- 图层复用池（≤120），出屏回收；`contents` 及时置空，释放位图
- 拖动进度或回退时清屏，重新定位游标；每段末尾 30 秒预取下一段

---

## 7. UI 设计落地（对照设计稿）

### 7.1 画板 → 代码映射

| 设计稿画板 | 代码 | 状态 |
|---|---|---|
| 首页 · 推荐（深/浅） | `Features/Home/HomeView.swift` | ✅ 频道条、Banner、双列卡片 |
| 热门 | `HomeView` 同一分页器 | ✅ |
| Tab 切换原型 | `App/RootView.swift` + `GlassTabBar` | ✅ 三页横向平移 420ms |
| 视频详情 | `Features/Video/VideoDetailView.swift` | ✅ |
| 播放器 · 横屏全屏 | `Features/Player/FullscreenPlayer.swift` · `PlayerDrawer.swift` | ✅ 差异见 §5.1 |
| 我的 | `Features/Mine/MineView.swift` | ✅（不做创作中心、钱包等官方业务） |
| 搜索（设计稿无此画板） | `Features/Search/SearchView.swift` | ✅ 沿用同一套玻璃组件，见 §7.5 |
| 评论（设计稿无此画板） | `Features/Comments/` | ✅ 见 §7.5 |
| UP 主空间（设计稿无此画板） | `Features/Space/` | ✅ 见 §7.5 |
| 设置 | `Features/Settings/SettingsView.swift` | ✅ 加入主题色、深色模式 |
| 离线缓存 | `Features/Library/DownloadsView.swift` · `Core/Downloads/` | ✅ 见 §7.5 |
| 资料库底部迷你播放条 | `Features/Player/MiniPlayer.swift` | ✅ 改为全局：根页面浮在底栏上方，二级页面贴底；和视频页是同一个舞台，见 §7.5「视频舞台」 |
| 动效规范 | `DesignSystem/Theme.swift` → `Motion` | ✅ |

### 7.2 关键结构
- **底部导航**：玻璃胶囊（首页 / 动态 / 我的）+ 右侧独立圆形搜索按钮，放在一个 `GlassEffectContainer` 里，相邻玻璃会自然融合
- **选中光轨**（`LiquidSelector`，底部 Tab 栏和所有分段控件共用）：整条只有一个指示器，胶囊和底部 2pt 强调色发光线（2.8s 呼吸）是同一个视图，位置由选中项直接算出，切换时两者走同一条弹簧、同步移动
- **按住滑动切换**（系统 Tab 栏同款）：按下时指示器浮起成放大的玻璃透镜（`glassEffect(.clear.interactive())`，横 1.08 / 纵 1.16 倍 + 投影），跟手滑动，经过的项图标与文字高亮并轻触反馈，松手切到手指下那一项；轻点走同一个手势。分段控件在可滚动页面里不独占触摸，竖向滑动照常滚动页面、不会误切；开启「减弱动态效果」时不浮起
- **顶部频道条**：个人中心 + 推荐 / 热门两个频道的玻璃胶囊 + 消息；内容是横向分页 `ScrollView(.paging)`，左右滑动和点击频道双向联动
- **配色**：深色优先；强调色默认 `#FB7299`，可选 `#00AEEC / #0A84FF / #FF9F0A`；浅色模式下文字用强调色压暗 28%（保证 4.5:1 对比度）

### 7.3 字体
设计稿标题用宋体（Songti SC）。iOS 没有预装中文衬线体，有三种做法：
1. **系统可下载字体**：用 `CTFontDescriptor` 按需下载 Songti SC，零包体，首次需联网（推荐）
2. 内置 Noto Serif SC 子集（只保留常用 3500 字，约 1.5MB）
3. 当前骨架：先用 `.system(design: .serif)` 兜底

### 7.4 动效令牌（`Motion`）

| 令牌 | 值 | SwiftUI 实现 |
|---|---|---|
| 微交互 | 180ms (.2,.8,.2,1) | `Motion.micro` |
| 组件切换 | spring .32 / .86 | `Motion.component` |
| Tab 切换 | 平移 420ms (.32,.72,0,1) | `Motion.tab` |
| 模糊入场 | blur 8→0、y 14→0、间隔 50ms | `.riseIn(index:)` |
| 按压回弹 | scale .95 + 提亮 | `PressableStyle` |
| 数字滚动 | — | `.contentTransition(.numericText())` |
| 减弱动态效果 | 全部降级为淡入淡出 | 读取 `accessibilityReduceMotion` |

### 7.5 搜索与评论（按设计语言补充）

设计稿没有这两页，沿用已有组件和动效令牌来做：

**搜索**
- 入口：点底部圆形搜索按钮，搜索页从按钮**放大展开**（`navigationTransition(.zoom)`），返回时缩回按钮；转场结束后再弹出键盘，两段动画不叠在一起
- 顶部：玻璃胶囊搜索框 + 取消
- 输入前：搜索历史（流式标签，最多 20 条，可清空）+ 热搜（两列，前三名用强调色）
- 输入中：200ms 防抖请求联想词；点 ↖ 可把联想词填回输入框继续编辑
- 结果：玻璃分段控件切换 视频 / UP 主（和首页频道条是同一个组件），视频可按 综合 / 最多播放 / 最新发布 / 最多弹幕 排序；分类和排序栏滚动时吸顶；标题里的关键词用强调色高亮
- 切换分类 / 排序时取消上一次请求，旧结果不会覆盖新结果

**评论**（详情页「评论」Tab）
- 热度 / 时间排序、置顶标记、等级角标、大会员昵称用强调色
- 正文里的 B 站表情（`[doge]`）以图片方式混排在文字里：表情图请求服务端缩放后的小图并全局缓存，同一个表情只下载一次
- 楼中楼：预览前 2 条，点开半屏面板看全部、继续回复
- 点赞先改界面再请求，失败自动恢复，带轻触反馈和数字滚动
- 底部玻璃输入栏：多行自动增高，有内容时才出现发送按钮；点某条评论的回复按钮会变成「回复 @某人：」
- 发评论、点赞都需要登录（用 Cookie 里的 `bili_jct` 做 csrf）

**UP 主空间**（结构参考 B 站空间页，视觉沿用本 App 的玻璃风格）
- 入口：视频详情的 UP 主头像/名字、搜索结果里的 UP 主、评论头像
- 头图：下拉放大、上滑视差（`visualEffect`，只做渲染变换不触发布局）；没有头图时用强调色渐变
- 资料：头像压在头图上，右侧 粉丝 / 关注 / 获赞 + 关注按钮；下面是昵称、等级、大会员、认证（个人橙色 / 机构蓝色）、签名（点击展开）
- 关注：先改界面再请求，失败回滚；取关前二次确认；粉丝数同步 ±1。详情页的关注按钮也接上了同一套逻辑
- 顶栏：玻璃返回 / 分享；滚过头图后中间浮出「头像 + 昵称」玻璃胶囊；主页 / 投稿 Tab 滚到顶栏下方时吸顶悬浮
- 主页：置顶视频（大封面）、代表作（横滑）、最近投稿（两列，可「查看全部」跳到投稿）
- 投稿：最新发布 / 最多播放 / 最多收藏，分页加载
- 名片走 `/x/web-interface/card`（风控较松）；投稿列表 `/x/space/wbi/arc/search` 需要 WBI + 浏览器指纹参数，否则常见 -352

**历史记录**（我的 → 历史记录）
- 按「今天 / 昨天 / 近一周 / 更早」分组；封面底部是强调色进度条，角标显示「看到 / 总时长」或「已看完」；观看设备图标 + 时间
- 左滑删除（先移除再请求，失败放回），右上角「清空」二次确认
- **续播**：进入视频时读取 `last_play_time`，同一分 P 且不在开头 / 结尾时自动定位，并提示「已定位到上次观看位置」；离开页面、进入后台时上报进度，其它设备也能续播

**收藏**（我的 → 我的收藏）
- 收藏夹两列网格：封面 + 玻璃角标显示数量；空收藏夹用星形占位
- 收藏夹详情：最近收藏 / 最多播放 / 最新投稿；失效视频变灰不可点；长按「取消收藏」
- 视频详情的「收藏」：弹出「收藏到」面板，多选收藏夹（未收藏时默认勾选默认收藏夹），完成后星标变实心

**稍后再看**（我的 → 稍后再看）
- 列表与历史记录同款：封面进度条 + 「看到 / 总时长」或「已看完」，显示播放量和「几天前添加」；左滑删除
- 顶部「共 N 个」+「开始播放」；右上角菜单：移除已看完（显示数量）、清空（二次确认）
- **添加入口**：首页、搜索结果、相关推荐、UP 主空间的视频卡片长按 →「稍后再看」/「分享」；视频页右上角「更多」→「稍后再看」/「分享」
- 卡片长按菜单没有自己的页面，提示走全局 `ToastCenter`，由 RootView 统一显示

**动态**（底栏「动态」）
- 顶部：宋体标题 + 玻璃分段「全部 / 视频」；下面是最近有更新的关注 UP 主头像条，有更新的带强调色渐变描边，点进空间
- 卡片：头像 + 昵称（大会员强调色）+「2小时前 · 投稿了视频」；正文是表情混排的富文本，超过 6 行点一下展开
  - 视频：16:9 大封面 + 播放量 / 弹幕 / 时长，点进视频，长按可稍后再看
  - 图文：1 张按原比例；2、4 张两列；其余三列正方形
  - 转发：原动态放在浅底卡片里，「@原作者」可点
  - 专栏：标题 + 摘要 + 封面
- 底部：转发数、评论（弹出评论面板，与视频评论同一套组件，按动态自带的评论区类型 11 / 17 / 1 加载）、点赞（乐观更新 + 轻触反馈）
- **大图查看**：全屏、左右翻页、双指 / 双击缩放、下滑关闭；评论里的图片也接上了
- **底栏红点**：读到第一页时记下 `update_baseline`；App 回到前台时请求一次新动态数，有新动态就在「动态」图标上显示强调色小圆点。切到动态页、或在动态页再点一次「动态」会刷新并清除红点。不轮询，开销只有回到前台时的一次请求

**离线缓存**（我的 → 离线缓存；视频页「缓存」）
- **缓存什么**：DASH 的视频、音频两路各存成完整的 fMP4 文件，外加封面和全部弹幕分段。播放时本地服务按 sidx 生成 HLS，分段直接从文件按 Range 读取——与在线播放同一套逻辑，两个引擎都能播，HDR / 杜比视界照常
- **下载**：后台 URLSession，App 退到后台、被挂起甚至被杀掉后系统继续下载，完成后唤醒 App 收尾；同时最多 2 个视频；暂停保存续传数据，继续时断点续传；默认仅 Wi-Fi（设置里可关）
- **地址过期**：下载返回 403 / 404 / 410 时，按同画质同编码重新取流，从头下载这一路
- **进度**：灵动岛紧凑视图显示图标 + 百分比，展开后是标题、进度条、剩余个数；锁屏横幅同样；最多每秒刷新一次。实况活动在小组件扩展 `NewBiWidgets` 里，与 App 共用 `Shared/DownloadActivity.swift`
- **播放**：打开已缓存的视频时优先播本地文件；断网时详情接口失败也能播，页面显示「离线播放 · 画质」和缓存时记下的标题
- **页面**：「已缓存 / 缓存中」玻璃分段；缓存中的行显示进度条、已下 / 总大小，右侧暂停 / 继续 / 重试；左滑删除（二次确认）；右上角全部暂停 / 全部开始；底部显示已缓存占用和手机剩余空间
- 缓存文件放在 Application Support/Downloads，不进 iCloud 备份
- **暂未做**：多 P 视频批量缓存（目前只缓存当前分 P）

**点赞 · 投币 · 三连**（视频页操作行）
- 进页面时用 `archive/relation` 一次拿到「已赞 / 已投几枚 / 已收藏」，图标直接显示实心状态
- 点赞乐观更新，失败回滚；计数显示为「详情统计 + 本页变化量」，不用重新拉详情
- 投币面板：1 枚 / 2 枚两张玻璃卡片，选中的硬币沿 Y 轴翻转一圈；可勾选同时点赞；底部显示硬币余额；确认后硬币下落、成功触感，余额随即刷新。已投 1 枚时只能再投 1 枚，投满 2 枚后点按钮直接提示
- 长按点赞 1.2 秒：点赞、投币、收藏三个图标外圈同时走一圈强调色光环，走满即一键三连；结果按项提示（如硬币不足时「已点赞，已收藏，硬币不足或已投满」）
- 分享改为系统分享面板（视频链接）

**多 P**
- 简介里「选集 当前 / 总数」：默认横向胶囊，当前 P 带跳动的波形图标并自动滚到中间；「全部」展开成两列网格
- 切 P 复用同一个播放器（只换流和弹幕），先上报上一 P 的进度；评论、简介不变
- 续播：历史里记的是哪一 P 就直接打开哪一 P 并定位；从历史卡片进入（带 cid）同理
- 播完自动播下一 P（设置可关）；锁屏 / 耳机的「下一首 / 上一首」切 P
- 缓存按钮针对当前这一 P，缓存标题带「P2 xxx」

**锁屏与控制中心**（`Features/Player/RemoteControl.swift`）
- 显示标题（多 P 带分 P 名）、UP 主、封面（600 宽服务端缩放）、进度和倍速
- 远程命令：播放 / 暂停、前进 / 后退 10 秒、拖动进度、切倍速、上一 / 下一 P
- 只服务最近开始播放的播放器；只在播放状态、拖动、倍速、时长变化时写入，系统自己推算进度，不跟时钟刷新
- 封面图回调在任意线程，`MPMediaItemArtwork` 在 nonisolated 函数里创建，避免 Swift 6 主线程隔离导致的崩溃

**视频舞台**（`Features/Player/VideoStage.swift`）：视频页、迷你胶囊、两者之间的过渡是同一个东西
- **为什么不用系统 zoom 转场**：它的来源 id 在推入时就定死，找不到来源（胶囊不在当前页面里）就退化成淡出，结果就是「视频先消失、胶囊再冒出来」。现在视频页不进导航栈，而是 RootView 最上层的一块全屏「舞台」，每一帧的形状都由自己算
- **一个进度值**：`progress` 1 = 铺满的视频页，0 = 收在锚点。锚点三选一：打开它的卡片封面（暂停 / 播完时返回）、迷你胶囊（播放中返回，或从视频页进了 UP 主空间等页面）、都没有（卡片已滑出屏幕）时原地缩小淡出
- **几何全部插值**（`StageMetrics`）：容器矩形、圆角（铺满时 0，途中和屏幕圆角 55 对齐，落到胶囊 28 / 卡片封面原圆角）、底（胶囊的玻璃 ⇄ 页面底色）、页面内容（按容器宽度等比缩放、晚一点淡入）、胶囊内容（最先退场）、下层 App 的压暗
- **胶囊展开成视频页**：胶囊本身就是容器——玻璃胶囊拉长、铺满屏幕的同时变成页面底色，左边的小画面连续移动、放大到页面顶部的播放区，标题和按钮先淡出，简介 / 评论最后浮现；收起时完全倒放
- **只重算小修饰器**：各图层是 `Animatable` 修饰器（`StageLayer` / `StageScrim` / `StageBackdrop`），动画每帧只跑这几个，视频页本身的 body 不重算；图层外壳一直在，打开时 progress 才能从 0 动画到 1
- **同一个画面**：只有一个播放器视图。展开 / 收起途中和停在胶囊时归舞台（`player.isMinimized`，跟着容器移动），铺满后交给视频页；还没出第一帧时两处都先盖同一张封面（内存缓存里直接拿），落回卡片时看不出接缝
- **跟手**：左边缘右滑（UIKit 边缘手势，页面里的横向分页等它失败）和在画面上下拉，页面跟手缩小、带圆角；松手超过阈值（或甩得够快）就从手指的位置接着收进胶囊 / 卡片，否则弹回。拖动中画面留在页面里随页面缩放，不换视图（换掉手指下的 UIKit 视图会取消触摸）
- **胶囊**：点它或上滑展开（上滑跟手），左右滑或点 × 关闭（淡出、上报进度、释放播放器）；高 56，左侧 64×36 实时小画面（同一图层，不挂弹幕），标题 + 时间、播放 / 暂停、前进 10 秒；根页面浮在底栏上方，二级页面贴底（位置变化也是插值的）
- **视频页里进别的页面**：舞台上没有导航栈，`RouteLink` 交给 RootView——先把视频页收进胶囊（不管在不在播），再推入 UP 主空间等页面
- **相关推荐**：在视频页里点相关视频原地换（淡入淡出），旧视频进返回历史；左上角返回先回到上一个视频，没有了再收起
- **打开入口**：`VideoLink` 替代 `NavigationLink(value: card)`，卡片里用 `.videoCover(cornerRadius:)` 标出封面，舞台从封面的位置和圆角展开；展开期间封面隐藏，像被「拿起来」了
- 开着「迷你播放条」设置、且正在播放时返回才进胶囊；关掉设置则总是收回卡片并停止播放

**正文链接**（评论、动态；`DesignSystem/RichText.swift`）
- 强调色可点：@提及（只认服务器给了 mid 的名字）→ UP 主空间；BV 号、bilibili.com 视频链接 → 站内打开；B 站识别的关键词、其它网址 → Safari / 官方 App
- 视频评论里的时间点（05:12、1:02:33）点了直接跳到该位置并继续播放
- 统一编码成 `newbi://space|video|seek/…`，RootView 的 openURL 处理导航，视频页先截下 seek；只有 BV 号的视频直接在舞台上打开（原地淡入），详情返回 aid 后再建评论区

**连播**（`Features/Video/PlayQueue.swift`）
- 从稍后再看（跳过已看完的，点进的那个除外）或 UP 主合集进入时设好队列；视频页简介里显示「稍后再看 · 连播 3 / 12 · 下一个 xxx」
- 播完（多 P 先播完所有 P）在画面底部弹出「即将播放」玻璃卡片，3 秒倒计时环走完自动换下一个，可立即播放或取消
- 换视频由舞台原地替换（不记进返回历史）：返回直接回列表；旧播放器随之释放

**全屏**：右上角新增「选集」抽屉（竖向列表，当前 P 波形图标、其它显示时长）；点赞、收藏改为真实状态

**收藏夹管理**：我的收藏右上角「+」新建；长按收藏夹编辑 / 删除（默认收藏夹不能删，删除需二次确认）；「收藏到」面板顶部可直接新建，建好自动勾选；私密收藏夹带锁图标。编辑面板：名称 ≤ 20 字、简介 ≤ 200 字、私密开关

**空间页新 Tab**：主页 · 动态 · 投稿 · 合集 · 收藏
- 动态：该 UP 主的动态流，卡片与动态页同一套（点赞、评论面板、大图）
- 合集：合集与系列，每个一行标题 + 横向前几个视频；点标题进全部视频（编号列表，从这里播放按顺序连播）
- 收藏：对方公开的收藏夹网格，点进去与自己的收藏夹详情同一页面
- 各 Tab 数据放在空间页模型里，切走再切回不重新加载


**首页顶栏**：左上角玻璃圆按钮里显示登录用户的头像（未登录是人形图标，加载好后交叉淡入）；右上角信封按钮进消息中心，红色角标显示「回复 + @ + 赞 + 系统 + 私信」未读总数（> 99 显示 99+）。登录状态变化、回到前台时刷新

**消息中心**（`Features/Messages/`，仿官方客户端）
- 顶部四个入口：回复我的 · @我 · 收到的赞 · 系统通知，彩色圆形图标 + 各自未读角标；下面是私信会话列表（头像、置顶、官方号标记、最后一条预览、时间、未读数），`end_ts` 翻页
- 通知列表：头像（赞可叠多个）、「谁 回复了你 / @了你 / 等 N 人赞了你」、内容、灰底引用原文、时间、右侧封面；点头像进空间，点条目打开对应视频 / 动态 / 评论。打开后清掉该类角标
- 系统通知：标题 + 正文，正文里 `#{文字}{"链接"}` 渲染成可点链接
- 聊天页：气泡左右分开、间隔超过 5 分钟插时间、撤回显示「对方撤回了一条消息」；文字、图片、分享卡片、通知卡片分别显示；底部沿用评论输入框，发送先乐观显示（转圈 / 失败可重试），成功后拉新消息；页面打开时每 5 秒轮询，进入即标记已读。官方号会话只读
- 不做推送：后台不轮询，靠打开 App 时刷新角标

**简介 / 评论切换**（`VideoDetailView` 的 `DetailPager`）
- 两页放在同一个横向分页滚动视图里，左右滑动或点 Tab 切换；两页都常驻，切回来不重建、不再播放淡入动画，滚动位置也保留
- 评论页第一次滑到或点到时才挂载、加载
- Tab 下的指示条跟随滑动进度连续移动，中途拉长再缩回；切换完成时轻触反馈
- 全屏时这部分高度收成 0 但不移除，退出全屏状态不丢

**连贯过渡**：视频卡片 ⇄ 视频页 ⇄ 迷你胶囊见上面「视频舞台」。搜索页仍用系统 zoom 转场从搜索按钮展开

**不做**：直播、动画（番剧）、影视。首页只有推荐 / 热门，搜索只有视频 / UP 主。

---

## 8. 性能与体积策略

| 场景 | 做法 | 为什么 |
|---|---|---|
| 玻璃效果 | 只用系统 `glassEffect`；**不做**设计稿里那条 7s 循环的 CSS 扫光 | 系统玻璃本身就有随光变化的高光；无限循环动画会让 GPU 一直工作 |
| 入场动画 | 只给首屏前 8 个元素做，只用透明度 + 位移（不用模糊） | `blur` 是离屏渲染，8 张卡片同时做会掉帧；滚动中再加载的内容直接显示 |
| 发光线 | 两层小阴影，只用在 2pt 的光轨上 | 阴影面积小，开销可忽略 |
| 列表图片 | 让 B 站服务端裁剪（`@w_h_1c.webp`）+ ImageIO 后台下采样 + 主线程可同步读的内存缓存（`ImageMemory` 80MB，另记每张图最近一个尺寸）+ URLCache 200MB；新一页到了先预取封面 | 解码出来的就是显示尺寸；缓存里有的图第一帧就画出来，滚回来不闪；大尺寸没到时先用小图顶上 |
| 列表 | `LazyVGrid` + `LazyHStack` 分页，频道模型常驻、视图按需创建 | 切换频道不重复请求 |
| 状态刷新 | Observation 按属性追踪；高频数据（进度）放进独立子视图 | 避免 4Hz 刷新带动整页重算 |
| 弹幕 | CALayer + 预渲染位图（§6） | 播放中主线程接近空闲 |
| 播放器 | 限制预缓冲；收起（不进胶囊）即释放 | 防止多个详情页叠加占内存 |
| 二进制 | 依赖极少、`DEAD_CODE_STRIPPING`、Release 全模块优化 | 不含 FFmpeg 引擎时安装包 < 5 MB；含 FFmpeg 约 25 MB |

**性能预算（iPhone 15 Pro）**：冷启动 < 400ms 出首帧；首页滚动稳定 120fps；1080P 播放 + 满屏弹幕时 CPU < 15%、内存 < 150MB。
**验证工具**：Instruments（Time Profiler、Animation Hitches、Allocations）、Xcode Organizer 的启动 / 卡顿指标。

---

## 9. 数据与安全
- 凭据归属（`Core/Auth/Credentials.swift`）：
  - Cookie（`SESSDATA`、`bili_jct`、`DedeUserID`…）只有一份，在系统 `HTTPCookieStorage.shared`：持久化在 App 沙盒内、受系统数据保护，API、媒体代理、后台下载共用；不另存副本
  - `refresh_token`：Keychain 通用密码项，`AfterFirstUnlockThisDeviceOnly`（后台唤醒也能读；不进 iCloud 钥匙串、不随备份迁移到别的设备）；轮换用 `SecItemUpdate` 原地替换
  - 退出登录：删 B 站域下除 `buvid*` 以外的 Cookie、删 Keychain 里的 `refresh_token`；会话世代加一，在途的查询结果作废
- Cookie 刷新（`CookieRefresher`，actor 串行，每次启动查一次）：`cookie/info` 问是否需要 → RSA-OAEP 加密 `refresh_<时间戳>` 取 `correspond` 页里的 `refresh_csrf` → `cookie/refresh` 换新 Cookie 与新 `refresh_token`（先写 Keychain）→ 用新 csrf + 旧 token `confirm/refresh`。刷新途中退出登录时丢弃新 Cookie
- 登录态：只有服务器明确回答才改；超时、断网保留最后确认的状态，回到前台 / 网络恢复时再查
- 本地设置：`@AppStorage`（主题色、外观、自动播放）；历史 / 屏蔽词后续用 SwiftData
- 不接任何第三方统计；日志不打印 Cookie

---

## 10. 目录结构

```
NewBi/
├── project.yml                       # XcodeGen（Mac 上生成 .xcodeproj）
├── docs/DESIGN.md
└── NewBi/
    ├── App/            NewBiApp.swift · RootView.swift · Orientation.swift
    ├── DesignSystem/   Theme.swift · GlassComponents.swift · RemoteImage.swift · RichText.swift · ImageViewer.swift
    ├── Core/
    │   ├── Network/    BiliClient.swift · Endpoint.swift · WBISigner.swift · NetworkStatus.swift
    │   ├── Media/      LocalMediaServer.swift（127.0.0.1 媒体代理，含本地文件）
    │   ├── Downloads/  DownloadManager.swift（后台下载 + 实况活动）· DownloadRecord.swift
    │   ├── Models/     Video.swift · Search.swift · Comment.swift · Space.swift · Library.swift · Dynamic.swift
    │   └── Auth/       QRLoginModel.swift · Credentials.swift（Keychain、Cookie 刷新）
    └── Features/
        ├── Home/       HomeView.swift
        ├── Video/      VideoDetailView.swift
        ├── Player/     PlayerController.swift · DanmakuEngine.swift · FullscreenPlayer.swift · PlayerDrawer.swift · DashHLS.swift · MiniPlayer.swift · RemoteControl.swift
        │   └── Engine/ PlaybackEngine.swift · AVPlayerEngine.swift · FFmpegEngine.swift（KSPlayer）
        ├── Search/     SearchView.swift（含 SearchModel）
        ├── Dynamic/    DynamicView.swift（含 DynamicModel、红点 DynamicBadge）
        ├── Comments/   CommentModel.swift · CommentViews.swift
        ├── Space/      SpaceView.swift（含 SpaceModel）· RelationModel.swift（含 FollowButton）
        ├── Library/    HistoryView.swift · WatchLaterView.swift · FavoritesView.swift（含收藏夹详情）· FavoriteSheet.swift · DownloadsView.swift（含缓存画质面板）
        ├── Mine/       MineView.swift（含 LoginView）
        └── Settings/   SettingsView.swift
```

---

## 11. 里程碑

| 周 | 目标 |
|---|---|
| W1 | 在 Mac 上编译跑通骨架，修 API 差异；推荐流出数据 |
| W2 | 登录、详情、MP4 播放、弹幕上屏；Instruments 跑一轮性能基线 |
| W3 | 横屏全屏播放器：真机调手势手感、旋转动画、抽屉性能 |
| W4 | 搜索、评论、历史 / 稍后再看 / 收藏 |
| W5 | DASH → 本地 HLS，画质切换，AV1/HEVC |
| W6 | 迷你播放条、画中画、Songti 字体下载、打磨与性能回归 |

---

## 12. 风险

| 风险 | 对策 |
|---|---|
| 接口变更 / 风控 | 接口集中在 `Endpoint`；补齐 buvid、WBI；控制频率 |
| 账号安全 | 只用官方扫码登录；Cookie 由系统 Cookie 存储保管（沙盒 + 数据保护），`refresh_token` 存 Keychain（仅本机），退出时全部清除（§9） |
| 无法上架 | 个人自用；免费账号 7 天重签，或付费账号 TestFlight |
| DASH 复杂 | 已实现 DASH→本地 HLS + FFmpeg 兜底引擎，失败逐级降级 |
| **Windows 开发环境** | iOS 编译**必须在 macOS + Xcode 26**；Windows 可写代码，构建用 Mac 或云端 macOS CI |
| 骨架未经编译 | 代码在 Windows 上编写，未经 Xcode 编译；首次在 Mac 上构建预计要修一些 API 细节 |

### 侧滑返回（`App/BackGesture.swift`）
- 各页面隐藏了系统导航栏（自绘玻璃顶栏），系统随之关掉了左边缘返回手势；在根页面背景放一个探针视图控制器，找到承载 NavigationStack 的 UINavigationController，接管边缘返回手势的 delegate 重新打开
- iOS 26 的全屏内容返回手势（从页面任意位置向右划）也一并打开，沿用系统自己的 delegate 处理与横向列表的冲突
- 根页面（首页 / 动态 / 我的）不触发；横屏全屏播放时关掉（那里左右滑是拖进度），退出全屏或离开视频页恢复
- 视频页不在导航栈里：它打开时关掉导航栈的返回手势，由舞台自己的边缘手势接管（跟手收进胶囊 / 卡片）
