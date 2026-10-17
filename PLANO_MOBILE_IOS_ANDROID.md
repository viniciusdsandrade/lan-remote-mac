# Plano de Implementação: Aplicativo Mobile (iOS & Android) para Controle da TV LG NetCast

> **Objetivo:** Transformar a engenharia reversa e a implementação já validada da TV LG NetCast (xxLN5700) em um aplicativo mobile nativo e multiplataforma para iPhone/iPad e smartphones Android, operando 100% na rede local (sem nuvem, sem servidores intermediários e com resposta instantânea).

---

## 1. Visão Geral da Arquitetura Mobile

Diferente do Mac, onde o aplicativo roda com acesso livre a sockets e portas locais, dispositivos móveis (iOS e Android) possuem restrições rígidas de segurança de rede, energia, ciclo de vida em background e permissões locais.

O aplicativo mobile seguirá uma **arquitetura direta (Serverless Local)**:
- O smartphone se comunica **diretamente com a TV** (`http://192.0.2.X:8080`) através da rede Wi-Fi local.
- **Zero infraestrutura externa**: Não depende de computador ligado, servidores na nuvem ou contas online.
- **Persistência local**: Armazenamento seguro de chave de pareamento (`pairing_key`), IP, porta e sessão (`session`) no Keychain (iOS) e SharedPreferences/EncryptedSharedPreferences (Android).

```
┌─────────────────────────────────────────────────────────────┐
│                      Smartphone                             │
│                                                             │
│  ┌───────────────────────┐       ┌───────────────────────┐  │
│  │    Interface Mobile   │       │   Motor de Protocolo  │  │
│  │  (SwiftUI / Compose   │ <───> │   • Queue & Debounce  │  │
│  │    / Multiplatform)   │       │   • Sessão & Retry    │  │
│  └───────────────────────┘       │   • SSDP Multicast    │  │
│                                  └──────────┬────────────┘  │
└─────────────────────────────────────────────┼───────────────┘
                                              │ HTTP / Port 8080
                                              ▼ (Wi-Fi Local)
                                 ┌─────────────────────────┐
                                 │   TV LG NetCast 2013    │
                                 │       (xxLN5700)        │
                                 └─────────────────────────┘
```

---

## 2. Requisitos Específicos e Peculiaridades de Rede no Mobile

### 2.1. iOS (Apple App Store & TestFlight)
1. **App Transport Security (ATS) — HTTP sem TLS**:
   - Por padrão, o iOS bloqueia requisições `http://` não seguras.
   - A TV LG opera exclusivamente em HTTP puro na porta `8080`.
   - **Solução necessária no `Info.plist`**:
     ```xml
     <key>NSAppTransportSecurity</key>
     <dict>
         <key>NSAllowsLocalNetworking</key>
         <true/>
     </dict>
     ```
2. **Permissão de Rede Local (iOS 14+)**:
   - A Apple exige consentimento do usuário para varreduras UDP e chamadas HTTP na sub-rede local.
   - **Chave obrigatória no `Info.plist`**:
     ```xml
     <key>NSLocalNetworkUsageDescription</key>
     <string>O app precisa acessar sua rede Wi-Fi local para descobrir e controlar sua TV LG NetCast.</string>
     ```
3. **SSDP Multicast Entitlement**:
   - Para envio e recepção de SSDP M-SEARCH (`239.255.255.250:1900`), o iOS pode exigir o entitlement `com.apple.developer.networking.multicast`.
   - **Estratégia de Fallback elegante**: Além do SSDP, implementar varredura TCP rápida da sub-rede `/24` na porta `8080` (que não exige entitlement especial) e campo para digitação direta do IP.

### 2.2. Android (Google Play Store)
1. **Tráfego de Texto Claro (Cleartext Traffic — Android 9+)**:
   - Por padrão, o Android 9+ (API 28+) barra requisições HTTP sem SSL.
   - **Solução necessária no `AndroidManifest.xml`**:
     ```xml
     <application
         android:usesCleartextTraffic="true"
         android:networkSecurityConfig="@xml/network_security_config" ...>
     ```
   - Em `res/xml/network_security_config.xml`:
     ```xml
     <?xml version="1.0" encoding="utf-8"?>
     <network-security-config>
         <base-config cleartextTrafficPermitted="true" />
     </network-security-config>
     ```
2. **Permissões de Multicast & Wi-Fi**:
   - O Android bloqueia pacotes multicast por economia de bateria, a menos que um `MulticastLock` seja solicitado explicitamente:
     ```xml
     <uses-permission android:name="android.permission.INTERNET" />
     <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
     <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
     <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
     ```
   - No código Kotlin:
     ```kotlin
     val wifiManager = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
     val multicastLock = wifiManager.createMulticastLock("lg_ssdp_lock")
     multicastLock.acquire()
     // executar busca SSDP
     multicastLock.release()
     ```

### 2.3. Regra Crítica do Protocolo (Descoberta no Firmware 05.02.11)
- O cabeçalho `User-Agent` **NÃO DEVE** conter a string `"UDAP/2.0"` ao realizar chamadas ROAP (`/roap/api/command`).
- Se contiver, a TV retorna `HTTP 400 Bad Request`.
- **User-Agent padrão em todas as requisições**:
  `User-Agent: lg_roap_control/1.0.0 (mobile)`
- **Content-Type**:
  `Content-Type: application/atom+xml`

---

## 3. Comparativo de Tecnologias & Recomendação

| Abordagem | Prós | Contras | Veredito |
|---|---|---|---|
| **Opção A: Nativo Duplo (SwiftUI + Jetpack Compose)** | • Reaproveita **90%** do código Swift que já criamos para Mac<br>• Widgets interativos no iOS 17/18 e Quick Settings no Android<br>• Resposta haptic perfeita e zero dependências pesadas | • Duas bases de código de UI | ⭐ **Altamente Recomendado** (Especialmente porque a parte iOS já está pronta!) |
| **Opção B: Flutter (Dart)** | • Código único para iOS e Android<br>• Suporte nativo completo a RawDatagramSocket (SSDP) e HTTP<br>• UI com renderização 120Hz idêntica nas duas plataformas | • Precisa reescrever a lógica em Dart<br>• Tamanho do app ligeiramente maior | ⭐ **Excelente alternativa para time único de desenvolvimento** |
| **Opção C: React Native / Expo** | • Familiaridade com TypeScript / React<br>• Prototipação rápida via Expo Go | • UDP Multicast no Expo Go exige prebuild ou módulos nativos (`react-native-udp`)<br>• Latência ligeiramente maior em bridges nativas | Viável, mas com mais atrito em rede UDP de baixo nível |
| **Opção D: Kotlin Multiplatform (KMP)** | • Compartilha todo o motor de rede (Ktor + Coroutines)<br>• UI nativa com Compose no Android e SwiftUI no iOS | • Configuração inicial do projeto mais complexa | Muito bom para projetos de longo prazo |

---

## 4. O Caminho Mais Rápido e Eficiente: Nativo (SwiftUI + Jetpack Compose)

### 4.1. Plataforma iOS: Reaproveitamento Quase Imediato
Como já escrevemos e testamos com sucesso os arquivos:
- `LGTVClient.swift` (gerenciamento de sessão, fila assíncrona, debounce de 0,3s, `URLSession`);
- `RemoteView.swift` e `RemoteComponents.swift` (D-Pad, botões, rockers de volume/canal, teclado numérico, paleta de cores);
- `SettingsView.swift` (pareamento, troca de IP);

**O que muda para o iPhone:**
1. Trocar a janela de desktop pelo container de tela cheia do iOS (`NavigationStack` e safe areas).
2. Adicionar **Feedback Tátil Háptico**:
   ```swift
   import UIKit

   func triggerHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
       let generator = UIImpactFeedbackGenerator(style: style)
       generator.prepare()
       generator.impactOccurred()
   }
   ```
   *Cada toque em volume, setas ou OK vibra suavemente, dando a sensação de um controle remoto real.*
3. **Controle pelos Botões Físicos de Volume do iPhone**:
   - Integrar com `MPVolumeView` / `AVAudioSession` para interceptar as teclas físicas de volume do celular enquanto o aplicativo estiver aberto na tela.
4. **Widgets no iOS 17 / 18 e Central de Controle**:
   - Criar `AppIntents` para Volume +, Volume - e Mute.
   - O usuário pode colocar botões do controle direto na tela de bloqueio ou na Central de Controle do iPhone sem precisar abrir o app!

### 4.2. Plataforma Android: Jetpack Compose + Ktor
Criar um app moderno em Kotlin puro:
- **Stack recomendada**:
  - UI: **Jetpack Compose** (Material 3 Dark Theme).
  - Rede HTTP: **Ktor Client** ou **OkHttp 4** (com timeouts baixos de 3.0s).
  - Assincronia: **Kotlin Coroutines & StateFlow** (com `delay(300)` para debounce).
  - Descoberta: `DatagramSocket` com `MulticastLock`.
  - Haptic: `Vibrator` / `VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)`.
- **Recursos Exclusivos Android**:
  - **Quick Settings Tile**: Adicionar um atalho no menu superior do Android ("Desligar TV", "Mudo", "Volume").
  - **Home Screen Widget**: Widget compacto 4x2 com botões de volume, direcional e liga/desliga.

---

## 5. Estrutura de Telas e Experiência do Usuário (UX Mobile)

### 5.1. Tela Principal do Controle (Single-Screen Ergonomics)
Projetada para uso com **uma única mão**:
- **Topo**:
  - Indicador LED de conexão (Verde = Online, Vermelho = TV em Standby/Desconectada).
  - Nome do modelo (`LG xxLN5700`) e entrada ativa (`HDMI2`, `TV`).
  - Nível de volume numérico e status de Mudo.
  - Botão de Configurações (engrenagem).
- **Área Superior**:
  - Botão Power (com confirmação para evitar desligamentos acidentais).
  - Botão de Troca de Entrada (Input / Source).
  - Botão `123` para expandir/recolher o teclado numérico.
- **Centro (Zona de Alcance Fácil do Polegar)**:
  - D-Pad circular ergonômico com botão OK central.
  - Botões satélites: Voltar, Sair, Home/Smart e Menu.
- **Zona Inferior**:
  - Gangorras táteis verticais de Volume (`+ VOL -`) e Canal (`+ CH -`).
  - Botão Mute centralizado.
  - Teclas de reprodução de mídia (Play, Pause, Stop, Rewind, Fast Forward).
  - Barra de teclas coloridas (Vermelho, Verde, Amarelo, Azul).

### 5.2. Fluxo de Pareamento Inicial (Onboarding)
1. **Primeira abertura**:
   - App dispara busca automática na rede Wi-Fi via SSDP.
   - Se encontrar a TV, exibe: *"LG xxLN5700 encontrada em 192.0.2.100"*.
   - Se o roteador bloquear multicast, o app oferece:
     - Botão "Varrer Rede Local" (busca na porta 8080);
     - Opção de digitar o IP manualmente.
2. **Exibição do Código na TV**:
   - Usuário clica em *"Solicitar Código na TV"*.
   - O app envia o comando `AuthKeyReq`.
   - Um aviso pop-up com 6 dígitos surge na tela física do televisor.
3. **Confirmação**:
   - Usuário digita os 6 números no app e clica em *"Conectar"*.
   - O app envia `AuthReq`, recebe o `session` e armazena permanentemente.
   - A partir desse momento, o controle fica 100% funcional.

---

## 6. Plano de Fases de Desenvolvimento

```
Fase 1: Preparação & Setup de Projetos
  ├── iOS: Criar projeto Xcode (iOS 17+) com as permissões de rede
  └── Android: Criar projeto Android Studio (API 26+) com Compose e Ktor

Fase 2: Motor de Rede e Protocolo
  ├── Importar LGTVClient para iOS e implementar equivalente Kotlin no Android
  ├── Implementar busca SSDP + fallback de varredura IP
  └── Testar pareamento e persistência de credenciais em dispositivo físico

Fase 3: Interface Mobile & Ergonomia Tátil
  ├── Adaptação de layout para telas de iPhone e Android
  ├── Feedback háptico (vibração tátil nos botões)
  ├── Animações de clique e estados visuais ativos
  └── Teclado numérico expansível

Fase 4: Recursos Nativos Avançados
  ├── Atalhos de teclado / Botões de volume do aparelho
  ├── Widgets interativos de tela de bloqueio e início
  └── Modo escuro OLED de alto contraste (redução de consumo de bateria)

Fase 5: Testes & Distribuição
  ├── Testes com a TV física conectada no mesmo roteador
  ├── Geração de build IPA (TestFlight) para iOS
  └── Geração de build APK / AAB para Android
```

---

## 7. Estimativa de Tempo de Execução

| Etapa | Escopo | Tempo Estimado |
|---|---|---|
| **Port iOS (SwiftUI)** | Adaptação do código Mac existente para iPhone, Safe Areas, Haptics e Info.plist | 1 a 2 dias |
| **Port Android (Compose)** | Criação do app Kotlin, motor de rede, layout Compose e permissões de Cleartext | 2 a 3 dias |
| **Ajustes de UX & Pareamento** | Onboarding de descoberta automática de IP e refinamento visual | 1 dia |
| **Widgets & Otimizações** | Widgets de tela inicial e interceptação de teclas de volume | 1 a 2 dias |
| **Total Estimado** | **App completo e funcional nas duas plataformas** | **5 a 8 dias úteis** |

---

## 8. Conclusão

Graças à arquitetura limpa implementada e testada no projeto Mac (`LGTVClient.swift`), a transição para mobile é extremamente direta:
1. No **iOS**, mais de **80% do código já está escrito e compilando** sem dependências de terceiros.
2. No **Android**, a especificação dos endpoints XML, headers e key codes já está 100% mapeada e testada contra o hardware real.
3. O resultado final será um aplicativo leve, sem anúncios, sem rastreamento, com resposta em menos de 100 milissegundos e controle total da TV na palma da mão.
