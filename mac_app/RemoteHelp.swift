import SwiftUI

// What every control does, in plain words. One catalog feeds the hover help panel, the button
// guide and VoiceOver, so they never disagree.

struct ControlHelp: Identifiable, Equatable {
    let id: String
    let label: String        // caption on the button itself
    let title: String        // heading in the help panel and in the guide
    let detail: String
    let symbol: String
    var shortcut: String? = nil
    var tint: Color? = nil   // color keys
}

enum Help {
    // Power and source
    static let powerOff = ControlHelp(id: "power", label: "Desligar", title: "Desligar a TV",
        detail: "Coloca a TV em standby. Para ligar de novo sem levantar, use o botão Ligar do app.",
        symbol: "power")
    static let powerOn = ControlHelp(id: "power-on", label: "Ligar", title: "Ligar a TV",
        detail: "Acorda a TV Box (ou o PS5, se ela não responder) e liga a TV pelo HDMI. Pela TV Box, a imagem volta em segundos e o controle em até 1 minuto; pelo PS5, que precisa reiniciar, em cerca de 2 minutos.",
        symbol: "power")
    static let input = ControlHelp(id: "input", label: "Entrada", title: "Entrada (fonte da imagem)",
        detail: "Troca entre TV (antena/cabo), HDMI 1, HDMI 2, AV… Cada toque passa para a próxima.",
        symbol: "rectangle.on.rectangle", shortcut: "I")
    static let keypad = ControlHelp(id: "keypad", label: "Números", title: "Teclado numérico",
        detail: "Mostra os números para ir direto a um canal: toque 1 e 3 para o canal 13.",
        symbol: "circle.grid.3x3.fill", shortcut: "0–9")
    static let digit = ControlHelp(id: "digit", label: "", title: "Número do canal",
        detail: "Digita o número do canal. Espere um instante depois do último dígito.",
        symbol: "number", shortcut: "0–9")
    static let previousChannel = ControlHelp(id: "previous", label: "Último", title: "Último canal",
        detail: "Volta para o canal que você estava vendo antes. Bom para alternar entre dois canais.",
        symbol: "arrow.uturn.backward.circle")
    static let info = ControlHelp(id: "info", label: "Info", title: "Informações",
        detail: "Mostra o nome do programa, o horário e os dados do canal atual.",
        symbol: "info.circle")

    // Navigation
    static let quickMenu = ControlHelp(id: "qmenu", label: "Ajuste rápido", title: "Ajuste rápido (Q.Menu)",
        detail: "Atalhos sem sair do que está vendo: modo de imagem, modo de som, formato da tela e timer para desligar.",
        symbol: "slider.horizontal.3")
    static let home = ControlHelp(id: "home", label: "Início", title: "Início (Smart TV)",
        detail: "Abre a tela inicial da LG, com os aplicativos, as entradas e os ajustes.",
        symbol: "house.fill", shortcut: "H")
    static let menu = ControlHelp(id: "menu", label: "Configurações", title: "Configurações da TV",
        detail: "Menu completo: imagem, som, canais, rede, horário e opções como o SIMPLINK.",
        symbol: "gearshape")
    static let arrows = ControlHelp(id: "arrows", label: "", title: "Setas",
        detail: "Movem a seleção nos menus e nos aplicativos da TV.",
        symbol: "arrow.up.and.down.and.arrow.left.and.right", shortcut: "← ↑ → ↓")
    static let ok = ControlHelp(id: "ok", label: "OK", title: "OK (confirmar)",
        detail: "Confirma o item selecionado no menu ou no aplicativo.",
        symbol: "checkmark.circle", shortcut: "Enter")
    static let back = ControlHelp(id: "back", label: "Voltar", title: "Voltar",
        detail: "Volta um passo: fecha a tela ou o menu que está aberto agora.",
        symbol: "arrow.uturn.backward", shortcut: "Esc")
    static let exit = ControlHelp(id: "exit", label: "Sair", title: "Sair dos menus",
        detail: "Fecha todos os menus de uma vez e volta direto para o que você estava assistindo.",
        symbol: "xmark", shortcut: "X")
    static let guide = ControlHelp(id: "epg", label: "Programação", title: "Guia de programação",
        detail: "Mostra o que está passando agora e o que vem depois em cada canal da TV aberta.",
        symbol: "calendar")

    // Volume and channels
    static let volumeUp = ControlHelp(id: "vol+", label: "", title: "Aumentar volume",
        detail: "Aumenta o volume da TV um ponto por toque.", symbol: "speaker.plus", shortcut: "+")
    static let volumeDown = ControlHelp(id: "vol-", label: "", title: "Diminuir volume",
        detail: "Diminui o volume da TV um ponto por toque.", symbol: "speaker.minus", shortcut: "−")
    static let volume = ControlHelp(id: "vol", label: "Volume", title: "Volume + / −",
        detail: "Aumenta ou diminui o volume da TV, um ponto por toque.", symbol: "speaker.wave.2", shortcut: "+  −")
    static let mute = ControlHelp(id: "mute", label: "Mudo", title: "Mudo",
        detail: "Corta o som na hora. Toque de novo para o som voltar no mesmo volume.",
        symbol: "speaker.slash.fill", shortcut: "M")
    static let liveTV = ControlHelp(id: "live", label: "TV ao vivo", title: "TV ao vivo",
        detail: "Sai do aplicativo ou do menu e volta para os canais da antena ou do cabo.",
        symbol: "antenna.radiowaves.left.and.right")
    static let channelUp = ControlHelp(id: "ch+", label: "", title: "Próximo canal",
        detail: "Passa para o próximo canal da lista.", symbol: "chevron.up", shortcut: "]")
    static let channelDown = ControlHelp(id: "ch-", label: "", title: "Canal anterior",
        detail: "Volta para o canal anterior da lista.", symbol: "chevron.down", shortcut: "[")
    static let channel = ControlHelp(id: "ch", label: "Canal", title: "Canal ˄ / ˅",
        detail: "Passa para o próximo canal da lista ou volta para o anterior.", symbol: "list.number",
        shortcut: "]  [")

    // TV features
    static let apps = ControlHelp(id: "apps", label: "Apps", title: "Aplicativos",
        detail: "Abre a lista de aplicativos da Smart TV, como YouTube e o navegador.",
        symbol: "square.grid.2x2.fill")
    static let aspect = ControlHelp(id: "ratio", label: "Formato", title: "Formato da imagem",
        detail: "Muda entre 16:9, 4:3, zoom e ajustar à tela. Use quando a imagem estiver esticada ou com faixas pretas.",
        symbol: "aspectratio")
    static let threeD = ControlHelp(id: "3d", label: "3D", title: "Modo 3D",
        detail: "Liga ou desliga o modo 3D. Só faz efeito em TVs e vídeos com 3D.",
        symbol: "cube")
    static let simplink = ControlHelp(id: "simplink", label: "SIMPLINK", title: "SIMPLINK (HDMI-CEC)",
        detail: "Abre o menu dos aparelhos ligados no HDMI (TV Box, PS5). Deixe ativado: é por ele que esses aparelhos podem ligar a TV.",
        symbol: "link")

    // Playback
    static let rewind = ControlHelp(id: "rew", label: "", title: "Retroceder",
        detail: "Volta o vídeo ou a música que está tocando na TV (pen drive, apps da LG).", symbol: "backward.fill")
    static let play = ControlHelp(id: "play", label: "", title: "Reproduzir",
        detail: "Começa ou retoma o vídeo ou a música que está tocando na TV.", symbol: "play.fill", shortcut: "Espaço")
    static let pause = ControlHelp(id: "pause", label: "", title: "Pausar",
        detail: "Pausa o vídeo ou a música. Toque em Reproduzir para continuar.", symbol: "pause.fill")
    static let stop = ControlHelp(id: "stop", label: "", title: "Parar",
        detail: "Encerra a reprodução e volta para a lista de arquivos.", symbol: "stop.fill")
    static let forward = ControlHelp(id: "ff", label: "", title: "Avançar",
        detail: "Adianta o vídeo ou a música que está tocando na TV.", symbol: "forward.fill")
    static let media = ControlHelp(id: "media", label: "", title: "Reprodução",
        detail: "Retroceder, reproduzir, pausar, parar e avançar: para vídeos e músicas tocando na TV (pen drive, apps da LG).",
        symbol: "playpause.fill", shortcut: "Espaço")

    // Color keys: their meaning comes from whatever is on screen.
    private static let colorDetail = "Faz o que a TV mostrar na parte de baixo da tela para essa cor (no guia, nos arquivos do pen drive)."
    static let red = ControlHelp(id: "red", label: "", title: "Botão vermelho", detail: colorDetail,
        symbol: "circle.fill", tint: Color(red: 0.85, green: 0.18, blue: 0.18))
    static let green = ControlHelp(id: "green", label: "", title: "Botão verde", detail: colorDetail,
        symbol: "circle.fill", tint: Color(red: 0.16, green: 0.70, blue: 0.28))
    static let yellow = ControlHelp(id: "yellow", label: "", title: "Botão amarelo", detail: colorDetail,
        symbol: "circle.fill", tint: Color(red: 0.92, green: 0.75, blue: 0.15))
    static let blue = ControlHelp(id: "blue", label: "", title: "Botão azul", detail: colorDetail,
        symbol: "circle.fill", tint: Color(red: 0.18, green: 0.45, blue: 0.88))
    static let colors = ControlHelp(id: "colors", label: "", title: "Botões coloridos",
        detail: "Mudam conforme a tela: quando servem para algo, a TV mostra embaixo o que cada cor faz (no guia, nos arquivos do pen drive).",
        symbol: "circle.grid.2x1.fill")

    // App window
    static let pin = ControlHelp(id: "pin", label: "", title: "Fixar janela",
        detail: "Mantém o controle sempre por cima das outras janelas.", symbol: "pin")
    static let refresh = ControlHelp(id: "refresh", label: "", title: "Atualizar",
        detail: "Pergunta de novo à TV se ela está ligada, o volume e a entrada atual.", symbol: "arrow.clockwise")
    static let guideSheet = ControlHelp(id: "guide-sheet", label: "", title: "Guia dos botões",
        detail: "Abre a lista com o que cada botão do controle faz.", symbol: "questionmark.circle")
    static let settings = ControlHelp(id: "settings", label: "", title: "Configurações do app",
        detail: "IP da TV, pareamento, e a TV Box ou o PS5 que ligam a TV pelo HDMI.", symbol: "gearshape.fill")
    static let volumeStatus = ControlHelp(id: "vol-status", label: "", title: "Volume atual",
        detail: "Volume que a TV informou agora (ou Mudo).", symbol: "speaker.wave.2.fill")
    static let inputStatus = ControlHelp(id: "input-status", label: "", title: "Entrada atual",
        detail: "Fonte que a TV está mostrando: TV, HDMI, AV…", symbol: "tv")
}

struct GuideSection: Identifiable {
    let title: String
    let items: [ControlHelp]
    var id: String { title }

    static let all: [GuideSection] = [
        GuideSection(title: "Ligar e escolher a fonte",
                     items: [Help.powerOn, Help.powerOff, Help.input, Help.keypad, Help.previousChannel, Help.info]),
        GuideSection(title: "Navegação",
                     items: [Help.quickMenu, Help.home, Help.menu, Help.arrows, Help.ok, Help.back, Help.exit,
                             Help.guide]),
        GuideSection(title: "Volume e canal", items: [Help.volume, Help.mute, Help.liveTV, Help.channel]),
        GuideSection(title: "Recursos da TV", items: [Help.apps, Help.aspect, Help.threeD, Help.simplink]),
        GuideSection(title: "Reprodução", items: [Help.media]),
        GuideSection(title: "Botões coloridos", items: [Help.colors]),
        GuideSection(title: "Janela do app", items: [Help.pin, Help.refresh, Help.guideSheet, Help.settings]),
    ]
}

// MARK: - Hover help

final class HelpCenter: ObservableObject {
    @Published var current: ControlHelp?
}

private struct HoverHelp: ViewModifier {
    @EnvironmentObject private var center: HelpCenter
    let help: ControlHelp

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside {
                    center.current = help
                } else if center.current == help {
                    center.current = nil
                }
            }
            .accessibilityLabel(Text(help.title))
            .accessibilityHint(Text(help.detail))
    }
}

extension View {
    /// Explains this control in the help panel while the mouse is over it.
    func controlHelp(_ help: ControlHelp) -> some View {
        modifier(HoverHelp(help: help))
    }
}

struct HelpIcon: View {
    let help: ControlHelp
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27)
            .fill(Color(white: 0.22))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: help.symbol)
                    .font(.system(size: size * (help.tint == nil ? 0.45 : 0.5), weight: .semibold))
                    .foregroundColor(help.tint ?? Color(white: 0.9))
            )
    }
}

struct ShortcutBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(Color(white: 0.8))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.24)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.34), lineWidth: 1))
            .help("Atalho no teclado")
    }
}

/// Fixed strip under the remote: explains the control under the mouse.
struct HelpPanel: View {
    @EnvironmentObject private var center: HelpCenter
    let openGuide: () -> Void

    var body: some View {
        Group {
            if let help = center.current {
                HStack(alignment: .top, spacing: 10) {
                    HelpIcon(help: help)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(help.title)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let shortcut = help.shortcut {
                                ShortcutBadge(text: shortcut)
                            }
                        }
                        Text(help.detail)
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.72))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 13))
                        .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.35))
                    Text("Passe o mouse sobre um botão para ver para que ele serve.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(action: openGuide) {
                        Text("Ver guia")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(red: 0.45, green: 0.72, blue: 1.0))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84, alignment: .topLeading)
        .background(Color(white: 0.115))
        .overlay(Rectangle().fill(Color(white: 0.22)).frame(height: 1), alignment: .top)
        .animation(.easeOut(duration: 0.12), value: center.current?.id)
    }
}

// MARK: - Button guide (the legend)

struct ButtonGuideView: View {
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Guia dos botões")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Para que serve cada botão do controle")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.6))
                }
                Spacer()
                Button("Fechar") { presentationMode.wrappedValue.dismiss() }
                    .buttonStyle(RemoteButtonStyle(bg: Color(white: 0.25), height: 28, cornerRadius: 6))
                    .frame(width: 70)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Rectangle().fill(Color(white: 0.22)).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(GuideSection.all) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.8)
                                .foregroundColor(Color(white: 0.5))
                            ForEach(section.items) { item in
                                GuideRow(help: item)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 400, height: 600)
        .background(Color(white: 0.11))
    }
}

private struct GuideRow: View {
    let help: ControlHelp

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if help.id == "colors" {
                ColorKeysIcon()
            } else {
                HelpIcon(help: help, size: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(help.title)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    if let shortcut = help.shortcut {
                        ShortcutBadge(text: shortcut)
                    }
                }
                Text(help.detail)
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ColorKeysIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 7.5)
            .fill(Color(white: 0.22))
            .frame(width: 28, height: 28)
            .overlay(
                VStack(spacing: 3) {
                    HStack(spacing: 3) { dot(Help.red.tint); dot(Help.green.tint) }
                    HStack(spacing: 3) { dot(Help.yellow.tint); dot(Help.blue.tint) }
                }
            )
    }

    private func dot(_ color: Color?) -> some View {
        Circle().fill(color ?? .gray).frame(width: 7, height: 7)
    }
}
