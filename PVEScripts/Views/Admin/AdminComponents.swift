import SwiftUI

/// Führt Aktionen aus, zeigt Fortschritt und Fehler an.
@MainActor
final class ActionRunner: ObservableObject {
    @Published var busy: String?
    @Published var error: String?
    @Published var message: String?

    var isBusy: Bool { busy != nil }

    func run(_ title: String, success: String? = nil, _ operation: @escaping () async throws -> Void) {
        guard busy == nil else { return }
        busy = title
        Task {
            do {
                try await operation()
                if let success { message = success }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            busy = nil
        }
    }
}

extension View {
    /// Fehler- und Erfolgsmeldungen eines ActionRunners als Alert, Fortschritt als Overlay.
    func actionRunner(_ runner: ActionRunner) -> some View {
        modifier(ActionRunnerModifier(runner: runner))
    }
}

private struct ActionRunnerModifier: ViewModifier {
    @ObservedObject var runner: ActionRunner

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let busy = runner.busy {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(busy).font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: runner.busy)
            .alert("Fehler", isPresented: Binding(get: { runner.error != nil }, set: { if !$0 { runner.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(runner.error ?? "")
            }
            .alert("Erledigt", isPresented: Binding(get: { runner.message != nil }, set: { if !$0 { runner.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(runner.message ?? "")
            }
    }
}

/// Auslastungsbalken mit Beschriftung.
struct UsageBar: View {
    let title: String
    let fraction: Double?
    let detail: String
    var symbol: String? = nil

    private var color: Color {
        let f = fraction ?? 0
        if f > 0.9 { return .red }
        if f > 0.75 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                }
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(color)
                        .frame(width: max(0, min(1, fraction ?? 0)) * geo.size.width)
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct StatusDot: View {
    let running: Bool
    var paused = false
    var body: some View {
        Circle()
            .fill(paused ? Color.yellow : (running ? Color.green : Color.gray))
            .frame(width: 9, height: 9)
    }
}

/// Erstellt eine Terminal-Sitzung, deren Host-Key-Bestätigung im HostStore landet.
@MainActor
func makeTerminalSession(host: ProxmoxHost, title: String, command: String?, hosts: HostStore) -> TerminalSession {
    let session = TerminalSession(host: host, title: title, initialCommand: command)
    let id = host.id
    session.onTrustHostKey = { key in
        hosts.trustHostKey(key, for: id)
        Task { await SSHPool.shared.drop(id) }
    }
    return session
}

/// Einheitlicher Zustand für "Host-Schlüssel bestätigen".
struct PendingHostKey: Identifiable {
    let id = UUID()
    let key: String
    let fingerprint: String
    let changed: Bool
}

extension View {
    func hostKeyAlert(_ pending: Binding<PendingHostKey?>, onTrust: @escaping (String) -> Void) -> some View {
        alert(item: pending) { item in
            Alert(
                title: Text(item.changed ? "Host-Schlüssel geändert!" : "Host-Schlüssel prüfen"),
                message: Text((item.changed
                    ? "Der Schlüssel stimmt nicht mehr mit dem gespeicherten überein. Nur bestätigen, wenn du den Host neu installiert hast.\n\n"
                    : "Die Echtheit des Hosts kann nicht bestätigt werden.\n\n") + item.fingerprint),
                primaryButton: .default(Text("Vertrauen")) { onTrust(item.key) },
                secondaryButton: .cancel()
            )
        }
    }
}
