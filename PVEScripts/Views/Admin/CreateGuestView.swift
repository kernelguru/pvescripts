import SwiftUI

/// Neue VM oder neuen LXC-Container anlegen.
struct CreateGuestView: View {
    let host: ProxmoxHost
    let kind: GuestKind
    let nodes: [String]
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = ActionRunner()

    // Allgemein
    @State private var node = ""
    @State private var vmid = 0
    @State private var name = ""
    @State private var startAfter = true
    @State private var onboot = false

    // Ressourcen
    @State private var cores = 2
    @State private var memory = 2048
    @State private var swap = 512
    @State private var diskStorage = ""
    @State private var diskGB = 32

    // Netzwerk
    @State private var bridge = "vmbr0"
    @State private var vlan = ""
    @State private var firewall = true
    @State private var ipMode = "dhcp"
    @State private var ip = ""
    @State private var gateway = ""

    // VM
    @State private var osType = "l26"
    @State private var isoStorage = ""
    @State private var iso = "none"
    @State private var isoList: [StorageItem] = []
    @State private var cpuType = "x86-64-v2-AES"
    @State private var uefi = false
    @State private var agent = true
    @State private var isoURL = ""

    // CT
    @State private var templateStorage = ""
    @State private var templates: [StorageItem] = []
    @State private var template = ""
    @State private var password = ""
    @State private var sshKey = ""
    @State private var unprivileged = true
    @State private var nesting = true
    @State private var available: [ApplianceTemplate] = []
    @State private var showDownload = false

    @State private var storages: [PVEStorage] = []
    @State private var contentStorages: [PVEStorage] = []
    @State private var bridges: [NetworkBridge] = []
    @State private var taskRef: TaskRef?

    private var client: PVEClient { PVEClient(host: host) }
    private var isVM: Bool { kind == .qemu }

    static let osTypes: [(String, String)] = [
        ("l26", "Linux 6.x / 5.x / 4.x / 3.x / 2.6"),
        ("win11", "Windows 11 / 2022 / 2025"),
        ("win10", "Windows 10 / 2016 / 2019"),
        ("other", "Andere"),
    ]

    private var canCreate: Bool {
        vmid >= 100 && !node.isEmpty && !diskStorage.isEmpty && !name.isEmpty
            && (isVM || (!template.isEmpty && (password.count >= 5 || !sshKey.isEmpty)))
            && (ipMode != "static" || ip.contains("/"))
    }

    var body: some View {
        NavigationStack {
            Form {
                generalSection
                if isVM { vmSystemSection } else { templateSection }
                resourceSection
                networkSection
                if !isVM { accessSection }
                Section {
                    Toggle("Nach dem Erstellen starten", isOn: $startAfter)
                    Toggle("Beim Booten des Hosts starten", isOn: $onboot)
                }
            }
            .navigationTitle(isVM ? "Neue VM" : "Neuer Container")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen") { create() }.disabled(!canCreate || runner.isBusy)
                }
            }
            .actionRunner(runner)
            .task { await initialLoad() }
            .onChange(of: node) { Task { await loadNode() } }
            .onChange(of: isoStorage) { Task { await loadISOs() } }
            .onChange(of: templateStorage) { Task { await loadTemplates() } }
            .sheet(item: $taskRef, onDismiss: {
                onCreated()
                dismiss()
            }) { ref in
                TaskLogView(client: client, upid: ref.upid, title: ref.title)
            }
            .sheet(isPresented: $showDownload) {
                TemplateDownloadView(client: client, node: node, storage: templateStorage, templates: available) {
                    Task { await loadTemplates() }
                }
            }
        }
    }

    // MARK: Sections

    private var generalSection: some View {
        Section("Allgemein") {
            if nodes.count > 1 {
                Picker("Node", selection: $node) {
                    ForEach(nodes, id: \.self) { Text($0).tag($0) }
                }
            }
            NumberField(title: isVM ? "VM-ID" : "CT-ID", value: $vmid)
            TextField(isVM ? "Name" : "Hostname", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var vmSystemSection: some View {
        Group {
            Section("Betriebssystem") {
                Picker("Gast-OS", selection: $osType) {
                    ForEach(Self.osTypes, id: \.0) { Text($0.1).tag($0.0) }
                }
                StoragePicker(title: "ISO-Storage", storages: contentStorages, selection: $isoStorage)
                Picker("ISO-Image", selection: $iso) {
                    Text("Kein Medium").tag("none")
                    ForEach(isoList) { Text($0.fileName).tag($0.volid) }
                }
            }
            ISODownloadSection(client: client, node: node, storage: isoStorage, url: $isoURL) {
                Task { await loadISOs() }
            }
            Section {
                Toggle("UEFI (OVMF) + Q35", isOn: $uefi)
                Picker("CPU-Typ", selection: $cpuType) {
                    ForEach(CPUMemoryEditor.cpuTypes, id: \.self) { Text($0).tag($0) }
                }
                Toggle("QEMU-Gast-Agent", isOn: $agent)
            } header: {
                Text("System")
            } footer: {
                Text(osType == "win11" ? "Für Windows 11 werden automatisch UEFI, Secure Boot und ein TPM 2.0 angelegt." : "„host“ bietet die beste Leistung, verhindert aber die Live-Migration zwischen unterschiedlichen CPUs.")
            }
        }
    }

    private var templateSection: some View {
        Section {
            StoragePicker(title: "Vorlagen-Storage", storages: contentStorages, selection: $templateStorage)
            Picker("Vorlage", selection: $template) {
                if templates.isEmpty { Text("Keine Vorlage vorhanden").tag("") }
                ForEach(templates) { Text($0.fileName).tag($0.volid) }
            }
            Button("Vorlage herunterladen …", systemImage: "arrow.down.circle") {
                Task {
                    if available.isEmpty { available = (try? await client.applianceTemplates(node: node)) ?? [] }
                    showDownload = true
                }
            }
            .disabled(templateStorage.isEmpty)
        } header: {
            Text("Vorlage")
        }
    }

    private var resourceSection: some View {
        Section("Ressourcen") {
            Stepper("Kerne: \(cores)", value: $cores, in: 1...128)
            NumberField(title: "RAM", value: $memory, unit: "MiB")
            HStack {
                ForEach([512, 1024, 2048, 4096, 8192], id: \.self) { value in
                    Button(value >= 1024 ? "\(value / 1024)G" : "\(value)M") { memory = value }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if !isVM { NumberField(title: "Swap", value: $swap, unit: "MiB") }
            StoragePicker(title: "Disk-Storage", storages: storages, selection: $diskStorage)
            Stepper("Disk: \(diskGB) GB", value: $diskGB, in: 1...65536, step: diskGB < 16 ? 1 : 8)
            if !isVM {
                Toggle("Unprivilegiert", isOn: $unprivileged)
                Toggle("Nesting (für Docker)", isOn: $nesting)
            }
        }
    }

    private var networkSection: some View {
        Section("Netzwerk") {
            BridgePicker(bridges: bridges, selection: $bridge)
            TextField("VLAN-Tag (optional)", text: $vlan).keyboardType(.numberPad)
            Toggle("Firewall", isOn: $firewall)
            if !isVM {
                Picker("IPv4", selection: $ipMode) {
                    Text("DHCP").tag("dhcp")
                    Text("Statisch").tag("static")
                }
                .pickerStyle(.segmented)
                if ipMode == "static" {
                    TextField("Adresse/CIDR, z. B. 192.168.1.50/24", text: $ip)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Gateway", text: $gateway)
                        .keyboardType(.numbersAndPunctuation)
                }
            }
        }
    }

    private var accessSection: some View {
        Section {
            SecureField("Root-Passwort (min. 5 Zeichen)", text: $password)
            TextField("SSH-Public-Key (optional)", text: $sshKey, axis: .vertical)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Zugang")
        } footer: {
            Text("Passwort oder SSH-Schlüssel ist erforderlich.")
        }
    }

    // MARK: Loading

    private func initialLoad() async {
        if node.isEmpty {
            let local = try? await client.localNodeName()
            node = nodes.first { $0 == local } ?? nodes.first ?? local ?? ""
        }
        name = isVM ? "vm-neu" : "ct-neu"
        vmid = (try? await client.nextID()) ?? 100
        await loadNode()
    }

    private func loadNode() async {
        guard !node.isEmpty else { return }
        do {
            storages = try await client.storages(node: node, content: isVM ? "images" : "rootdir")
            contentStorages = try await client.storages(node: node, content: isVM ? "iso" : "vztmpl")
            bridges = try await client.bridges(node: node)
            if !storages.contains(where: { $0.storage == diskStorage }) { diskStorage = storages.first?.storage ?? "" }
            if isVM {
                if !contentStorages.contains(where: { $0.storage == isoStorage }) { isoStorage = contentStorages.first?.storage ?? "" }
            } else if !contentStorages.contains(where: { $0.storage == templateStorage }) {
                templateStorage = contentStorages.first?.storage ?? ""
            }
            if let first = bridges.first, !bridges.contains(where: { $0.iface == bridge }) { bridge = first.iface }
        } catch {
            runner.error = error.localizedDescription
        }
    }

    private func loadISOs() async {
        guard !isoStorage.isEmpty else { return }
        isoList = (try? await client.storageContent(node: node, storage: isoStorage, content: "iso")) ?? []
    }

    private func loadTemplates() async {
        guard !templateStorage.isEmpty else { return }
        templates = (try? await client.storageContent(node: node, storage: templateStorage, content: "vztmpl")) ?? []
        if !templates.contains(where: { $0.volid == template }) {
            // Bevorzugt Debian, sonst die neueste Vorlage.
            template = templates.last(where: { $0.fileName.hasPrefix("debian") })?.volid ?? templates.last?.volid ?? ""
        }
    }

    // MARK: Create

    private func create() {
        let params = isVM ? vmParams() : ctParams()
        let path = "/nodes/\(node)/\(kind.rawValue)"
        let title = isVM ? "VM \(vmid) wird erstellt" : "Container \(vmid) wird erstellt"
        runner.run("Wird erstellt …") {
            let upid = try await client.create(path, params)
            if let upid {
                taskRef = TaskRef(upid: upid, title: title)
            } else {
                onCreated()
                dismiss()
            }
        }
    }

    private func netValue(prefix: String) -> String {
        var p = PropertyString(prefix)
        p["bridge"] = bridge
        p["tag"] = vlan.filter(\.isNumber)
        p["firewall"] = firewall ? "1" : nil
        return p.raw
    }

    private func vmParams() -> [(String, String)] {
        let win11 = osType == "win11"
        let useUEFI = uefi || win11
        var params: [(String, String)] = [
            ("vmid", String(vmid)),
            ("name", CommandBuilder.sanitizedHostname(name)),
            ("ostype", osType),
            ("cores", String(cores)),
            ("sockets", "1"),
            ("cpu", cpuType),
            ("memory", String(memory)),
            ("scsihw", "virtio-scsi-single"),
            ("scsi0", "\(diskStorage):\(diskGB),discard=on,iothread=1,ssd=1"),
            ("ide2", iso == "none" ? "none,media=cdrom" : "\(iso),media=cdrom"),
            ("net0", netValue(prefix: osType.hasPrefix("win") ? "e1000e" : "virtio")),
            ("boot", "order=scsi0;ide2;net0"),
            ("onboot", onboot ? "1" : "0"),
            ("start", startAfter ? "1" : "0"),
        ]
        if agent { params.append(("agent", "enabled=1")) }
        if useUEFI {
            params.append(("bios", "ovmf"))
            params.append(("machine", "q35"))
            params.append(("efidisk0", "\(diskStorage):1,efitype=4m,pre-enrolled-keys=\(win11 ? "1" : "0")"))
        }
        if win11 {
            params.append(("tpmstate0", "\(diskStorage):1,version=v2.0"))
        }
        if osType == "l26" {
            params.append(("serial0", "socket"))
        }
        return params
    }

    private func ctParams() -> [(String, String)] {
        var net = PropertyString(items: [("name", "eth0")])
        net["bridge"] = bridge
        net["ip"] = ipMode == "static" ? ip : "dhcp"
        if ipMode == "static", !gateway.isEmpty { net["gw"] = gateway }
        net["tag"] = vlan.filter(\.isNumber)
        net["firewall"] = firewall ? "1" : nil
        net["type"] = "veth"

        var params: [(String, String)] = [
            ("vmid", String(vmid)),
            ("hostname", CommandBuilder.sanitizedHostname(name)),
            ("ostemplate", template),
            ("cores", String(cores)),
            ("memory", String(memory)),
            ("swap", String(swap)),
            ("rootfs", "\(diskStorage):\(diskGB)"),
            ("net0", net.raw),
            ("unprivileged", unprivileged ? "1" : "0"),
            ("onboot", onboot ? "1" : "0"),
            ("start", startAfter ? "1" : "0"),
        ]
        if nesting { params.append(("features", "nesting=1")) }
        if !password.isEmpty { params.append(("password", password)) }
        let key = sshKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { params.append(("ssh-public-keys", key)) }
        return params
    }
}

/// Container-Vorlage aus dem Proxmox-Katalog herunterladen.
struct TemplateDownloadView: View {
    let client: PVEClient
    let node: String
    let storage: String
    let templates: [ApplianceTemplate]
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var taskRef: TaskRef?
    @StateObject private var runner = ActionRunner()

    private var filtered: [ApplianceTemplate] {
        let system = templates.filter { $0.section == "system" }
        let base = search.isEmpty ? system : templates
        guard !search.isEmpty else { return base }
        return base.filter { $0.template.localizedCaseInsensitiveContains(search) || ($0.headline ?? "").localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { template in
                Button {
                    runner.run("Download wird gestartet …") {
                        let upid = try await client.create("/nodes/\(node)/aplinfo", [("storage", storage), ("template", template.template)])
                        if let upid { taskRef = TaskRef(upid: upid, title: "Vorlage laden") }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.template).font(.subheadline.weight(.medium))
                        if let headline = template.headline {
                            Text(headline).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                if templates.isEmpty {
                    ContentUnavailableView("Keine Vorlagen", systemImage: "tray",
                                           description: Text("Führe auf dem Host „pveam update“ aus, um die Liste zu laden."))
                }
            }
            .searchable(text: $search, prompt: "Alle Vorlagen durchsuchen")
            .navigationTitle("Vorlagen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
            }
            .sheet(item: $taskRef, onDismiss: {
                onFinished()
                dismiss()
            }) { ref in
                TaskLogView(client: client, upid: ref.upid, title: ref.title)
            }
            .actionRunner(runner)
        }
    }
}
