import Foundation

/// 全局 AppState 持有者（供 AppDelegate / 非 SwiftUI 上下文访问）。
@MainActor
public final class AppStateHolder {
    public static let shared = AppStateHolder()
    public var state: AppState?
    private init() {}
}
