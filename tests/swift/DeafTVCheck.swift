import Foundation

/// The TV's control server inside the test: every HTTP request is answered here, none reaches the
/// network. Deaf, it fails each request with timeout; answering, it says 200 (or 401 once when
/// `requireAuthOnce` is armed) and keeps the key codes it was sent.
final class FakeTV: URLProtocol {
    enum Mode { case deaf, answering }
    private static let lock = NSLock()
    private static var _mode = Mode.deaf
    private static var _requireAuthOnce = false
    private static var _keys: [Int] = []
    private static var _pairings = 0

    static var keys: [Int] { lock.withLock { _keys } }
    static var pairings: Int { lock.withLock { _pairings } }
    static func clearKeys() { lock.withLock { _keys.removeAll(); _pairings = 0 } }
    static func set(_ mode: Mode, requireAuthOnce: Bool = false) {
        lock.withLock {
            _mode = mode
            _requireAuthOnce = requireAuthOnce
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, Self.lock.withLock({ Self._mode }) == .answering else {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }

        if url.path.hasSuffix("/auth") || url.path.hasSuffix("/pairing") {
            Self.lock.withLock { Self._pairings += 1 }
            let xml = "<envelope><session>99887766</session></envelope>"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(xml.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let needs401 = Self.lock.withLock { () -> Bool in
            if Self._requireAuthOnce {
                Self._requireAuthOnce = false
                return true
            }
            return false
        }
        if needs401 {
            let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        if url.path.hasSuffix("/command"), let code = Self.keyCode(in: Self.body(of: request)) {
            Self.lock.withLock { Self._keys.append(code) }
        }
        let xml = "<envelope><data><level>10</level><mute>false</mute></data></envelope>"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(xml.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func keyCode(in xml: String) -> Int? {
        guard let start = xml.range(of: "<value>"), let end = xml.range(of: "</value>") else { return nil }
        return Int(xml[start.upperBound..<end.lowerBound])
    }
}

@main
struct DeafTVCheck {
    @MainActor static var failures = 0

    @MainActor static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok    " : "FALHA ") + what)
        if !ok { failures += 1 }
    }

    @MainActor static func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor static func main() async {
        URLProtocol.registerClass(FakeTV.self)
        let client = LGTVClient()
        client.config.host = "127.0.0.1"   // answers ping, like the TV while it is on
        client.config.mac = nil
        client.config.pairingKey = "123456"

        // 1. The control server is deaf and the TV answers ping: on, not "off"
        await waitUntil(8) { client.powerState != .unknown }
        check(client.powerState == .on && client.notAnswering,
              "servidor de controle sem resposta com ping ativo: Ligada, sem resposta (\(client.powerState))")

        // 2. Keys pressed while it is deaf wait, and go in order once it answers again (even across a 401)
        client.sendKey(.volumeUp)
        client.sendKey(.volumeUp)
        client.sendKey(.volumeDown)
        try? await Task.sleep(nanoseconds: 2_200_000_000)
        check(FakeTV.keys.isEmpty, "nada sai enquanto o servidor está sem resposta")
        FakeTV.set(.answering, requireAuthOnce: true)
        await waitUntil(8) { FakeTV.keys.count >= 3 }
        check(FakeTV.keys == [24, 24, 25], "as teclas chegam na ordem quando ele volta (mesmo com 401): \(FakeTV.keys)")
        check(FakeTV.pairings >= 1, "sessão expirada (401) após espera refaz o pareamento antes de reenviar")
        check(client.powerState == .on && !client.notAnswering, "e a TV volta a aparecer como Ligada")

        // 3. Stale keys older than keyPatience are dropped instead of firing late
        FakeTV.clearKeys()
        FakeTV.set(.deaf)
        client.keyPatience = 1.2
        client.sendKey(.mute)
        client.sendKey(.home)
        try? await Task.sleep(nanoseconds: 2_600_000_000)
        FakeTV.set(.answering)
        await client.refreshStatus()
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(FakeTV.keys.isEmpty, "teclas vencidas (acima de keyPatience) são descartadas e não disparam atrasadas: \(FakeTV.keys)")
        client.keyPatience = 15

        // 4. While turningOn, ping alone does not abort the boot state before port 8080 answers
        FakeTV.set(.deaf)
        client.powerState = .turningOn
        await client.refreshStatus()
        check(client.powerState == .turningOn, "durante Ligando, ping antes da porta 8080 subir mantém Ligando (\(client.powerState))")
        FakeTV.set(.answering)
        await client.refreshStatus()
        check(client.powerState == .on && !client.notAnswering, "assim que a porta 8080 responde 200, conclui Ligando -> Ligada")

        // 5. Standby: no answer, not even to ping
        FakeTV.set(.deaf)
        client.config.host = "192.0.2.1"
        await client.refreshStatus()
        check(client.powerState == .off, "sem resposta nem ao ping: Desligada (\(client.powerState))")

        // 6. Right after the power key the TV still answers ping while it shuts down: stays off
        client.config.host = "127.0.0.1"
        FakeTV.set(.answering)
        await client.refreshStatus()
        client.sendKey(.power)
        await waitUntil { client.powerState == .off }
        FakeTV.set(.deaf)
        await client.refreshStatus()
        check(client.powerState == .off, "logo depois da tecla de desligar, o ping não a religa (\(client.powerState))")

        // 7. Saved MAC is NOT overwritten by a conflicting device's MAC during status refresh,
        //    and an active IP conflict (different MAC answering ARP right after the TV answered) is flagged.
        let tvMac = "02:00:5e:00:00:10"
        let impostorMac = "02:00:5e:00:00:99"
        client.config.mac = tvMac
        client.arpLookup = { _ in impostorMac }
        FakeTV.set(.answering)
        await client.refreshStatus()
        check(client.config.mac == tvMac, "MAC salvo da TV não é sobrescrito pelo MAC de outro aparelho (\(client.config.mac ?? "nil"))")

        FakeTV.set(.deaf)
        await client.refreshStatus()
        check(client.powerState == .on && client.notAnswering && client.ipConflict,
              "outro MAC respondendo logo após a TV: Ligada · conflito de IP (conflict=\(client.ipConflict))")

        // 8. When the TV never answered recently (e.g. off for hours and DHCP gave its old IP to another MAC),
        //    another MAC answering ping is treated as offline (standby), not as the TV.
        let fresh = LGTVClient()
        fresh.config.host = "127.0.0.1"
        fresh.config.mac = tvMac
        fresh.arpLookup = { _ in impostorMac }
        await waitUntil(8) { fresh.powerState != .unknown }
        check(fresh.powerState == .off && !fresh.notAnswering && !fresh.ipConflict,
              "IP antigo reatribuído pelo DHCP a outro MAC com a TV desligada: Desligada (\(fresh.powerState))")

        exit(failures == 0 ? 0 : 1)
    }
}
