import Foundation

// 独立回归检查，不需要播放器依赖或 iOS 模拟器：
// swiftc NewBi/Features/Space/SpaceScrollState.swift Tests/SpaceScrollStateChecks.swift -o /tmp/newbi-space-checks
// /tmp/newbi-space-checks
@main
struct SpaceScrollStateChecks {
    static func equal(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        precondition(abs(actual - expected) < 0.001, "\(message): \(actual) != \(expected)")
    }

    static func main() {
        var state = SpaceScrollState(activePage: "videos")
        state.setCollapseLimit(350)
        state.scroll("videos", from: 0, to: 1250)
        equal(state.headerOffset, 350, "投稿上滑后页头吸顶")
        equal(state.readingOffset(for: "videos"), 900, "投稿正文阅读距离")

        state.select("dynamic")
        equal(state.scrollOffset(for: "dynamic"), 350, "首次进入板块继承页头位置")
        state.scroll("dynamic", from: 350, to: 0)
        state.select("videos")
        equal(state.headerOffset, 0, "切回投稿不收起刚展开的页头")
        equal(state.scrollOffset(for: "videos"), 900, "正文相对标签栏仍读到900")
        // 可见正文距标签栏 = (headerHeight - scrollOffset) - (headerHeight - headerOffset)。
        equal(state.headerOffset - state.scrollOffset(for: "videos"), -900, "视觉阅读位置不变")

        state.scroll("videos", from: 900, to: 940)
        equal(state.headerOffset, 40, "继续上滑时从当前页头位置跟手收起")
        equal(state.readingOffset(for: "videos"), 900, "收起页头不消耗正文")
        state.scroll("videos", from: 940, to: 840)
        equal(state.headerOffset, 40, "向下先滚动正文")
        equal(state.readingOffset(for: "videos"), 800, "正文倒退100")
        state.scroll("videos", from: 840, to: -50)
        equal(state.headerOffset, 0, "正文到底后再展开页头")
        equal(state.readingOffset(for: "videos"), 0, "顶部回弹不产生负阅读距离")
        state.scroll("videos", from: -50, to: 0)
        equal(state.headerOffset, 0, "回弹复位不收起页头")

        state.scroll("videos", from: 0, to: 1350)
        state.select("dynamic")
        state.scroll("dynamic", from: 350, to: 200)
        state.select("videos")
        equal(state.headerOffset, 200, "半展开状态跨页保留")
        equal(state.readingOffset(for: "videos"), 1000, "深处阅读距离不被覆盖")
        equal(state.scrollOffset(for: "videos"), 1200, "仅补偿页头的150点差值")
        state.scroll("dynamic", from: 200, to: 0)
        equal(state.headerOffset, 200, "离屏页面的惯性回调不能改顶部")

        for _ in 0..<100 {
            state.select("dynamic")
            state.select("videos")
        }
        equal(state.headerOffset, 200, "反复切换不漂移")
        equal(state.readingOffset(for: "videos"), 1000, "反复切换不丢阅读距离")
        state.scroll("videos", from: 1200, to: 1350)
        state.setCollapseLimit(400)
        equal(state.headerOffset, 400, "资料高度变化时保持已吸顶状态")
        equal(state.readingOffset(for: "videos"), 1000, "资料高度变化不改变正文位置")
        print("SpaceScrollState regression checks passed")
    }
}
