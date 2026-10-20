import Foundation
import CryptoKit
import CommonCrypto

// Second way of switching the TV on: the PlayStation 5 plugged into it. In rest mode the PS5 keeps
// its network up and answers the discovery protocol of the Remote Play app (UDP 9302). A WAKEUP
// carrying the credential obtained once by "Link Device" wakes it, and with "Enable HDMI Device
// Link" the console turns the TV on through HDMI-CEC (SIMPLINK) and selects its own input.
//
// The registration exchange is the one the Remote Play app does, as documented by the chiaki-ng
// and playactor projects: a search on UDP 9295, then an HTTP POST whose body is 480 bytes of
// padding carrying an obfuscated nonce, followed by the account id encrypted with AES-128-CFB
// under a key derived from the PIN. The key tables at the end follow playactor (ISC); see
// THIRD_PARTY_NOTICES.md.

enum PlayStationError: LocalizedError {
    case network(String)
    case notFound
    case timeout
    case alreadyAwake
    case notRegistered
    case badPIN
    case badAccountId
    case rejected(Int, String?)
    case badResponse(String)
    case psn(String)

    var errorDescription: String? {
        switch self {
        case .network(let why): return "Não consegui falar com o PS5 (\(why))."
        case .notFound:
            return "O PS5 não respondeu na rede. Ele está na tomada e com 'Permanecer conectado à internet' no modo de repouso?"
        case .timeout: return "O PS5 não acordou a tempo."
        case .alreadyAwake: return "O PS5 já estava ligado; ele só tenta ligar a TV quando sai do repouso."
        case .notRegistered: return "O app ainda não está registrado no PS5."
        case .badPIN: return "O PIN tem 8 números, como aparece em Vincular dispositivo."
        case .badAccountId:
            return "Não reconheci a conta PSN. Cole o endereço da página final do login ou o ID de 12 caracteres."
        case .rejected(let status, let reason): return "O PS5 recusou o registro (\(reason ?? "HTTP \(status)"))."
        case .badResponse(let why): return "Resposta inesperada do PS5 (\(why))."
        case .psn(let why): return "O login na PSN não deu certo (\(why))."
        }
    }
}

/// The console registered to switch the TV on. Saved apart from config.json, which the Python
/// CLI also rewrites.
struct PlayStationConsole: Codable, Equatable, Identifiable {
    var name: String                 // host-name, e.g. "PS5-123"
    var host: String                 // last known IPv4 address
    var hostId: String               // host-id: its MAC address, without separators
    var systemVersion: String? = nil
    var registered: Bool = false
    var accountId: String? = nil     // PSN account id (8 bytes, base64) used in the registration
    var credential: String? = nil    // user-credential that the WAKEUP carries

    var id: String { hostId }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lg_roap_control/playstation.json")
    }

    static func load() -> PlayStationConsole? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PlayStationConsole.self, from: data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }

    static func forget() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// A console that answered the search, and whether it was awake or in rest mode.
struct DiscoveredPlayStation: Identifiable, Equatable {
    var console: PlayStationConsole
    var awake: Bool

    var id: String { console.hostId }
}

// MARK: - UDP helper

enum UDPExchange {
    struct Reply {
        let host: String
        let data: Data
    }

    /// Sends `payload` to every target and collects what comes back within `window` seconds; `stop`
    /// ends the wait early. Blocking: call it off the main thread.
    static func run(_ payload: Data, to targets: [String], port: UInt16, window: TimeInterval,
                    until stop: ((Reply) -> Bool)? = nil) throws -> [Reply] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw PlayStationError.network("sem socket UDP") }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var sent = 0
        for target in targets {
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = port.bigEndian
            guard inet_pton(AF_INET, target, &destination.sin_addr) == 1 else { continue }
            let result = payload.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if result >= 0 { sent += 1 }
        }
        guard sent > 0 else { throw PlayStationError.network(String(cString: strerror(errno))) }

        var replies: [Reply] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(window)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sender.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            let reply = Reply(host: String(cString: text), data: Data(buffer[0..<Int(count)]))
            replies.append(reply)
            if stop?(reply) == true { break }
        }
        return replies
    }
}

// MARK: - Discovery and wake-up (UDP 9302)

/// A device-discovery message: `HTTP/1.1 620 Server Standby` followed by `key:value` lines.
struct DDPMessage {
    let status: Int
    let fields: [String: String]

    init?(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first, first.hasPrefix("HTTP/1.1 ") else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        self.status = status
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.fields = fields
    }

    var awake: Bool { status == 200 }   // 620 = rest mode
}

enum PlayStationDiscovery {
    static let port: UInt16 = 9302
    static let protocolVersion = "00030010"   // PS5

    /// Consoles answering a search: on the whole network, or only at `host`.
    static func search(host: String? = nil, timeout: TimeInterval = 2.5) async -> [DiscoveredPlayStation] {
        let request = Data("SRCH * HTTP/1.1\ndevice-discovery-protocol-version:\(protocolVersion)\n".utf8)
        let targets = host.map { [$0] } ?? broadcastAddresses()
        let replies = await Task.detached(priority: .userInitiated) {
            (try? UDPExchange.run(request, to: targets, port: port, window: timeout,
                                  until: host == nil ? nil : { _ in true })) ?? []
        }.value
        var found: [DiscoveredPlayStation] = []
        for reply in replies {
            guard let message = DDPMessage(reply.data), let hostId = message.fields["host-id"],
                  !found.contains(where: { $0.console.hostId == hostId }) else { continue }
            let console = PlayStationConsole(name: message.fields["host-name"] ?? "PS5", host: reply.host, hostId: hostId,
                                             systemVersion: message.fields["system-version"])
            found.append(DiscoveredPlayStation(console: console, awake: message.awake))
        }
        return found
    }

    /// Where `console` is now: at its last address, or wherever it answers the broadcast (DHCP).
    static func locate(_ console: PlayStationConsole) async -> DiscoveredPlayStation? {
        if let seen = await search(host: console.host, timeout: 1.5).first(where: { $0.console.hostId == console.hostId }) {
            return seen
        }
        return await search().first(where: { $0.console.hostId == console.hostId })
    }

    /// Wakes the console from rest mode and waits until it reports itself awake. Returns the
    /// console with its current address.
    static func wake(_ console: PlayStationConsole, timeout: TimeInterval = 30) async throws -> PlayStationConsole {
        guard console.registered, let credential = console.credential else { throw PlayStationError.notRegistered }
        guard let seen = await locate(console) else { throw PlayStationError.notFound }
        if seen.awake { throw PlayStationError.alreadyAwake }
        var current = console
        current.host = seen.console.host

        let message = Data(("WAKEUP * HTTP/1.1\nclient-type:vr\nauth-type:R\nmodel:w\napp-type:r\n"
                            + "user-credential:\(credential)\ndevice-discovery-protocol-version:\(protocolVersion)\n").utf8)
        let host = current.host
        let deadline = Date().addingTimeInterval(timeout)
        var lastSent = Date.distantPast
        while Date() < deadline {
            if Date().timeIntervalSince(lastSent) >= 5 {   // the console doesn't answer the WAKEUP itself
                try await Task.detached(priority: .userInitiated) {
                    _ = try UDPExchange.run(message, to: [host], port: port, window: 0)
                }.value
                lastSent = Date()
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await search(host: host, timeout: 1.5).first?.awake == true { return current }
        }
        throw PlayStationError.timeout
    }

    private static func broadcastAddresses() -> [String] {
        var addresses = ["255.255.255.255"]
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return addresses }
        defer { freeifaddrs(interfaces) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_BROADCAST != 0, flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let broadcast = pointer.pointee.ifa_dstaddr, broadcast.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { address in
                _ = inet_ntop(AF_INET, &address.pointee.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            }
            let address = String(cString: text)
            if !address.hasPrefix("169.254."), !addresses.contains(address) { addresses.append(address) }
        }
        return addresses
    }
}

// MARK: - Registration crypto

enum RemotePlayCrypto {
    static let clientType = "dabfa2ec873de5839bee8d3f4c0239c4282c07c25c6077a2931afcf0adc0d34f"
    private static let hmacKey: [UInt8] = [0x46, 0x46, 0x87, 0xb3, 0x49, 0xca, 0x8c, 0xe8,
                                           0x59, 0xc5, 0x27, 0x0f, 0x5d, 0x7a, 0x69, 0xd6]
    private static let prefaceLength = 480

    struct Payload {
        let body: Data
        let key: [UInt8]
        let iv: [UInt8]
    }

    /// Body of the registration request; `key` and `iv` also decrypt the console's answer.
    static func registrationPayload(accountId: String, pin: UInt32, nonce: [UInt8]) throws -> Payload {
        // Filler the console ignores, except for the bytes patched below and the two it reads
        // as table offsets (0x00 and 0x18D).
        var preface = [UInt8](repeating: 0x41, count: prefaceLength)
        let key = seed(pin: pin, offset: Int(preface[0x18D] & 0x1F))
        let mark = aeropause(nonce: nonce, offset: Int(preface[0] >> 3))
        preface.replaceSubrange(0xC7..<0xCF, with: mark[8..<16])
        preface.replaceSubrange(0x191..<0x199, with: mark[0..<8])
        let iv = iv(nonce: nonce, counter: 0)
        let header = "Client-Type: \(clientType)\r\nNp-AccountId: \(accountId)\r\n"
        let encrypted = try cfb(Data(header.utf8), key: key, iv: iv, encrypt: true)
        return Payload(body: Data(preface) + encrypted, key: key, iv: iv)
    }

    /// AES key derived from the PIN.
    static func seed(pin: UInt32, offset: Int) -> [UInt8] {
        var seed = (0..<16).map { initKeys[($0 * 0x20 + offset) % initKeys.count] }
        seed[0xC] ^= UInt8(truncatingIfNeeded: pin >> 24)
        seed[0xD] ^= UInt8(truncatingIfNeeded: pin >> 16)
        seed[0xE] ^= UInt8(truncatingIfNeeded: pin >> 8)
        seed[0xF] ^= UInt8(truncatingIfNeeded: pin)
        return seed
    }

    /// The nonce, obfuscated the way the console expects to find it in the preface.
    static func aeropause(nonce: [UInt8], offset: Int) -> [UInt8] {
        (0..<16).map { i in (nonce[i] ^ aeroKeys[i * 0x20 + offset]) &+ 0xD3 &+ UInt8(i) }
    }

    /// IV for message `counter`: HMAC-SHA256 of nonce and counter, truncated.
    static func iv(nonce: [UInt8], counter: UInt64) -> [UInt8] {
        var message = Data(nonce)
        message.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: counter >> (56 - 8 * $0)) })
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(hmacKey)))
        return Array(Data(mac).prefix(16))
    }

    /// AES-128-CFB without padding, the cipher of the whole Remote Play protocol.
    static func cfb(_ input: Data, key: [UInt8], iv: [UInt8], encrypt: Bool) throws -> Data {
        var cryptor: CCCryptorRef?
        let created = CCCryptorCreateWithMode(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCMode(kCCModeCFB),
                                              CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), iv, key, key.count,
                                              nil, 0, 0, 0, &cryptor)
        guard created == kCCSuccess, let cryptor else { throw PlayStationError.badResponse("cifra indisponível") }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: input.count + 16)
        var moved = 0
        let updated = input.withUnsafeBytes { bytes in
            CCCryptorUpdate(cryptor, bytes.baseAddress, input.count, &output, output.count, &moved)
        }
        var finished = 0
        guard updated == kCCSuccess,
              CCCryptorFinal(cryptor, &output[moved], output.count - moved, &finished) == kCCSuccess else {
            throw PlayStationError.badResponse("falha na cifra")
        }
        return Data(output[0..<(moved + finished)])
    }
}

// MARK: - Registration ("Link Device", TCP 9295)

enum PlayStationRegistration {
    static let port: UInt16 = 9295

    /// Registers this app with the console, which must be on and showing Settings › System ›
    /// Remote Play › Link Device. Returns the console with its wake credential.
    static func register(_ console: PlayStationConsole, accountId: String, pin: String) async throws -> PlayStationConsole {
        let digits = pin.filter(\.isNumber)
        guard digits.count == 8, let pinNumber = UInt32(digits) else { throw PlayStationError.badPIN }
        guard let account = Data(base64Encoded: accountId), account.count == 8 else { throw PlayStationError.badAccountId }

        // The console only accepts the request right after a search on its registration port.
        let host = console.host
        let probe = Data("SRC3".utf8) + Data([0])
        let answers = try await Task.detached(priority: .userInitiated) {
            try UDPExchange.run(probe, to: [host], port: port, window: 3) { $0.data.prefix(4) == Data("RES3".utf8) }
        }.value
        guard answers.contains(where: { $0.data.prefix(4) == Data("RES3".utf8) }) else {
            throw PlayStationError.network("ele não respondeu à busca de registro; está ligado e em Vincular dispositivo?")
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        var nonce = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else {
            throw PlayStationError.badResponse("sem gerador aleatório")
        }
        let payload = try RemotePlayCrypto.registrationPayload(accountId: accountId, pin: pinNumber, nonce: nonce)
        var request = URLRequest(url: URL(string: "http://\(host):\(port)/sie/ps5/rp/sess/rgst")!)
        request.httpMethod = "POST"
        request.httpBody = payload.body
        request.timeoutInterval = 15
        request.setValue("remoteplay Windows", forHTTPHeaderField: "User-Agent")
        request.setValue("1.0", forHTTPHeaderField: "RP-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PlayStationError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw PlayStationError.badResponse("sem resposta HTTP") }
        guard http.statusCode == 200 else {
            let reason = http.value(forHTTPHeaderField: "RP-Application-Reason")
            throw PlayStationError.rejected(http.statusCode, reason.map(describe(reason:)))
        }

        let plain = try RemotePlayCrypto.cfb(data, key: payload.key, iv: payload.iv, encrypt: false)
        let fields = parseFields(plain)
        guard let registKey = fields["PS5-RegistKey"], let credential = credential(fromRegistKey: registKey) else {
            throw PlayStationError.badResponse("sem chave de registro")
        }
        var registered = console
        registered.registered = true
        registered.accountId = accountId
        registered.credential = credential
        if let nickname = fields["PS5-Nickname"], !nickname.isEmpty { registered.name = nickname }
        if let mac = fields["PS5-Mac"], mac.count == 12 { registered.hostId = mac.uppercased() }
        return registered
    }

    /// `Key: Value` lines of the decrypted answer.
    static func parseFields(_ data: Data) -> [String: String] {
        var fields: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    /// The RegistKey comes hex-encoded; decoded, it is the text of a hexadecimal number, and the
    /// WAKEUP wants that number in decimal.
    static func credential(fromRegistKey registKey: String) -> String? {
        guard let bytes = Data(hex: registKey), let text = String(data: bytes, encoding: .utf8) else { return nil }
        let number = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        return UInt64(number, radix: 16).map(String.init)
    }

    private static func describe(reason: String) -> String {
        switch reason.lowercased() {
        case "80108b09": return "PIN incorreto ou registro recusado"
        case "80108b02": return "conta PSN inválida"
        case "80108b10": return "a Reprodução Remota já está em uso"
        case "80108b15": return "a Reprodução Remota travou no console"
        case "80108b11": return "versão do protocolo incompatível"
        default: return "código \(reason)"
        }
    }
}

// MARK: - PSN account id

enum PSNAccount {
    // The Remote Play app for Windows: its login is what gives out the account id in the format
    // the console expects.
    private static let clientId = "ba495a24-818c-472b-b12d-ff231c1b5745"
    private static let clientSecret = "mvaiZkRsAsI1IBkY"
    private static let redirectURI = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    private static let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!

    static let loginURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize"
                              + "?service_entity=urn:service-entity:psn&response_type=code&client_id=\(clientId)"
                              + "&redirect_uri=\(redirectURI)&scope=psn:clientapp&request_locale=en_US&ui=pr"
                              + "&service_logo=ps&layout_type=popup&smcid=remoteplay&prompt=always&PlatformPrivacyWs1=minimal&")!

    /// The page the login ends on; its address carries the code.
    static func isRedirect(_ url: URL) -> Bool {
        url.host == "remoteplay.dl.playstation.net" && url.path.hasPrefix("/remoteplay/redirect")
    }

    /// The account id (8 bytes, base64) from the address of the page the login ends on, or from
    /// the id itself when the user already has it.
    static func accountId(from input: String) async throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = Data(base64Encoded: text), data.count == 8 { return text }
        guard let components = URLComponents(string: text),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw PlayStationError.badAccountId
        }
        let token = try await accessToken(code: code)
        let info = try await json(request(url: tokenURL.appendingPathComponent(token)))
        let userId = (info["user_id"] as? String).flatMap(UInt64.init) ?? (info["user_id"] as? NSNumber)?.uint64Value
        guard var number = userId?.littleEndian else { throw PlayStationError.psn("resposta sem o id da conta") }
        return Data(bytes: &number, count: 8).base64EncodedString()
    }

    private static func accessToken(code: String) async throws -> String {
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "authorization_code"),
                           URLQueryItem(name: "code", value: code),
                           URLQueryItem(name: "redirect_uri", value: redirectURI)]
        var request = request(url: tokenURL)
        request.httpMethod = "POST"
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        guard let token = try await json(request)["access_token"] as? String, !token.isEmpty else {
            throw PlayStationError.psn("o código do login não foi aceito; faça o login de novo")
        }
        return token
    }

    private static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let basic = Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func json(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PlayStationError.psn(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PlayStationError.psn("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlayStationError.psn("resposta ilegível")
        }
        return object
    }
}

// MARK: - Key tables (PS5), as published by the chiaki-ng and playactor projects

extension RemotePlayCrypto {
    static let initKeys: [UInt8] = [
        0x24, 0xd8, 0xc2, 0x69, 0x4c, 0x67, 0x78, 0x71, 0xee, 0x31, 0xbd, 0x2b, 0x83, 0xb2, 0x1d, 0x61,
        0xc9, 0xa7, 0x8e, 0xed, 0x9a, 0xd3, 0x6a, 0x6b, 0x5c, 0xc8, 0x35, 0x79, 0xa7, 0x24, 0xe2, 0x17,
        0x06, 0x60, 0x2e, 0xdf, 0xf4, 0xdb, 0x27, 0x10, 0x55, 0xd9, 0xea, 0x16, 0x4e, 0x90, 0x0c, 0xbf,
        0x40, 0x6f, 0x54, 0xa5, 0x31, 0x70, 0x2d, 0x5d, 0x1e, 0x27, 0xdf, 0x37, 0x40, 0xba, 0x9d, 0x5d,
        0xff, 0xe1, 0x05, 0x70, 0x80, 0xd4, 0xb7, 0xc2, 0x96, 0x7f, 0x2f, 0x42, 0xeb, 0x5a, 0x08, 0xde,
        0xc1, 0xb5, 0x52, 0x15, 0xf6, 0xb5, 0xf2, 0xd9, 0x69, 0xa5, 0xc7, 0xc4, 0x7f, 0x46, 0x64, 0xa4,
        0xfd, 0x46, 0x98, 0xa7, 0xe1, 0x2a, 0x8e, 0x6f, 0xaf, 0x65, 0x42, 0x28, 0xb9, 0xc2, 0x6f, 0x3e,
        0xe3, 0xe4, 0x4e, 0xe4, 0x5b, 0x9d, 0x60, 0x10, 0xb8, 0x5a, 0xb0, 0x7d, 0x04, 0x0c, 0x4c, 0x24,
        0x78, 0xbd, 0xb8, 0xba, 0xdb, 0x8f, 0xe3, 0xa0, 0x75, 0x6d, 0x28, 0xc2, 0x33, 0x5b, 0x32, 0x83,
        0xdd, 0x51, 0xb0, 0xa5, 0x8d, 0x09, 0x66, 0xe4, 0x5c, 0xb8, 0x70, 0x0b, 0xe6, 0x82, 0x14, 0xb6,
        0xd2, 0xb0, 0xc2, 0xe0, 0x55, 0xf3, 0x84, 0xad, 0x9d, 0x3a, 0xf8, 0x77, 0xf5, 0x9d, 0x9a, 0xa9,
        0x7d, 0xf1, 0x45, 0x1b, 0x9b, 0x55, 0x25, 0xd8, 0xc1, 0xff, 0x03, 0xa5, 0x48, 0x0b, 0x1b, 0x19,
        0x0c, 0xbd, 0xe0, 0xcd, 0x48, 0xf3, 0x2c, 0x99, 0x19, 0xd6, 0xb8, 0xbb, 0xd6, 0x35, 0x43, 0x6f,
        0x71, 0xe3, 0xef, 0x3e, 0x97, 0xb8, 0xe9, 0x40, 0xa8, 0x47, 0xe0, 0xe0, 0x01, 0x16, 0x9d, 0xa7,
        0xe5, 0x94, 0x4b, 0x1d, 0xd2, 0x80, 0xa2, 0x7f, 0xf2, 0x98, 0x10, 0x38, 0x0d, 0xb8, 0x56, 0xc3,
        0x7a, 0x4b, 0x4c, 0x85, 0xec, 0x2f, 0x23, 0x89, 0xaf, 0xd5, 0xba, 0x9a, 0xad, 0xb0, 0x61, 0x9c,
        0x51, 0xb4, 0x6d, 0x02, 0x49, 0x26, 0xa4, 0x34, 0x84, 0x20, 0x35, 0x30, 0x23, 0x0a, 0x47, 0x14,
        0x32, 0x1a, 0x96, 0x0e, 0xe8, 0x0f, 0x96, 0x96, 0xd4, 0xba, 0x68, 0x3a, 0x67, 0x15, 0x74, 0xe0,
        0xd6, 0x60, 0x4c, 0x68, 0x50, 0x73, 0x14, 0x2f, 0x11, 0x59, 0xac, 0xc8, 0x32, 0xd1, 0xdb, 0x4c,
        0x8a, 0x94, 0x75, 0x33, 0x61, 0xd1, 0xd4, 0xfd, 0xaa, 0x6a, 0x61, 0x68, 0xd8, 0xae, 0x31, 0x4f,
        0xb8, 0x07, 0x7b, 0x27, 0x0f, 0xf9, 0x0b, 0xb0, 0xc2, 0x64, 0xb3, 0x72, 0xea, 0x8b, 0x87, 0x40,
        0x09, 0xb4, 0x82, 0xb4, 0xad, 0x76, 0xf9, 0x36, 0x05, 0x60, 0x89, 0xc8, 0x20, 0xeb, 0xa5, 0xf1,
        0x51, 0x0b, 0x27, 0xa7, 0xf0, 0x76, 0x84, 0x96, 0xeb, 0xb1, 0x2e, 0xc2, 0x85, 0x28, 0xbc, 0x48,
        0x34, 0xd4, 0x01, 0x8d, 0x5b, 0x25, 0x54, 0xe0, 0xc4, 0x4f, 0xa0, 0xfa, 0x99, 0x8d, 0x6d, 0x7a,
        0x64, 0xb1, 0xa9, 0x5d, 0xa4, 0xf9, 0xf5, 0x22, 0xeb, 0x9a, 0xf4, 0xa8, 0x7a, 0x78, 0x4b, 0x7f,
        0xe2, 0x8b, 0x04, 0x50, 0x43, 0x7d, 0x26, 0x2d, 0x19, 0x98, 0x38, 0x6a, 0x4f, 0x2d, 0x30, 0x15,
        0x2e, 0x4f, 0xcd, 0xb9, 0xce, 0x9e, 0x8d, 0x12, 0xc9, 0xfe, 0x33, 0x8b, 0x84, 0xce, 0x5b, 0x40,
        0xe3, 0x7f, 0x72, 0x6d, 0x6c, 0x8a, 0x6a, 0x9e, 0x54, 0xf1, 0xe3, 0x64, 0x5d, 0x6e, 0x7f, 0xac,
        0x1a, 0xe7, 0xf7, 0xfa, 0x00, 0x22, 0xed, 0x2b, 0x23, 0xfa, 0x58, 0xc5, 0xeb, 0x44, 0x92, 0x5d,
        0xcc, 0xaa, 0x82, 0x9f, 0x23, 0xfb, 0xa6, 0xc9, 0x65, 0x2a, 0xe0, 0x79, 0x12, 0x65, 0x2c, 0x34,
        0xc5, 0x23, 0x16, 0xc9, 0xcc, 0x05, 0x30, 0xf3, 0x96, 0x0b, 0x90, 0x67, 0x1a, 0xa7, 0x69, 0x4c,
        0x3e, 0x43, 0x24, 0x9d, 0x4e, 0x68, 0xbd, 0x8b, 0x75, 0x6e, 0x9d, 0x07, 0x6f, 0x1a, 0x6a, 0xba,
    ]

    static let aeroKeys: [UInt8] = [
        0x79, 0x4d, 0x78, 0x30, 0xfe, 0x10, 0x52, 0x4c, 0xa8, 0x90, 0x5b, 0x9a, 0x7e, 0x5f, 0xd3, 0xe1,
        0x13, 0xe0, 0xf1, 0x0f, 0xa3, 0xe7, 0xbb, 0x45, 0x7f, 0xdc, 0x8e, 0xd5, 0xf1, 0x04, 0x5c, 0x78,
        0x51, 0xef, 0xf8, 0x65, 0x59, 0x03, 0x39, 0x84, 0x37, 0xae, 0x59, 0xdf, 0x23, 0xb6, 0x60, 0x34,
        0xe6, 0x4b, 0xe2, 0xf5, 0x4c, 0x13, 0xc6, 0xda, 0xf9, 0xfd, 0xb3, 0x65, 0x84, 0xd6, 0x45, 0xec,
        0x2c, 0x00, 0xf2, 0xed, 0xdc, 0xcb, 0x93, 0x6e, 0x61, 0x46, 0xe5, 0xd6, 0x01, 0x94, 0xee, 0x78,
        0x85, 0x0e, 0x68, 0x5e, 0xb5, 0x5b, 0xcd, 0xd3, 0x63, 0x41, 0xfc, 0x81, 0x43, 0x1c, 0x6f, 0x7c,
        0xba, 0xe8, 0xbd, 0x86, 0x31, 0xd5, 0x70, 0x7f, 0xb5, 0x4a, 0x90, 0x3e, 0x84, 0xe1, 0x71, 0xe0,
        0x02, 0x99, 0xf4, 0x71, 0xe7, 0x02, 0xed, 0x36, 0xaf, 0xde, 0x56, 0xc2, 0x90, 0xe0, 0xae, 0xc2,
        0xf9, 0xaf, 0x53, 0xc6, 0xd8, 0x62, 0x16, 0x32, 0x27, 0xfb, 0x6e, 0x9b, 0x48, 0xc6, 0xea, 0xff,
        0x6f, 0x78, 0x02, 0x22, 0x98, 0x2c, 0x1f, 0xbf, 0xb0, 0x8e, 0xa9, 0x39, 0xbc, 0xdf, 0x17, 0xde,
        0xd7, 0x0e, 0xe1, 0x7a, 0x01, 0x0e, 0xc3, 0x87, 0xfc, 0xaa, 0xe4, 0x6b, 0x0f, 0x5b, 0x0a, 0xf1,
        0x18, 0x19, 0x8a, 0xe5, 0x2c, 0x36, 0x9b, 0x40, 0x30, 0x99, 0x24, 0x94, 0x48, 0xd7, 0x47, 0xb2,
        0xaf, 0x6b, 0x8c, 0x40, 0x9e, 0x4d, 0x6d, 0x34, 0x07, 0xc1, 0x26, 0x2f, 0xbb, 0x14, 0xf7, 0xbc,
        0x36, 0x52, 0xbd, 0x84, 0xfe, 0x4a, 0x9a, 0xf4, 0x8a, 0xdb, 0x34, 0x89, 0xaa, 0xf1, 0x0d, 0x94,
        0x0b, 0x92, 0xf4, 0x1c, 0xe4, 0x6c, 0x79, 0x2d, 0x6e, 0xc0, 0x19, 0x0a, 0xd5, 0x55, 0x94, 0x14,
        0x05, 0x13, 0xc2, 0x62, 0x23, 0xb3, 0xd4, 0x26, 0xc4, 0x44, 0x56, 0x7a, 0xcd, 0x1c, 0xea, 0xd4,
        0x74, 0xb9, 0x36, 0x40, 0x9f, 0x08, 0xfb, 0x49, 0x62, 0x05, 0x92, 0x98, 0xad, 0x1d, 0x9f, 0x8a,
        0x76, 0x8b, 0xd4, 0x0f, 0x21, 0x40, 0x76, 0xb6, 0x16, 0x91, 0x45, 0x93, 0x66, 0xcc, 0x12, 0xea,
        0x4d, 0xf4, 0x09, 0xe2, 0xac, 0x33, 0xd0, 0x6f, 0x43, 0x51, 0x07, 0x3e, 0xd7, 0x95, 0x2c, 0x1e,
        0x1f, 0x0c, 0x24, 0xb3, 0x0e, 0x3a, 0xef, 0x95, 0xf5, 0xeb, 0x77, 0xdd, 0x20, 0xf2, 0x35, 0x98,
        0xf2, 0xae, 0xa9, 0x66, 0xe6, 0x13, 0xef, 0x5d, 0x3a, 0x2d, 0x66, 0xed, 0xe2, 0x1e, 0xe9, 0x32,
        0x4a, 0x40, 0xbf, 0x37, 0xc6, 0x70, 0x29, 0xd9, 0x8c, 0xa1, 0x61, 0x4a, 0x29, 0x3d, 0xc7, 0x55,
        0x9c, 0x94, 0x9e, 0xc9, 0x11, 0x45, 0x10, 0x28, 0xa7, 0x27, 0xd1, 0xd3, 0xd0, 0x84, 0x79, 0xc7,
        0xa9, 0xb0, 0xf6, 0xaf, 0x45, 0x8c, 0x3c, 0xd4, 0xdf, 0x3b, 0xf7, 0x0d, 0xa2, 0x4f, 0x13, 0x97,
        0x78, 0x27, 0xf0, 0x48, 0xc0, 0xa5, 0xab, 0x83, 0x01, 0x05, 0xd0, 0x12, 0xd7, 0x1e, 0x12, 0x3a,
        0x4e, 0x98, 0x77, 0xae, 0xba, 0xb1, 0x4e, 0xb5, 0x3b, 0x59, 0xca, 0x6d, 0xa5, 0x11, 0x80, 0x91,
        0x9c, 0x07, 0x69, 0x59, 0x5a, 0x53, 0x70, 0x7c, 0x95, 0x97, 0x11, 0x6d, 0x66, 0x8d, 0xa3, 0xbd,
        0xbb, 0x2d, 0xb0, 0xbf, 0x9b, 0x10, 0xcb, 0xc7, 0x0f, 0x5b, 0x7e, 0x67, 0xe2, 0xb0, 0x4b, 0xba,
        0x10, 0x12, 0xb9, 0xbc, 0x97, 0xfd, 0x48, 0xe4, 0x8a, 0xc1, 0x0f, 0xa1, 0x30, 0x9d, 0x56, 0x20,
        0x24, 0x1a, 0x7d, 0x5b, 0xa0, 0xb4, 0xbe, 0x9d, 0x38, 0x4f, 0xb4, 0x56, 0xa8, 0x4d, 0x13, 0x7c,
        0x44, 0xe8, 0x84, 0x97, 0xeb, 0x78, 0x2c, 0x52, 0x85, 0xe4, 0xa2, 0xf6, 0xf3, 0xd9, 0x71, 0x9e,
        0xee, 0xb8, 0x11, 0x47, 0xfb, 0xa9, 0x1b, 0xc7, 0x40, 0xc6, 0xe1, 0x19, 0x6d, 0x50, 0xa1, 0x2a,
    ]
}
