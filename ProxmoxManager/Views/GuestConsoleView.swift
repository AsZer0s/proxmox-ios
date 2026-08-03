import SwiftUI
import WebKit
import UIKit

enum NativeConsoleTarget {
    case guest(ProxmoxVM, terminal: Bool)
    case node(node: String, command: String)

    var node: String {
        switch self {
        case .guest(let guest, _): guest.node
        case .node(let node, _): node
        }
    }

    var guestType: GuestType? {
        guard case .guest(let guest, _) = self else { return nil }
        return guest.type
    }

    var vmid: Int? {
        guard case .guest(let guest, _) = self else { return nil }
        return guest.vmid
    }

    var isTerminal: Bool {
        switch self {
        case .guest(_, let terminal): terminal
        case .node: true
        }
    }
}

struct GuestConsoleView: View {
    let guest: ProxmoxVM

    var body: some View {
        NativeConsoleView(
            target: .guest(guest, terminal: guest.type == .lxc),
            title: guest.type == .qemu ? String(localized: "Console") : String(localized: "Terminal")
        )
    }
}

struct NativeConsoleView: View {
    @EnvironmentObject private var appState: AppState

    let target: NativeConsoleTarget
    let title: String

    @State private var error: String?

    var body: some View {
        Group {
            if let service = appState.service {
                ProxmoxNativeConsoleWebView(service: service, target: target) {
                    error = $0
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Console Unavailable")
                        .font(.headline)
                    Text("The server connection is unavailable.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .background(Color.black)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
        }
    }
}

private struct ProxmoxNativeConsoleWebView: UIViewRepresentable {
    let service: ProxmoxAPIService
    let target: NativeConsoleTarget
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(service: service, target: target, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "consoleSocket")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        context.coordinator.webView = webView

        let directory = target.isTerminal ? "ConsoleAssets/xterm" : "ConsoleAssets/novnc"
        let filename = target.isTerminal ? "terminal" : "vnc"
        guard let url = Bundle.main.url(
            forResource: filename,
            withExtension: "html",
            subdirectory: directory
        ) else {
            onError(String(localized: "The bundled console client could not be loaded."))
            return webView
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "consoleSocket")
        coordinator.close()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let service: ProxmoxAPIService
        private let target: NativeConsoleTarget
        private let onError: (String) -> Void
        private var socket: URLSessionWebSocketTask?
        private var proxy: ProxmoxConsoleProxy?
        private var preparationTask: Task<Void, Never>?
        private var receiveTask: Task<Void, Never>?
        private var terminalPageReady = false
        private var terminalAuthenticated = false
        private var terminalHandshakeComplete = false
        weak var webView: WKWebView?

        init(
            service: ProxmoxAPIService,
            target: NativeConsoleTarget,
            onError: @escaping (String) -> Void
        ) {
            self.service = service
            self.target = target
            self.onError = onError
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            let labels = [
                "paste": String(localized: "Paste"),
                "escape": String(localized: "Esc"),
                "tab": String(localized: "Tab"),
                "ctrlAltDelete": String(localized: "Ctrl Alt Delete"),
                "ctrlC": String(localized: "Ctrl C"),
                "ctrlZ": String(localized: "Ctrl Z"),
                "ctrlL": String(localized: "Ctrl L"),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: labels),
               let json = String(data: data, encoding: .utf8) {
                evaluate("localizeConsole(\(json))")
            }
            prepareIfNeeded()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            report(error)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let payload = message.body as? [String: Any],
                  let action = payload["action"] as? String else { return }

            switch action {
            case "pageReady":
                terminalPageReady = true
                openTerminalIfReady()
            case "socketCreated":
                evaluate("nativeSocketOpened()")
            case "sendBinary":
                guard let encoded = payload["data"] as? String,
                      let data = Data(base64Encoded: encoded) else { return }
                send(.data(data))
            case "terminalInput":
                guard let input = payload["data"] as? String else { return }
                let count = input.lengthOfBytes(using: .utf8)
                send(.string("0:\(count):\(input)"))
            case "resize":
                guard let columns = payload["columns"] as? Int,
                      let rows = payload["rows"] as? Int else { return }
                send(.string("1:\(columns):\(rows):"))
            case "ping":
                send(.string("2"))
            case "requestPaste":
                let value = UIPasteboard.general.string ?? ""
                evaluate("nativePaste(\(Self.javaScriptLiteral(value)))")
            case "setClipboard":
                if let value = payload["data"] as? String {
                    UIPasteboard.general.string = value
                }
            case "close":
                close()
            case "clientError":
                if let detail = payload["message"] as? String {
                    onError(detail)
                }
            default:
                break
            }
        }

        private func prepareIfNeeded() {
            guard preparationTask == nil else { return }
            preparationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let proxy: ProxmoxConsoleProxy
                    switch target {
                    case .guest(let guest, let terminal):
                        proxy = try await service.createGuestConsoleProxy(
                            node: guest.node,
                            type: guest.type,
                            vmid: guest.vmid,
                            terminal: terminal
                        )
                    case .node(let node, let command):
                        proxy = try await service.createNodeConsoleProxy(node: node, command: command)
                    }

                    let socket = try await service.makeConsoleWebSocketTask(
                        node: target.node,
                        type: target.guestType,
                        vmid: target.vmid,
                        proxy: proxy
                    )
                    self.proxy = proxy
                    self.socket = socket
                    socket.resume()
                    self.receiveTask = Task { [weak self] in await self?.receiveLoop() }

                    if target.isTerminal {
                        openTerminalIfReady()
                    } else {
                        let password = Self.javaScriptLiteral(proxy.password ?? proxy.ticket)
                        let keyboard = Self.javaScriptLiteral(String(localized: "Keyboard"))
                        evaluate("startVNC(\(password),\(keyboard))")
                    }
                } catch {
                    report(error)
                }
            }
        }

        private func openTerminalIfReady() {
            guard target.isTerminal,
                  terminalPageReady,
                  !terminalAuthenticated,
                  let proxy,
                  socket != nil else { return }
            terminalAuthenticated = true
            evaluate("nativeSocketOpened()")
            send(.string("\(proxy.user):\(proxy.ticket)\n"))
        }

        private func send(_ message: URLSessionWebSocketTask.Message) {
            guard let socket else { return }
            Task { [weak self] in
                do {
                    try await socket.send(message)
                } catch {
                    self?.report(error)
                }
            }
        }

        private func receiveLoop() async {
            guard let socket else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    var data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    if target.isTerminal, !terminalHandshakeComplete {
                        terminalHandshakeComplete = true
                        if data.starts(with: Data("OK".utf8)) {
                            data.removeFirst(2)
                            if data.first == 10 { data.removeFirst() }
                        }
                        if data.isEmpty { continue }
                    }
                    evaluate("nativeSocketReceive('\(data.base64EncodedString())')")
                }
            } catch {
                if !Task.isCancelled {
                    evaluate("nativeSocketClosed()")
                    report(error)
                }
            }
        }

        private func evaluate(_ script: String) {
            Task { @MainActor [weak self] in
                self?.webView?.evaluateJavaScript(script)
            }
        }

        private func report(_ error: Error) {
            Task { @MainActor [weak self] in
                self?.onError(error.localizedDescription)
                self?.evaluate("nativeSocketError(\(Self.javaScriptLiteral(error.localizedDescription)))")
            }
        }

        func close() {
            preparationTask?.cancel()
            receiveTask?.cancel()
            socket?.cancel(with: .goingAway, reason: nil)
            preparationTask = nil
            receiveTask = nil
            socket = nil
        }

        private static func javaScriptLiteral(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let json = String(data: data, encoding: .utf8) else { return "\"\"" }
            return String(json.dropFirst().dropLast())
        }
    }
}
