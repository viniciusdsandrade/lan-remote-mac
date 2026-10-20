import SwiftUI
import WebKit

// Sony's login inside the app. It ends on the Remote Play redirect page, whose address carries the
// code the account id comes from; the page is intercepted before it shows, so the user never has to
// copy anything.

struct PSNLoginSheet: View {
    let onRedirect: (String) -> Void
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Entrar na PSN")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Entre com a conta que você usa no PS5. Ao terminar, o app pega o id da conta sozinho.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.65))
                }
                Spacer()
                Button("Cancelar") { presentationMode.wrappedValue.dismiss() }
                    .buttonStyle(RemoteButtonStyle(bg: Color(white: 0.25), height: 28, cornerRadius: 6))
                    .frame(width: 84)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            .background(Color(white: 0.11))

            PSNLoginWebView { url in
                presentationMode.wrappedValue.dismiss()
                onRedirect(url)
            }
        }
        .frame(width: 560, height: 720)
    }
}

private struct PSNLoginWebView: NSViewRepresentable {
    let onRedirect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onRedirect: onRedirect) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()   // the login leaves no cookies behind
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: PSNAccount.loginURL))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onRedirect: (String) -> Void

        init(onRedirect: @escaping (String) -> Void) {
            self.onRedirect = onRedirect
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, PSNAccount.isRedirect(url) {
                decisionHandler(.cancel)
                onRedirect(url.absoluteString)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
