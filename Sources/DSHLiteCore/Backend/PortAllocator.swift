import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 端口分配器：绑定 127.0.0.1:0 获取系统随机端口，释放后返回。
///
/// 注意：从释放到 DSH bind 之间存在极小的 TOCTOU 窗口，由 BackendSupervisor
/// 的重试策略兜底（最多 3 次，每次重新申请端口）。
public enum PortAllocator {
    /// 分配一个空闲随机端口。
    /// 通过 Darwin socket 显式绑定 IPv4 loopback，获取系统分配的端口号后立即关闭。
    public static func allocate() async throws -> UInt16 {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw PortAllocatorError.system(errno) }
            defer { Darwin.close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(0).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else { throw PortAllocatorError.system(errno) }
            var bound = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard nameResult == 0, bound.sin_port != 0 else { throw PortAllocatorError.noPortAssigned }
            return UInt16(bigEndian: bound.sin_port)
    }
}

public enum PortAllocatorError: Error, LocalizedError {
    case noPortAssigned
    case system(Int32)

    public var errorDescription: String? {
        switch self {
        case .noPortAssigned:
            return "系统未分配端口"
        case .system(let code):
            return String(cString: strerror(code))
        }
    }
}
