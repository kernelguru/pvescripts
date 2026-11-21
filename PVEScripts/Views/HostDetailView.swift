import SwiftUI

struct HostDetailView: View {
    let hostID: UUID

    @EnvironmentObject private var hosts: HostStore
    @State private var guests: [ProxmoxGuest] = []
    @State private var loading = false
    @State private var error: String?
    @State private var pendingHostKey: (key: String, fingerprint: String, changed: Bool)?
    @State private var session: TerminalSession?
    @State private var editing = false
    @State private var busyGuest: String?

    private var host: ProxmoxHost? { hosts.host(id: hostID) }

    var body: some View {
        Group {
            if let host {
                content(host)
            } else {
                ContentUnavailableView("Host gelöscht", systemImage: "trash")
            }
        }
        .navigationTitle(host?.displayName ?? "Host")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Bearbeiten") { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            if let host { HostEditView(host: host) }
        }
        .fullScreenCover(item: $session) { session in
            TerminalScreen(session: session)
        }
        .task(id: hostID) { await load() }
        .alert("Host-Schlüssel prüfen", isPresented: Binding(get: { pendingHostKey != nil }, set: { if !$0 { pendingHostKey = nil } })) {
            Button(pendingHostKey?.changed == true ? "Neuen Schlüssel vertrauen" : "Vertrauen") {
                if let key = pendingHostKey?.key { hosts.trustHostKey(key, for: hostID) }
                pendingHostKey = nil
                Task { await load() }
            }
            Button("Abbrechen", role: .cancel) { pendingHostKey = nil }
        } message: {
            Text((pendingHostKey?.changed == true
                  ? "Der Host-Schlüssel hat sich geändert! Nur bestätigen, wenn du den Host neu installiert hast.\n\n"
                  : "Die Echtheit des Hosts kann nicht bestätigt werden.\n\n") + (pendingHostKey?.fingerprint ?? ""))
        }
    }

    @ViewBuilder
    private func content(_ host: ProxmoxHost) -> some View {
        List {
            Section {
                Button {
                    openTerminal(title: "Shell – \(host.displayName)", command: nil)
                } label: {
                    Label("Shell öffnen", systemImage: "terminal")
                }
                Button {
                    openTerminal(title: "Updates – \(host.displayName)",
                                 command: "apt update && apt -y dist-upgrade")
                } label: {
                    Label("Host aktualisieren (apt dist-upgrade)", systemImage: "arrow.down.circle")
                }
            } header: {
                Text(host.endpoint)
            }

            Section {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                if guests.isEmpty && !loading && error == nil {
                    Text("Keine Container oder VMs gefunden.")
                        .foregroundStyle(.secondary)
                }
                ForEach(guests) { guest in
                    GuestRow(guest: guest, busy: busyGuest == guest.id)
                        .contextMenu { guestActions(guest, host: host) }
                        .swipeActions(edge: .trailing) {
                            if guest.isRunning {
                                Button("Stopp") { Task { await act(.shutdown, guest, host) } }.tint(.red)
                            } else {
                                Button("Start") { Task { await act(.start, guest, host) } }.tint(.green)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if guest.isContainer && guest.isRunning {
                                Button("Konsole") {
                                    openTerminal(title: "CT \(guest.vmid) – \(guest.displayName)", command: "pct enter \(guest.vmid)")
                                }
                                .tint(.blue)
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Container & VMs")
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                }
            } footer: {
                Text("Wischen oder lange drücken für Aktionen. „Update“ startet das Community-Script-Update im Container.")
            }
        }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func guestActions(_ guest: ProxmoxGuest, host: ProxmoxHost) -> some View {
        if guest.isRunning {
            if guest.isContainer {
                Button("Konsole", systemImage: "terminal") {
                    openTerminal(title: "CT \(guest.vmid) – \(guest.displayName)", command: "pct enter \(guest.vmid)")
                }
                Button("Update (Community Script)", systemImage: "arrow.triangle.2.circlepath") {
                    openTerminal(title: "Update – \(guest.displayName)",
                                 command: "pct exec \(guest.vmid) -- bash -lc 'if command -v update >/dev/null; then update; else echo \"Kein update-Befehl gefunden.\"; fi'")
                }
            }
            Button("Neu starten", systemImage: "arrow.clockwise") { Task { await act(.reboot, guest, host) } }
            Button("Herunterfahren", systemImage: "power") { Task { await act(.shutdown, guest, host) } }
            Button("Stoppen (hart)", systemImage: "stop.fill", role: .destructive) { Task { await act(.stop, guest, host) } }
        } else {
            Button("Starten", systemImage: "play.fill") { Task { await act(.start, guest, host) } }
        }
    }

    private func openTerminal(title: String, command: String?) {
        guard let host else { return }
        let session = TerminalSession(host: host, title: title, initialCommand: command)
        let store = hosts
        let id = host.id
        session.onTrustHostKey = { key in store.trustHostKey(key, for: id) }
        self.session = session
    }

    private func load() async {
        guard let host else { return }
        loading = true
        defer { loading = false }
        do {
            guests = try await GuestService.listGuests(host: host)
            error = nil
        } catch SSHConnectError.unknownHostKey(let key, let fp) {
            pendingHostKey = (key, fp, false)
        } catch SSHConnectError.hostKeyMismatch(let key, let fp) {
            pendingHostKey = (key, fp, true)
            error = "Host-Schlüssel hat sich geändert."
        } catch let e {
            error = e.localizedDescription
        }
    }

    private func act(_ action: GuestAction, _ guest: ProxmoxGuest, _ host: ProxmoxHost) async {
        busyGuest = guest.id
        defer { busyGuest = nil }
        do {
            try await GuestService.perform(action, on: guest, host: host)
            try? await Task.sleep(for: .seconds(1))
            await load()
        } catch let e {
            error = "\(action.title) fehlgeschlagen: \(e.localizedDescription)"
        }
    }
}

private struct GuestRow: View {
    let guest: ProxmoxGuest
    let busy: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: guest.isContainer ? "shippingbox.fill" : "desktopcomputer")
                .foregroundStyle(guest.isRunning ? .green : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(guest.displayName).font(.body.weight(.medium)).lineLimit(1)
                    if guest.isCommunityScript { Badge(text: "CS", color: .teal) }
                }
                HStack(spacing: 8) {
                    Text("\(guest.isContainer ? "CT" : "VM") \(guest.vmid)")
                    if let node = guest.node { Text(node) }
                    if let mem = guest.maxmem, mem > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(mem), countStyle: .memory))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if busy {
                ProgressView()
            } else {
                Text(guest.isRunning ? "läuft" : (guest.status ?? "—"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(guest.isRunning ? .green : .secondary)
            }
        }
    }
}
