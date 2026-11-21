import SwiftUI

struct ScriptDetailView: View {
    let script: Script

    @EnvironmentObject private var catalog: CatalogService
    @EnvironmentObject private var hosts: HostStore
    @State private var showInstall = false
    @State private var copied = false

    private var command: String { CommandBuilder.websiteCommand(for: script) }

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

            if script.isDisabled {
                Section {
                    Label(script.disableMessage?.isEmpty == false ? script.disableMessage! : "Dieses Script ist derzeit deaktiviert.",
                          systemImage: "nosign")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    showInstall = true
                } label: {
                    Label(script.type == .lxc || script.type == .vm ? "Installieren" : "Ausführen",
                          systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if !script.description.isEmpty {
                Section("Beschreibung") {
                    Text(script.description)
                        .font(.body)
                }
            }

            if let hint = executionHint {
                Section {
                    Label(hint, systemImage: "info.circle")
                        .font(.callout)
                }
            }

            if !script.installMethods.isEmpty, script.installMethods.contains(where: { !($0.resources?.isEmpty ?? true) }) {
                Section("Standard-Ressourcen") {
                    ForEach(Array(script.installMethods.enumerated()), id: \.offset) { _, method in
                        ResourceRow(method: method, showTitle: script.installMethods.count > 1)
                    }
                }
            }

            if script.defaultUser != nil || script.defaultPassword != nil || script.port != nil {
                Section("Zugang") {
                    if let port = script.port {
                        LabeledContent("Port", value: String(port))
                    }
                    if let user = script.defaultUser {
                        LabeledContent("Benutzer") { Text(user).textSelection(.enabled) }
                    }
                    if let pass = script.defaultPassword {
                        LabeledContent("Passwort") { Text(pass).textSelection(.enabled) }
                    }
                    if let config = script.defaultMethod?.configPath, !config.isEmpty {
                        LabeledContent("Konfiguration") {
                            Text(config).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }

            if !script.notes.isEmpty {
                Section("Hinweise") {
                    ForEach(script.notes, id: \.self) { note in
                        Label {
                            Text(.init(note.text))
                                .font(.callout)
                        } icon: {
                            Image(systemName: note.isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundStyle(note.isWarning ? .orange : .blue)
                        }
                    }
                }
            }

            Section("Befehl") {
                Text(command)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = command
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Kopiert" : "In Zwischenablage kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            }

            Section("Links") {
                if let url = script.pageURL { Link(destination: url) { Label("community-scripts.org", systemImage: "globe") } }
                Link(destination: CommandBuilder.sourceURL(for: script)) { Label("Quellcode ansehen", systemImage: "chevron.left.forwardslash.chevron.right") }
                if let url = script.websiteURL { Link(destination: url) { Label("Website", systemImage: "safari") } }
                if let url = script.documentationURL { Link(destination: url) { Label("Dokumentation", systemImage: "book") } }
            }
        }
        .navigationTitle(script.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let url = script.pageURL {
                    ShareLink(item: url)
                }
            }
        }
        .sheet(isPresented: $showInstall) {
            InstallView(script: script)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ScriptLogo(url: script.logoURL, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(script.name).font(.title2.bold())
                HStack(spacing: 6) {
                    TypeBadge(type: script.type)
                    if script.isDev { Badge(text: "DEV", color: .purple) }
                    if script.updateable { Badge(text: "Update", color: .green) }
                    if script.privileged { Badge(text: "Privilegiert", color: .orange) }
                    if script.hasArm { Badge(text: "ARM64", color: .gray) }
                }
                let names = script.categoryIDs.compactMap { catalog.category(for: $0)?.name }
                if !names.isEmpty {
                    Text(names.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var executionHint: String? {
        if let product = script.foreignProduct {
            return "Dieses Script wird auf einem \(product) ausgeführt. Lege ihn als eigenen Host an."
        }
        if script.runsInsideGuest {
            return "Dieses Add-on wird innerhalb eines bestehenden Containers installiert. Du kannst beim Ausführen einen LXC auswählen."
        }
        switch script.type {
        case .lxc: return "Erstellt einen neuen LXC-Container auf deinem Proxmox-Host."
        case .vm: return "Erstellt eine neue virtuelle Maschine auf deinem Proxmox-Host."
        case .pve: return "Wird direkt auf dem Proxmox-Host ausgeführt."
        case .addon: return "Wird direkt auf dem Proxmox-Host ausgeführt."
        default: return nil
        }
    }
}

private struct ResourceRow: View {
    let method: InstallMethod
    let showTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showTitle {
                Text(method.isAlpine ? "Alpine" : "Standard")
                    .font(.subheadline.weight(.semibold))
            }
            HStack(spacing: 0) {
                if let cpu = method.resources?.cpu { stat("\(cpu)", "vCPU", "cpu") }
                if let ram = method.resources?.ram { stat(ram >= 1024 && ram % 1024 == 0 ? "\(ram / 1024) GB" : "\(ram) MB", "RAM", "memorychip") }
                if let hdd = method.resources?.hdd { stat("\(hdd) GB", "Disk", "internaldrive") }
                if let os = method.resources?.os, !os.isEmpty {
                    stat([os.capitalized, method.resources?.version].compactMap { $0 }.joined(separator: " "), "OS", "opticaldisc")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ value: String, _ label: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
