import SwiftUI
import LocalAuthentication

/// Full-screen lock overlay shown when Face ID / app lock is enabled.
struct AppLockView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isAuthenticating = false
    @State private var authFailed = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Proxmox Manager")
                .font(.title2.weight(.semibold))

            Text("Authenticate to unlock")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if authFailed {
                Text("Authentication failed. Try again.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button(action: authenticate) {
                HStack {
                    if isAuthenticating {
                        ProgressView()
                    }
                    Text("Unlock")
                }
                .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isAuthenticating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            authenticate()
        }
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        authFailed = false
        Task {
            let success = await appState.authenticateWithBiometrics()
            await MainActor.run {
                isAuthenticating = false
                if !success {
                    authFailed = true
                }
            }
        }
    }
}
