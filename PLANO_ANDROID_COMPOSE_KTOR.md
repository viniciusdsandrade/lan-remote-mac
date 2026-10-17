# Plano de Implementação Android: Jetpack Compose + Ktor Client

> **Documento salvo no repositório Android em:** `PLANO_IMPLEMENTACAO.md` (repositório `lan-remote-android`)  
> **Repositório GitHub:** `lan-remote-android` (projeto irmão)

---

## 1. Resumo da Stack

- **Linguagem:** Kotlin 2.0+ (K2)
- **UI:** Jetpack Compose + Material 3 (Dark OLED Titanium)
- **Cliente HTTP:** Ktor Client 3.x (Engine CIO/Android)
- **Concorrência:** Coroutines + StateFlow + ViewModel + Mutex (Debounce de 300ms)
- **Descoberta de Rede:** `DatagramSocket` UDP + `WifiManager.MulticastLock` (SSDP M-SEARCH)
- **Persistência:** Jetpack DataStore Preferences
- **Feedback Tátil:** `Vibrator` / `VibrationEffect.createPredefined(EFFECT_CLICK)`
- **Integrações de Sistema:** `TileService` (Quick Settings) e interceptação de teclas físicas de volume (`onKeyDown`)

---

## 2. Peculiaridades de Rede

1. **Cleartext HTTP**: A TV opera em HTTP puro na porta 8080. Configurado via `network_security_config.xml`.
2. **User-Agent**: `lg_roap_control/1.0.0 (android)` sem `"UDAP/2.0"` para chamadas ROAP, evitando o erro HTTP 400.
3. **MulticastLock**: Adquirido temporariamente durante buscas SSDP para contornar a economia de bateria do Android.
4. **Fila Serial**: Mutex com intervalo de 300ms para evitar descarte de repetições rápidas de teclas pelo hardware da TV.

Consulte o documento completo com o código de exemplo e arquitetura de pacotes em `PLANO_IMPLEMENTACAO.md` (repositório `lan-remote-android`).
