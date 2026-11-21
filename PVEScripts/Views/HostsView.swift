import SwiftUI
import UniformTypeIdentifiers

struct HostsView: View {
    @EnvironmentObject private var hosts: HostStore
    @State private var editing: ProxmoxHost?

    var body: some View {
        NavigationStack {
            List {
                ForEach(hosts.hosts) { host in
                    NavigationLink(value: host.id) {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(host.displayName).font(.headline)
                                    if host.id == hosts.defaultHost?.id {
                                        Badge(text: "Standard", color: .accentColor)
                                    }
                                }
                                Text(host.endpoint)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            hosts.defaultHostID = host.id
                        } label: {
                            Label("Standard", systemImage: "star")
                        }
                        .tint(.yellow)
                    }
                    .contextMenu {
                        Button("Bearbeiten", systemImage: "pencil") { editing = host }
                        Button("Als Standard", systemImage: "star") { hosts.defaultHostID = host.id }
                    }
                }
                .onDelete { hosts.delete(at: $0) }
                .onMove { hosts.move(from: $0, to: $1) }
            }
            .overlay {
                if hosts.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("Kein Host", systemImage: "server.rack")
                    } description: {
                        Text("Füge deinen Proxmox-VE-Host hinzu. Die App verbindet sich per SSH (Port 22) als root.")
                    } actions: {
                        Button("Host hinzufügen") { editing = ProxmoxHost() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Hosts")
            .navigationDestination(for: UUID.self) { id in
                HostDetailView(hostID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = ProxmoxHost() } label: { Image(systemName: "plus") }
                }
                if !hosts.hosts.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
            }
            .sheet(item: $editing) { host in
                HostEditView(host: host)
            }
        }
    }
}

struct HostEditView: View {
    @EnvironmentObject private var hosts: HostStore
    @Environment(\.dismiss) private var dismiss

    @State private var host: ProxmoxHost
    @State private var credentials: HostCredentials
    @State private var importingKey = false
    @State private var testState: TestState = .idle
    private let isNew: Bool
    private let onSave: ((ProxmoxHost) -> Void)?

    enum TestState: Equatable {
        case idle, running, success(String), failure(String)
    }

    init(host: ProxmoxHost, onSave: ((ProxmoxHost) -> Void)? = nil) {
        _host = State(initialValue: host)
        _credentials = State(initialValue: HostCredentials.load(for: host.id))
        self.onSave = onSave
        isNew = host.address.isEmpty
    }

    private var canSave: Bool {
        !host.address.trimmingCharacters(in: .whitespaces).isEmpty
            && (host.authMethod == .password ? !credentials.password.isEmpty : !credentials.privateKey.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Name (z. B. pve01)", text: $host.name)
                    TextField("IP-Adresse oder Hostname", text: $host.address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $host.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    TextField("Benutzer", text: $host.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("Anmeldung", selection: $host.authMethod) {
                        ForEach(HostAuthMethod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch host.authMethod {
                    case .password:
                        SecureField("Passwort", text: $credentials.password)
                            .textContentType(.password)
                    case .privateKey:
                        TextEditor(text: $credentials.privateKey)
                            .font(.caption2.monospaced())
                            .frame(minHeight: 120)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .overlay(alignment: .topLeading) {
                                if credentials.privateKey.isEmpty {
                                    Text("-----BEGIN OPENSSH PRIVATE KEY-----\n…")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                            }
                        Button("Aus Datei importieren …", systemImage: "doc") { importingKey = true }
                        if UIPasteboard.general.hasStrings {
                            Button("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard") {
                                credentials.privateKey = UIPasteboard.general.string ?? ""
                            }
                        }
                        SecureField("Passphrase (optional)", text: $credentials.passphrase)
                    }
                } header: {
                    Text("Anmeldung")
                } footer: {
                    Text(host.authMethod == .password
                         ? "Das Passwort wird nur im iOS-Schlüsselbund gespeichert."
                         : "Unterstützt Ed25519- und RSA-Schlüssel im OpenSSH-Format. Der öffentliche Schlüssel muss in /root/.ssh/authorized_keys auf dem Host stehen.")
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Label("Verbindung testen", systemImage: "bolt.horizontal")
                            Spacer()
                            if testState == .running { ProgressView() }
                        }
                    }
                    .disabled(!canSave || testState == .running)
                    switch testState {
                    case .success(let info):
                        Label(info, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    default:
                        EmptyView()
                    }
                }

                if let key = host.trustedHostKey {
                    Section {
                        Text(TOFUHostKeyValidator.fingerprint(of: key))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Host-Schlüssel vergessen", role: .destructive) {
                            host.trustedHostKey = nil
                        }
                    } header: {
                        Text("Vertrauter Host-Schlüssel")
                    }
                }
            }
            .navigationTitle(isNew ? "Neuer Host" : "Host bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                        .disabled(!canSave)
                }
            }
            .fileImporter(isPresented: $importingKey, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    credentials.privateKey = text
                }
            }
        }
    }

    private func normalizedHost() -> ProxmoxHost {
        var h = host
        h.address = h.address.trimmingCharacters(in: .whitespacesAndNewlines)
        h.username = h.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.username.isEmpty { h.username = "root" }
        if h.port <= 0 || h.port > 65535 { h.port = 22 }
        // Bei geänderter Adresse muss der Host-Schlüssel neu bestätigt werden.
        if let old = hosts.host(id: h.id), old.address != h.address || old.port != h.port {
            h.trustedHostKey = nil
        }
        return h
    }

    private func save() {
        let h = normalizedHost()
        var creds = credentials
        if h.authMethod == .password { creds.privateKey = ""; creds.passphrase = "" } else { creds.password = "" }
        hosts.upsert(h, credentials: creds)
        onSave?(h)
        dismiss()
    }

    private func test() async {
        testState = .running
        var h = normalizedHost()
        let creds = credentials
        do {
            let info = try await GuestService.hostInfo(host: h, credentials: creds)
            testState = .success(info.isEmpty ? "Verbunden" : info)
        } catch SSHConnectError.unknownHostKey(let key, _) {
            // Der Test wurde explizit angefordert: Schlüssel übernehmen (TOFU) und
            // den Fingerprint unten anzeigen, damit er geprüft werden kann.
            h.trustedHostKey = key
            host.trustedHostKey = key
            do {
                let info = try await GuestService.hostInfo(host: h, credentials: creds)
                testState = .success((info.isEmpty ? "Verbunden" : info) + "\nHost-Schlüssel übernommen – Fingerprint unten prüfen.")
            } catch {
                testState = .failure(error.localizedDescription)
            }
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }
}
