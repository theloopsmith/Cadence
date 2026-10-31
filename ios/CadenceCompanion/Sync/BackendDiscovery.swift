import Combine
import Foundation

/// Bonjour only supplies candidate addresses. Normal sign-in and server identity
/// checks still decide which account/server owns this phone's queued records.
final class BackendDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    struct Server: Identifiable {
        var id: String { address }
        let name: String
        let address: String
    }
    @Published private(set) var servers: [Server] = []
    @Published private(set) var message = ""
    private let browser = NetServiceBrowser()
    private var searchTimeout: DispatchWorkItem?
    private var services: [NetService] = []

    override init() { super.init(); browser.delegate = self }

    func start() {
        stop()
        servers = []
        message = "Looking for your Mac on this Wi-Fi… Allow Local Network access when asked."
        browser.searchForServices(ofType: "_cadence._tcp.", inDomain: "local.")
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.servers.isEmpty else { return }
            self.message = "No Mac found yet. Start the phone server on your Mac, check Wi-Fi and Local Network permission, or enter its address below."
        }
        searchTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    func stop() {
        searchTimeout?.cancel(); searchTimeout = nil
        browser.stop()
        for service in services { service.stop(); service.delegate = nil }
        services = []
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 8)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        let address = "http://\(host.trimmingCharacters(in: CharacterSet(charactersIn: "."))):\(sender.port)"
        servers.removeAll { $0.address == address }
        servers.append(Server(name: sender.name, address: address))
        message = "Choose your Mac, then sign in with the phone account printed by the Mac setup."
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        if let host = service.hostName {
            let address = "http://\(host.trimmingCharacters(in: CharacterSet(charactersIn: "."))):\(service.port)"
            servers.removeAll { $0.address == address }
        }
        service.stop()
        services.removeAll { $0 == service }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        message = "Discovery is unavailable. Allow Local Network access in iPhone Settings, or enter the Mac address printed by setup."
    }
}
