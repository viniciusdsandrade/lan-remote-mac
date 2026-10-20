import Foundation
import Network

// Turning the TV on. The LG NetCast cuts its network in standby (Wake-on-LAN does nothing), so the
// app asks the TV Box plugged into it (Android TV) to do it: when the box wakes up it switches the
// TV on through HDMI-CEC ("One Touch Play"), which LG calls SIMPLINK and must be enabled on the TV.
// The box itself sleeps deeply too, but it does answer Wake-on-LAN on its Wi-Fi MAC.

/// The Android TV box used to switch the TV on. Saved apart from config.json, which the Python
/// CLI also rewrites.
struct AndroidTVBox: Codable, Equatable, Identifiable {
    var name: String     // Bonjour name, e.g. "TV Box da sala"
    var host: String     // last known IPv4 address
    var paired: Bool
    var mac: String? = nil   // Wi-Fi MAC, for Wake-on-LAN

    var id: String { name }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/lg_roap_control/androidtv.json")
    }

    static func load() -> AndroidTVBox? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AndroidTVBox.self, from: data)
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

enum TVPowerState: Equatable {
    case unknown      // first check still running
    case on
    case off          // not answering: standby, for this TV
    case turningOn
}

enum BoxPairingStage: Equatable {
    case idle
    case searching
    case requestingCode
    case waitingForCode
    case confirming
    case failed(String)
}

// MARK: - Discovery

enum TVBoxDiscovery {
    static let serviceType = "_androidtvremote2._tcp"

    /// Android TV devices announcing the remote service on the local network.
    static func find(timeout: TimeInterval = 3) async -> [AndroidTVBox] {
        let queue = DispatchQueue(label: "tvbox.discovery")
        let names: [String] = await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            var found = Set<String>()
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint { found.insert(name) }
                }
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error), .waiting(let error):
                    NSLog("TV Box discovery: Bonjour browse unavailable (%@)", "\(error)")
                default: break
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                browser.cancel()
                continuation.resume(returning: found.sorted())
            }
        }
        var boxes: [AndroidTVBox] = []
        for name in names {
            if let address = await resolve(name) {
                boxes.append(AndroidTVBox(name: name, host: address, paired: false, mac: ARPCache.mac(for: address)))
            }
        }
        if boxes.count != names.count {
            NSLog("TV Box discovery: %d service(s) announced, %d resolved", names.count, boxes.count)
        }
        return boxes
    }

    /// IPv4 address behind a Bonjour service name (connects briefly to read the resolved endpoint).
    private static func resolve(_ name: String, timeout: TimeInterval = 3) async -> String? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: .service(name: name, type: serviceType, domain: "local.", interface: nil),
                                      using: parameters)
        let queue = DispatchQueue(label: "tvbox.resolve")
        return await withCheckedContinuation { continuation in
            var finished = false
            func finish(_ address: String?) {   // always called on `queue`
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: address)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint,
                       case let .ipv4(address) = host {
                        finish(address.rawValue.map { String($0) }.joined(separator: "."))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}

// MARK: - Power on and box pairing

extension LGTVClient {
    var canTurnOnTV: Bool { box?.paired == true || console?.registered == true }

    /// Who switches the TV on, for the texts: "a TV Box da sala", "o PS5-123" or both.
    var powerOnHelpers: String? {
        let box = box?.paired == true ? box.map { "a \($0.name)" } : nil
        let console = console?.registered == true ? console.map { "o \($0.name)" } : nil
        switch (box, console) {
        case let (box?, console?): return "\(box) (ou \(console), se ela não acordar)"
        case let (box?, nil): return box
        case let (nil, console?): return console
        default: return nil
        }
    }

    func turnOn() {
        guard powerState != .turningOn, canTurnOnTV else { return }
        Task { await performTurnOn() }
    }

    /// The TV Box first; the PS5 when the box doesn't wake (it drops off the Wi-Fi after hours in
    /// standby, and then the Wake-on-LAN never reaches it).
    private func performTurnOn() async {
        powerState = .turningOn
        powerOnError = nil
        var problems: [String] = []
        var helper: String?
        var restartConsole = false

        if let box, box.paired {
            powerOnStep = "Acordando a \(box.name) pelo Wi-Fi…"
            do {
                try await wakeBox(box)
                helper = box.name
            } catch AndroidTVError.notPaired {
                self.box?.paired = false
                self.box?.save()
                problems.append("A TV Box não reconhece mais este Mac: pareie de novo em Configurações.")
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if helper == nil, let console, console.registered {
            powerOnStep = problems.isEmpty ? "Acordando o \(console.name) pela rede…"
                                           : "A TV Box não acordou. Acordando o \(console.name) pela rede…"
            do {
                let awake = try await PlayStationDiscovery.wake(console)
                if awake != console {   // moved to another address (DHCP)
                    self.console = awake
                    awake.save()
                }
                helper = console.name
                restartConsole = true
            } catch PlayStationError.alreadyAwake {
                helper = console.name   // awake with the TV off: the restart below still turns it on
                restartConsole = true
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        guard let helper else {
            var message = problems.joined(separator: " ")
            if box?.paired == true, console?.registered != true {
                message += " Ela está ligada na tomada e no Wi-Fi?"
            }
            failTurnOn(message)
            return
        }

        // Woken over the network the PS5 leaves the TV off; it sends One-Touch Play when it boots.
        if restartConsole, let console {
            powerOnStep = "O \(helper) acordou, mas assim ele não liga a TV. Reiniciando o \(helper) pelo Uso remoto…"
            do {
                try await PlayStationRestart.run(console) { [weak self] step in self?.powerOnStep = step }
            } catch {
                failTurnOn(error.localizedDescription)
                return
            }
        }

        // The picture comes back in seconds; the NetCast network takes almost a minute more (and a
        // restarting PS5 needs about 30 s before it turns the TV on).
        powerOnStep = "\(helper) está ligando a TV. O controle volta a responder em até \(restartConsole ? 2 : 1) minuto\(restartConsole ? "s" : "")…"
        let deadline = Date().addingTimeInterval(restartConsole ? 150 : 90)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshStatus()
            if powerState == .on {
                powerOnStep = ""
                return
            }
        }
        failTurnOn("\(helper) acordou, mas a TV não respondeu. Confira se o SIMPLINK está ligado na TV "
                   + "e o controle HDMI (CEC) nesse aparelho.")
    }

    private func wakeBox(_ box: AndroidTVBox) async throws {
        let mac = box.mac ?? ARPCache.mac(for: box.host)
        if let mac, mac != box.mac {
            self.box?.mac = mac
            self.box?.save()
        }
        try await withBox { host in try await AndroidTVRemote.switchTVOn(host: host, mac: mac) }
    }

    private func failTurnOn(_ message: String) {
        powerState = .off
        powerOnStep = ""
        powerOnError = message
    }

    /// Runs `action` against the box; if it moved to another address (DHCP), finds it by name and retries.
    private func withBox(_ action: (String) async throws -> Void) async throws {
        guard let box else { throw AndroidTVError.notPaired }
        do {
            try await action(box.host)
        } catch let error where Self.isReachabilityError(error) {
            // A sleeping box doesn't answer Bonjour: wake it (the magic packet is broadcast, so it
            // reaches the box at any address) and look it up while it is awake.
            if let mac = box.mac { WakeOnLAN.send(mac: mac, host: box.host) }
            guard let moved = await TVBoxDiscovery.find().first(where: { $0.name == box.name }),
                  moved.host != box.host else { throw error }
            self.box?.host = moved.host
            self.box?.save()
            try await action(moved.host)
        }
    }

    private static func isReachabilityError(_ error: Error) -> Bool {
        switch error {
        case AndroidTVError.connection, AndroidTVError.timeout, AndroidTVError.asleep: return true
        default: return false
        }
    }

    // MARK: Pairing with the box (once)

    func searchBoxes() {
        boxPairingStage = .searching
        Task {
            let found = await TVBoxDiscovery.find()
            discoveredBoxes = found
            boxPairingStage = .idle
        }
    }

    /// Makes the box show a 6-character code on the TV screen.
    func requestBoxCode(for candidate: AndroidTVBox) {
        activePairing?.cancel()
        boxCodeError = nil
        boxPairingStage = .requestingCode
        Task {
            do {
                let pairing = try AndroidTVPairing(host: candidate.host)
                try await pairing.start()
                activePairing = pairing
                pairingCandidate = candidate
                boxPairingStage = .waitingForCode
            } catch {
                boxPairingStage = .failed(error.localizedDescription)
            }
        }
    }

    func confirmBoxCode(_ code: String) {
        guard let pairing = activePairing, var candidate = pairingCandidate else { return }
        boxCodeError = nil
        boxPairingStage = .confirming
        Task {
            do {
                try await pairing.finish(code: code)
                candidate.paired = true
                candidate.mac = candidate.mac ?? ARPCache.mac(for: candidate.host)
                candidate.save()
                box = candidate
                activePairing = nil
                pairingCandidate = nil
                powerOnError = nil
                boxPairingStage = .idle
            } catch AndroidTVError.wrongCode {
                // The checksum in the code catches typos before anything is sent; the box keeps waiting.
                boxCodeError = AndroidTVError.wrongCode.localizedDescription
                boxPairingStage = .waitingForCode
            } catch {
                pairing.cancel()
                activePairing = nil
                boxPairingStage = .failed(error.localizedDescription)
            }
        }
    }

    func cancelBoxPairing() {
        activePairing?.cancel()
        activePairing = nil
        pairingCandidate = nil
        boxPairingStage = .idle
    }

    func forgetBox() {
        cancelBoxPairing()
        AndroidTVBox.forget()
        box = nil
    }
}
