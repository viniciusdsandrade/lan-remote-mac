import SwiftUI
import AppKit

struct RemoteView: View {
    @ObservedObject var client: LGTVClient
    @StateObject private var help = HelpCenter()
    @State private var showSettings: Bool = false
    @State private var showGuide: Bool = false
    @State private var showKeypad: Bool = false
    @State private var showPowerAlert: Bool = false
    @State private var alwaysOnTop: Bool = false

    /// Keys can't reach the TV right now: dim the remote and show how to switch it on.
    private var tvAsleep: Bool { client.powerState == .off || client.powerState == .turningOn }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    // MARK: - TV Header & Status Bar
                    headerView

                    // MARK: - How to switch the TV on (only while it is off)
                    if tvAsleep {
                        PowerBanner(client: client, openSettings: { showSettings = true })
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // MARK: - Power & Primary Actions
                    topActionsView

                    // MARK: - Collapsible Numeric Keypad
                    if showKeypad {
                        numericKeypadView
                            .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)),
                                                    removal: .opacity.combined(with: .move(edge: .top))))
                    }

                    VStack(spacing: 12) {
                        navigationSection
                        volumeSection
                        featuresSection
                        mediaSection
                        colorKeysSection
                    }
                    .opacity(tvAsleep ? 0.45 : 1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .animation(.easeInOut(duration: 0.2), value: tvAsleep)
            }

            // MARK: - What the control under the mouse does
            HelpPanel(openGuide: { showGuide = true })
        }
        .frame(width: 320)
        .background(
            LinearGradient(
                colors: [Color(white: 0.14), Color(white: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .environmentObject(help)
        .sheet(isPresented: $showSettings) {
            SettingsView(client: client)
        }
        .sheet(isPresented: $showGuide) {
            ButtonGuideView()
        }
        .alert(isPresented: $showPowerAlert) {
            Alert(
                title: Text("Desligar a TV?"),
                message: Text(client.canTurnOnTV
                    ? "Para ligar de novo, use o botão Ligar do app: \(client.powerOnHelpers ?? "a TV Box") tenta ligar a TV pelo HDMI."
                    : "Esta TV não liga pela rede sozinha. Para ligar pelo app depois, configure a TV Box ou o PS5 em Configurações."),
                primaryButton: .destructive(Text("Desligar")) {
                    client.sendKey(.power)
                },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        }
    }

    // MARK: - Header
    private var headerView: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                // Online LED Indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.8), radius: 3)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tvName)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(statusColor)
                        .help(statusHelp)
                }

                Spacer()

                headerButton(alwaysOnTop ? "pin.fill" : "pin", tint: alwaysOnTop ? Color.yellow : Color(white: 0.6),
                             help: Help.pin, action: toggleAlwaysOnTop)

                // Refresh Status
                Button(action: {
                    Task { await client.refreshStatus() }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(white: 0.7))
                        .rotationEffect(.degrees(client.isRefreshing ? 360 : 0))
                        .animation(client.isRefreshing ? Animation.linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: client.isRefreshing)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .controlHelp(Help.refresh)

                headerButton("questionmark.circle", help: Help.guideSheet) { showGuide = true }
                headerButton("gearshape.fill", help: Help.settings) { showSettings = true }
            }

            // Sub-status line: Volume & Current Source
            if client.powerState == .on {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: client.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10))
                            .foregroundColor(client.isMuted ? Color.orange : Color(white: 0.8))
                        Text(client.isMuted ? "Mudo" : "Vol \(client.volumeLevel)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(white: 0.85))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(white: 0.2))
                    .cornerRadius(6)
                    .controlHelp(Help.volumeStatus)

                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "tv")
                            .font(.system(size: 10))
                            .foregroundColor(Color(red: 0.4, green: 0.7, blue: 1.0))
                        Text(client.inputSourceName.isEmpty ? "TV" : client.inputSourceName)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(Color(white: 0.9))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(white: 0.2))
                    .cornerRadius(6)
                    .controlHelp(Help.inputStatus)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(white: 0.16))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(white: 0.25), lineWidth: 1)
        )
    }

    private var tvName: String {
        let model = (client.config.model ?? "").split(separator: "-").first.map(String.init) ?? ""
        return model.isEmpty ? "TV LG" : "TV LG \(model)"
    }

    private var statusText: String {
        switch client.powerState {
        case .on:
            if client.ipConflict { return "Ligada · conflito de IP" }
            return client.notAnswering ? "Ligada · sem resposta" : "Ligada"
        case .off: return "Desligada"
        case .turningOn: return "Ligando…"
        case .unknown: return "Verificando…"
        }
    }

    private var statusHelp: String {
        guard client.powerState == .on, client.notAnswering else { return "" }
        if client.ipConflict {
            return "Outro aparelho na rede respondeu no mesmo IP da TV (conflito de IP). "
                + "Fixe um IP para a TV no roteador ou use Buscar TV na rede em Configurações."
        }
        return "A TV respondeu ao ping, mas a porta 8080 não aceitou conexão agora. "
            + "Os botões apertados aguardam até 15 s para sair na ordem."
    }

    private var statusColor: Color {
        switch client.powerState {
        case .on: return client.notAnswering ? Color.orange : Color.green
        case .off: return Color(red: 0.95, green: 0.35, blue: 0.3)
        case .turningOn: return Color(red: 0.4, green: 0.7, blue: 1.0)
        case .unknown: return Color(white: 0.55)
        }
    }

    private func headerButton(_ symbol: String, tint: Color = Color(white: 0.7), help: ControlHelp,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .controlHelp(help)
    }

    // MARK: - Power & Top Row
    private var topActionsView: some View {
        HStack(spacing: 8) {
            if tvAsleep {
                Button(action: { client.canTurnOnTV ? client.turnOn() : (showSettings = true) }) {
                    ControlLabel(help: Help.powerOn)
                }
                .buttonStyle(PowerButtonStyle(turnsOn: true))
                .disabled(client.powerState == .turningOn)
                .controlHelp(Help.powerOn)
            } else {
                Button(action: { showPowerAlert = true }) {
                    ControlLabel(help: Help.powerOff)
                }
                .buttonStyle(PowerButtonStyle())
                .controlHelp(Help.powerOff)
            }

            keyButton(.input, Help.input)

            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showKeypad.toggle() } }) {
                ControlLabel(help: Help.keypad)
            }
            .buttonStyle(RemoteButtonStyle(bg: showKeypad ? Color(red: 0.18, green: 0.35, blue: 0.55) : Color(white: 0.20),
                                           height: 46))
            .controlHelp(Help.keypad)
        }
    }

    // MARK: - Numeric Keypad
    private var numericKeypadView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                keypadButton(.digit1)
                keypadButton(.digit2)
                keypadButton(.digit3)
            }
            HStack(spacing: 6) {
                keypadButton(.digit4)
                keypadButton(.digit5)
                keypadButton(.digit6)
            }
            HStack(spacing: 6) {
                keypadButton(.digit7)
                keypadButton(.digit8)
                keypadButton(.digit9)
            }
            HStack(spacing: 6) {
                keypadButton(.previousChannel, help: Help.previousChannel)
                keypadButton(.digit0)
                keypadButton(.info, help: Help.info)
            }
        }
        .padding(8)
        .background(Color(white: 0.16))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(white: 0.25), lineWidth: 1)
        )
    }

    private func keypadButton(_ key: TVKey, help: ControlHelp = Help.digit) -> some View {
        Button(action: { client.sendKey(key) }) {
            if help == Help.digit {
                Text(key.label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            } else {
                HStack(spacing: 4) {
                    Image(systemName: help.symbol)
                    Text(help.label)
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
        }
        .buttonStyle(RemoteButtonStyle(bg: Color(white: 0.22), height: 32, cornerRadius: 8))
        .controlHelp(help)
    }

    private func keyButton(_ key: TVKey, _ help: ControlHelp, bg: Color = Color(white: 0.20),
                           height: CGFloat = 46) -> some View {
        Button(action: { client.sendKey(key) }) {
            ControlLabel(help: help)
        }
        .buttonStyle(RemoteButtonStyle(bg: bg, height: height, cornerRadius: 10))
        .controlHelp(help)
    }

    // MARK: - Navigation D-Pad & Controls
    private var navigationSection: some View {
        RemoteSection(title: "Navegação") {
            HStack(spacing: 8) {
                keyButton(.quickMenu, Help.quickMenu)
                keyButton(.home, Help.home, bg: Color(red: 0.15, green: 0.40, blue: 0.65))
                keyButton(.menu, Help.menu)
            }

            DPadView(onKey: client.sendKey)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)

            HStack(spacing: 8) {
                keyButton(.back, Help.back)
                keyButton(.exit, Help.exit)
                keyButton(.epg, Help.guide)
            }
        }
    }

    // MARK: - Rockers (Volume & Channel)
    private var volumeSection: some View {
        RemoteSection(title: "Volume e canal") {
            HStack(spacing: 12) {
                RockerSwitchView(title: "VOLUME", upSymbol: "plus", downSymbol: "minus",
                                 upKey: .volumeUp, downKey: .volumeDown,
                                 upHelp: Help.volumeUp, downHelp: Help.volumeDown, onKey: client.sendKey)

                VStack(spacing: 8) {
                    Button(action: { client.sendKey(.mute) }) {
                        VStack(spacing: 3) {
                            Image(systemName: client.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(client.isMuted ? Color.orange : Color.white)
                            Text(client.isMuted ? "Sem som" : Help.mute.label)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        }
                    }
                    .buttonStyle(RemoteButtonStyle(bg: client.isMuted ? Color(red: 0.5, green: 0.25, blue: 0.1) : Color(white: 0.22),
                                                   height: 50, cornerRadius: 10))
                    .controlHelp(Help.mute)

                    keyButton(.liveTv, Help.liveTV, bg: Color(white: 0.22), height: 50)
                }
                .frame(maxWidth: .infinity)

                RockerSwitchView(title: "CANAL", upSymbol: "chevron.up", downSymbol: "chevron.down",
                                 upKey: .channelUp, downKey: .channelDown,
                                 upHelp: Help.channelUp, downHelp: Help.channelDown, onKey: client.sendKey)
            }
        }
    }

    // MARK: - Smart Keys
    private var featuresSection: some View {
        RemoteSection(title: "Recursos da TV") {
            HStack(spacing: 6) {
                keyButton(.apps, Help.apps)
                keyButton(.aspectRatio, Help.aspect)
                keyButton(.key3d, Help.threeD)
                keyButton(.simplink, Help.simplink)
            }
        }
    }

    // MARK: - Media Controls
    private var mediaSection: some View {
        RemoteSection(title: "Reprodução") {
            HStack(spacing: 6) {
                mediaButton(.rewind, Help.rewind)
                mediaButton(.play, Help.play, bg: Color(red: 0.15, green: 0.45, blue: 0.25))
                mediaButton(.pause, Help.pause)
                mediaButton(.stop, Help.stop)
                mediaButton(.fastForward, Help.forward)
            }
        }
    }

    private func mediaButton(_ key: TVKey, _ help: ControlHelp, bg: Color = Color(white: 0.20)) -> some View {
        Button(action: { client.sendKey(key) }) {
            Image(systemName: help.symbol)
                .font(.system(size: 12))
        }
        .buttonStyle(RemoteButtonStyle(bg: bg, height: 32, cornerRadius: 8))
        .controlHelp(help)
    }

    // MARK: - Color Buttons
    private var colorKeysSection: some View {
        RemoteSection(title: "Botões coloridos") {
            HStack(spacing: 8) {
                colorKey(.red, Help.red)
                colorKey(.green, Help.green)
                colorKey(.yellow, Help.yellow)
                colorKey(.blue, Help.blue)
            }
        }
    }

    private func colorKey(_ key: TVKey, _ help: ControlHelp) -> some View {
        Button(action: { client.sendKey(key) }) {
            EmptyView()
        }
        .buttonStyle(ColorKeyStyle(color: help.tint ?? Color.gray))
        .controlHelp(help)
    }

    // MARK: - Always on Top Window Control
    private func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        if let window = NSApplication.shared.windows.first {
            window.level = alwaysOnTop ? .floating : .normal
        }
    }
}

// MARK: - Power banner

/// Shown while the TV is off: says why the remote is dimmed and offers the way to switch it on.
private struct PowerBanner: View {
    @ObservedObject var client: LGTVClient
    let openSettings: () -> Void
    @State private var nudge = false

    private var turningOn: Bool { client.powerState == .turningOn }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.17, green: 0.25, blue: 0.33))
                        .frame(width: 34, height: 34)
                    if turningOn {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(red: 0.55, green: 0.78, blue: 1.0))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(turningOn ? "Ligando a TV…" : "A TV está desligada")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(client.powerOnError != nil && !turningOn ? Color.orange : Color(white: 0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !turningOn {
                if client.canTurnOnTV {
                    Button(action: client.turnOn) {
                        Label(client.powerOnError == nil ? "Ligar a TV" : "Tentar de novo", systemImage: "power")
                    }
                    .buttonStyle(RemoteButtonStyle(bg: Color(red: 0.13, green: 0.55, blue: 0.27), height: 34, cornerRadius: 9))
                    .controlHelp(Help.powerOn)
                } else {
                    Button(action: openSettings) {
                        Label("Configurar para ligar pelo app", systemImage: "gearshape")
                    }
                    .buttonStyle(RemoteButtonStyle(bg: Color(red: 0.15, green: 0.40, blue: 0.65), height: 34, cornerRadius: 9))
                    .controlHelp(Help.settings)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.11, green: 0.15, blue: 0.19)))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(nudge ? Color.orange : Color(red: 0.24, green: 0.36, blue: 0.48), lineWidth: nudge ? 2 : 1)
        )
        .scaleEffect(nudge ? 1.02 : 1)
        .onChange(of: client.attentionPulse) { _ in
            // A key was pressed with the TV off: point at the way out instead of failing silently.
            withAnimation(.easeOut(duration: 0.12)) { nudge = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeIn(duration: 0.25)) { nudge = false }
            }
        }
    }

    private var message: String {
        if turningOn { return client.powerOnStep }
        if let error = client.powerOnError { return error }
        if let helpers = client.powerOnHelpers {
            return "Toque em Ligar: \(helpers) tenta ligar a TV pelo HDMI. A imagem volta em segundos; o controle, em até 1 minuto."
        }
        return "Em standby esta TV desliga a rede. Dá para ligá-la pela TV Box ou pelo PS5 ligados no HDMI: configure uma vez."
    }
}
