import Foundation

/// Mock ROAP control server for turn-on orchestration tests: intercepts every URLSession request
/// in-process so zero packets go to a real LAN TV.
final class FakeTurnOnTV: URLProtocol {
    enum Mode { case deaf, answering }
    private static let lock = NSLock()
    private static var _mode = Mode.deaf
    private static var _requireAuthOnce = false

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
            let xml = "<envelope><session>11223344</session></envelope>"
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

        let xml = "<envelope><data><level>12</level><mute>false</mute></data></envelope>"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(xml.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _boxCalls = 0
    private var _wakeHosts: [String] = []
    private var _restartHosts: [String] = []
    private var _reloginHosts: [String] = []
    private var _sawAbortInRestarter = false

    var boxCalls: Int { lock.withLock { _boxCalls } }
    var wakeHosts: [String] { lock.withLock { _wakeHosts } }
    var restartHosts: [String] { lock.withLock { _restartHosts } }
    var reloginHosts: [String] { lock.withLock { _reloginHosts } }
    var sawAbortInRestarter: Bool { lock.withLock { _sawAbortInRestarter } }

    func reset() {
        lock.withLock {
            _boxCalls = 0
            _wakeHosts.removeAll()
            _restartHosts.removeAll()
            _reloginHosts.removeAll()
            _sawAbortInRestarter = false
        }
    }

    func recordBox() { lock.withLock { _boxCalls += 1 } }
    func recordWake(_ host: String) { lock.withLock { _wakeHosts.append(host) } }
    func recordRestart(_ host: String) { lock.withLock { _restartHosts.append(host) } }
    func recordRelogin(_ host: String) { lock.withLock { _reloginHosts.append(host) } }
    func recordAbort(_ aborted: Bool) { lock.withLock { _sawAbortInRestarter = aborted } }
}

@main
struct TurnOnFlowCheck {
    @MainActor static var failures = 0

    @MainActor static func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok    " : "FALHA ") + what)
        if !ok { failures += 1 }
    }

    @MainActor static func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    @MainActor static func makeClient() async -> LGTVClient {
        FakeTurnOnTV.set(.deaf)
        let client = LGTVClient()
        client.pingProbe = { _ in false }
        client.arpLookup = { _ in nil }
        client.config.host = "192.0.2.10"
        client.config.mac = "02:00:5e:00:00:10"
        client.config.pairingKey = "123456"
        client.turnOnPollInterval = 0.05
        client.turnOnTimeoutOverride = 1.5
        client.box = AndroidTVBox(name: "TV Box da sala", host: "192.0.2.20", paired: true, mac: "02:00:5e:00:00:20")
        client.console = PlayStationConsole(
            name: "PS5-100",
            host: "192.0.2.40",
            hostId: "02005E000040",
            systemVersion: "01000000",
            registered: true,
            accountId: "AAAAAAAAAAA=",
            credential: "1234567890"
        )
        await waitUntil(4) { client.powerState == .off }
        return client
    }

    @MainActor static func main() async {
        URLProtocol.registerClass(FakeTurnOnTV.self)

        // 1. Helper & protocol sanity checks
        check(!PlayStationDiscovery.isUsableHost("0.0.0.0")
              && !PlayStationDiscovery.isUsableHost("255.255.255.255")
              && !PlayStationDiscovery.isUsableHost("169.254.10.20")
              && !PlayStationDiscovery.isUsableHost("")
              && PlayStationDiscovery.isUsableHost("192.0.2.77"),
              "isUsableHost filtra 0.0.0.0, broadcast e link-local antes do DHCP concluir")

        check(PlayStationRestart.ps5ctlArguments(host: "192.0.2.77", command: ["press", "cross"])
              == ["--host", "192.0.2.77", "press", "cross"],
              "ps5ctlArguments propaga --host <ip> atual do PS5 para o ps5ctl")

        check(PlayStationRestart.ps5ctlArguments(host: "   ", command: ["press", "circle"])
              == ["press", "circle"],
              "ps5ctlArguments preserva o comando quando o host está vazio")

        check((PlayStationError.notFound.errorDescription ?? "").contains("repouso"),
              "PlayStationError.notFound orienta sobre desligado por completo vs modo de repouso")

        let recorder = Recorder()

        // 2. Scenario A: TV comes on externally while boxWaker fails (before pollTimer fires).
        //    Must detect port 8080 immediately and NEVER wake or restart the PS5.
        let clientA = await makeClient()
        recorder.reset()
        clientA.boxWaker = { _, _ in
            recorder.recordBox()
            FakeTurnOnTV.set(.answering)
            throw AndroidTVError.asleep
        }
        clientA.consoleWaker = { console in
            recorder.recordWake(console.host)
            return console
        }
        clientA.consoleRestarter = { console, _, _ in
            recorder.recordRestart(console.host)
            return true
        }
        clientA.turnOn()
        await waitUntil(4) { clientA.powerState == .on && clientA.turnOnTask == nil }
        check(clientA.powerState == .on && clientA.powerOnError == nil && clientA.powerOnStep.isEmpty,
              "TV ligou durante a tentativa da TV Box: conclui como Ligada sem erro (\(clientA.powerState))")
        check(recorder.boxCalls == 1 && recorder.wakeHosts.isEmpty && recorder.restartHosts.isEmpty,
              "TV já ligada após falha da TV Box não acorda nem reinicia o PS5 (wake=\(recorder.wakeHosts), restart=\(recorder.restartHosts))")

        // 3. Scenario B: TV comes on via background refreshStatus() (401 -> re-pair -> 200) while
        //    consoleWaker is running — exact reproduction of the ghost PS5 restart bug.
        let clientB = await makeClient()
        recorder.reset()
        clientB.boxWaker = { _, _ in
            recorder.recordBox()
            throw AndroidTVError.asleep
        }
        clientB.consoleWaker = { console in
            recorder.recordWake(console.host)
            for _ in 0..<60 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return console
        }
        clientB.consoleRestarter = { console, _, _ in
            recorder.recordRestart(console.host)
            return true
        }
        clientB.consoleRelogin = { console in
            recorder.recordRelogin(console.host)
            return console
        }
        clientB.turnOn()
        await waitUntil(3) { !recorder.wakeHosts.isEmpty }
        FakeTurnOnTV.set(.answering, requireAuthOnce: true)
        await clientB.refreshStatus()
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(clientB.powerState == .on && clientB.turnOnTask == nil && clientB.powerOnError == nil,
              "refreshStatus (401->200) durante wake do PS5 cancela turnOnTask na hora (\(clientB.powerState))")
        check(recorder.restartHosts.isEmpty && recorder.reloginHosts.isEmpty,
              "wake cancelado pela TV já ligada JAMAIS dispara PlayStationRestart (restart=\(recorder.restartHosts))")

        // 4. Scenario C: TV comes on mid-consoleRestarter before Restart PS5 is confirmed.
        //    shouldAbort() becomes true, restarter aborts cleanly (returns false), and reloginTask is NOT scheduled.
        let clientC = await makeClient()
        recorder.reset()
        clientC.boxWaker = { _, _ in throw AndroidTVError.asleep }
        clientC.consoleWaker = { console in
            recorder.recordWake(console.host)
            return console
        }
        clientC.consoleRestarter = { console, shouldAbort, progress in
            recorder.recordRestart(console.host)
            await progress("Abrindo o menu de energia do \(console.name) pelo Uso remoto…")
            for _ in 0..<60 {
                if await shouldAbort() {
                    recorder.recordAbort(true)
                    return false
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return true
        }
        clientC.consoleRelogin = { console in
            recorder.recordRelogin(console.host)
            return console
        }
        clientC.turnOn()
        await waitUntil(3) { !recorder.restartHosts.isEmpty }
        FakeTurnOnTV.set(.answering)
        await clientC.refreshStatus()
        await waitUntil(3) { recorder.sawAbortInRestarter }
        try? await Task.sleep(nanoseconds: 150_000_000)
        check(recorder.sawAbortInRestarter && clientC.powerState == .on && clientC.powerOnStep.isEmpty,
              "TV ligando no meio do Uso remoto sinaliza shouldAbort() e encerra sem reiniciar o PS5")
        check(recorder.reloginHosts.isEmpty,
              "abort antes do reboot não agenda relogin pós-boot desnecessário")

        // 5. Scenario D: Full PS5 fallback with DHCP IP migration on wake (192.0.2.40 -> 192.0.2.77)
        //    and again on post-reboot relogin (192.0.2.77 -> 192.0.2.88).
        let clientD = await makeClient()
        recorder.reset()
        clientD.boxWaker = { _, _ in throw AndroidTVError.asleep }
        clientD.consoleWaker = { console in
            recorder.recordWake(console.host)
            var moved = console
            moved.host = "192.0.2.77"
            return moved
        }
        clientD.consoleRestarter = { console, _, progress in
            recorder.recordRestart(console.host)
            await progress("Reiniciando o \(console.name). Ao ligar de novo, ele liga a TV…")
            return true
        }
        clientD.consoleRelogin = { console in
            recorder.recordRelogin(console.host)
            try? await Task.sleep(nanoseconds: 250_000_000)
            var postBoot = console
            postBoot.host = "192.0.2.88"
            return postBoot
        }
        clientD.turnOn()
        await waitUntil(3) { !recorder.restartHosts.isEmpty }
        try? await Task.sleep(nanoseconds: 80_000_000)
        FakeTurnOnTV.set(.answering)   // One-Touch Play turns the TV on while reloginTask is still waiting for PS5 boot
        await waitUntil(3) { clientD.powerState == .on }
        await waitUntil(3) { clientD.console?.host == "192.0.2.88" }
        check(recorder.restartHosts == ["192.0.2.77"],
              "PlayStationRestart recebe o novo IP DHCP descoberto no wake (192.0.2.77), não o IP antigo: \(recorder.restartHosts)")
        check(recorder.reloginHosts == ["192.0.2.77"]
              && clientD.console?.host == "192.0.2.88"
              && PlayStationConsole.load()?.host == "192.0.2.88",
              "relogin pós-boot sobrevive à subida da TV, reautentica a sessão do PS5 e grava novo IP DHCP (\(clientD.console?.host ?? "nil"))")

        // 6. Scenario E: Both helpers offline -> returns cleanly to .off with clear combined diagnostics.
        let clientE = await makeClient()
        recorder.reset()
        clientE.boxWaker = { _, _ in throw AndroidTVError.asleep }
        clientE.consoleWaker = { _ in throw PlayStationError.notFound }
        clientE.turnOn()
        await waitUntil(3) { clientE.powerState == .off && clientE.powerOnError != nil }
        let err = clientE.powerOnError ?? ""
        check(clientE.powerState == .off && clientE.powerOnStep.isEmpty
              && err.contains("TV Box") && err.contains("PS5") && err.contains("repouso"),
              "ambos os helpers inacessíveis: volta para Desligada com diagnóstico claro da TV Box e do PS5")

        exit(failures == 0 ? 0 : 1)
    }
}
