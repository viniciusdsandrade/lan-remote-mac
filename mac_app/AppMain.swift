import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var client: LGTVClient?
    private var eventMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupKeyboardMonitor()
    }
    
    private func setupKeyboardMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let client = self.client else { return event }

            // A sheet (button guide, settings) is in front: keys belong to it, not to the TV
            if NSApp.keyWindow?.sheetParent != nil {
                return event
            }

            // If user is currently typing in a TextField (e.g. inside settings), do not intercept
            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder is NSTextView || firstResponder is NSTextField {
                return event
            }
            
            // Check modifier keys: ignore Cmd, Ctrl, Option shortcuts
            if event.modifierFlags.contains(.command) ||
               event.modifierFlags.contains(.control) ||
               event.modifierFlags.contains(.option) {
                return event
            }
            
            let chars = event.charactersIgnoringModifiers ?? ""
            let keyCode = event.keyCode
            
            var targetKey: TVKey?
            
            // Key mapping
            switch keyCode {
            case 126: targetKey = .up
            case 125: targetKey = .down
            case 123: targetKey = .left
            case 124: targetKey = .right
            case 36, 76: targetKey = .ok
            case 51, 53, 117: targetKey = .back
            case 116: targetKey = .channelUp
            case 121: targetKey = .channelDown
            default: break
            }
            
            if targetKey == nil {
                switch chars.lowercased() {
                case "+", "=": targetKey = .volumeUp
                case "-", "_": targetKey = .volumeDown
                case "m": targetKey = .mute
                case "]": targetKey = .channelUp
                case "[": targetKey = .channelDown
                case "h": targetKey = .home
                case "i": targetKey = .input
                case "x": targetKey = .exit
                case " ": targetKey = .play
                case "0": targetKey = .digit0
                case "1": targetKey = .digit1
                case "2": targetKey = .digit2
                case "3": targetKey = .digit3
                case "4": targetKey = .digit4
                case "5": targetKey = .digit5
                case "6": targetKey = .digit6
                case "7": targetKey = .digit7
                case "8": targetKey = .digit8
                case "9": targetKey = .digit9
                default: break
                }
            }
            
            if let key = targetKey {
                Task { @MainActor in
                    client.sendKey(key)
                }
                return nil
            }
            
            return event
        }
    }
}

@main
struct LGRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var client = LGTVClient()
    
    init() {
        // Customize appearance for dark titanium remote look
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    
    var body: some Scene {
        WindowGroup {
            RemoteView(client: client)
                .onAppear {
                    appDelegate.client = client
                }
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 860)
    }
}
