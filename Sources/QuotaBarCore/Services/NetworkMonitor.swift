import Foundation
import Network

/// Reports whether the system currently has a usable network path.
/// `start` must be called once; `onChange` fires on the main queue, in order, with the initial state and on every change.
public protocol NetworkMonitoring: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable (Bool) -> Void)
}

public final class NetworkMonitor: NetworkMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()

    public init() {}

    public func start(onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in onChange(path.status == .satisfied) }
        monitor.start(queue: .main)
    }

    deinit { monitor.cancel() }
}
