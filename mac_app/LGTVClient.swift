import Foundation
import Combine
import Network

// MARK: - Key Codes Definitions

enum TVKey: Int, CaseIterable, Identifiable {
    case power = 1
    case digit0 = 2, digit1 = 3, digit2 = 4, digit3 = 5, digit4 = 6
    case digit5 = 7, digit6 = 8, digit7 = 9, digit8 = 10, digit9 = 11
    case up = 12, down = 13, left = 14, right = 15, ok = 20
    case home = 21, menu = 22, back = 23, exit = 412
    case volumeUp = 24, volumeDown = 25, mute = 26
    case channelUp = 27, channelDown = 28, previousChannel = 403, favoriteChannel = 404
    case blue = 29, green = 30, red = 31, yellow = 32
    case play = 33, pause = 34, stop = 35, fastForward = 36, rewind = 37
    case skipForward = 38, skipBackward = 39, record = 40, recordingList = 41, repeatKey = 42
    case liveTv = 43, epg = 44, info = 45, aspectRatio = 46, input = 47
    case pip = 48, subtitle = 49, programList = 50, teletext = 51, mark = 52
    case key3d = 400, key3dLr = 401, dash = 402, quickMenu = 405, textOption = 406
    case audioDescription = 407, netcast = 408, energySaving = 409, avMode = 410
    case simplink = 411, reservationList = 413, pipChannelUp = 414, pipChannelDown = 415
    case switchVideo = 416, apps = 417
    
    var id: Int { rawValue }
    
    var label: String {
        switch self {
        case .power: return "Power"
        case .digit0: return "0"
        case .digit1: return "1"
        case .digit2: return "2"
        case .digit3: return "3"
        case .digit4: return "4"
        case .digit5: return "5"
        case .digit6: return "6"
        case .digit7: return "7"
        case .digit8: return "8"
        case .digit9: return "9"
        case .up: return "Cima"
        case .down: return "Baixo"
        case .left: return "Esquerda"
        case .right: return "Direita"
        case .ok: return "OK"
        case .home: return "Home"
        case .menu: return "Menu"
        case .back: return "Voltar"
        case .exit: return "Sair"
        case .volumeUp: return "Vol +"
        case .volumeDown: return "Vol -"
        case .mute: return "Mudo"
        case .channelUp: return "Canal +"
        case .channelDown: return "Canal -"
        case .previousChannel: return "Canal Ant."
        case .favoriteChannel: return "Favoritos"
        case .blue: return "Azul"
        case .green: return "Verde"
        case .red: return "Vermelho"
        case .yellow: return "Amarelo"
        case .play: return "Play"
        case .pause: return "Pause"
        case .stop: return "Stop"
        case .fastForward: return "Avançar"
        case .rewind: return "Retroceder"
        case .liveTv: return "Live TV"
        case .epg: return "Guia"
        case .info: return "Info"
        case .aspectRatio: return "Formato"
        case .input: return "Entrada"
        case .key3d: return "3D"
        case .quickMenu: return "Q.Menu"
        case .apps: return "Apps"
        case .energySaving: return "Eco"
        case .simplink: return "SIMPLINK"
        default: return "Tecla \(rawValue)"
        }
    }
}

// MARK: - TV Configuration Model

struct TVConfig: Codable {
    var host: String
    var port: Int
    var protocolType: String
    var model: String?
    var name: String?
    var pairingKey: String?
    var session: String?
    var mac: String?
    
    enum CodingKeys: String, CodingKey {
        case host
        case port
        case protocolType = "protocol"
        case model
        case name
        case pairingKey = "pairing_key"
        case session
        case mac
    }
}

// MARK: - LGTVClient

@MainActor
final class LGTVClient: ObservableObject {
    @Published var config: TVConfig
    @Published var powerState: TVPowerState = .unknown
    /// On, but its control server isn't taking requests (see `checkTVPing`): recent keys wait briefly.
    @Published var notAnswering: Bool = false
    /// Another device on the LAN answered ARP at the TV's IP right after the TV was active there.
    @Published var ipConflict: Bool = false
    @Published var isMuted: Bool = false
    @Published var volumeLevel: Int = 10
    @Published var inputSourceName: String = "---"
    @Published var channelMajor: String = ""
    @Published var isRefreshing: Bool = false

    // Turning the TV on through the TV Box (see TVBoxLink.swift)
    @Published var box: AndroidTVBox? = AndroidTVBox.load()
    @Published var powerOnStep: String = ""
    @Published var powerOnError: String?
    @Published var attentionPulse: Int = 0          // bumped when a key is pressed with the TV off
    @Published var boxPairingStage: BoxPairingStage = .idle
    @Published var discoveredBoxes: [AndroidTVBox] = []
    @Published var boxCodeError: String?
    var activePairing: AndroidTVPairing?
    var pairingCandidate: AndroidTVBox?

    // The PS5 that switches the TV on when the box doesn't answer (see PlayStationLink.swift)
    @Published var console: PlayStationConsole? = PlayStationConsole.load()
    @Published var consolePairingStage: ConsolePairingStage = .idle
    @Published var discoveredConsoles: [DiscoveredPlayStation] = []
    @Published var psnAccountId: String?
    @Published var psnStage: ConsolePairingStage = .idle

    var isConnected: Bool { powerState == .on }

    private var pollTimer: Timer?
    private var lastSendTime: DispatchTime = .now()
    private let minGapSeconds: Double = 0.30
    private var pendingKeys: [(code: Int, label: String, pressed: Date)] = []
    private var sendingKeys = false
    /// How long a key waits for the control server to come back before it is dropped (short enough
    /// never to surprise the user a minute later with stale volume or navigation presses).
    var keyPatience: TimeInterval = 15
    var pingProbe: @Sendable (String) async -> Bool = { await LGTVDiscovery.answersPing($0) }
    var arpLookup: @Sendable (String) -> String? = { ARPCache.mac(for: $0) }
    private var poweredOffAt: Date?
    private var lastAnsweredAt: Date?
    private let ipConflictWindow: TimeInterval = 120
    private var lastAutomaticSearch: Date = .distantPast
    
    static var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/lg_roap_control/config.json")
    }
    
    init() {
        let loaded = Self.loadConfigFromDisk()
        self.config = loaded ?? TVConfig(
            host: "192.0.2.100",
            port: 8080,
            protocolType: "roap",
            model: "xxLN5700-SA_11",
            name: "[TV][LG]xxLN5700-SA",
            pairingKey: nil,
            session: nil,
            mac: nil
        )
        
        startPolling()
        Task {
            await self.refreshStatus()
        }
    }
    
    deinit {
        pollTimer?.invalidate()
    }
    
    // MARK: - Configuration Persistence
    
    static func loadConfigFromDisk() -> TVConfig? {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(TVConfig.self, from: data)
    }
    
    func saveConfigToDisk() {
        let url = Self.configURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(config) {
            try? data.write(to: url, options: .atomic)
            #if os(macOS)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #endif
        }
    }
    
    // MARK: - Polling
    
    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshStatus()
            }
        }
    }
    
    // MARK: - Network Request Helpers
    
    private func createRequest(path: String, method: String = "GET", body: String? = nil) -> URLRequest {
        let url = URL(string: "http://\(config.host):\(config.port)\(path)")!
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 3.5
        req.setValue("Close", forHTTPHeaderField: "Connection")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        
        // Critical: LG xxLN5700 fw 05.02.11 bug:
        // User-Agent must NOT contain "UDAP/2.0" for ROAP, otherwise the TV responds 400 Bad Request
        if config.protocolType == "udap" {
            req.setValue("macOS/1.0 UDAP/2.0 lg_roap_control/1.0.0", forHTTPHeaderField: "User-Agent")
            req.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        } else {
            req.setValue("lg_roap_control/1.0.0 (macOS)", forHTTPHeaderField: "User-Agent")
            req.setValue("application/atom+xml", forHTTPHeaderField: "Content-Type")
        }
        
        if let body = body {
            req.httpBody = body.data(using: .utf8)
        }
        return req
    }
    
    // MARK: - Command Execution with Debounce
    
    func sendKey(_ key: TVKey) {
        guard powerState != .off, powerState != .turningOn else {
            attentionPulse += 1   // nothing to send to; point the user at the "turn on" banner
            return
        }
        pendingKeys.append((key.rawValue, key.label, Date()))
        guard !sendingKeys else { return }
        sendingKeys = true
        Task { [weak self] in await self?.sendPendingKeys() }
    }

    /// Sends the keys one at a time, in the order they were pressed: a key waiting for the TV holds
    /// the ones pressed after it, and any key that waited longer than `keyPatience` is dropped.
    private func sendPendingKeys() async {
        while !pendingKeys.isEmpty {
            guard powerState != .off else {
                pendingKeys.removeAll()
                break
            }
            let key = pendingKeys.removeFirst()
            guard Date().timeIntervalSince(key.pressed) < keyPatience else {
                NSLog("LG TV: tecla %@ descartada, esperou mais de %.0f s na fila", key.label, keyPatience)
                continue
            }

            // Debounce timing: Ensure min gap between key transmissions
            let now = DispatchTime.now()
            let elapsed = Double(now.uptimeNanoseconds - lastSendTime.uptimeNanoseconds) / 1_000_000_000.0
            if elapsed < minGapSeconds {
                let waitNanos = UInt64((minGapSeconds - elapsed) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: waitNanos)
            }
            lastSendTime = DispatchTime.now()

            await performSendKey(code: key.code, label: key.label, pressed: key.pressed)
        }
        sendingKeys = false
    }

    private func performSendKey(code: Int, label: String, pressed: Date,
                                allowAuthRetry: Bool = true, allowRelocate: Bool = true) async {
        let session = config.session ?? ""
        let xml: String
        let path: String
        
        if config.protocolType == "udap" {
            path = "/udap/api/command"
            xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><envelope><api type=\"command\"><name>HandleKeyInput</name><value>\(code)</value></api></envelope>"
        } else {
            path = "/roap/api/command"
            xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><command><session>\(session)</session><type>HandleKeyInput</type><value>\(code)</value></command>"
        }
        
        let req = createRequest(path: path, method: "POST", body: xml)
        
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let httpResp = resp as? HTTPURLResponse {
                if httpResp.statusCode == 200 {
                    // The power key only switches the TV off: its network goes down right after.
                    if code == TVKey.power.rawValue {
                        notAnswering = false
                        ipConflict = false
                        self.powerState = .off
                        poweredOffAt = Date()
                        lastAnsweredAt = nil
                    } else {
                        markAnswering()
                        self.powerState = .on
                    }

                    // Trigger status refresh shortly after volume/channel commands
                    if code == TVKey.volumeUp.rawValue || code == TVKey.volumeDown.rawValue || code == TVKey.mute.rawValue {
                        Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            await self?.refreshStatus()
                        }
                    }
                    return
                } else if httpResp.statusCode == 401 && allowAuthRetry {
                    // Session expired or unauthenticated; attempt re-pairing
                    markAnswering()
                    let success = await self.pairWithSavedKey()
                    if success {
                        await self.performSendKey(code: code, label: label, pressed: pressed,
                                                  allowAuthRetry: false, allowRelocate: false)
                        return
                    }
                } else {
                    let respStr = String(data: data, encoding: .utf8) ?? ""
                    NSLog("LG TV rejected key %@ (HTTP %d): %@", label, httpResp.statusCode, respStr)
                }
            }
        } catch {
            if allowRelocate, await self.relocateTVIfNeeded() {
                await self.performSendKey(code: code, label: label, pressed: pressed,
                                          allowAuthRetry: allowAuthRetry, allowRelocate: false)
                return
            }
            switch await checkTVPing() {
            case .aliveSameTV:
                markNotAnswering()
            case .ipConflict(let otherMac):
                markNotAnswering(conflictWith: otherMac)
            case .unreachable:
                markUnreachable()
                return
            }
            guard Date().timeIntervalSince(pressed) < keyPatience else {
                NSLog("LG TV: tecla %@ descartada, a TV ficou %.0f s sem aceitar comandos", label, keyPatience)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await performSendKey(code: code, label: label, pressed: pressed,
                                 allowAuthRetry: allowAuthRetry, allowRelocate: false)
        }
    }

    private enum PingStatus {
        case unreachable
        case aliveSameTV
        case ipConflict(otherMac: String)
    }

    /// Distinguishes standby (network interface down, no ping) from an awake TV whose HTTP port timed
    /// out, and from an active LAN IP conflict where another MAC answered ARP at the TV's IP right
    /// after the TV was responding there. Right after the power key the TV still answers ping briefly
    /// while shutting down.
    private func checkTVPing() async -> PingStatus {
        if let poweredOffAt, Date().timeIntervalSince(poweredOffAt) < 30 { return .unreachable }
        let host = config.host
        let probe = pingProbe
        let lookup = arpLookup
        guard await probe(host) else { return .unreachable }
        guard let expectedMac = config.mac?.lowercased() else { return .aliveSameTV }
        let actualMac = await Task.detached { lookup(host) }.value?.lowercased()
        if actualMac == expectedMac {
            return .aliveSameTV
        }
        if let actualMac, let lastAnsweredAt, Date().timeIntervalSince(lastAnsweredAt) < ipConflictWindow {
            return .ipConflict(otherMac: actualMac)
        }
        return .unreachable
    }

    private func markNotAnswering(conflictWith otherMac: String? = nil) {
        let isConflict = (otherMac != nil)
        if let otherMac, !ipConflict {
            NSLog("LG TV: conflito de IP em %@ — outro aparelho (%@) respondeu no lugar da TV (%@)",
                  config.host, otherMac, config.mac ?? "?")
        } else if !isConflict, !notAnswering {
            NSLog("LG TV: ligada (responde ao ping), mas sem aceitar comandos na porta %d", config.port)
        }
        notAnswering = true
        ipConflict = isConflict
        if powerState != .turningOn {
            powerState = .on
            powerOnError = nil
        }
    }

    private func markAnswering() {
        if notAnswering {
            NSLog("LG TV: voltou a aceitar comandos")
        }
        notAnswering = false
        ipConflict = false
        poweredOffAt = nil
        lastAnsweredAt = Date()
    }

    /// No answer from the TV, not even to ping: standby (unless we are switching it on).
    private func markUnreachable() {
        notAnswering = false
        ipConflict = false
        if powerState != .turningOn {
            powerState = .off
        }
    }

    /// Where the TV answers now (nil when it wasn't found); a new IP (DHCP) goes to the configuration.
    /// The configured IP and the ARP cache are checked every time. Every failed request asks for this,
    /// and this TV often stalls for many seconds, so the automatic SSDP search runs at most every 30 s.
    /// `askedByUser` (Settings) skips that wait and may use the UDAP search, whose popup on the TV is
    /// expected there.
    func locateTV(askedByUser: Bool = false) async -> String? {
        var found = await LGTVDiscovery.probeKnownHosts(of: config)
        if found == nil, askedByUser || Date().timeIntervalSince(lastAutomaticSearch) >= 30 {
            if !askedByUser {
                lastAutomaticSearch = Date()
            }
            found = await LGTVDiscovery.locate(matching: config, allowUDAP: askedByUser)
        }
        guard let newHost = found else { return nil }
        if newHost != config.host {
            NSLog("LG TV migrou de IP: %@ -> %@", config.host, newHost)
            self.config.host = newHost
            self.lastAnsweredAt = nil
            self.notAnswering = false
            self.ipConflict = false
            if self.config.mac == nil {
                self.config.mac = await Task.detached { ARPCache.mac(for: newHost) }.value
            }
            self.saveConfigToDisk()
        } else if self.config.mac == nil,
                  let mac = await Task.detached(operation: { ARPCache.mac(for: newHost) }).value {
            self.config.mac = mac
            self.saveConfigToDisk()
        }
        return newHost
    }

    /// Checks if the TV has moved to another IP address (DHCP) and updates configuration.
    func relocateTVIfNeeded() async -> Bool {
        let oldHost = config.host
        guard let newHost = await locateTV() else { return false }
        return newHost != oldHost
    }
    
    // MARK: - Status Queries

    /// What the TV is showing, as a JPEG (the screen_image query). Nil when the TV doesn't answer.
    func screenImage() async -> Data? {
        let basePath = config.protocolType == "udap" ? "/udap/api/data" : "/roap/api/data"
        let request = createRequest(path: "\(basePath)?target=screen_image&session=\(config.session ?? "")")
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           data.starts(with: [0xFF, 0xD8]) {
            return data
        }
        if await relocateTVIfNeeded() {
            let retryReq = createRequest(path: "\(basePath)?target=screen_image&session=\(config.session ?? "")")
            if let (data, response) = try? await URLSession.shared.data(for: retryReq),
               (response as? HTTPURLResponse)?.statusCode == 200,
               data.starts(with: [0xFF, 0xD8]) {
                return data
            }
        }
        return nil
    }

    func refreshStatus() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        
        await performStatusRefresh(allowRelocate: true)
    }

    private func performStatusRefresh(allowRelocate: Bool) async {
        let basePath = config.protocolType == "udap" ? "/udap/api/data" : "/roap/api/data"
        var session = config.session ?? ""
        let volPath = "\(basePath)?target=volume_info&session=\(session)"
        let volReq = createRequest(path: volPath)

        do {
            let (data, resp) = try await URLSession.shared.data(for: volReq)
            if let httpResp = resp as? HTTPURLResponse {
                if httpResp.statusCode == 200 {
                    markAnswering()
                    self.powerState = .on
                    self.powerOnError = nil
                    if config.mac == nil {
                        let host = config.host
                        let lookup = arpLookup
                        if let mac = await Task.detached(operation: { lookup(host) }).value {
                            self.config.mac = mac
                            self.saveConfigToDisk()
                        }
                    }
                    if let str = String(data: data, encoding: .utf8) {
                        if let muteVal = Self.extractXMLTag(from: str, tag: "mute") {
                            self.isMuted = (muteVal.lowercased() == "true")
                        }
                        if let lvlVal = Self.extractXMLTag(from: str, tag: "level"), let lvl = Int(lvlVal) {
                            self.volumeLevel = lvl
                        }
                    }
                } else if httpResp.statusCode == 401 {
                    markAnswering()
                    // Session expired or unauthenticated; attempt re-pairing
                    if await self.pairWithSavedKey() {
                        session = config.session ?? ""
                        let retryVolPath = "\(basePath)?target=volume_info&session=\(session)"
                        let retryReq = createRequest(path: retryVolPath)
                        if let (vData, vResp) = try? await URLSession.shared.data(for: retryReq),
                           (vResp as? HTTPURLResponse)?.statusCode == 200,
                           let str = String(data: vData, encoding: .utf8) {
                            self.powerState = .on
                            self.powerOnError = nil
                            if let muteVal = Self.extractXMLTag(from: str, tag: "mute") {
                                self.isMuted = (muteVal.lowercased() == "true")
                            }
                            if let lvlVal = Self.extractXMLTag(from: str, tag: "level"), let lvl = Int(lvlVal) {
                                self.volumeLevel = lvl
                            }
                        }
                    } else {
                        switch await checkTVPing() {
                        case .aliveSameTV:
                            markNotAnswering()   // it answered 401: on, but re-pairing got no answer
                        case .ipConflict(let otherMac):
                            markNotAnswering(conflictWith: otherMac)
                        case .unreachable:
                            markUnreachable()
                        }
                        return
                    }
                } else {
                    if allowRelocate, await self.relocateTVIfNeeded() {
                        await self.performStatusRefresh(allowRelocate: false)
                        return
                    }
                    markUnreachable()
                    return
                }
            }
        } catch {
            // Check first whether DHCP moved the TV to another IP; otherwise use ping + MAC to tell
            // standby apart from a transient HTTP stall or an active LAN IP conflict.
            if allowRelocate, await self.relocateTVIfNeeded() {
                await self.performStatusRefresh(allowRelocate: false)
                return
            }
            switch await checkTVPing() {
            case .aliveSameTV:
                markNotAnswering()
            case .ipConflict(let otherMac):
                markNotAnswering(conflictWith: otherMac)
            case .unreachable:
                markUnreachable()
            }
            return   // no point asking for the channel as well
        }
        
        // Also fetch current channel / input
        session = config.session ?? ""
        let chPath = "\(basePath)?target=cur_channel&session=\(session)"
        let chReq = createRequest(path: chPath)
        if let (chData, chResp) = try? await URLSession.shared.data(for: chReq),
           let chHttp = chResp as? HTTPURLResponse, chHttp.statusCode == 200,
           let str = String(data: chData, encoding: .utf8) {
            if let src = Self.extractXMLTag(from: str, tag: "inputSourceName"), !src.isEmpty {
                self.inputSourceName = src
            }
            if let major = Self.extractXMLTag(from: str, tag: "major"), major != "65520", !major.isEmpty {
                self.channelMajor = major
            }
        }
    }
    
    // MARK: - Pairing & Discovery
    
    func requestPairingKeyOnTV() async -> (success: Bool, message: String) {
        let path = config.protocolType == "udap" ? "/udap/api/pairing" : "/roap/api/auth"
        let xml: String
        if config.protocolType == "udap" {
            xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><envelope><api type=\"pairing\"><name>showKey</name></api></envelope>"
        } else {
            xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><auth><type>AuthKeyReq</type></auth>"
        }
        
        let req = createRequest(path: path, method: "POST", body: xml)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let httpResp = resp as? HTTPURLResponse {
                if httpResp.statusCode == 200 {
                    return (true, "Código exibido na tela da TV! Digite os 6 números abaixo.")
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                return (false, "TV retornou status \(httpResp.statusCode): \(body)")
            }
        } catch {
            return (false, "Falha ao conectar: \(error.localizedDescription)")
        }
        return (false, "Resposta desconhecida")
    }
    
    func confirmPairing(key: String) async -> (success: Bool, message: String) {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanKey.count >= 6 else {
            return (false, "Chave deve ter 6 dígitos.")
        }
        
        let path = config.protocolType == "udap" ? "/udap/api/pairing" : "/roap/api/auth"
        let xml: String
        if config.protocolType == "udap" {
            xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><envelope><api type=\"pairing\"><name>hello</name><value>\(cleanKey)</value><port>\(config.port)</port></api></envelope>"
        } else {
            xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><auth><type>AuthReq</type><value>\(cleanKey)</value></auth>"
        }
        
        let req = createRequest(path: path, method: "POST", body: xml)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let httpResp = resp as? HTTPURLResponse {
                if httpResp.statusCode == 200 {
                    markAnswering()
                    self.config.pairingKey = cleanKey
                    if let str = String(data: data, encoding: .utf8) {
                        if let session = Self.extractXMLTag(from: str, tag: "session") {
                            self.config.session = session
                        }
                    }
                    let host = config.host
                    if let mac = await Task.detached(operation: { ARPCache.mac(for: host) }).value {
                        self.config.mac = mac
                    }
                    self.saveConfigToDisk()
                    self.powerState = .on
                    self.powerOnError = nil
                    if !isRefreshing {
                        await self.refreshStatus()
                    }
                    return (true, "Pareamento concluído com sucesso!")
                } else if httpResp.statusCode == 401 {
                    return (false, "Código incorreto! Confira os dígitos exibidos na TV.")
                } else {
                    return (false, "Erro HTTP \(httpResp.statusCode)")
                }
            }
        } catch {
            return (false, "Erro de rede: \(error.localizedDescription)")
        }
        return (false, "Erro inesperado")
    }
    
    private func pairWithSavedKey() async -> Bool {
        guard let key = config.pairingKey, !key.isEmpty else { return false }
        let res = await confirmPairing(key: key)
        return res.success
    }
    
    // MARK: - Utilities
    
    nonisolated static func extractXMLTag(from xml: String, tag: String) -> String? {
        let pattern = "<\(tag)>\\s*([^<]+?)\\s*</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: xml, options: [], range: NSRange(xml.startIndex..., in: xml)),
              let range = Range(match.range(at: 1), in: xml) else {
            return nil
        }
        return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
