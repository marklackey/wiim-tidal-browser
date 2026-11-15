import Foundation
import Observation
import Darwin

struct DiscoveredWiiM: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
    let url: URL

    var address: WiiMAddress? {
        guard url.scheme == "http", url.host == host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return WiiMAddress(host: host, queuePort: String(url.port ?? 80), queuePath: url.path)
    }
}

/// Bonjour is available on iOS with Local Network access. Validate each advertisement
/// through the same UPnP description parser used by the desktop app before selecting it.
@MainActor @Observable
final class WiiMDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private(set) var devices: [DiscoveredWiiM] = []
    private(set) var searching = false
    private(set) var message: String?
    @ObservationIgnored private var browser: NetServiceBrowser?
    @ObservationIgnored private var services: [NetService] = []
    @ObservationIgnored private var probes: [Task<Void, Never>] = []
    @ObservationIgnored private var hosts: Set<String> = []
    @ObservationIgnored private var generation = UUID()

    func scan() async {
        guard !searching else { return }
        stop()
        let scanID = UUID()
        generation = scanID
        devices = []
        hosts = []
        message = nil
        searching = true
        let browser = NetServiceBrowser()
        self.browser = browser
        browser.delegate = self
        browser.searchForServices(ofType: "_linkplay._tcp.", inDomain: "local.")
        do { try await Task.sleep(for: .seconds(8)) }
        catch { if generation == scanID { stop() }; return }
        guard generation == scanID else { return }
        browser.stop()
        for probe in probes { await probe.value }
        guard generation == scanID else { return }
        searching = false
        if devices.isEmpty && message == nil {
            message = "No WiiM found. Check Wi-Fi and Local Network access, or enter its IP address below."
        }
    }

    func stop() {
        generation = UUID()
        browser?.stop()
        browser = nil
        services.forEach { $0.stop() }
        services = []
        probes.forEach { $0.cancel() }
        probes = []
        searching = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard searching, services.count < 32 else { return }
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        message = "Discovery is unavailable. Allow Local Network access in iOS Settings, then try again."
        stop()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard searching else { return }
        let scanID = generation
        for data in sender.addresses ?? [] {
            guard data.count >= MemoryLayout<sockaddr_in>.size else { continue }
            let host: String? = data.withUnsafeBytes { buffer in
                guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                      pointer.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(pointer, socklen_t(data.count), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: name)
            }
            guard let host, WiiMAddress(host: host, queuePort: "49152") != nil, hosts.insert(host).inserted else { continue }
            let advertisedPort = sender.port
            probes.append(Task { [weak self] in
                let ports = advertisedPort > 0 && advertisedPort != 49152 ? [49152, advertisedPort] : [49152]
                for port in ports {
                    guard !Task.isCancelled else { return }
                    if let device = try? await TIDALCatalogClient.probeDevice(host: host, port: port), device.address != nil {
                        guard let self, !Task.isCancelled, self.generation == scanID else { return }
                        self.devices.removeAll { $0.id == device.id }
                        self.devices.append(device)
                        self.devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        return
                    }
                }
            })
        }
    }
}
