import Foundation
import Network
import Observation

/// 当前网络状况（NWPathMonitor）。App 启动时开始监听，主线程读取；
/// 用于「移动网络播放提醒」等只需要知道当下是不是蜂窝网络的地方
@MainActor
@Observable
final class NetworkStatus {
    static let shared = NetworkStatus()

    private(set) var isOnline = true
    /// 当前走蜂窝网络
    private(set) var isCellular = false
    /// 系统认为「昂贵」的网络：蜂窝或个人热点
    private(set) var isExpensive = false
    /// 低数据模式
    private(set) var isConstrained = false

    private let monitor = NWPathMonitor()

    private init() {
        // 回调在监听队列上：只取出数值，回主线程再写入被观察的属性
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let snapshot = NetworkSnapshot(path)
            Task { @MainActor [weak self] in self?.apply(snapshot) }
        }
        monitor.start(queue: DispatchQueue(label: "newbi.network-status", qos: .utility))
    }

    /// 只在值变化时写，避免无谓的界面刷新
    private func apply(_ snapshot: NetworkSnapshot) {
        if isOnline != snapshot.isOnline { isOnline = snapshot.isOnline }
        if isCellular != snapshot.isCellular { isCellular = snapshot.isCellular }
        if isExpensive != snapshot.isExpensive { isExpensive = snapshot.isExpensive }
        if isConstrained != snapshot.isConstrained { isConstrained = snapshot.isConstrained }
    }
}

private struct NetworkSnapshot: Sendable {
    let isOnline: Bool
    let isCellular: Bool
    let isExpensive: Bool
    let isConstrained: Bool

    init(_ path: NWPath) {
        isOnline = path.status == .satisfied
        isCellular = path.usesInterfaceType(.cellular)
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
    }
}
