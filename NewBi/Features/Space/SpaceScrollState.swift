import Foundation

/// 页头位置全局共享，正文阅读距离按板块保存。距离均以标签栏下沿为参照。
struct SpaceScrollState<Page: Hashable> {
    private(set) var activePage: Page
    private(set) var headerOffset: CGFloat = 0
    private(set) var collapseLimit: CGFloat = 0
    private var readingOffsets: [Page: CGFloat] = [:]

    init(activePage: Page) { self.activePage = activePage }

    func readingOffset(for page: Page) -> CGFloat { readingOffsets[page] ?? 0 }
    func scrollOffset(for page: Page) -> CGFloat { headerOffset + readingOffset(for: page) }

    mutating func select(_ page: Page) {
        // 选页不能恢复旧页头状态，否则正文还没切完，顶部就会跳动。
        activePage = page
    }

    mutating func setCollapseLimit(_ value: CGFloat) {
        let wasPinned = collapseLimit > 0 && headerOffset >= collapseLimit - 1
        collapseLimit = max(0, value)
        headerOffset = wasPinned ? collapseLimit : min(headerOffset, collapseLimit)
    }

    mutating func scroll(_ page: Page, from oldOffset: CGFloat, to newOffset: CGFloat) {
        guard page == activePage else { return }
        let delta = max(0, newOffset) - max(0, oldOffset)
        if delta > 0 {
            // 向上：先收起共享页头，再消耗正文；不会从旧板块的折叠状态跳起。
            headerOffset = min(collapseLimit, headerOffset + delta)
        } else {
            // 向下：正文先回到开头，剩余距离才展开页头。
            let remaining = max(0, -delta - readingOffset(for: page))
            headerOffset = max(0, headerOffset - remaining)
        }
        readingOffsets[page] = max(0, newOffset - headerOffset)
    }
}
