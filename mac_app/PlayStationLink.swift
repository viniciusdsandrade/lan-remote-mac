import Foundation

// The PS5 as the second way of switching the TV on (the protocol is in PlayStationRemote.swift).
// After hours in standby the TV Box drops off the Wi-Fi and ignores Wake-on-LAN; the PS5 in rest
// mode keeps answering, so the power-on flow in TVBoxLink.swift falls back to it.

enum ConsolePairingStage: Equatable {
    case idle
    case searching
    case working
    case failed(String)
}

extension LGTVClient {
    func searchConsoles() {
        consolePairingStage = .searching
        Task {
            discoveredConsoles = await PlayStationDiscovery.search()
            consolePairingStage = .idle
        }
    }

    /// Turns what the user pasted (the address the PSN login ends on, or the account id itself)
    /// into the account id the registration needs.
    func usePSNAccount(_ input: String) {
        psnStage = .working
        Task {
            do {
                psnAccountId = try await PSNAccount.accountId(from: input)
                psnStage = .idle
            } catch {
                psnStage = .failed(error.localizedDescription)
            }
        }
    }

    /// Registers with the console showing "Link Device"; the PIN is the one on the TV screen.
    func registerConsole(_ candidate: DiscoveredPlayStation, pin: String) {
        guard let accountId = psnAccountId ?? console?.accountId else {
            consolePairingStage = .failed(PlayStationError.badAccountId.localizedDescription)
            return
        }
        consolePairingStage = .working
        Task {
            do {
                let registered = try await PlayStationRegistration.register(candidate.console, accountId: accountId, pin: pin)
                registered.save()
                console = registered
                powerOnError = nil
                consolePairingStage = .idle
            } catch {
                consolePairingStage = .failed(error.localizedDescription)
            }
        }
    }

    func forgetConsole() {
        PlayStationConsole.forget()
        console = nil
        consolePairingStage = .idle
    }
}
