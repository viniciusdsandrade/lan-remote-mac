# ROAP / UDAP na LG xxLN5700: viabilidade e beabá do protocolo

## Resumo executivo

- **É viável em 2026.** O controle por rede das LG NetCast 2012/2013 é um protocolo HTTP
  local, sem nenhuma dependência de nuvem. A LG desligou as lojas e serviços online do NetCast,
  mas o servidor HTTP de controle remoto continua no firmware da TV e responde normalmente.
- **Confirmado na TV real deste projeto** (`xxLN5700-SA_11`, `tvEvent = NC4.0 SU1`, firmware
  05.02.11, IP 192.0.2.100): ela responde ao SSDP, entrega a descrição UDAP com a lista de
  serviços, e expõe os caminhos `/roap/api/...` **e** `/udap/api/...` (ambos devolvem HTTP 401
  antes do pairing, o que prova que existem). Os caminhos `/hdcp/api/...` citados em alguns
  scripts para "2013" devolvem 404 nesta TV.
- **Pairing e comandos validados na TV real em 15/10/2026** pela rota ROAP: `AuthReq` com o
  código da tela devolveu `<session>`, `HandleKeyInput` 24/25/26 alteraram volume e mute (lidos
  de volta com `volume_info`), e `cur_channel` e `context_ui` responderam. A rota UDAP 2.0
  oficial também aceitou o `showKey` (HTTP 200) e fica disponível com `--protocol udap`.
- **Pegadinha do firmware**: se o `User-Agent` da requisição contiver `UDAP/2.0`, a TV passa a
  responder como handler UDAP 2.0 (`SERVER: ... UDAP/2.0`) e devolve HTTP 400 para o XML do
  ROAP (`<auth>`, `<command>`). Com User-Agent neutro ela responde `SERVER: ... UDAP/1.0` e
  aceita, com ou sem o prólogo `<?xml ...?>`. O programa usa `UDAP/2.0` só no SSDP, na
  descrição `rootservice.xml` e na variante udap.

## A plataforma

| Item | Valor |
|---|---|
| Modelo | xxLN5700-SA (sufixo `_11` no modelName) |
| Plataforma | NetCast 4.0 (2013). Não é webOS. |
| Servidor | `SERVER: Linux/3.0.13 UDAP/2.0 xxLN5700-SA/05.02.11` |
| Porta | TCP 8080 (HTTP puro, sem TLS) |
| Serviços anunciados | `netrcu` (teclas, toque, troca de canal, consultas), `mobilehome` (apps), `smartText` (teclado), `AppToApp` |

Descrição real obtida com `GET http://192.0.2.100:8080/udap/api/data?target=rootservice.xml`
(trecho):

```xml
<envelope>
  <device>
    <deviceType>TV</deviceType>
    <modelName>xxLN5700-SA_11</modelName>
    <friendlyName>[TV][LG]xxLN5700-SA</friendlyName>
    <tvEvent>NC4.0 SU1</tvEvent>
    <manufacturer>LG Electronics</manufacturer>
    <uuid>00000000-0000-0000-0000-000000000000</uuid>
  </device>
  <port>8080</port>
  <serviceList>
    <service name="netrcu">
      <apiList>
        <api type="command"><name>HandleKeyInput</name><name>HandleTouchMove</name>
          <name>HandleTouchClick</name><name>HandleTouchWheel</name><name>HandleChannelChange</name></api>
        <api type="event"><name>CursorVisible</name><name>ChannelChanged</name>
          <name>CallStateChanged</name><name>DragMode</name><name>3DMode</name></api>
        <api type="query"><name>cur_channel</name><name>context_ui</name><name>channel_list</name>
          <name>screen_image</name><name>is_3d</name><name>volume_info</name></api>
      </apiList>
    </service>
    ...
  </serviceList>
</envelope>
```

## Dois nomes, um mecanismo: UDAP 2.0 e ROAP

| | UDAP 2.0 | ROAP |
|---|---|---|
| Origem | Spec oficial da LG ("LG UDAP 2.0 Protocol Specification", para NetCast 3.0 e 4.0) | Protocolo do app "LG TV Remote" 2012/2013; documentado por engenharia reversa (pylgnetcast, lgcommander, Connect SDK) |
| Pairing | `POST /udap/api/pairing` com `<envelope><api type="pairing">` (`showKey`, `hello`, `byebye`) | `POST /roap/api/auth` com `<auth><type>AuthKeyReq</type>` e `<auth><type>AuthReq</type><value>CHAVE</value>` |
| Sessão | Nenhuma: a TV registra o IP do controlador após `hello` | A TV devolve `<session>ID</session>`, que vai em cada comando |
| Comando | `POST /udap/api/command`, `<envelope><api type="command"><name>HandleKeyInput</name><value>N</value></api></envelope>` | `POST /roap/api/command`, `<command><session>ID</session><type>HandleKeyInput</type><value>N</value></command>` |
| Consulta | `GET /udap/api/data?target=volume_info` | `GET /roap/api/data?target=volume_info` |
| Content-Type | `text/xml; charset=utf-8`, `User-Agent` com `UDAP/2.0` | `application/atom+xml`, `User-Agent` **sem** `UDAP/2.0` (senão 400) |
| Key codes | Tabela "Anexo A" do spec | A mesma tabela |
| Nesta TV | existe (401 antes do pairing) | existe (401 antes do pairing) |

Variante `hdcp` (`/hdcp/api/auth`, `/hdcp/api/dtv_wifirc`): aparece na pylgnetcast e em relatos
de 2013, mas **não existe nesta xxLN5700** (404). O programa mantém suporte para quem tiver
outro firmware/modelo.

O programa detecta a variante sem mostrar nada na TV: faz `GET .../data?target=volume_info` em
cada caminho; 404 significa "não existe", qualquer outro status (401, 200, 400) significa "existe".
Ordem: roap, hdcp, hdcp_wifirc, udap. Forçar com `--protocol`.

## O protocolo passo a passo

### 1. Discovery (SSDP)

O Mac manda um `M-SEARCH` em multicast UDP para `239.255.255.250:1900`. O spec da LG pede o
`ST: udap:rootservice` e um `USER-AGENT` contendo `UDAP/2.0`; a TV também responde ao
`urn:schemas-upnp-org:device:MediaRenderer:1` (DLNA) e ao `ssdp:all`.

```
M-SEARCH * HTTP/1.1
HOST: 239.255.255.250:1900
MAN: "ssdp:discover"
MX: 3
ST: udap:rootservice
USER-AGENT: macOS/1.0 UDAP/2.0 lg_roap_control/1.0.0
```

Resposta real da xxLN5700 (cabeçalhos relevantes):

```
HTTP/1.1 200 OK
ST: udap:rootservice
SERVER: Linux/3.0.13 UDAP/2.0 xxLN5700-SA/05.02.11
LOCATION: http://192.0.2.100:8080/udap/api/data?target=rootservice.xml
```

O spec prevê ainda o `B-SEARCH` em broadcast (`255.255.255.255:1990`) para roteadores que
bloqueiam multicast; o `discover` envia os dois. Se nada responder, `discover --scan` testa a
porta 8080 em toda a sub-rede /24 e identifica LG pelo `rootservice.xml`.

**Toda busca UDAP aparece na tela.** Depois de responder a um ST UDAP válido
(`udap:rootservice` ou `urn:schemas-udap:service:...`, por M-SEARCH ou B-SEARCH), a TV mostra no
canto inferior direito o pop-up de descoberta: o `modelName`, um celular apontando para a TV e o
campo "Pairing Key" (spec, figura "Host screen after discovery response"). Na TV real, em
30/10/2026, ele voltava a cada busca da redescoberta automática, que rodava a cada requisição
que falhava. A TV tem um segundo servidor SSDP, o renderizador DLNA
(`SERVER: Linux/i686 UPnP/1.0 DLNADOC/1.50 Platinum/1.0.3.0`), que responde ao
`urn:schemas-upnp-org:device:MediaRenderer:1`. Por isso a busca UDAP fica só no `discover`, no
`pair` e no botão "Buscar TV na rede" do app (depois da DLNA), quando alguém pediu. A
redescoberta automática procura a TV pelo MAC no cache ARP e pela busca DLNA, sem `UDAP/2.0` no
User-Agent. No app, o IP salvo e o cache ARP são conferidos a cada falha, e a busca DLNA roda no
máximo a cada 30 s. Outros aparelhos LG com DLNA, como uma TV webOS, podem responder à busca com
`manufacturer` LG Electronics: quem responde só conta como a TV se a porta 8080 também abrir. O
sufixo do `modelName` muda de uma ligação para outra e não serve para reconhecer a TV; o MAC serve.

### 2. Pairing

ROAP (o que o programa usa por padrão nesta TV):

```http
POST /roap/api/auth HTTP/1.1
Content-Type: application/atom+xml
Connection: Close

<?xml version="1.0" encoding="utf-8"?><auth><type>AuthKeyReq</type></auth>
```

A TV mostra um código de 6 dígitos na tela. Em seguida:

```http
POST /roap/api/auth HTTP/1.1
Content-Type: application/atom+xml

<?xml version="1.0" encoding="utf-8"?><auth><type>AuthReq</type><value>123456</value></auth>
```

Resposta real da xxLN5700 (200; 401 se a chave estiver errada):

```xml
<?xml version="1.0" encoding="utf-8"?><envelope><ROAPError>200</ROAPError><ROAPErrorDetail>OK</ROAPErrorDetail><session>123456789</session></envelope>
```

O `AuthKeyReq` devolve o mesmo envelope sem `<session>`. A sessão se repete para a mesma
chave enquanto a TV estiver ligada.

UDAP 2.0 (alternativa, `--protocol udap`):

```xml
<!-- mostrar o código -->
<envelope><api type="pairing"><name>showKey</name></api></envelope>
<!-- parear -->
<envelope><api type="pairing"><name>hello</name><value>123456</value><port>8080</port></api></envelope>
<!-- encerrar (opcional) -->
<envelope><api type="pairing"><name>byebye</name><port>8080</port></api></envelope>
```

Códigos de resposta definidos no spec: 200 ok, 400 XML malformado, 401 chave inválida,
503 número máximo de controladores excedido. O popup com o código fica 60 s na tela e some
quando o pairing dá certo. **O código é fixo por TV**: só muda em reset de fábrica.

### 3. Sessão

ROAP: o `session` devolvido no `AuthReq` vai dentro de cada `<command>`. Quando a TV desliga
e liga, a sessão morre e os comandos voltam 401; o programa refaz o `AuthReq` com a chave
salva e reenvia a tecla uma vez. UDAP: não há sessão; a TV lembra o IP do controlador
enquanto estiver ligada, e o programa manda `hello` uma vez por execução.

### 4. Comando (tecla)

```http
POST /roap/api/command HTTP/1.1
Content-Type: application/atom+xml

<?xml version="1.0" encoding="utf-8"?><command><session>SESSAO</session><type>HandleKeyInput</type><value>24</value></command>
```

`24` é "volume up". Resposta real: 200 com
`<envelope><ROAPError>200</ROAPError><ROAPErrorDetail>OK</ROAPErrorDetail></envelope>`
(no UDAP a resposta 200 vem sem corpo). A TV também aceita `HandleChannelChange` e
`HandleTouchMove/Click/Wheel` (cursor do Magic Remote); não implementados aqui.

Observado: a TV descarta teclas iguais em rajada. Três `24` enviados em sequência imediata
(requisições HTTP uma atrás da outra, sem pausa) registraram só um; três `24` a cada 0,3 s
registraram os três (volume 10 para 13). `mute` tem uma janela maior: repetido com 1 s o
segundo toque foi descartado, com 2,5 s passou. Regra prática: 0,3 s entre teclas, 2 s
entre dois `mute`.

### 5. Consultas

```http
GET /roap/api/data?target=volume_info HTTP/1.1
```

Resposta real (ROAP; o UDAP embrulha o `<data>` em `<dataList name="...">`):

```xml
<?xml version="1.0" encoding="utf-8"?><envelope><ROAPError>200</ROAPError><ROAPErrorDetail>OK</ROAPErrorDetail>
<data><mute>false</mute><minLevel>0</minLevel><maxLevel>100</maxLevel><level>10</level></data></envelope>
```

`cur_channel` com a TV em HDMI2 (real):

```xml
<data><chtype>terrestrial</chtype><sourceIndex>8</sourceIndex><physicalNum>65535</physicalNum>
<major>65520</major><displayMajor>65520</displayMajor><minor>65520</minor><displayMinor>-16</displayMinor>
<chname></chname><progName></progName><audioCh>0</audioCh><inputSourceName>HDMI2</inputSourceName>
<inputSourceType>6</inputSourceType><labelName></labelName><inputSourceIdx>4</inputSourceIdx></data>
```

`context_ui` devolveu `<mode>VolCh</mode>` (tela normal de TV/entrada). Alvos: `volume_info`,
`cur_channel`, `context_ui`, `is_3d`, `channel_list`, `screen_image` (captura da tela, JPEG).
Sem sessão válida a TV responde 401 (é assim que o programa detecta a variante sem popup).

### 6. Eventos (não implementados)

O spec prevê que a TV faça `POST` no controlador (`ChannelChanged`, `KeyboardVisible` etc.) na
porta informada no `hello`. Exigiria um servidor HTTP no Mac; fora do escopo.

## Testando na mão com curl

```bash
TV=192.0.2.100
# descrição (sem pairing)
curl -s -A "UDAP/2.0" "http://$TV:8080/udap/api/data?target=rootservice.xml"
# mostrar código na tela
curl -s -X POST -H "Content-Type: application/atom+xml" --data '<?xml version="1.0" encoding="utf-8"?><auth><type>AuthKeyReq</type></auth>' "http://$TV:8080/roap/api/auth"
# parear (troque 123456)
curl -s -X POST -H "Content-Type: application/atom+xml" --data '<?xml version="1.0" encoding="utf-8"?><auth><type>AuthReq</type><value>123456</value></auth>' "http://$TV:8080/roap/api/auth"
# volume up (troque SESSAO pelo valor devolvido acima)
curl -s -X POST -H "Content-Type: application/atom+xml" --data '<?xml version="1.0" encoding="utf-8"?><command><session>SESSAO</session><type>HandleKeyInput</type><value>24</value></command>' "http://$TV:8080/roap/api/command"
```

## Riscos e limitações conhecidas

1. **Ligar pela rede não funciona.** Em standby a NetCast 2013 desliga a interface de rede;
   não há Wake-on-LAN confiável nesse modelo (só os webOS a partir de 2014 ligam por WoL).
   `power` (key 1) desliga; religar exige controle físico, botão da TV ou HDMI-CEC/SIMPLINK
   de outro aparelho. O `wol` do programa é um melhor esforço e provavelmente não terá efeito.
2. **Mesma rede.** SSDP não cruza roteadores; redes de visitantes/isolamento de clientes
   bloqueiam o tráfego. Nunca exponha a porta 8080 da TV à internet: o pairing é a única
   proteção e o tráfego é HTTP em claro.
3. **Pairing inicial** precisa de alguém olhando a tela. Depois disso é automático.
4. **Firmware antigo (2013).** Timeouts de 2 a 4 s são normais; de vez em quando uma resposta
   vem vazia. O programa tem timeout configurável, uma re-tentativa com re-autenticação e
   mensagens de erro explícitas.
5. **Variantes de firmware.** Alguns 2013 só aceitam `/hdcp/api`, outros exigem `<name>` em
   vez de `<type>` no XML do ROAP. Nesta TV o `/hdcp/api` não existe e o ROAP com `<type>` e
   `<session>` funciona, desde que o `User-Agent` não contenha `UDAP/2.0` (senão HTTP 400).
   Se o ROAP recusar algo, a rota `--protocol udap` segue o spec oficial.
9. **Teclas repetidas em rajada descartadas.** Três `vol+` sem intervalo viraram um; a cada
   0,3 s os três passam. `mute` repetido com 1 s perdeu o segundo toque (com 2,5 s passou).
   O programa usa 0,3 s entre teclas por padrão; para alternar o mudo duas vezes, espace 2 s
   ou confira com `status volume_info`.
6. **Múltiplos controladores.** O spec define um limite (503 quando excedido). Feche o app
   LG TV Remote no celular se receber 503.
7. **IP dinâmico.** Se o DHCP trocar o IP da TV, rode `discover` de novo ou fixe o IP no
   roteador.
8. **Sem Bluetooth, sem IR.** Tudo depende da rede; se o roteador cair, o controle cai junto.
10. **Ping, inicialização e conflito de IP na LAN.** Em standby a TV desliga a interface de rede
    (o Mac recebe "host is down" e o ping não responde). Ao ligar, o Wi-Fi sobe antes do servidor
    ROAP: a TV já responde ao ping enquanto a porta 8080 recusa conexões ("connection refused") por
    cerca de 1 minuto até o serviço subir; depois disso responde em 5 a 30 ms sem interrupções. Se
    outro aparelho da rede usar o mesmo IP da TV (conflito de IP, por exemplo um ponto de acesso com
    IP fixo dentro da faixa do DHCP), o cache ARP do Mac alterna entre os dois MACs: enquanto aponta
    para o outro aparelho, o ping continua respondendo, mas os `SYN` TCP nas portas 8080 e 1387
    expiram sem resposta. Por isso o app só dá a TV como desligada quando não a encontra em outro IP
    nem recebe resposta ao ping da própria TV, e sinaliza conflito de IP quando outro MAC assume o
    endereço logo após a TV ter respondido.

## Isto ainda é usável em 2026?

Sim. O protocolo é local e estável desde 2012; o firmware não recebe atualizações, logo nada
muda do lado da TV. O que morreu foi o ecossistema em volta: o app oficial "LG TV Remote"
saiu das lojas e os apps NetCast perderam servidores. O Home Assistant mantém a integração
`lg_netcast` (baseada na pylgnetcast) exatamente para essas TVs, o que é a melhor evidência de
uso contínuo.

Referências de código e documentação, por ordem de utilidade:

| Referência | O que tem |
|---|---|
| `pylgnetcast` (wokar/pylgnetcast; fork Drafteed/python-lgnetcast usado pelo Home Assistant) | ROAP e variante HDCP em Python 3, tabela de key codes, consultas. Base do `lg_netcast` do HA |
| "LG UDAP 2.0 Protocol Specification" (PDF `NetCast-UDAP.pdf`, webostv.developer.lge.com) | Spec oficial: SSDP, pairing, comandos, consultas, eventos, Anexo A com os key codes |
| `lgcommander` (ubaransel/lgcommander) | Script Python 2 clássico; UDAP 1.0 (2011) e ROAP (2012) |
| Connect SDK, `NetcastTVService` | Implementação Java/ObjC comercial para NetCast 3.x/4.x |
| Thread "Workaround LG TV Remote" na comunidade Home Assistant | Relatos de campo 2011-2013, inclusive a variante `/hdcp/api` |
| harizanov.com, "Control LG Smart TV over the internet using a Raspberry Pi" (2013) | Exemplo mínimo de ROAP com Python |

## Tabela completa de key codes

Fonte: LG UDAP 2.0 Protocol Specification, Anexo A (idêntica à usada pelo ROAP e pela pylgnetcast).

| Código | Tecla | Código | Tecla |
|---|---|---|---|
| 1 | Power | 36 | Fast forward |
| 2 a 11 | Números 0 a 9 | 37 | Rewind |
| 12 | Up | 38 | Skip forward |
| 13 | Down | 39 | Skip backward |
| 14 | Left | 40 | Record |
| 15 | Right | 41 | Recording list |
| 20 | OK | 42 | Repeat |
| 21 | Home menu | 43 | Live TV |
| 22 | Menu (igual ao Home) | 44 | EPG |
| 23 | Back | 45 | Program information |
| 24 | Volume up | 46 | Aspect ratio |
| 25 | Volume down | 47 | External input |
| 26 | Mute (toggle) | 48 | PIP secondary video |
| 27 | Channel up | 49 | Subtitle |
| 28 | Channel down | 50 | Program list |
| 29 | Blue | 51 | Teletext |
| 30 | Green | 52 | Mark |
| 31 | Red | 400 | 3D video |
| 32 | Yellow | 401 | 3D L/R |
| 33 | Play | 402 | Dash (-) |
| 34 | Pause | 403 | Previous channel |
| 35 | Stop | 404 | Favorite channel |
| 405 | Quick menu | 412 | Exit |
| 406 | Text option | 413 | Reservation list |
| 407 | Audio description | 414 | PIP channel up |
| 408 | NetCast (igual ao Home) | 415 | PIP channel down |
| 409 | Energy saving | 416 | Switch primary/secondary video |
| 410 | A/V mode | 417 | My Apps |
| 411 | SIMPLINK | | |
