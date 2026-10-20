# lan-remote-mac

Controle da **LG xxLN5700 / xxLN5700-SA** (NetCast 4.0, 2013) pela rede, a partir de um
Mac com Apple Silicon, usando só HTTP na porta 8080 da TV (protocolo ROAP, com
UDAP 2.0 como alternativa). Sem Bluetooth, sem hardware extra, sem nuvem.

Validação feita neste repositório (15/10/2026):

| Etapa | Onde foi validada |
|---|---|
| Descoberta SSDP, leitura de modelo, detecção da variante, pairing com o código da tela, `volume_up`, `volume_down`, `mute`, consultas `volume_info`, `cur_channel` e `context_ui`, controle virtual `remote` (página, API, cliques em rajada, encerramento) | TV real `xxLN5700-SA_11`, firmware 05.02.11, NetCast 4.0, IP 192.0.2.100, variante ROAP |
| Re-autenticação após 401, mensagens de erro, modo `live`, as 4 variantes de caminho (roap, hdcp, hdcp_wifirc, udap) | Simulador que imita a TV |

A teoria do protocolo, os riscos, as referências e os detalhes descobertos na TV real estão
em [PROTOCOLO.md](PROTOCOLO.md).

## Arquivos

| Arquivo | Para que serve |
|---|---|
| `lg_roap_control.py` | O programa. Um arquivo só, biblioteca padrão do Python; usa `requests` se existir |
| `requirements.txt` | Só `requests` (opcional) |
| `README.md` | Este guia de instalação e uso |
| `PROTOCOLO.md` | Como o ROAP/UDAP funciona nesse modelo, limitações, referências e tabela completa de key codes |

## Requisitos no Mac

- macOS recente em Apple Silicon (testado em macOS 26, arm64).
- Python 3.9 ou mais novo. O `python3` que vem com o Xcode Command Line Tools
  (`/usr/bin/python3`, hoje 3.9.6) é suficiente. Homebrew é opcional.
- Mac e TV na **mesma rede local** (mesmo Wi-Fi ou cabo no mesmo roteador).
- TV **ligada** (não em standby) durante o uso.

## Instalação

Opção A, zero instalação (recomendada para começar):

```bash
cd ~/lan-remote-mac
python3 lg_roap_control.py --help
```

Opção B, ambiente virtual com `requests` (evita o erro "externally-managed-environment"
do pip em Python do Homebrew):

```bash
cd ~/lan-remote-mac
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Opção C, Python novo via Homebrew (se quiser 3.12+):

```bash
brew install python
python3 --version
```

Para chamar de qualquer pasta, crie um alias no `~/.zshrc`:

```bash
alias tv='python3 ~/lan-remote-mac/lg_roap_control.py'
```

Depois disso `tv volume_up`, `tv mute`, `tv live` etc. funcionam de qualquer lugar.

## Primeiro uso passo a passo

1. Ligue a TV e confirme que ela está na rede (na TV: `Settings/Ajustes > Rede > Conexão de rede`
   ou `Status da rede`). Se a TV estiver em standby ela não responde.
2. Descubra a TV:

   ```bash
   python3 lg_roap_control.py discover
   ```

   Saída esperada (exemplo real):

   ```
   Procurando TVs LG NetCast (SSDP 3s) ...
   - 192.0.2.100:8080  modelo=xxLN5700-SA_11  nome=[TV][LG]xxLN5700-SA  (via udap-description)
   IP 192.0.2.100 salvo em ~/.config/lg_roap_control/config.json. Proximo passo: 'pair'.
   ```

   Se nada aparecer, tente `discover --scan` (varre a sub-rede na porta 8080) ou informe o IP
   à mão com `--host`. Veja [Como achar o IP](#como-achar-o-ip-da-tv-manualmente).
3. Faça o pairing (uma vez só):

   ```bash
   python3 lg_roap_control.py pair
   ```

   O programa detecta a variante do protocolo, pede para a TV mostrar um código de 6 dígitos
   na tela e espera você digitá-lo. O código é fixo por TV (só muda em reset de fábrica) e fica
   salvo. Se você já souber o código: `pair --key 123456`.
4. Teste:

   ```bash
   python3 lg_roap_control.py volume_up
   python3 lg_roap_control.py status
   ```

Se o passo 3 ou 4 falhar na variante `roap`, force a variante oficial UDAP 2.0, que a TV
também expõe: `pair --protocol udap` e depois use normalmente. Para voltar:
`config --set-protocol auto`. Um HTTP 400 no pairing ROAP significa requisição com
`UDAP/2.0` no `User-Agent`; o programa já evita isso (veja
[Comportamentos observados](#comportamentos-observados-na-tv-real)).

## Comandos

```
python3 lg_roap_control.py <subcomando> [opções]
python3 lg_roap_control.py <tecla> [tecla ...]        # atalho para 'send'
```

| Subcomando | O que faz |
|---|---|
| `discover [--scan] [--cidr 192.0.2.0/24] [--save]` | Procura a TV por SSDP; `--scan` também varre a sub-rede na porta 8080 |
| `info` | Modelo, nome, uuid e variante do protocolo. Não mostra código na tela |
| `pair [--key 123456]` | Pairing completo; salva a chave |
| `send TECLA [TECLA ...]` | Envia teclas em sequência (`--delay` controla a pausa, padrão 0,3 s) |
| `digits 123 [--no-enter]` | Digita um número de canal e confirma com `ok` |
| `raw 412` | Envia um key code numérico cru |
| `status [volume_info\|cur_channel\|context_ui\|is_3d\|channel_list]` | Consulta a TV |
| `keys` | Lista todas as teclas e key codes |
| `interactive` | Prompt `lg>` para digitar comandos |
| `live` | Modo controle remoto: setas, Enter, +, -, m, [ ], h, i, 0-9 direto no terminal |
| `remote [--lan] [--http-port 8765] [--no-open]` | Controle virtual com botões no navegador; `--lan` libera para o celular |
| `config [--set-host IP] [--set-key K] [--set-protocol P] [--reset]` | Vê ou altera a configuração salva |
| `wol [MAC]` | Envia Wake-on-LAN (melhor esforço; veja limitações) |

Opções globais (antes ou depois do subcomando): `--host IP`, `--port N`, `--key K`,
`--protocol auto|roap|hdcp|hdcp_wifirc|udap`, `--timeout s`, `--delay s`, `--debug`, `-q`.
Variáveis de ambiente equivalentes: `LG_TV_HOST`, `LG_TV_KEY`, `LG_TV_PROTOCOL`.

### Exemplos

```bash
python3 lg_roap_control.py volume_up            # uma tecla
python3 lg_roap_control.py vol+ vol+ vol+       # aliases: vol+, vol-, ch+, ch-, off, enter, smart, source
python3 lg_roap_control.py send mute
python3 lg_roap_control.py digits 13            # canal 13 (envia 1, 3, ok)
python3 lg_roap_control.py home                 # menu Smart/Home
python3 lg_roap_control.py input                # troca de entrada (abre a lista de entradas)
python3 lg_roap_control.py up up ok             # navegação
python3 lg_roap_control.py back exit
python3 lg_roap_control.py power                # DESLIGA a TV (não religa; veja limitações)
python3 lg_roap_control.py status volume_info   # [volume_info] mute=false, level=12, ...
python3 lg_roap_control.py --debug mute         # mostra o HTTP e o XML trocados com a TV
python3 lg_roap_control.py --host 192.0.2.100 --key 123456 ok   # sem usar o config salvo
python3 lg_roap_control.py live                 # setas/Enter/+/-/m no terminal; q sai
```

### Teclas mais úteis

| Nome no programa | Key code | Nome no programa | Key code |
|---|---|---|---|
| `power` (desliga) | 1 | `mute` | 26 |
| `0` … `9` | 2 … 11 | `channel_up` / `ch+` | 27 |
| `up` / `down` / `left` / `right` | 12 / 13 / 14 / 15 | `channel_down` / `ch-` | 28 |
| `ok` / `enter` | 20 | `previous_channel` | 403 |
| `home` / `smart` | 21 | `input` / `source` | 47 |
| `menu` | 22 | `exit` | 412 |
| `back` | 23 | `apps` (My Apps) | 417 |
| `volume_up` / `vol+` | 24 | `play` / `pause` / `stop` | 33 / 34 / 35 |
| `volume_down` / `vol-` | 25 | `red` / `green` / `yellow` / `blue` | 31 / 30 / 32 / 29 |

A tabela completa (3D, EPG, legendas, SIMPLINK etc.) está em `keys` e em
[PROTOCOLO.md](PROTOCOLO.md#tabela-completa-de-key-codes).

## Aplicativo Desktop para Mac (`Controle Remoto LG.app`)

Para ter um controle remoto virtual nativo no macOS que parece um controle físico de TV e funciona com cliques ou teclado:

1. **Abrir**:
   - Pelo Dock, ou dois cliques no atalho **`Controle Remoto LG.app`** na Mesa (Desktop).
   - Ou abra pelo terminal:
     ```bash
     python3 lg_roap_control.py gui
     # ou
     open ~/Applications/"Controle Remoto LG.app"
     ```
   - O app fica instalado em `~/Applications`; na Mesa há só um atalho. Instalado na Mesa (pasta
     protegida pelo macOS) ele voltava a pedir acesso à Mesa a cada recompilação.

2. **Destaques do App Nativo (SwiftUI / Apple Silicon)**:
   - **Liga a TV sem levantar**: com a TV em standby, o botão **Ligar** acorda a TV Box (Android TV)
     ligada no HDMI, que liga a TV pelo HDMI-CEC, ou, se ela não responder, acorda e reinicia o PS5,
     que liga a TV ao voltar. Detalhes em "Ligar a TV pelo app" abaixo.
   - **Botões que se explicam**: cada botão tem ícone e nome em português, agrupados por função
     (Navegação, Volume e canal, Recursos da TV, Reprodução, Botões coloridos). Passar o mouse mostra
     no rodapé o que o botão faz e o atalho de teclado; o **?** do topo abre o **Guia dos botões**.
   - **Estado da TV à vista**: `Ligada`, `Desligada` ou `Ligando…` no topo, volume (ex.: `Vol 10`) e
     entrada atual (ex.: `HDMI2`). Com a TV desligada, os botões ficam esmaecidos e um cartão mostra
     como ligá-la.
   - **Sempre no topo (Pin)**: Botão de fixação para deixar o controle flutuando sobre outras janelas enquanto você assiste ou trabalha.
   - **D-Pad circular**: Setas direcionais (▲, ▼, ◀, ▶) com OK no centro, além de Voltar, Sair e Programação.
   - **Gangorras de Volume e Canal**.
   - **Teclado numérico retrátil**: botão **Números**, com Último canal e Info.
   - **Teclas Smart & Mídia**: Início, Apps, Ajuste rápido (Q.Menu), 3D, Formato, SIMPLINK, Retroceder, Reproduzir, Pausar, Parar, Avançar.
   - **4 Teclas Coloridas**: Vermelho, Verde, Amarelo e Azul.
   - **Atalhos instantâneos de teclado** (com a janela em foco):
     - `Setas`: Cima, Baixo, Esquerda, Direita
     - `Enter`: OK / Selecionar
     - `Backspace` / `Esc`: Voltar
     - `+` / `-`: Volume + / Volume -
     - `m`: Mudo (Mute)
     - `]` / `[`: Canal + / Canal -
     - `h`: Home / Smart
     - `i`: Trocar Entrada (Input)
     - `x`: Sair (Exit)
     - `Espaço`: Play
     - `0` a `9`: Dígitos diretos
   - **Painel de Configurações**: Ícone de engrenagem para alterar IP, porta e solicitar/confirmar novo pareamento direto na interface.

3. **Versão Desktop em Python puro (Tkinter)**:
   Se preferir executar uma versão desktop 100% em Python sem compilar nada:
   ```bash
   python3 lg_roap_control.py gui --python
   # ou
   python3 lg_remote_gui.py
   ```

4. **Recompilar o App Nativo**:
   O binário e o bundle `.app` são gerados automaticamente pelo script:
   ```bash
   bash mac_app/build_app.sh
   ```

### Ligar a TV pelo app

Em standby a NetCast 2013 desliga a rede (Wake-on-LAN não funciona nela), então o app liga a TV
por outro caminho: a **TV Box da sala** (Android TV/Google TV) ligada no HDMI.

1. O app manda **Wake-on-LAN** para o Wi-Fi da TV Box. Ela também dorme fundo, mas acorda a rede
   por alguns segundos (responde em ~1 s).
2. Nesse intervalo o app aperta **POWER** pelo protocolo do controle remoto do Android TV (o mesmo
   do app Google TV, portas 6466/6467, TLS com certificado próprio).
3. Ao acordar, a TV Box manda **One Touch Play** pelo HDMI-CEC e a TV liga, já na entrada dela.
   A imagem volta em segundos; a rede da TV, em até ~1 minuto, e aí o controle volta a responder.

Requisitos, uma vez só:

- **SIMPLINK ligado na TV** (botão SIMPLINK do app → "SIMPLINK Ligado"). Sem ele a TV ignora o CEC.
- **HDMI-CEC na TV Box** (Configurações › Tela e som ou Sistema › Entradas › HDMI-CEC): mantenha o
  **HDMI-CEC ativado** e desative **"Desligar automaticamente"**.
- **Modo de energia na TV Box** (Configurações › Sistema › Energia e alimentação): selecione
  **Modo de consumo elevado (Sempre conectado)** e timer de desligamento em **Nunca**, para a TV Box
  não desconectar do Wi-Fi após horas em espera.
- **Parear o app com a TV Box**: Configurações → "Ligar a TV pelo app" → Parear, com a TV ligada na
  entrada da TV Box. A TV Box mostra um código de 6 caracteres e o app o lê sozinho: fotografa a tela
  da TV (consulta `screen_image`), lê o código por OCR (Vision) e confere o dígito verificador dele antes
  de enviar, o que separa as confusões do OCR (0/D, 8/B). Se não conseguir, o campo para digitar fica
  na tela.

Testado nesta casa: TV desligada e TV Box em repouso → TV ligada e respondendo em ~42 s (em
20/10/2026: 44 a 57 s, também depois de 17 min em repouso).
O pareamento fica em `~/.config/lg_roap_control/androidtv.json` (nome, IP e MAC da TV Box) e o
certificado do app em `~/.config/lg_roap_control/androidtv/client.p12`, com a senha dele, gerada ao
acaso na criação, em `client.pass` ao lado (ambos com permissão `0600`). O certificado vale 20 anos e
o pareamento dura o mesmo, desde que os **dois** arquivos fiquem: sem um deles, o app cria outro
certificado, que a TV Box não conhece, e é preciso parear de novo. Não usar `KEYCODE_TV_POWER`
(177) nem `KEYCODE_WAKEUP` (224): essa TV Box ignora os dois.

#### Reserva: o PS5

Depois de horas em standby a TV Box sai do Wi-Fi de vez (nem o ARP a encontra) e o Wake-on-LAN não
chega até ela. O PS5 em repouso, com "Permanecer conectado à internet", continua respondendo na rede,
então o botão **Ligar** usa o PS5 quando a TV Box não acorda:

1. O app pergunta pelo PS5 com o protocolo de descoberta do app Remote Play (UDP 9302; em repouso ele
   responde `620 Server Standby`) e manda um **WAKEUP** com a credencial obtida no registro.
2. O PS5 sai do repouso, mas **acordado pela rede ele não manda o HDMI-CEC "ligar a TV"** (One-Touch
   Play, "Reprodução com um toque" no menu do PS5): a TV continua apagada. Ele só manda esse comando
   ao ligar do zero ou quando um controle físico conecta.
3. Então o app **reinicia o PS5 pelo Uso remoto**, com o `ps5ctl` do projeto Controle PS5: PS (Central
   de controle) › ↓ (fileira de baixo) › ← (dá a volta até Energia) › ✕ › ↓ quatro vezes › ✕. O menu de
   energia não dá a volta, então os quatro ↓ terminam em "Reiniciar PS5" mesmo que algum se perca.
   Antes de cada ✕ o app lê a tela do PS5 por OCR (Vision) e só segue com "Energia" em foco e com a
   descrição de "Reiniciar PS5" na tela: um ↓ perdido deixaria o foco em "Desligar PS5", e desligado o
   PS5 não acorda mais pela rede.
4. No boot o PS5 manda o One-Touch Play, e a TV liga já na entrada dele.

**Testado em 20/10/2026:** TV desligada pelo app, TV Box fora da tomada e PS5 em repouso → botão
**Ligar** → TV respondendo na entrada do PS5 em 142 s. O que não liga a TV, também medido: o WAKEUP
pela rede (nem troca a entrada com a TV já ligada), o WAKEUP com `app-type:c` (o PS5 ignora), abrir uma
sessão do Uso remoto e o PS apertado por ela. O Wake-on-LAN direto na TV também não funciona.

O reinício **fecha jogos e apps suspensos** no repouso. Para esse passo o app precisa do `ps5ctl`
(projeto Controle PS5) pareado com o console, em `~/.local/bin/ps5ctl` ou na variável `PS5CTL`, e do
`ffmpeg` que ele usa para as capturas.

Registro, uma vez só, em Configurações → "Ligar a TV pelo app" → PlayStation 5:

- **Conta PSN**: "Entrar na PSN" abre o login da Sony numa janela do próprio app (o login do app
  Remote Play para Windows). Ao terminar, o app intercepta a página de retorno, troca o código pelo id
  da conta (8 bytes em base64) e segue; não há nada para copiar. Quem já tem o id (do chiaki, por
  exemplo) pode colar direto no campo ao lado.
- **PIN**: no PS5 ligado, Configurações › Sistema › Reprodução Remota › Vincular dispositivo mostra um
  PIN de 8 números; digite e registre. O app faz o que o Remote Play faz: busca `SRC3` na porta 9295 e
  `POST /sie/ps5/rp/sess/rgst` com o id da conta cifrado em AES-128-CFB por uma chave derivada do PIN
  (esquema documentado pelos projetos chiaki-ng e playactor). A resposta traz a `PS5-RegistKey`, que
  vira a credencial do WAKEUP.
- No PS5: Configurações › Sistema › HDMI › **Ativar Link de dispositivo HDMI** e **Reprodução com um
  toque**; e Configurações ›
  Sistema › Economia de energia › Recursos disponíveis no modo de repouso › **Permanecer conectado à
  internet** e **Ativar ligar o PS5 pela rede**.

O registro fica em `~/.config/lg_roap_control/playstation.json` (nome, IP, MAC, id da conta e
credencial de wake; permissão `0600`). O PS5 fica ligado depois (não há como voltar ao repouso só com
o protocolo de descoberta); ele volta a dormir pelo timer dele ou pelo controle.

---

## Outras Formas de Controle Virtual

1. **No terminal**: `python3 lg_roap_control.py live`. Setas navegam, Enter é OK,
   Backspace/Esc voltam, `+`/`-` volume, `m` mudo, `]`/`[` canal, `h` Home, `i` Input,
   `0-9` números, `x` Exit, `q` sai.
2. **No navegador do Mac**: `python3 lg_roap_control.py remote`. Sobe um servidor local em
   `http://127.0.0.1:8765/` e abre a página com o controle completo (power, input, home,
   números, direcional, volume, canal, mídia, teclas coloridas). Os atalhos de teclado também funcionam na página. `Ctrl-C` no terminal encerra.
3. **No celular ou tablet**: `python3 lg_roap_control.py remote --lan`. O programa imprime o
   endereço `http://IP-do-Mac:8765/`; abra no Safari do iPhone na mesma rede Wi-Fi e use
   "Adicionar à Tela de Início" para virar um app. Não há senha: use só em rede confiável
   e encerre quando não precisar. O Mac precisa ficar acordado.

A página fala com o servidor local, e só ele fala com a TV, um comando por vez. A API é
simples e dá para usar em Atalhos ou scripts enquanto o `remote` estiver rodando:

```bash
curl -X POST http://127.0.0.1:8765/api/key/volume_up
curl -X POST http://127.0.0.1:8765/api/key/mute
curl -X POST --data 13 http://127.0.0.1:8765/api/digits     # canal 13 + ok
curl http://127.0.0.1:8765/api/status                        # volume, mudo, entrada/canal
```

Se a porta 8765 estiver ocupada: `remote --http-port 8766`.

## Onde fica a configuração

Arquivo: `~/.config/lg_roap_control/config.json` (ou `$XDG_CONFIG_HOME/lg_roap_control/config.json`),
criado com permissão `0600`. Conteúdo típico:

```json
{
  "host": "192.0.2.100",
  "port": 8080,
  "protocol": "roap",
  "pairing_key": "123456",
  "session": "a1b2c3d4e5f6",
  "model": "xxLN5700-SA_11",
  "name": "[TV][LG]xxLN5700-SA",
  "mac": "aa:bb:cc:dd:ee:ff"
}
```

- `pairing_key` é o código de 6 dígitos mostrado na TV. É persistente.
- `session` é o id que a TV devolve no ROAP; o programa renova sozinho quando a TV devolve 401
  (por exemplo depois de desligar e ligar).
- `mac` é lido da tabela ARP do Mac depois de falar com a TV, para o `wol`.
- `config --reset` apaga tudo; a TV não guarda nada que precise ser desfeito.

## Como achar o IP da TV manualmente

1. Na TV: `Settings > Rede > Conexão de rede` (ou `Status da rede` / `Configuração avançada`),
   o IP aparece na tela.
2. No roteador: lista de clientes DHCP, procure por "LG" ou pelo nome `[TV][LG]xxLN5700-SA`.
3. No Mac: `python3 lg_roap_control.py discover --scan` varre a sub-rede /24 do Mac na porta 8080
   e identifica quem é LG lendo `/udap/api/data?target=rootservice.xml`.
4. Fixe o IP da TV no DHCP do roteador para a configuração não quebrar quando o lease mudar.

## Problemas conhecidos no macOS / Apple Silicon

- **Rede Local (macOS 15+)**: na primeira execução o macOS pergunta se o Terminal (ou iTerm,
  VS Code etc.) pode acessar a rede local. Se você negou, o SSDP falha em silêncio. Libere em
  `Ajustes do Sistema > Privacidade e Segurança > Rede Local`. O `--host` direto e o
  `--scan` continuam funcionando mesmo sem multicast.
- **Firewall do macOS** com "Bloquear todas as conexões de entrada" pode descartar as respostas
  SSDP (UDP de volta para o Mac). Use `--host` ou `--scan`, ou libere o Python no firewall.
- **Aviso `NotOpenSSLWarning` do urllib3**: aparece com o `python3` da Apple (compilado com
  LibreSSL) quando `requests` está instalado. É inofensivo e o programa já o silencia.
- **`error: externally-managed-environment` no `pip install`**: Python do Homebrew exige venv
  (Opção B acima) ou `pip install --user`.
- **`python3` 3.9 da Apple**: funciona. O código evita sintaxe mais nova de propósito. Se usar
  Homebrew, nada muda.
- **Wi-Fi com isolamento de clientes** (redes de visitantes, alguns roteadores de operadora)
  bloqueia Mac e TV entre si. Coloque os dois na rede principal ou use cabo na TV.
- **Mac em VLAN/sub-rede diferente** da TV: SSDP não atravessa roteadores; use `--host`.
- **Sleep do Mac** não afeta nada; a configuração é por arquivo e cada comando abre a conexão
  na hora. O "session" expira só quando a TV reinicia.
- Nada aqui depende de arquitetura: é Python puro, roda igual em arm64 e x86_64.

## Comportamentos observados na TV real

- **HTTP 400 no pairing ROAP** acontece se a requisição levar `UDAP/2.0` no `User-Agent`: a TV
  troca para o handler UDAP 2.0 (`SERVER: ... UDAP/2.0`) e rejeita o XML do ROAP. O programa usa
  User-Agent neutro no ROAP e `UDAP/2.0` só no SSDP, na descrição e na variante udap. Se for
  testar com `curl`, não passe `-A "... UDAP/2.0"` em chamadas `/roap/api/...`.
- **Teclas iguais em rajada são descartadas**: três `vol+` enviados sem intervalo (cliques em
  paralelo) viraram um só na TV; a cada 0,3 s os três registram (10 para 13). Por isso o
  `send` usa 0,3 s entre teclas por padrão e o `remote` espaça os envios sozinho.
- **`mute` repetido em menos de ~1 s é descartado**: `mute mute` com 1 s de intervalo deixou
  a TV muda (o segundo toque foi ignorado); com 2,5 s os dois passaram. Para alternar o mudo
  duas vezes, espace 2 s ou confira com `status volume_info`.
- **Sessão ROAP estável**: a TV devolve o mesmo `session` para a mesma chave enquanto está
  ligada; o programa só renova quando recebe 401.
- **`cur_channel` em entrada HDMI** devolve `inputSourceName=HDMI2`, `major=65520` etc.; os
  números de canal só fazem sentido com o sintonizador ativo.
- **O código de pairing continua o mesmo** entre execuções e após refazer `pair`; só muda em
  reset de fábrica.

## Limitações do protocolo (resumo)

- **Ligar a TV direto pela rede não funciona** nesse modelo: em standby a NetCast desliga o
  controlador de rede (o `wol` existe como melhor esforço e não acorda esta TV). O app de Mac
  liga a TV pela TV Box ou pelo PS5 via HDMI-CEC; veja "Ligar a TV pelo app".
- A TV precisa estar ligada e na mesma rede. Não há acesso remoto pela internet (e nem deve
  haver: a porta 8080 não tem autenticação além do pairing).
- Um só pairing key por TV; vários controladores podem usar o mesmo código.
- Não há entrada de texto nem controle de apps neste programa (a TV expõe `mobilehome` e
  `smartText`, veja PROTOCOLO.md), só teclas e consultas.
- Firmware de 2013: respostas às vezes vazias, timeouts de 2 a 4 s. O programa tenta uma vez
  a re-autenticação e desiste com mensagem clara.

## Melhorias futuras (não implementadas)

- Atalhos globais no macOS via `skhd`, Hammerspoon ou Karabiner chamando `tv volume_up`.
- Integração com Atalhos (Shortcuts) do macOS/iOS: ação "Executar Script do Shell" com
  `python3 ~/lan-remote-mac/lg_roap_control.py mute`; dá para chamar pela Siri.
- Barra de menus (rumps/py2app) ou Raycast script commands.
- `AppExecute`/`applist_get` do serviço `mobilehome` para abrir apps (Netflix, YouTube) direto.
- `HandleTouchMove`/`HandleTouchClick` para emular o Magic Remote (cursor).
- Eventos da TV (`ChannelChanged`, `KeyboardVisible`) via servidor HTTP local, como o spec
  UDAP prevê.
- Home Assistant: a integração oficial `lg_netcast` usa o mesmo protocolo (pylgnetcast).
