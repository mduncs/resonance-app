import Foundation
import Network
import Combine

@MainActor
@Observable
final class NetworkMonitor {
    private let monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "NetworkMonitor")
    let isInert: Bool

    private(set) var isConnected: Bool = true
    private(set) var isExpensive: Bool = false
    private(set) var connectionType: ConnectionType = .unknown

    enum ConnectionType: Sendable {
        case wifi
        case cellular
        case ethernet
        case unknown
    }

    init(inert: Bool = false) {
        self.isInert = inert
        self.monitor = inert ? nil : NWPathMonitor()
        if !inert {
            startMonitoring()
        } else {
            // Fixture launches have no live connection state. Keep this
            // deterministic and avoid creating a path-monitor source.
            self.isConnected = true
        }
    }

    convenience init(fixtureMode: Bool) {
        self.init(inert: fixtureMode)
    }

    convenience init(isInert: Bool) {
        self.init(inert: isInert)
    }

    deinit {
        monitor?.cancel()
    }

    private func startMonitoring() {
        monitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isConnected = path.status == .satisfied
                self?.isExpensive = path.isExpensive

                if path.usesInterfaceType(.wifi) {
                    self?.connectionType = .wifi
                } else if path.usesInterfaceType(.cellular) {
                    self?.connectionType = .cellular
                } else if path.usesInterfaceType(.wiredEthernet) {
                    self?.connectionType = .ethernet
                } else {
                    self?.connectionType = .unknown
                }
            }
        }
        monitor?.start(queue: queue)
    }

    func checkConnectivity() -> Bool {
        isConnected
    }
}
