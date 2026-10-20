import Foundation

// Woken over the network, the PS5 turns on but leaves the TV off: it sends One-Touch Play (the
// HDMI-CEC "turn the TV on") only when it boots or when a physical controller connects. The one
// network-only way to make it switch the TV on is a restart, done through a Remote Play session:
// Control Center › Power › Restart PS5.
//
// The app has no Remote Play session of its own, so it drives `ps5ctl`, the CLI of the companion
// project "Controle PS5" (it pairs with the console on its own and saves screenshots of the
// session's video). Before the last ✕ the app reads the console's screen with OCR: a ↓ lost in
// the Power menu would leave the focus on "Turn Off PS5", and a console turned off no longer wakes
// from the network.

enum PlayStationRestart {
    /// `ps5ctl`: $PS5CTL, or the usual install places.
    static var tool: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [ProcessInfo.processInfo.environment["PS5CTL"],
                          "\(home)/.local/bin/ps5ctl", "/opt/homebrew/bin/ps5ctl", "/usr/local/bin/ps5ctl"]
        return candidates.compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Restarts `console`, which must be awake. Returns once it has dropped off the network to reboot.
    static func run(_ console: PlayStationConsole, progress: @escaping @MainActor (String) -> Void) async throws {
        guard let tool else { throw PlayStationError.noRemotePlayTool }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ps5-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = Session(tool: tool, folder: folder)

        try await Task.sleep(nanoseconds: 4_000_000_000)   // a session right after the wake loses the first key
        var why = ""
        for attempt in 1...2 {
            await progress("Abrindo o menu de energia do \(console.name) pelo Uso remoto…")
            // Two ○ close whatever was left open; ↓ goes from the cards to the bottom row (Home) and
            // ← wraps around to Power.
            let row = try await session.screen(["wait 2", "press circle", "wait 0.8", "press circle", "wait 0.8",
                                                "press ps", "wait 1.5", "press down", "wait 1", "press left",
                                                "wait 1.2", "shot energia"])
            if row.hasLine(["energia", "power"]), !row.contains(["modo de repouso", "rest mode"]) {
                // The menu doesn't wrap around: from its first item (Rest Mode) four ↓ end on Restart,
                // the last one, even if a couple of them get lost.
                let menu = try await session.screen(["wait 1.5", "press cross", "wait 1.5",
                                                     "press down", "wait 0.8", "press down", "wait 0.8",
                                                     "press down", "wait 0.8", "press down", "wait 1.2", "shot menu"])
                if menu.contains(["reinicie", "restart your"]), !menu.contains(["desligue", "turn off your"]) {
                    await progress("Reiniciando o \(console.name). Ao ligar de novo, ele liga a TV…")
                    for _ in 1...2 {
                        try await session.press("cross")
                        if await droppedOff(console) { return }
                        // The ✕ got lost: confirm the focus is still on Restart before trying again.
                        let again: ScreenText
                        do {
                            again = try await session.screen(["wait 1.5", "shot menu"])
                        } catch {
                            if await droppedOff(console) { return }   // slow to leave, but restarting
                            throw error
                        }
                        guard again.contains(["reinicie", "restart your"]) else { break }
                    }
                    why = "o PS5 não saiu da rede depois de Reiniciar"
                } else {
                    why = "o foco não ficou em Reiniciar PS5"
                }
            } else {
                why = "o ícone de energia não ficou em foco"
            }
            _ = try? await session.screen(["wait 1", "press circle", "wait 0.8", "press circle", "wait 0.5", "shot fim"])
            if attempt == 1 { await progress("O menu do \(console.name) não abriu como esperado. Tentando de novo…") }
        }
        throw PlayStationError.restartFailed(why)
    }

    /// A restarting console stops answering the discovery protocol within a few seconds.
    private static func droppedOff(_ console: PlayStationConsole) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if await PlayStationDiscovery.search(host: console.host, timeout: 1.5).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Remote Play sessions through `ps5ctl`. The console refuses a new session for 6 to 8 s after
    /// one closes, so each call waits for that first.
    private final class Session: @unchecked Sendable {
        let tool: URL
        let folder: URL
        private var lastClosed = Date.distantPast

        init(tool: URL, folder: URL) {
            self.tool = tool
            self.folder = folder
        }

        func press(_ button: String) async throws {
            try await run(["press", button])
        }

        /// Runs `steps` in one session with video and reads the text of the screenshot they end with.
        func screen(_ steps: [String]) async throws -> ScreenText {
            guard let shot = steps.last?.split(separator: " ").last.map(String.init) else { return ScreenText(lines: []) }
            let image = folder.appendingPathComponent("\(shot).jpg")
            try? FileManager.default.removeItem(at: image)
            try await run(["script", "--out", folder.path] + steps)
            return ScreenText(image: image)
        }

        private func run(_ arguments: [String]) async throws {
            let wait = 8.5 - Date().timeIntervalSince(lastClosed)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            defer { lastClosed = Date() }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let log = folder.appendingPathComponent("ps5ctl.log")
            let tool = tool
            try await Task.detached(priority: .userInitiated) {
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let output = try FileHandle(forWritingTo: log)
                defer { try? output.close() }
                let process = Process()
                process.executableURL = tool
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = output
                try process.run()
                let deadline = Date().addingTimeInterval(45)
                while process.isRunning, Date() < deadline { usleep(200_000) }
                if process.isRunning {
                    process.terminate()
                    throw PlayStationError.restartFailed("o ps5ctl não terminou")
                }
                guard process.terminationStatus == 0 else {
                    // ps5ctl ends with "Erro: <why>"; chiaki's own log lines come before it.
                    let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                    let reason = text.split(separator: "\n").last { $0.contains("Erro") }
                        .map { $0.replacingOccurrences(of: "Erro: ", with: "") }
                    throw PlayStationError.restartFailed(reason ?? "o ps5ctl terminou com \(process.terminationStatus)")
                }
            }.value
        }
    }
}
