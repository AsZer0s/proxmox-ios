import CryptoKit
import Security
import SwiftUI
import WebKit

struct GuestConsoleView: View {
    @EnvironmentObject private var appState: AppState

    let guest: ProxmoxVM

    @State private var ticket: String?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if let ticket, let server = appState.connectedServer {
                ProxmoxConsoleWebView(
                    server: server,
                    ticket: ticket,
                    guest: guest,
                    onError: { error = $0 }
                )
            } else if let error {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Console Unavailable")
                        .font(.headline)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            } else {
                ProgressView("Opening console…")
            }
        }
        .navigationTitle(guest.type == .qemu ? "Console" : "Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let error, ticket != nil {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
        }
        .task { await loadTicket() }
    }

    @MainActor
    private func loadTicket() async {
        guard let service = appState.service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            ticket = try await service.webConsoleTicket()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ProxmoxConsoleWebView: UIViewRepresentable {
    let server: ProxmoxServer
    let ticket: String
    let guest: ProxmoxVM
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(server: server, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptEnabled = true
        configuration.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .black
        webView.isOpaque = false

        guard let cookie = authCookie(), let url = consoleURL() else {
            onError(String(localized: "Could not create the console session."))
            return webView
        }

        configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private func authCookie() -> HTTPCookie? {
        let domain = server.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return HTTPCookie(properties: [
            .domain: domain,
            .path: "/",
            .name: "PVEAuthCookie",
            .value: ticket,
            .secure: "TRUE",
        ])
    }

    private func consoleURL() -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        let host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = server.port
        components.path = "/"
        var query = [
            URLQueryItem(name: "console", value: guest.type == .qemu ? "kvm" : "lxc"),
            URLQueryItem(name: "vmid", value: "\(guest.vmid)"),
            URLQueryItem(name: "vmname", value: guest.displayName),
            URLQueryItem(name: "node", value: guest.node),
            URLQueryItem(name: "resize", value: "scale"),
        ]
        query.append(
            URLQueryItem(name: guest.type == .qemu ? "novnc" : "xtermjs", value: "1")
        )
        components.queryItems = query
        return components.url
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let server: ProxmoxServer
        private let onError: (String) -> Void

        init(server: ProxmoxServer, onError: @escaping (String) -> Void) {
            self.server = server
            self.onError = onError
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            onError(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            onError(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard server.allowInsecureSSL,
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  hostMatches(challenge.protectionSpace.host),
                  let trust = challenge.protectionSpace.serverTrust,
                  let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let certificate = certificates.first,
                  let expected = KeychainHelper.certificateFingerprint(for: server.id) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            let actual = Self.fingerprint(for: certificate)
            guard expected.caseInsensitiveCompare(actual) == .orderedSame else {
                onError(String(localized: "The console certificate does not match the pinned certificate."))
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        private func hostMatches(_ challengeHost: String) -> Bool {
            let configured = server.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return challengeHost.caseInsensitiveCompare(configured) == .orderedSame
        }

        private static func fingerprint(for certificate: SecCertificate) -> String {
            let data = SecCertificateCopyData(certificate) as Data
            let digest = SHA256.hash(data: data)
            return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
        }
    }
}
