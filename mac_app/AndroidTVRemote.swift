import Foundation
import Network
import Security
import CryptoKit

// Client for the Android TV Remote protocol v2 (the one used by the Google TV app), spoken by the
// TV Box plugged into the LG. The LG NetCast turns its network off in standby, so the only way to
// switch it on from the network is asking the box to do it over HDMI-CEC (SIMPLINK).
//
// Ports: 6467 = pairing (once, with the code shown on screen), 6466 = remote control.
// Both are TLS with a self-signed client certificate; messages are protobuf, each one prefixed
// by its length as a varint.

enum AndroidTVError: LocalizedError {
    case certificate(String)
    case connection(String)
    case secureChannel
    case timeout
    case rejected(String)
    case wrongCode
    case notPaired
    case asleep

    var errorDescription: String? {
        switch self {
        case .certificate(let why): return "Não consegui preparar o certificado do app (\(why))."
        case .connection(let why): return "Não consegui falar com a TV Box (\(why))."
        case .secureChannel: return "A TV Box recusou a conexão segura."
        case .timeout: return "A TV Box não respondeu a tempo."
        case .rejected(let why): return "A TV Box recusou o pedido (\(why))."
        case .wrongCode: return "Código incorreto. Confira os 6 caracteres na tela da TV."
        case .notPaired: return "O app ainda não está pareado com a TV Box."
        case .asleep: return "A TV Box está em repouso e não acordou pelo Wi-Fi."
        }
    }
}

/// Android key codes the app sends to the box.
enum AndroidKey: Int {
    case power = 26
}

// MARK: - Minimal protobuf

struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }
    mutating func int(_ field: Int, _ value: Int) {
        varint(UInt64(field << 3))
        varint(UInt64(bitPattern: Int64(value)))
    }
    mutating func bytes(_ field: Int, _ value: Data) {
        varint(UInt64(field << 3 | 2))
        varint(UInt64(value.count))
        data.append(value)
    }
    mutating func string(_ field: Int, _ value: String) { bytes(field, Data(value.utf8)) }
    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }
}

/// Integer (wire type 0) and length-delimited (wire type 2) fields of a message, last one wins.
struct ProtoMessage {
    private var ints: [Int: UInt64] = [:]
    private var blobs: [Int: Data] = [:]

    init(_ raw: Data) throws {
        let data = Data(raw)   // re-based copy: indices start at 0
        var i = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < data.count, shift < 64 {
                let byte = data[i]
                i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            throw AndroidTVError.rejected("mensagem malformada")
        }
        while i < data.count {
            let key = try varint()
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: ints[field] = try varint()
            case 1: i += 8
            case 2:
                let length = Int(try varint())
                guard length >= 0, i + length <= data.count else { throw AndroidTVError.rejected("mensagem truncada") }
                blobs[field] = data.subdata(in: i..<(i + length))
                i += length
            case 5: i += 4
            default: throw AndroidTVError.rejected("tipo de campo desconhecido")
            }
        }
    }

    func has(_ field: Int) -> Bool { ints[field] != nil || blobs[field] != nil }
    func int(_ field: Int) -> Int { Int(truncatingIfNeeded: ints[field] ?? 0) }
    func message(_ field: Int) -> ProtoMessage? { blobs[field].flatMap { try? ProtoMessage($0) } }
    func string(_ field: Int) -> String? { blobs[field].flatMap { String(data: $0, encoding: .utf8) } }
}

// MARK: - TLS channel with length-prefixed messages

final class TLSChannel {
    private let host: String
    private let port: UInt16
    private let identity: SecIdentity
    private let queue = DispatchQueue(label: "androidtv.tls")
    private var connection: NWConnection?
    private var buffer = Data()
    private(set) var serverCertificate: SecCertificate?

    init(host: String, port: UInt16, identity: SecIdentity) {
        self.host = host
        self.port = port
        self.identity = identity
    }

    func open(timeout: TimeInterval = 6) async throws {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let localIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(options, localIdentity)
        }
        // The box uses a self-signed certificate; trust comes from pairing, not from a CA.
        sec_protocol_options_set_verify_block(options, { [weak self] _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            self?.serverCertificate = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
            complete(true)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                      using: NWParameters(tls: tls, tcp: tcp))
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            func finish(_ result: Result<Void, Error>) {   // always called on `queue`
                guard !finished else { return }
                finished = true
                connection.stateUpdateHandler = nil
                if case .failure = result { connection.cancel() }
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .waiting(.tls), .failed(.tls):
                    finish(.failure(AndroidTVError.secureChannel))
                case .waiting(let error), .failed(let error):
                    finish(.failure(AndroidTVError.connection(Self.describe(error))))
                case .cancelled: finish(.failure(AndroidTVError.connection("conexão cancelada")))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(AndroidTVError.timeout)) }
        }
    }

    func send(_ payload: Data) async throws {
        guard let connection else { throw AndroidTVError.connection("canal fechado") }
        var framed = ProtoWriter()
        framed.varint(UInt64(payload.count))
        let data = framed.data + payload
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: AndroidTVError.connection(Self.describe(error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Next complete message, waiting at most `timeout` seconds.
    func receive(timeout: TimeInterval = 8) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let message = takeMessage() { return message }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw AndroidTVError.timeout }
            buffer.append(try await receiveChunk(timeout: remaining))
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    private func takeMessage() -> Data? {
        var length = 0
        var shift = 0
        var index = buffer.startIndex
        while index < buffer.endIndex, shift < 35 {
            let byte = buffer[index]
            index += 1
            length |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                guard buffer.distance(from: index, to: buffer.endIndex) >= length else { return nil }
                let end = index + length
                let message = buffer.subdata(in: index..<end)
                buffer = buffer.subdata(in: end..<buffer.endIndex)
                return message
            }
            shift += 7
        }
        return nil
    }

    private func receiveChunk(timeout: TimeInterval) async throws -> Data {
        guard let connection else { throw AndroidTVError.connection("canal fechado") }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            var finished = false
            func finish(_ result: Result<Data, Error>) {   // always called on `queue`
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    finish(.success(data))
                } else if case .tls = error {
                    finish(.failure(AndroidTVError.secureChannel))
                } else if let error {
                    finish(.failure(AndroidTVError.connection(Self.describe(error))))
                } else if isComplete {
                    finish(.failure(AndroidTVError.connection("a TV Box encerrou a conexão")))
                } else {
                    finish(.success(Data()))
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(AndroidTVError.timeout)) }
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED: return "conexão recusada"
        case .posix(let code) where code == .EHOSTUNREACH || code == .EHOSTDOWN: return "aparelho fora da rede"
        case .posix(let code) where code == .ETIMEDOUT: return "tempo esgotado"
        case .dns: return "nome não encontrado na rede"
        default: return error.localizedDescription
        }
    }
}

// MARK: - Client certificate

enum AndroidTVIdentity {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lg_roap_control/androidtv", isDirectory: true)
    }
    private static var bundleURL: URL { directory.appendingPathComponent("client.p12") }
    private static var passphraseURL: URL { directory.appendingPathComponent("client.pass") }

    /// The app's certificate; created on first use and reused so pairing survives restarts.
    static func load() throws -> SecIdentity {
        if !FileManager.default.fileExists(atPath: bundleURL.path)
            || !FileManager.default.fileExists(atPath: passphraseURL.path) {
            try create()
        }
        let data = try Data(contentsOf: bundleURL)
        var options: [String: Any] = [kSecImportExportPassphrase as String: try passphrase()]
        if #available(macOS 15.0, *) {
            options[kSecImportToMemoryOnly as String] = true   // keep it out of the Keychain
        }
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let entry = (items as? [[String: Any]])?.first,
              let identity = entry[kSecImportItemIdentity as String] else {
            throw AndroidTVError.certificate("PKCS#12 \(status)")
        }
        return identity as! SecIdentity
    }

    static func certificate(of identity: SecIdentity) throws -> SecCertificate {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw AndroidTVError.certificate("certificado ilegível")
        }
        return certificate
    }

    /// Passphrase of client.p12: random, generated together with the certificate and kept next to
    /// it with the same permissions, so the source code holds nothing that opens anyone's certificate.
    private static func passphrase() throws -> String {
        guard let data = try? Data(contentsOf: passphraseURL),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw AndroidTVError.certificate("senha do certificado ausente")
        }
        return text
    }

    private static func create() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var random = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw AndroidTVError.certificate("sem gerador aleatório")
        }
        let passphrase = random.map { String(format: "%02x", $0) }.joined()
        try Data(passphrase.utf8).write(to: passphraseURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passphraseURL.path)

        let key = directory.appendingPathComponent("client-key.pem")
        let cert = directory.appendingPathComponent("client-cert.pem")
        defer {
            try? FileManager.default.removeItem(at: key)
            try? FileManager.default.removeItem(at: cert)
        }
        // The pairing lasts as long as this certificate: 20 years (still a UTCTime, before 2050).
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "7300",
                     "-subj", "/CN=atvremote/O=Controle Remoto LG", "-keyout", key.path, "-out", cert.path])
        // The passphrase goes through the environment, not the command line (visible in `ps`).
        try openssl(["pkcs12", "-export", "-inkey", key.path, "-in", cert.path, "-out", bundleURL.path,
                     "-name", "Controle Remoto LG", "-passout", "env:LG_P12_PASS",
                     "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"],
                    environment: ["LG_P12_PASS": passphrase])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bundleURL.path)
    }

    private static func openssl(_ arguments: [String], environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AndroidTVError.certificate("openssl indisponível")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AndroidTVError.certificate("openssl terminou com \(process.terminationStatus)")
        }
    }

    /// Modulus and public exponent of an RSA certificate, big-endian without leading zeros.
    static func rsaComponents(_ certificate: SecCertificate) throws -> (modulus: Data, exponent: Data) {
        guard let key = SecCertificateCopyKey(certificate),
              let der = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw AndroidTVError.certificate("chave pública ilegível")
        }
        // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
        var reader = DERReader(Data(der))
        try reader.enter(tag: 0x30)
        let modulus = try reader.read(tag: 0x02)
        let exponent = try reader.read(tag: 0x02)
        return (modulus.drop { $0 == 0 }, exponent.drop { $0 == 0 })
    }
}

private struct DERReader {
    private let data: Data
    private var index = 0

    init(_ data: Data) { self.data = data }

    mutating func enter(tag: UInt8) throws { _ = try header(tag: tag) }

    mutating func read(tag: UInt8) throws -> Data {
        let length = try header(tag: tag)
        guard index + length <= data.count else { throw AndroidTVError.certificate("DER truncado") }
        defer { index += length }
        return data.subdata(in: index..<(index + length))
    }

    private mutating func header(tag: UInt8) throws -> Int {
        guard index + 2 <= data.count, data[index] == tag else { throw AndroidTVError.certificate("DER inesperado") }
        index += 1
        var length = Int(data[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count <= 4, index + count <= data.count else { throw AndroidTVError.certificate("DER inválido") }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(data[index])
                index += 1
            }
        }
        return length
    }
}

// MARK: - Pairing (port 6467)

/// One pairing attempt: `start()` makes the box show a 6-character code on the TV,
/// `finish(code:)` sends the proof derived from it.
final class AndroidTVPairing {
    private let host: String
    private let identity: SecIdentity
    private var channel: TLSChannel?

    init(host: String) throws {
        self.host = host
        self.identity = try AndroidTVIdentity.load()
    }

    func start() async throws {
        let channel = TLSChannel(host: host, port: 6467, identity: identity)
        try await channel.open()
        self.channel = channel
        try await send { $0.message(10) { request in        // pairing_request
            request.string(1, "atvremote")                  // service_name
            request.string(2, "Controle Remoto LG (Mac)")   // client_name
        } }
        try await expect(11)                                // pairing_request_ack
        try await send { $0.message(20) { option in          // pairing_option
            option.message(1) { encoding in                  // input_encodings: hexadecimal, 6 symbols
                encoding.int(1, 3)
                encoding.int(2, 6)
            }
            option.int(3, 1)                                 // preferred_role: input
        } }
        try await expect(20)
        try await send { $0.message(30) { configuration in   // pairing_configuration
            configuration.message(1) { encoding in
                encoding.int(1, 3)
                encoding.int(2, 6)
            }
            configuration.int(2, 1)                          // client_role: input
        } }
        try await expect(31)                                // configuration_ack: code is on screen now
    }

    /// Whether `code` passes its own check digit, without sending anything to the box.
    func accepts(_ code: String) -> Bool {
        (try? secret(for: code)) != nil
    }

    func finish(code rawCode: String) async throws {
        let secret = try secret(for: rawCode)
        try await send { $0.message(40) { $0.bytes(1, secret) } }   // pairing_secret
        try await expect(41)                                         // secret_ack
        cancel()
    }

    private func secret(for rawCode: String) throws -> Data {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6, let checksum = UInt8(code.prefix(2), radix: 16),
              let nonce = Data(hex: String(code.suffix(4))) else { throw AndroidTVError.wrongCode }
        guard let serverCertificate = channel?.serverCertificate else { throw AndroidTVError.connection("canal fechado") }
        let client = try AndroidTVIdentity.rsaComponents(try AndroidTVIdentity.certificate(of: identity))
        let server = try AndroidTVIdentity.rsaComponents(serverCertificate)
        var hash = SHA256()
        hash.update(data: client.modulus)
        hash.update(data: client.exponent)
        hash.update(data: server.modulus)
        hash.update(data: server.exponent)
        hash.update(data: nonce)
        let secret = Data(hash.finalize())
        // The first byte of the code is a checksum of the rest: catches typos before the box does.
        guard secret.first == checksum else { throw AndroidTVError.wrongCode }
        return secret
    }

    func cancel() {
        channel?.close()
        channel = nil
    }

    private func send(_ build: (inout ProtoWriter) -> Void) async throws {
        guard let channel else { throw AndroidTVError.connection("canal fechado") }
        var message = ProtoWriter()
        message.int(1, 2)      // protocol_version
        message.int(2, 200)    // status: OK
        build(&message)
        try await channel.send(message.data)
    }

    private func expect(_ field: Int) async throws {
        guard let channel else { throw AndroidTVError.connection("canal fechado") }
        let reply = try ProtoMessage(await channel.receive())
        switch reply.int(2) {
        case 200: break
        case 402: throw AndroidTVError.wrongCode
        case let status: throw AndroidTVError.rejected("status \(status)")
        }
        guard reply.has(field) else { throw AndroidTVError.rejected("resposta inesperada") }
    }
}

// MARK: - Remote control (port 6466)

enum AndroidTVRemote {
    /// Connects, completes the handshake and presses `keys` in order. Returns whether the box
    /// reported its screen as on before the keys were sent (nil if it didn't say).
    @discardableResult
    static func press(_ keys: [AndroidKey], host: String) async throws -> Bool? {
        try await press(codes: keys.map(\.rawValue), host: host)
    }

    /// Same as `press(_:host:)` with raw Android key codes.
    @discardableResult
    static func press(codes keys: [Int], host: String) async throws -> Bool? {
        let identity = try AndroidTVIdentity.load()
        let channel = TLSChannel(host: host, port: 6466, identity: identity)
        do {
            try await channel.open()
        } catch AndroidTVError.secureChannel {
            throw AndroidTVError.notPaired
        }
        defer { channel.close() }

        // Handshake: the box sends remote_configure and remote_set_active and waits for our echo.
        // Right after it, it usually says whether its screen is on (remote_start).
        var configured = false
        var active = false
        var screenOn: Bool?
        let handshakeDeadline = Date().addingTimeInterval(8)
        var settleDeadline: Date?
        while true {
            if configured && active {
                let settle = settleDeadline ?? Date().addingTimeInterval(1)
                settleDeadline = settle
                if screenOn != nil || Date() >= settle { break }
            }
            let remaining = (settleDeadline ?? handshakeDeadline).timeIntervalSinceNow
            guard remaining > 0 else { throw AndroidTVError.timeout }
            let raw: Data
            do {
                raw = try await channel.receive(timeout: remaining)
            } catch AndroidTVError.timeout where settleDeadline != nil {
                break
            } catch AndroidTVError.secureChannel {
                throw AndroidTVError.notPaired
            } catch AndroidTVError.connection where !configured {
                throw AndroidTVError.notPaired   // the box drops unknown certificates right away
            }
            let message = try ProtoMessage(raw)
            if message.has(1) {                                // remote_configure
                try await send(channel) { $0.message(1) { configure in
                    configure.int(1, 622)                          // features: key, ime, power, volume, app link
                    configure.message(2) { info in
                        info.string(1, "Mac")
                        info.string(2, "Apple")
                        info.int(3, 1)
                        info.string(4, "1")
                        info.string(5, "controle-remoto-lg")
                        info.string(6, "1.0.0")
                    }
                } }
                configured = true
            } else if message.has(2) {                         // remote_set_active
                try await send(channel) { $0.message(2) { $0.int(1, 622) } }
                active = true
            } else if let ping = message.message(8) {          // remote_ping_request
                try await send(channel) { $0.message(9) { $0.int(1, ping.int(1)) } }
            } else if message.has(40) {                        // remote_start
                screenOn = message.message(40)?.int(1) == 1
            } else if message.has(3) {                         // remote_error
                throw AndroidTVError.rejected("erro remoto")
            }
        }

        for key in keys {
            try await send(channel) { $0.message(10) { inject in   // remote_key_inject
                inject.int(1, key)
                inject.int(2, 3)                                   // direction: short press
            } }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        return screenOn
    }

    /// Switches the TV on through the box. Waking the box makes Android TV send HDMI-CEC
    /// "One Touch Play", which turns the TV on and selects the box's input. (KEYCODE_TV_POWER would
    /// be the direct way, but this box ignores it, and KEYCODE_WAKEUP doesn't wake it.)
    ///
    /// A few seconds after the TV goes to standby the box follows it into deep sleep and closes the
    /// remote service. Wake-on-LAN brings its network back for a few seconds (the port answers in
    /// about 1 s), which is enough to press POWER.
    static func switchTVOn(host: String, mac: String?) async throws {
        if let mac { WakeOnLAN.send(mac: mac, host: host) }
        guard await waitUntilReachable(host, mac: mac, timeout: mac == nil ? 5 : 10) else {
            throw AndroidTVError.asleep
        }
        if try await press(codes: [], host: host) == true {
            // Box awake while the TV is off: only a fresh wake-up sends One Touch Play, so put it
            // to sleep first and wake it again.
            try await press([.power], host: host)
            try await Task.sleep(nanoseconds: 3_000_000_000)
            if let mac { WakeOnLAN.send(mac: mac, host: host) }
            _ = await waitUntilReachable(host, mac: mac, timeout: 12)
        }
        try await press([.power], host: host)
    }

    /// Polls the remote port until the box accepts TCP connections, re-sending Wake-on-LAN on each
    /// miss so a cold ARP cache that resolves after the first TCP probe still receives the magic packet.
    private static func waitUntilReachable(_ host: String, mac: String? = nil, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await accepts(host, port: 6466, within: 0.6) { return true }
            if let mac { WakeOnLAN.send(mac: mac, host: host) }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private static func accepts(_ host: String, port: UInt16, within timeout: TimeInterval) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "androidtv.probe")
        return await withCheckedContinuation { continuation in
            var finished = false
            func finish(_ open: Bool) {   // always called on `queue`
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: open)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .waiting, .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    private static func send(_ channel: TLSChannel, _ build: (inout ProtoWriter) -> Void) async throws {
        var message = ProtoWriter()
        build(&message)
        try await channel.send(message.data)
    }
}

// MARK: - Wake-on-LAN and the ARP cache

enum WakeOnLAN {
    /// Sends the magic packet for `mac` to the broadcast addresses and straight to `host`.
    static func send(mac: String, host: String) {
        guard let address = Data(hex: mac.filter(\.isHexDigit)), address.count == 6 else { return }
        let packet = Data(repeating: 0xFF, count: 6) + Data((0..<16).flatMap { _ in address })
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var targets = ["255.255.255.255", host]
        let octets = host.split(separator: ".")
        if octets.count == 4 {
            targets.append(octets.prefix(3).joined(separator: ".") + ".255")   // /24 broadcast
        }
        for target in targets {
            for port: UInt16 in [9, 7] {
                var destination = sockaddr_in()
                destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                destination.sin_family = sa_family_t(AF_INET)
                destination.sin_port = port.bigEndian
                guard inet_pton(AF_INET, target, &destination.sin_addr) == 1 else { continue }
                packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &destination) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }
}

enum ARPCache {
    /// MAC address the Mac has cached for `ip`, as aa:bb:cc:dd:ee:ff (macOS drops leading zeros).
    static func mac(for ip: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", ip]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        // "? (192.0.2.101) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]"
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ")
            guard let at = words.firstIndex(of: "at"), at + 1 < words.count else { continue }
            let octets = words[at + 1].split(separator: ":")
            guard octets.count == 6, octets.allSatisfy({ $0.count <= 2 && $0.allSatisfy(\.isHexDigit) }) else { continue }
            return octets.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":").lowercased()
        }
        return nil
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
