import SwiftUI
import WebKit

// MARK: - noVNC

struct VNCTarget: Identifiable {
    let guest: ProxmoxGuest
    var id: String { guest.id }

    func url(host: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = 8006
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "console", value: guest.kind == .qemu ? "kvm" : "lxc"),
            URLQueryItem(name: "novnc", value: "1"),
            URLQueryItem(name: "vmid", value: String(guest.vmid)),
            URLQueryItem(name: "vmname", value: guest.displayName),
            URLQueryItem(name: "node", value: guest.node),
            URLQueryItem(name: "resize", value: "scale"),
        ]
        return components.url
    }
}

/// Öffnet die noVNC-Konsole der Proxmox-Weboberfläche (Port 8006) mit automatischem Login.
struct NoVNCScreen: View {
    let host: ProxmoxHost
    let target: VNCTarget

    @Environment(\.dismiss) private var dismiss
    @State private var status = "Anmeldung …"
    @State private var ready = false
    @State private var ticket: String?
    @State private var reloadToken = UUID()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if ready, let url = target.url(host: host.address) {
                    NoVNCWebView(url: url, host: host.address, ticket: ticket, status: $status)
                        .id(reloadToken)
                        .ignoresSafeArea(.container, edges: .bottom)
                }
                if !status.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text(status).font(.footnote).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle(target.guest.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { reloadToken = UUID() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { await prepare() }
        }
        .preferredColorScheme(.dark)
    }

    private func prepare() async {
        // Ticket direkt auf dem Host erzeugen – so ist kein Passwort-Login nötig.
        ticket = try? await PVEClient(host: host).webTicket()
        if ticket == nil { status = "Automatische Anmeldung nicht möglich – bitte in der Weboberfläche anmelden." }
        ready = true
    }
}

struct NoVNCWebView: UIViewRepresentable {
    let url: URL
    let host: String
    let ticket: String?
    @Binding var status: String

    func makeCoordinator() -> Coordinator { Coordinator(host: host, status: $status) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        let load = { webView.load(URLRequest(url: url)) }
        if let ticket, let cookie = HTTPCookie(properties: [
            .name: "PVEAuthCookie",
            .value: ticket.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ticket,
            .domain: host,
            .path: "/",
            .secure: "TRUE",
        ]) {
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { load() }
        } else {
            load()
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let host: String
        let status: Binding<String>

        init(host: String, status: Binding<String>) {
            self.host = host
            self.status = status
        }

        /// Proxmox nutzt standardmäßig ein selbst signiertes Zertifikat – nur für diesen Host akzeptieren.
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               challenge.protectionSpace.host == host,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            status.wrappedValue = ""
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            status.wrappedValue = "Fehler: \(error.localizedDescription)"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            status.wrappedValue = "Weboberfläche auf Port 8006 nicht erreichbar: \(error.localizedDescription)"
        }
    }
}

// MARK: - QEMU-Gast-Agent

struct AgentSetupView: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let config: GuestConfig
    let addresses: [GuestAddress]
    let onSave: (Bool) -> Void
    let openTerminal: (TerminalSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = ActionRunner()
    @State private var vmAddress = ""
    @State private var vmUser = "root"
    @State private var vmPassword = ""
    @State private var copied: String?

    private var agentEnabled: Bool {
        let p = PropertyString(config["agent"] ?? "0")
        return p.positional == "1" || p["enabled"] == "1"
    }

    static let installScript = """
    if command -v apt-get >/dev/null; then apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-guest-agent; \
    elif command -v dnf >/dev/null; then dnf install -y qemu-guest-agent; \
    elif command -v yum >/dev/null; then yum install -y qemu-guest-agent; \
    elif command -v zypper >/dev/null; then zypper -n install qemu-guest-agent; \
    elif command -v apk >/dev/null; then apk add qemu-guest-agent && rc-update add qemu-guest-agent default; \
    elif command -v pacman >/dev/null; then pacman -Sy --noconfirm qemu-guest-agent; \
    else echo "Unbekannter Paketmanager"; exit 1; fi; \
    systemctl enable --now qemu-guest-agent 2>/dev/null || rc-service qemu-guest-agent start 2>/dev/null || service qemu-guest-agent start; \
    echo; echo "QEMU-Gast-Agent installiert."
    """

    /// Läuft als root direkt, sonst über sudo.
    static var remoteCommand: String {
        let quoted = CommandBuilder.shellQuote(installScript)
        return "S=\(quoted); if [ \"$(id -u)\" = 0 ]; then sh -c \"$S\"; else sudo sh -c \"$S\"; fi"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Label("Agent in der VM-Konfiguration", systemImage: agentEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(agentEnabled ? .green : .primary)
                        Spacer()
                        if !agentEnabled {
                            Button("Aktivieren") {
                                runner.run("Wird aktiviert …") {
                                    try await client.updateConfig(guest, set: [("agent", "enabled=1")])
                                    onSave(true)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    if guest.isRunning {
                        Button("VM aus- und wieder einschalten", systemImage: "power") {
                            runner.run("VM wird neu gestartet …", success: "Die VM wurde neu gestartet. Der Agent ist nach dem Booten aktiv, sobald er im Gast installiert ist.") {
                                try await client.wait(try await client.perform(.shutdown, on: guest), timeout: 300)
                                try await client.wait(try await client.perform(.start, on: guest), timeout: 120)
                            }
                        }
                    }
                } header: {
                    Text("1. Auf dem Host aktivieren")
                } footer: {
                    Text("Die Option wird erst nach einem vollständigen Stopp und Start der VM wirksam – ein Neustart im Gast reicht nicht.")
                }

                Section {
                    TextField("IP-Adresse der VM", text: $vmAddress)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Benutzer", text: $vmUser)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Passwort", text: $vmPassword)
                    Button("Per SSH installieren", systemImage: "terminal") { installViaSSH() }
                        .disabled(vmAddress.isEmpty || vmUser.isEmpty || vmPassword.isEmpty)
                } header: {
                    Text("2. Im Gast installieren (Linux)")
                } footer: {
                    Text("Die App verbindet sich per SSH mit der VM und installiert das Paket qemu-guest-agent (apt, dnf, yum, zypper, apk oder pacman). Ohne root wird sudo verwendet – das Passwort ggf. im Terminal eingeben.")
                }

                Section {
                    copyRow("Debian / Ubuntu", "apt update && apt install -y qemu-guest-agent && systemctl enable --now qemu-guest-agent")
                    copyRow("RHEL / Fedora / Rocky", "dnf install -y qemu-guest-agent && systemctl enable --now qemu-guest-agent")
                    copyRow("Alpine", "apk add qemu-guest-agent && rc-update add qemu-guest-agent && rc-service qemu-guest-agent start")
                    copyRow("Arch", "pacman -Sy --noconfirm qemu-guest-agent && systemctl enable --now qemu-guest-agent")
                } header: {
                    Text("Oder manuell (z. B. über die Konsole)")
                }

                Section {
                    Text("Unter Windows die VirtIO-Treiber-ISO (virtio-win.iso) als CD einlegen und darin „virtio-win-guest-tools.exe“ ausführen. Sie installiert den QEMU-Gast-Agent und alle VirtIO-Treiber.")
                        .font(.callout)
                    Link("virtio-win.iso herunterladen", destination: URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!)
                } header: {
                    Text("Windows")
                }
            }
            .navigationTitle("QEMU-Gast-Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .actionRunner(runner)
            .onAppear {
                if vmAddress.isEmpty, let v4 = addresses.first(where: { !$0.isIPv6 }) {
                    vmAddress = v4.address.components(separatedBy: "/").first ?? ""
                }
            }
        }
    }

    private func copyRow(_ title: String, _ command: String) -> some View {
        Button {
            UIPasteboard.general.string = command
            copied = title
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: copied == title ? "checkmark" : "doc.on.doc").foregroundStyle(.tint)
                }
                Text(command).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }

    private func installViaSSH() {
        let target = ProxmoxHost(
            name: guest.displayName,
            address: vmAddress.trimmingCharacters(in: .whitespaces),
            port: 22,
            username: vmUser,
            authMethod: .password,
            trustedHostKey: nil
        )
        let session = TerminalSession(
            host: target,
            title: "Agent – \(guest.displayName)",
            initialCommand: Self.remoteCommand,
            credentials: HostCredentials(password: vmPassword)
        )
        openTerminal(session)
    }
}
