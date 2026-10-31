import Foundation
import Network
import Darwin

// MARK: - Discovered LG TV Model

struct DiscoveredLGTV: Identifiable, Equatable {
    var host: String
    var port: Int
    var model: String?
    var name: String?
    var mac: String?
    var uuid: String?

    var id: String { mac ?? uuid ?? host }
}

// MARK: - LG TV Discovery & Relocation Engine

enum LGTVDiscovery {
    static let ssdpPort: UInt16 = 1900
    static let bcastPort: UInt16 = 1990
    static let defaultPort: Int = 8080

    /// Search for the TV's DLNA renderer, a server of its own on the TV. Every answer to a UDAP search
    /// (udap:rootservice) puts LG's discovery popup on screen instead: "model_XX", a phone pointing at
    /// the TV and a "Pairing Key" field (UDAP 2.0 spec, "Host screen after discovery response").
    static let dlnaSearch = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSER-AGENT: macOS/1.0 UPnP/1.1 lg_roap_control/1.0.0\r\n\r\n"

    /// Quick probe to check if a TV answers HTTP on `host:port`.
    static func probeHost(_ host: String, port: Int = defaultPort, timeout: TimeInterval = 1.0) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/roap/api/data?target=volume_info") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("Close", forHTTPHeaderField: "Connection")
        req.setValue("lg_roap_control/1.0.0 (macOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return false }
            return http.statusCode == 200 || http.statusCode == 401
        } catch {
            return false
        }
    }

    /// Locates the LG TV matching `config` (by current IP, ARP table cache, or SSDP discovery).
    /// The SSDP step searches through DLNA; `allowUDAP` (a search the user asked for) falls back to
    /// the UDAP search, which shows the discovery popup on the TV.
    static func locate(matching config: TVConfig, allowUDAP: Bool = false) async -> String? {
        let port = config.port > 0 ? config.port : defaultPort

        // 1. Fast check: is the currently configured host responding?
        if await probeHost(config.host, port: port) {
            return config.host
        }

        // 2. Fast check: ARP cache by MAC (instantaneous, 0 network overhead)
        if let mac = config.mac, let arpIP = ARPCache.ip(for: mac), !arpIP.isEmpty {
            if await probeHost(arpIP, port: port) {
                return arpIP
            }
        }

        // 3. SSDP: DLNA first, UDAP only when the user asked for the search
        if let host = match(config, in: await search(timeout: 2.0, udap: false)) {
            return host
        }
        guard allowUDAP else { return nil }
        return match(config, in: await search(timeout: 2.0, udap: true))
    }

    private static func match(_ config: TVConfig, in found: [DiscoveredLGTV]) -> String? {
        // Match by MAC
        if let mac = config.mac {
            let cleanMac = mac.lowercased()
            if let match = found.first(where: { $0.mac?.lowercased() == cleanMac }) {
                return match.host
            }
        }

        // Match by Name or Model
        if let name = config.name, let match = found.first(where: { $0.name == name }) {
            return match.host
        }
        if let model = config.model, let match = found.first(where: { $0.model == model }) {
            return match.host
        }

        // If only one LG NetCast TV was found on the local network, that's our TV
        if found.count == 1 {
            return found[0].host
        }

        return nil
    }

    /// Searches for LG NetCast TVs on the local network via SSDP: the DLNA renderer search, plus
    /// with `udap` the UDAP search in multicast and broadcast.
    static func search(timeout: TimeInterval = 2.0, udap: Bool = false) async -> [DiscoveredLGTV] {
        let candidateIPs = await Task.detached(priority: .userInitiated) {
            discoverCandidates(timeout: timeout, udap: udap)
        }.value

        var results: [DiscoveredLGTV] = []
        for ip in candidateIPs {
            if let tv = await inspectTV(host: ip, udap: udap) {
                results.append(tv)
            }
        }
        return results
    }

    /// Sends the SSDP searches (M-SEARCH, and B-SEARCH with `udap`) and collects sender IP addresses.
    private static func discoverCandidates(timeout: TimeInterval, udap: Bool) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { Darwin.close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var ttl: u_char = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<u_char>.size))

        if udap {
            let msearchRootservice = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: udap:rootservice\r\nUSER-AGENT: macOS/1.0 UDAP/2.0 lg_roap_control/1.0.0\r\n\r\n"
            let bsearchRootservice = "B-SEARCH * HTTP/1.1\r\nHOST: 255.255.255.255:1990\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: udap:rootservice\r\nUSER-AGENT: macOS/1.0 UDAP/2.0 lg_roap_control/1.0.0\r\n\r\n"
            sendUDP(payload: msearchRootservice, to: "239.255.255.250", port: ssdpPort, fd: fd)
            sendUDP(payload: bsearchRootservice, to: "255.255.255.255", port: bcastPort, fd: fd)
        }
        sendUDP(payload: dlnaSearch, to: "239.255.255.250", port: ssdpPort, fd: fd)

        var foundIPs = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(remaining * 1000))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }

            var sender = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buffer, buffer.count, 0, sa, &len)
                }
            }
            guard count > 0 else { continue }

            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sender.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: text)

            let replyStr = String(data: Data(buffer[0..<Int(count)]), encoding: .utf8) ?? ""
            if replyStr.contains("UDAP") || replyStr.contains("47LN5700") || replyStr.contains("rootservice") || replyStr.contains("LG Electronics") {
                foundIPs.insert(ip)
            } else if replyStr.contains("HTTP/1.1 200") && (replyStr.contains("udap:rootservice") || replyStr.contains("MediaRenderer")) {
                foundIPs.insert(ip)
            }
        }

        return Array(foundIPs)
    }

    private static func sendUDP(payload: String, to host: String, port: UInt16, fd: Int32) {
        guard let data = payload.data(using: .utf8) else { return }
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &dest.sin_addr) == 1 else { return }

        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, bytes.baseAddress, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Fetches details from rootservice.xml (with `udap`) or volume_info on the candidate IP.
    private static func inspectTV(host: String, port: Int = defaultPort, udap: Bool) async -> DiscoveredLGTV? {
        // Try rootservice.xml with UDAP/2.0 User-Agent
        if udap, let url = URL(string: "http://\(host):\(port)/udap/api/data?target=rootservice.xml") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            req.setValue("Close", forHTTPHeaderField: "Connection")
            req.setValue("macOS/1.0 UDAP/2.0 lg_roap_control/1.0.0", forHTTPHeaderField: "User-Agent")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let xml = String(data: data, encoding: .utf8) {
                let model = LGTVClient.extractXMLTag(from: xml, tag: "modelName")
                let name = LGTVClient.extractXMLTag(from: xml, tag: "friendlyName")
                let uuid = LGTVClient.extractXMLTag(from: xml, tag: "uuid")
                return DiscoveredLGTV(host: host, port: port, model: model, name: name, mac: ARPCache.mac(for: host), uuid: uuid)
            }
        }

        // Fallback: check if volume_info endpoint exists (returns 200 or 401). The MAC is read after
        // the request, which is what puts a host found by the search in the ARP cache.
        if await probeHost(host, port: port) {
            return DiscoveredLGTV(host: host, port: port, model: nil, name: nil, mac: ARPCache.mac(for: host), uuid: nil)
        }

        return nil
    }
}
