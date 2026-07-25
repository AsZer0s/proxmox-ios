import SwiftUI

/// Shows live status for a single guest and exposes start / stop / shutdown /
/// reboot actions with a confirmation for destructive ones.
struct VMDetailView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = VMDetailViewModel()

    let guest: ProxmoxVM

    @State private var pendingAction: GuestAction?

    var body: some View {
        List {
            statusSection
            resourceSection
            actionSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(guest.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(service: appState.service, guest: guest) }
        .task { await model.refresh(service: appState.service, guest: guest) }
        .confirmationDialog(
            pendingAction.map { "\($0.label) \(guest.displayName)?" } ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                Button(action.label, role: action.isDestructive ? .destructive : nil) {
                    Task {
                        await model.perform(action, service: appState.service, guest: guest)
                        pendingAction = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        }
        .overlay {
            if model.isPerformingAction {
                Color.black.opacity(0.1).ignoresSafeArea()
                ProgressView().controlSize(.large)
            }
        }
        .alert("Error", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var currentStatus: String {
        model.status?.status ?? guest.status
    }

    private var isRunning: Bool {
        model.status?.isRunning ?? guest.isRunning
    }

    @ViewBuilder
    private var statusSection: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                StatusBadge(status: currentStatus)
            }
            LabeledContent("ID", value: "\(guest.type.label) \(guest.vmid)")
            LabeledContent("Node", value: guest.node)
            if let uptime = model.status?.uptime, uptime > 0 {
                LabeledContent("Uptime", value: uptime.formattedUptime)
            }
        }
    }

    @ViewBuilder
    private var resourceSection: some View {
        if let status = model.status, status.isRunning {
            Section("Resources") {
                if let cpu = status.cpu {
                    MetricBar(label: "CPU", value: cpu, detail: cpu.asPercentDetailed)
                        .padding(.vertical, 4)
                }
                if let used = status.mem, let total = status.maxmem, total > 0 {
                    MetricBar(
                        label: "Memory",
                        value: Double(used) / Double(total),
                        detail: "\(used.formattedBytes) / \(total.formattedBytes)"
                    )
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section("Actions") {
            HStack(spacing: 12) {
                ActionButton(action: .start, isBusy: model.isPerformingAction, isEnabled: !isRunning) {
                    pendingAction = .start
                }
                ActionButton(action: .reboot, isBusy: model.isPerformingAction, isEnabled: isRunning) {
                    pendingAction = .reboot
                }
            }
            HStack(spacing: 12) {
                ActionButton(action: .shutdown, isBusy: model.isPerformingAction, isEnabled: isRunning) {
                    pendingAction = .shutdown
                }
                ActionButton(action: .stop, isBusy: model.isPerformingAction, isEnabled: isRunning) {
                    pendingAction = .stop
                }
            }
        }
    }
}

@MainActor
final class VMDetailViewModel: ObservableObject {
    @Published var status: VMStatus?
    @Published var isPerformingAction = false
    @Published var error: String?

    func refresh(service: ProxmoxAPIService?, guest: ProxmoxVM) async {
        guard let service = service else { return }
        do {
            status = try await service.fetchGuestStatus(
                node: guest.node, type: guest.type, vmid: guest.vmid
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    func perform(_ action: GuestAction, service: ProxmoxAPIService?, guest: ProxmoxVM) async {
        guard let service = service else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await service.performAction(action, node: guest.node, type: guest.type, vmid: guest.vmid)
            // Give the task a moment to change state, then refresh.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refresh(service: service, guest: guest)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        VMDetailView(guest: ProxmoxVM(
            vmid: 100, name: "test-vm", status: "running",
            cpu: 0.12, cpus: 2, mem: 1_073_741_824, maxmem: 2_147_483_648,
            disk: nil, maxdisk: nil, uptime: 90_000
        ))
    }
    .environmentObject(AppState())
}
