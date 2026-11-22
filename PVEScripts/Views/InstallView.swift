import SwiftUI

struct InstallView: View {
    let script: Script

    @EnvironmentObject private var hosts: HostStore
    @Environment(\.dismiss) private var dismiss

    @State private var hostID: UUID?
    @State private var options = InstallOptions()
    @State private var showAddHost = false
    @State private var session: TerminalSession?
    @State private var guests: [ProxmoxGuest] = []
    @State private var loadingGuests = false
    @State private var guestError: String?

    private var createsGuest: Bool { [.lxc, .vm, .turnkey].contains(script.type) }
    private var selectedHost: ProxmoxHost? { hosts.host(id: hostID) ?? hosts.defaultHost }
    private var command: String { CommandBuilder.command(for: script, options: options) }
    private var baseResources: ScriptResources? {
        (options.variant == .alpine ? script.alpineMethod : script.defaultMethod)?.resources
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ScriptLogo(url: script.logoURL, size: 36)
                        VStack(alignment: .leading) {
                            Text(script.name).font(.headline)
                            Text(script.type.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                hostSection

                if script.alpineMethod != nil {
                    Section {
                        Picker("Variante", selection: $options.variant) {
                            ForEach(InstallVariant.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Variante")
                    } footer: {
                        Text("Alpine-Container sind deutlich kleiner, aber nicht für jede Anwendung gleich gut getestet.")
                    }
                }

                if createsGuest {
                    Section {
                        Picker("Modus", selection: $options.mode) {
                            ForEach(InstallMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Installationsmodus")
                    } footer: {
                        Text(options.mode.explanation)
                    }

                    if options.mode == .default {
                        overridesSection
                    }
                }

                if script.runsInsideGuest {
                    guestSection
                }

                Section {
                    Text(command)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("Wird ausgeführt")
                } footer: {
                    Text("Der Befehl läuft als \(selectedHost?.username ?? "root") auf \(selectedHost?.displayName ?? "deinem Host"). Rückfragen des Scripts beantwortest du im Terminal.")
                }
            }
            .navigationTitle("Installation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    start()
                } label: {
                    Label("Im Terminal starten", systemImage: "terminal")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedHost == nil || (script.runsInsideGuest && options.targetGuestID.isEmpty))
                .padding()
                .background(.bar)
            }
            .sheet(isPresented: $showAddHost) {
                HostEditView(host: ProxmoxHost()) { newHost in
                    hostID = newHost.id
                }
            }
            .fullScreenCover(item: $session) { session in
                TerminalScreen(session: session)
            }
            .onAppear {
                if hostID == nil { hostID = hosts.defaultHost?.id }
            }
        }
    }

    @ViewBuilder
    private var hostSection: some View {
        Section("Proxmox-Host") {
            if hosts.hosts.isEmpty {
                Button {
                    showAddHost = true
                } label: {
                    Label("Host hinzufügen", systemImage: "plus.circle.fill")
                }
            } else {
                Picker("Host", selection: Binding(get: { selectedHost?.id }, set: { hostID = $0 })) {
                    ForEach(hosts.hosts) { host in
                        Text(host.displayName).tag(UUID?.some(host.id))
                    }
                }
                if let host = selectedHost {
                    LabeledContent("Verbindung", value: host.endpoint)
                        .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder
    private var overridesSection: some View {
        Section {
            Stepper(value: Binding(get: { options.cpu ?? baseResources?.cpu ?? 1 }, set: { options.cpu = $0 }), in: 1...64) {
                LabeledContent("CPU-Kerne", value: "\(options.cpu ?? baseResources?.cpu ?? 1)")
            }
            Stepper(value: Binding(get: { options.ramMB ?? baseResources?.ram ?? 512 }, set: { options.ramMB = $0 }), in: 128...262_144, step: 256) {
                LabeledContent("RAM", value: "\(options.ramMB ?? baseResources?.ram ?? 512) MB")
            }
            Stepper(value: Binding(get: { options.diskGB ?? baseResources?.hdd ?? 4 }, set: { options.diskGB = $0 }), in: 1...4096) {
                LabeledContent("Disk", value: "\(options.diskGB ?? baseResources?.hdd ?? 4) GB")
            }
            TextField("Hostname (optional)", text: $options.hostname)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("CT/VM-ID (optional, sonst nächste freie)", text: $options.containerID)
                .keyboardType(.numberPad)
            if script.type == .lxc {
                Picker("Container-Typ", selection: $options.privilege) {
                    ForEach(ContainerPrivilege.allCases) { Text($0.title).tag($0) }
                }
            }
            Toggle("Ausführliche Ausgabe", isOn: $options.verbose)
            if options.cpu != nil || options.ramMB != nil || options.diskGB != nil {
                Button("Auf Script-Standard zurücksetzen", role: .destructive) {
                    options.cpu = nil
                    options.ramMB = nil
                    options.diskGB = nil
                }
            }
        } header: {
            Text("Ressourcen")
        } footer: {
            Text("Nur geänderte Werte werden übergeben. Storage und Netzwerk wählt das Script bei Bedarf im Terminal ab.")
        }
    }

    @ViewBuilder
    private var guestSection: some View {
        Section {
            if loadingGuests {
                ProgressView()
            } else if guests.isEmpty {
                Button("Container laden") { Task { await loadGuests() } }
                    .disabled(selectedHost == nil)
                if let guestError {
                    Text(guestError).font(.footnote).foregroundStyle(.red)
                }
            } else {
                Picker("Container", selection: $options.targetGuestID) {
                    Text("Bitte wählen").tag("")
                    ForEach(guests.filter(\.isContainer)) { guest in
                        Text("\(guest.vmid) · \(guest.displayName)").tag(String(guest.vmid))
                    }
                }
            }
            TextField("oder CT-ID eingeben", text: $options.targetGuestID)
                .keyboardType(.numberPad)
        } header: {
            Text("Ziel-Container")
        } footer: {
            Text("Das Add-on wird mit `pct exec` im gewählten LXC ausgeführt.")
        }
    }

    private func loadGuests() async {
        guard let host = selectedHost else { return }
        loadingGuests = true
        guestError = nil
        defer { loadingGuests = false }
        do {
            guests = try await PVEClient(host: host).guests().filter { !$0.isTemplate }
        } catch {
            guestError = error.localizedDescription
        }
    }

    private func start() {
        guard let host = selectedHost else { return }
        let session = TerminalSession(host: host, title: script.name, initialCommand: command)
        let store = hosts
        session.onTrustHostKey = { key in store.trustHostKey(key, for: host.id) }
        self.session = session
    }
}
