import SwiftUI

struct SettingsView: View {
    @ObservedObject var client: LGTVClient
    @Environment(\.presentationMode) var presentationMode

    @State private var hostInput: String = ""
    @State private var portInput: String = "8080"
    @State private var pairingKeyInput: String = ""
    @State private var boxCodeInput: String = ""
    @State private var psnInput: String = ""
    @State private var consolePinInput: String = ""
    @State private var selectedConsoleId: String?
    @State private var showPSNLogin: Bool = false
    @State private var alertTitle: String = ""
    @State private var alertMessage: String = ""
    @State private var showAlert: Bool = false
    @State private var isProcessing: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Configurações")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button("Fechar") {
                    client.cancelBoxPairing()
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(RemoteButtonStyle(bg: Color(white: 0.25), height: 28, cornerRadius: 6))
                .frame(width: 70)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().background(Color(white: 0.3))

            ScrollView {
                VStack(spacing: 16) {
                    powerSection
                    networkSection
                    pairingSection
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 700)
        .background(Color(white: 0.11))
        .onAppear {
            hostInput = client.config.host
            portInput = String(client.config.port)
            pairingKeyInput = client.config.pairingKey ?? ""
            if client.box?.paired != true && client.discoveredBoxes.isEmpty {
                client.searchBoxes()
            }
            if client.console?.registered != true && client.discoveredConsoles.isEmpty {
                client.searchConsoles()
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text(alertTitle), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
        .sheet(isPresented: $showPSNLogin) {
            PSNLoginSheet { redirect in
                psnInput = ""
                client.usePSNAccount(redirect)
            }
        }
    }

    // MARK: - Turning the TV on through the TV Box or the PS5

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Ligar a TV pelo app")

            Text("Em standby esta TV desliga a rede, então nenhum comando chega até ela. O app pede a um aparelho ligado no HDMI que a ligue pelo SIMPLINK (HDMI-CEC): a TV Box e, como reserva, o PS5 (a TV Box pode sair do Wi-Fi depois de horas parada). Acordado pela rede, o PS5 não liga a TV, então o app o reinicia pelo Uso remoto e ele liga a TV ao voltar (leva cerca de 2 minutos e fecha jogos suspensos). Basta configurar uma vez.")
                .font(.caption)
                .foregroundColor(Color(white: 0.7))
                .fixedSize(horizontal: false, vertical: true)

            if client.canTurnOnTV && client.powerState == .off {
                Button(action: client.turnOn) {
                    Label("Ligar a TV agora", systemImage: "power")
                }
                .buttonStyle(RemoteButtonStyle(bg: Color(red: 0.13, green: 0.55, blue: 0.27), height: 34))
            }

            deviceTitle("TV Box (Android TV)", symbol: "tv.and.mediabox")
            if let box = client.box, box.paired {
                pairedRow(name: box.name, detail: "Pareada · \(box.host)", forget: client.forgetBox)
            } else {
                boxPairingSteps
            }

            Divider().background(Color(white: 0.3))

            deviceTitle("PlayStation 5", symbol: "gamecontroller")
            if let console = client.console, console.registered {
                pairedRow(name: console.name, detail: "Registrado · \(console.host)", forget: client.forgetConsole)
            } else {
                consoleSetupSteps
            }

            requirements
        }
        .padding(14)
        .background(Color(white: 0.15))
        .cornerRadius(12)
    }

    private func deviceTitle(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(Color(white: 0.85))
    }

    private func pairedRow(name: String, detail: String, forget: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(Color(white: 0.6))
            }
            Spacer()
            Button("Esquecer", action: forget)
                .buttonStyle(RemoteButtonStyle(bg: Color(white: 0.22), height: 28, cornerRadius: 6))
                .frame(width: 84)
        }
    }

    // MARK: PS5 registration (once)

    @ViewBuilder
    private var consoleSetupSteps: some View {
        switch client.consolePairingStage {
        case .searching:
            progressRow("Procurando PS5 na rede…")
        case .working:
            progressRow("Registrando no PS5…")
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            consoleCandidates
        case .idle:
            consoleCandidates
        }
    }

    /// The console chosen in the list; with one console found there is nothing to choose.
    private var selectedConsole: DiscoveredPlayStation? {
        client.discoveredConsoles.first { $0.id == selectedConsoleId }
            ?? (client.discoveredConsoles.count == 1 ? client.discoveredConsoles.first : nil)
    }

    @ViewBuilder
    private var consoleCandidates: some View {
        if client.discoveredConsoles.isEmpty {
            Text("Nenhum PS5 encontrado. Ele precisa estar na tomada e na mesma rede do Mac, ligado ou em repouso com 'Permanecer conectado à internet'.")
                .font(.caption)
                .foregroundColor(Color(white: 0.75))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: client.searchConsoles) {
                Label("Procurar PS5", systemImage: "magnifyingglass")
            }
            .buttonStyle(RemoteButtonStyle(bg: Color(white: 0.22), height: 30))
        } else {
            ForEach(client.discoveredConsoles) { candidate in
                HStack(spacing: 10) {
                    Image(systemName: selectedConsole?.id == candidate.id ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundColor(Color(red: 0.4, green: 0.7, blue: 1.0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.console.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text("\(candidate.console.host) · \(candidate.awake ? "Ligado" : "Em repouso")")
                            .font(.caption)
                            .foregroundColor(Color(white: 0.6))
                    }
                    Spacer()
                }
                .padding(10)
                .background(Color(white: 0.19))
                .cornerRadius(10)
                .contentShape(Rectangle())
                .onTapGesture { selectedConsoleId = candidate.id }
            }

            stepText(1, "Conta PSN: clique em Entrar na PSN e faça o login na janela que abre, com a conta que você usa no PS5. O app pega o id da conta sozinho; não há nada para procurar nem copiar.")
            HStack(spacing: 8) {
                Button("Entrar na PSN") { showPSNLogin = true }
                    .buttonStyle(RemoteButtonStyle(bg: Color(red: 0.2, green: 0.4, blue: 0.65), height: 28, cornerRadius: 6))
                    .frame(width: 110)
                    .disabled(client.psnStage == .working)
                TextField("ou cole o id da conta, se já o tiver", text: $psnInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit(usePSNAccount)
                Button("Usar", action: usePSNAccount)
                    .buttonStyle(RemoteButtonStyle(bg: Color(white: 0.25), height: 28, cornerRadius: 6))
                    .frame(width: 56)
                    .disabled(psnInput.trimmingCharacters(in: .whitespaces).isEmpty || client.psnStage == .working)
            }
            switch client.psnStage {
            case .working:
                progressRow("Conferindo a conta na PSN…")
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                if client.psnAccountId != nil {
                    Label("Conta PSN pronta.", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            stepText(2, "No PS5 ligado, com a TV na entrada dele: Configurações › Sistema › Reprodução Remota › Vincular dispositivo. Digite o PIN de 8 números que aparece:")
            HStack(spacing: 8) {
                TextField("00000000", text: $consolePinInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .onChange(of: consolePinInput) { value in
                        let cleaned = String(value.filter(\.isNumber).prefix(8))
                        if cleaned != value { consolePinInput = cleaned }
                    }
                    .onSubmit(registerConsole)
                Button("Registrar", action: registerConsole)
                    .buttonStyle(RemoteButtonStyle(bg: Color(red: 0.15, green: 0.55, blue: 0.25), height: 30, cornerRadius: 6))
                    .frame(width: 110)
                    .disabled(consolePinInput.count != 8 || client.psnAccountId == nil || selectedConsole == nil)
            }
        }
    }

    private func usePSNAccount() {
        let input = psnInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        client.usePSNAccount(input)
    }

    private func registerConsole() {
        guard consolePinInput.count == 8, let candidate = selectedConsole else { return }
        client.registerConsole(candidate, pin: consolePinInput)
    }

    // MARK: TV Box pairing (once)

    @ViewBuilder
    private var boxPairingSteps: some View {
        switch client.boxPairingStage {
        case .searching:
            progressRow("Procurando TV Box na rede…")
        case .requestingCode:
            progressRow("Pedindo o código para a TV Box…")
        case .waitingForCode, .confirming:
            codeEntry
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            candidates
        case .idle:
            candidates
        }
    }

    @ViewBuilder
    private var candidates: some View {
        if client.discoveredBoxes.isEmpty {
            Text("Nenhuma TV Box encontrada. Ela precisa estar na tomada e no mesmo Wi-Fi do Mac.")
                .font(.caption)
                .foregroundColor(Color(white: 0.75))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: client.searchBoxes) {
                Label("Procurar de novo", systemImage: "magnifyingglass")
            }
            .buttonStyle(RemoteButtonStyle(bg: Color(white: 0.22), height: 30))
        } else {
            stepText(1, "Ligue a TV (só desta vez) e coloque na entrada HDMI da TV Box.")
            stepText(2, "Clique em Parear: um código de 6 caracteres aparece na tela da TV.")
            ForEach(client.discoveredBoxes) { candidate in
                HStack(spacing: 10) {
                    Image(systemName: "tv.and.mediabox")
                        .font(.system(size: 16))
                        .foregroundColor(Color(red: 0.4, green: 0.7, blue: 1.0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text(candidate.host)
                            .font(.caption)
                            .foregroundColor(Color(white: 0.6))
                    }
                    Spacer()
                    Button("Parear") { client.requestBoxCode(for: candidate) }
                        .buttonStyle(RemoteButtonStyle(bg: Color(red: 0.2, green: 0.4, blue: 0.65), height: 28, cornerRadius: 6))
                        .frame(width: 84)
                }
                .padding(10)
                .background(Color(white: 0.19))
                .cornerRadius(10)
            }
        }
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            stepText(3, "Digite o código que apareceu na tela da TV:")
            HStack {
                TextField("Ex.: 4F2A9C", text: $boxCodeInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .onChange(of: boxCodeInput) { value in
                        let cleaned = String(value.uppercased().filter { $0.isHexDigit }.prefix(6))
                        if cleaned != value { boxCodeInput = cleaned }
                    }
                    .onSubmit(confirmBoxCode)
                Button(client.boxPairingStage == .confirming ? "Confirmando…" : "Confirmar", action: confirmBoxCode)
                    .buttonStyle(RemoteButtonStyle(bg: Color(red: 0.15, green: 0.55, blue: 0.25), height: 30, cornerRadius: 6))
                    .frame(width: 110)
                    .disabled(boxCodeInput.count != 6 || client.boxPairingStage == .confirming)
            }
            if let error = client.boxCodeError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Button("Cancelar") {
                boxCodeInput = ""
                client.cancelBoxPairing()
            }
            .buttonStyle(PlainButtonStyle())
            .font(.caption)
            .foregroundColor(Color(white: 0.6))
        }
    }

    private var requirements: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Se a TV não ligar, confira:")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(white: 0.75))
            Text("• Na TV LG: SIMPLINK ligado (Configurações › Opções › SIMPLINK, ou o botão SIMPLINK do app).")
            Text("• Na TV Box (HDMI-CEC): Configurações › Tela e som (ou Sistema › Entradas) › HDMI-CEC ativado, e 'Desligar automaticamente' desativado.")
            Text("• Na TV Box (Energia): Configurações › Sistema › Energia e alimentação › Modo de energia em 'Consumo elevado (Sempre conectado)' e timer de desligamento em 'Nunca'.")
            Text("• No PS5 (HDMI): Configurações › Sistema › HDMI › 'Ativar Link de dispositivo HDMI'.")
            Text("• No PS5 (repouso): Configurações › Sistema › Economia de energia › Recursos disponíveis no modo de repouso › 'Permanecer conectado à internet' e 'Ativar ligar o PS5 pela rede'.")
            Text("• Para o reinício do PS5: o ps5ctl do projeto Controle PS5, pareado com o console, em ~/.local/bin/ps5ctl (ou na variável PS5CTL), e o ffmpeg.")
        }
        .font(.caption)
        .foregroundColor(Color(white: 0.6))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func confirmBoxCode() {
        guard boxCodeInput.count == 6 else { return }
        client.confirmBoxCode(boxCodeInput)
    }

    // MARK: - LG TV network

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Conexão com a TV")

            HStack {
                Text("IP da TV:")
                    .frame(width: 80, alignment: .leading)
                    .foregroundColor(Color(white: 0.8))
                TextField("192.0.2.100", text: $hostInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("Porta:")
                    .frame(width: 80, alignment: .leading)
                    .foregroundColor(Color(white: 0.8))
                TextField("8080", text: $portInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            HStack {
                Text("Modelo:")
                    .frame(width: 80, alignment: .leading)
                    .foregroundColor(Color(white: 0.8))
                Text(client.config.model ?? "LG NetCast")
                    .foregroundColor(Color(white: 0.95))
                    .font(.system(size: 13, weight: .medium))
            }

            Button(action: saveSettings) {
                Text("Salvar IP e porta")
            }
            .buttonStyle(RemoteButtonStyle(bg: Color.blue, height: 32))
        }
        .padding(14)
        .background(Color(white: 0.15))
        .cornerRadius(12)
    }

    // MARK: - LG TV pairing

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Pareamento com a TV (código de 6 dígitos)")

            Text("Caso a TV peça uma nova conexão ou código:")
                .font(.caption)
                .foregroundColor(Color(white: 0.7))

            Button(action: requestPairingCode) {
                HStack {
                    Image(systemName: "tv")
                    Text(isProcessing ? "Solicitando..." : "Pedir Código na TV")
                }
            }
            .buttonStyle(RemoteButtonStyle(bg: Color(red: 0.2, green: 0.4, blue: 0.65), height: 34))
            .disabled(isProcessing)

            HStack {
                Text("Código:")
                    .frame(width: 80, alignment: .leading)
                    .foregroundColor(Color(white: 0.8))
                TextField("6 dígitos", text: $pairingKeyInput)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }

            Button(action: confirmPairing) {
                HStack {
                    Image(systemName: "checkmark.circle")
                    Text(isProcessing ? "Confirmando..." : "Salvar e Parear")
                }
            }
            .buttonStyle(RemoteButtonStyle(bg: Color(red: 0.15, green: 0.55, blue: 0.25), height: 34))
            .disabled(isProcessing || pairingKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
        .background(Color(white: 0.15))
        .cornerRadius(12)
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(Color(red: 0.4, green: 0.7, blue: 1.0))
    }

    private func stepText(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color(red: 0.2, green: 0.4, blue: 0.65)))
            Text(text)
                .font(.caption)
                .foregroundColor(Color(white: 0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundColor(Color(white: 0.75))
        }
    }

    private func saveSettings() {
        let cleanHost = hostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPort = Int(portInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 8080
        if !cleanHost.isEmpty {
            client.config.host = cleanHost
            client.config.port = cleanPort
            client.saveConfigToDisk()
            Task {
                await client.refreshStatus()
            }
            alertTitle = "Configurações Salvas"
            alertMessage = "IP atualizado para \(cleanHost):\(cleanPort)."
            showAlert = true
        }
    }

    private func requestPairingCode() {
        isProcessing = true
        Task {
            let res = await client.requestPairingKeyOnTV()
            isProcessing = false
            alertTitle = res.success ? "Código Solicitado" : "Falha no Pareamento"
            alertMessage = res.message
            showAlert = true
        }
    }

    private func confirmPairing() {
        isProcessing = true
        Task {
            let res = await client.confirmPairing(key: pairingKeyInput)
            isProcessing = false
            alertTitle = res.success ? "Sucesso!" : "Erro no Pareamento"
            alertMessage = res.message
            showAlert = true
            if res.success {
                client.saveConfigToDisk()
            }
        }
    }
}
