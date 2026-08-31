import Foundation

/// 后端生命周期状态（UI 观察）。
public enum BackendPhase: String, Sendable {
    case stopped
    case starting
    case waitingForReady
    case ready
    case stopping
    case failed
    case restarting
}

/// UI 可观察的 DSH 后端状态快照。
public struct BackendState: Sendable, Equatable {
    public var phase: BackendPhase
    /// 当前阶段描述（Loading UI 使用）
    public var stageText: String
    /// 当前 URL（ready 后有效）
    public var currentURL: URL?
    /// 失败原因
    public var failureReason: String?
    /// 退出码
    public var exitCode: Int32?
    /// 端口
    public var port: UInt16?
    /// 崩溃重启计数
    public var restartCount: Int

    public static let initial = BackendState(
        phase: .stopped,
        stageText: "",
        currentURL: nil,
        failureReason: nil,
        exitCode: nil,
        port: nil,
        restartCount: 0
    )
}

/// 面向 UI 的状态发布器：BackendSupervisor 通过它发布状态。
/// 采用回调式（不依赖 Combine，便于在无 Xcode 宏环境下使用）。
@MainActor
public final class BackendStatePublisher {
    public private(set) var state: BackendState = .initial
    /// 状态变化回调
    public var onStateChange: ((BackendState) -> Void)?

    public init() {}

    public func publish(_ newState: BackendState) {
        state = newState
        onStateChange?(newState)
    }
}
