import SwiftUI

struct SettingsView: View {
    @ObservedObject var client: LGTVClient
    @Environment(\.presentationMode) var presentationMode

    @State private var hostInput: String = ""
    @State private var portInput: String = "8080"
    @State private var pairingKeyInput: String = ""
    @State private var boxCodeInput: String = ""
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
                    boxSection
                    networkSection
                    pairingSection
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 640)
        .background(Color(white: 0.11))
        .onAppear {
            hostInput = client.config.host
            portInput = String(client.config.port)
            pairingKeyInput = client.config.pairingKey ?? ""
            if client.box?.paired != true && client.discoveredBoxes.isEmpty {
                client.searchBoxes()
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text(alertTitle), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: - Turning the TV on through the TV Box

    private var boxSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Ligar a TV pelo app")

            Text("Em standby esta TV desliga a rede, então nenhum comando chega até ela. O app pede para a TV Box ligada no HDMI ligar a TV pelo SIMPLINK (HDMI-CEC). Basta parear uma vez.")
                .font(.caption)
                .foregroundColor(Color(white: 0.7))
                .fixedSize(horizontal: false, vertical: true)

            if let box = client.box, box.paired {
                pairedRow(name: box.name, detail: "Pareada · \(box.host)", forget: client.forgetBox)
                if client.powerState == .off {
                    Button(action: client.turnOn) {
                        Label("Ligar a TV agora", systemImage: "power")
                    }
                    .buttonStyle(RemoteButtonStyle(bg: Color(red: 0.13, green: 0.55, blue: 0.27), height: 34))
                }
            } else {
                boxPairingSteps
            }

            requirements
        }
        .padding(14)
        .background(Color(white: 0.15))
        .cornerRadius(12)
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
