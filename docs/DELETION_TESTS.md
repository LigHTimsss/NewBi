# 本人内容删除：验证说明

## 实现边界

- 仅作者 UID 与登录 UID 相同的内容显示入口；网络提交前还检查 Cookie 的 DedeUserID，并固定该请求使用的 Cookie。切换账号、取消确认都不发起删除。
- 动态：JSON POST `/x/dynamic/feed/operate/remove?csrf=...`，正文 `dyn_id_str`。
- 评论：表单 POST `/x/v2/reply/del`，包含 `oid/type/rpid/csrf`；一级评论和楼中楼共用入口。
- 视频：官方管理页完成删除及验证，NewBi 不伪造验证结果，不自动点击删除。页面收到 `/x/web/archive/delete` 的成功响应后，仅匹配这次选择的 aid 才更新本地。管理页改版导致无法识别时，不猜测成功；返回列表后下拉刷新核对。
- 不删除离线缓存文件，不批量删除。视频删除入口会明确说明这是删除线上稿件。

## 接口证据（2026-11-08 查阅）

- [bpi-rs 动态删除实现](https://docs.rs/bpi-rs/latest/src/bpi_rs/creativecenter/opus.rs.html)：动态 id 放 JSON，csrf 放 query。
- [评论操作接口记录](https://github.com/melon-444/bilibili-API-collect-fork/blob/master/docs/comment/action.md)：评论删除 POST 参数。
- [biliup-app-new 稿件删除实现](https://github.com/biliup/biliup-app-new/blob/master/src-tauri/src/commands/archive_delete.rs)：删除稿件涉及极验 / 短信，最后提交 `/x/web/archive/delete`。这些为第三方实现参考，不是 B 站对接口稳定性的承诺。

## 自动检查

运行 `node Tests/video-deletion-observer.mjs`。仅用内存里的 fetch / XHR 响应测试结果观察器，不登录、不访问真实删除接口。

Swift / iOS 编译与真机验证需在 Mac 和测试设备上执行；Windows 的 Swift 语法解析不能替代编译。

## 真机回归（使用可丢弃的本人测试内容）

1. 未登录、其他作者、作者字段缺失：三个入口均不显示；不要用他人内容测试删除。
2. 自己的文字 / 图片 / 转发动态：点更多，取消后内容保留；确认后只删除当前动态。动态流和个人空间之间来回切换、下拉刷新，不应重新出现。
3. 自己的视频：长按卡片和播放器更多都能进入官方管理页；确认提示显示目标标题。关闭管理页、取消官方确认、验证失败，都不能显示「删除成功」或移除卡片。
4. 在官方管理页完成目标稿件删除：对应投稿、最近投稿、代表作、动态中的原视频投稿卡片消失；连播跳过该稿件；正在播放该稿件时停播并关闭舞台。删除另一稿件不能误将目标稿件移除（其他稿件在刷新列表后更新）。
5. 在别人视频下删除自己的评论；删除自己的一级评论；在楼中楼删除自己的回复。列表、预览同步移除；删除当前楼主评论后详情面板关闭，删除回复后重新分页不漏下一页。
6. 断网、登录过期、接口报错：失败保留内容并提示。网络中断时可能服务器已处理但客户端未收到结果，应先刷新核对，App 不自动重试删除。
7. 快速重复点确认：动态 / 评论最多一个同 id 在途请求。打开确认后切换账号，不允许沿用旧确认。
8. 列表请求仍在途时完成删除，再等旧响应返回：已删条目不能复活。检查深浅色、全屏 / 普通播放器的确认面板。
