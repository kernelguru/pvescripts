import SwiftUI

// MARK: - Gemeinsames Gerüst

/// Formular mit Abbrechen/Sichern, das die Speicheraktion im ActionRunner ausführt.
struct EditorForm<Content: View>: View {
    let title: String
    var saveTitle = "Sichern"
    var canSave = true
    let save: () async throws -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form { content() }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saveTitle) {
                            runner.run("Wird gespeichert …") {
                                try await save()
                                dismiss()
                            }
                        }
                        .disabled(!canSave || runner.isBusy)
                    }
                }
                .disabled(runner.isBusy)
                .actionRunner(runner)
        }
    }
}

/// Lädt Storages und Bridges eines Nodes für Auswahllisten.
@MainActor
final class NodeChoices: ObservableObject {
    @Published var storages: [PVEStorage] = []
    @Published var bridges: [NetworkBridge] = []
    @Published var error: String?
    private var loaded = false

    func load(client: PVEClient, node: String, content: String?, bridges loadBridges: Bool = false) async {
        guard !loaded else { return }
        loaded = true
        do {
            storages = try await client.storages(node: node, content: content)
            if loadBridges { bridges = try await client.bridges(node: node) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct StoragePicker: View {
    let title: String
    let storages: [PVEStorage]
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            if storages.isEmpty { Text("Lädt …").tag(selection) }
            ForEach(storages) { storage in
                Text("\(storage.storage) (\(Fmt.bytes(storage.avail)) frei)").tag(storage.storage)
            }
        }
    }
}

struct BridgePicker: View {
    let bridges: [NetworkBridge]
    @Binding var selection: String

    var body: some View {
        Picker("Bridge", selection: $selection) {
            if !bridges.contains(where: { $0.iface == selection }) { Text(selection).tag(selection) }
            ForEach(bridges) { bridge in
                Text(bridge.comments.map { "\(bridge.iface) – \($0)" } ?? bridge.iface).tag(bridge.iface)
            }
        }
    }
}

struct NumberField: View {
    let title: String
    @Binding var value: Int
    var unit: String = ""

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: $value, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - CPU & RAM

struct CPUMemoryEditor: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let config: GuestConfig
    let onSave: (Bool) -> Void

    @State private var sockets = 1
    @State private var cores = 1
    @State private var cpuType = ""
    @State private var memory = 512
    @State private var ballooning = true
    @State private var balloonMin = 0
    @State private var swap = 512
    @State private var cpuLimit = 0.0

    static let cpuTypes = ["host", "x86-64-v2-AES", "x86-64-v3", "x86-64-v4", "kvm64", "qemu64", "max"]
    private var isVM: Bool { guest.kind == .qemu }

    var body: some View {
        EditorForm(title: "CPU & Arbeitsspeicher", save: save) {
            Section("Prozessor") {
                if isVM {
                    Stepper("Sockel: \(sockets)", value: $sockets, in: 1...8)
                }
                Stepper("Kerne: \(cores)", value: $cores, in: 1...256)
                if isVM {
                    Picker("CPU-Typ", selection: $cpuType) {
                        Text("Standard (kvm64/x86-64-v2-AES)").tag("")
                        ForEach(Self.cpuTypes, id: \.self) { Text($0).tag($0) }
                        if !cpuType.isEmpty && !Self.cpuTypes.contains(cpuType) { Text(cpuType).tag(cpuType) }
                    }
                }
                VStack(alignment: .leading) {
                    Text(cpuLimit == 0 ? "CPU-Limit: unbegrenzt" : String(format: "CPU-Limit: %.1f Kerne", cpuLimit))
                    Slider(value: $cpuLimit, in: 0...Double(max(1, cores * sockets)), step: 0.5)
                }
            }
            Section {
                NumberField(title: "RAM", value: $memory, unit: "MiB")
                HStack {
                    ForEach([512, 1024, 2048, 4096, 8192, 16384], id: \.self) { value in
                        Button(value >= 1024 ? "\(value / 1024)G" : "\(value)M") { memory = value }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                if isVM {
                    Toggle("Ballooning", isOn: $ballooning)
                    if ballooning {
                        NumberField(title: "Minimum", value: $balloonMin, unit: "MiB")
                    }
                } else {
                    NumberField(title: "Swap", value: $swap, unit: "MiB")
                }
            } header: {
                Text("Arbeitsspeicher")
            } footer: {
                if isVM { Text("Bei laufenden VMs greifen Änderungen ohne aktiviertes Hotplug erst nach einem Neustart.") }
            }
        }
        .onAppear(perform: populate)
    }

    private func populate() {
        sockets = Int(config["sockets"] ?? "1") ?? 1
        cores = Int(config["cores"] ?? "1") ?? 1
        cpuType = PropertyString(config["cpu"] ?? "").positional ?? ""
        memory = Int(config["memory"] ?? "512") ?? 512
        let balloon = config["balloon"]
        ballooning = balloon != "0"
        balloonMin = Int(balloon ?? "") ?? memory
        swap = Int(config["swap"] ?? "512") ?? 512
        cpuLimit = Double(config["cpulimit"] ?? "0") ?? 0
    }

    private func save() async throws {
        var values: [(String, String)] = [("cores", String(cores)), ("memory", String(memory))]
        values.append(("cpulimit", cpuLimit == 0 ? "" : String(cpuLimit)))
        if isVM {
            values.append(("sockets", String(sockets)))
            if !cpuType.isEmpty {
                var props = PropertyString(config["cpu"] ?? "")
                if props.positional != nil, let idx = props.items.firstIndex(where: { $0.key.isEmpty }) {
                    props.items[idx].value = cpuType
                } else {
                    props = PropertyString(cpuType)
                }
                values.append(("cpu", props.raw))
            }
            values.append(("balloon", ballooning ? String(min(balloonMin, memory)) : "0"))
        } else {
            values.append(("swap", String(swap)))
        }
        try await client.updateConfig(guest, set: values)
        onSave(isVM)
    }
}

// MARK: - Optionen

struct OptionsEditor: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let config: GuestConfig
    let onSave: (Bool) -> Void

    @State private var name = ""
    @State private var onboot = false
    @State private var protection = false
    @State private var tags = ""
    @State private var description = ""
    @State private var agent = false
    @State private var nesting = false
    @State private var keyctl = false
    @State private var startOrder = ""

    private var isVM: Bool { guest.kind == .qemu }

    var body: some View {
        EditorForm(title: "Optionen", save: save) {
            Section {
                TextField(isVM ? "Name" : "Hostname", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Tags (durch Leerzeichen getrennt)", text: $tags)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                Toggle("Beim Booten des Hosts starten", isOn: $onboot)
                TextField("Start-Reihenfolge (optional, z. B. 1)", text: $startOrder)
                    .keyboardType(.numberPad)
                Toggle("Schutz vor Löschen", isOn: $protection)
                if isVM {
                    Toggle("QEMU-Gast-Agent", isOn: $agent)
                } else {
                    Toggle("Nesting (für Docker)", isOn: $nesting)
                    Toggle("keyctl", isOn: $keyctl)
                }
            } footer: {
                Text(isVM ? "Der Agent wird erst nach einem vollständigen Stopp und Start der VM aktiv." : "Feature-Änderungen greifen nach einem Neustart des Containers.")
            }
            Section("Notizen") {
                TextEditor(text: $description).frame(minHeight: 100)
            }
        }
        .onAppear(perform: populate)
    }

    private func populate() {
        name = config[isVM ? "name" : "hostname"] ?? ""
        onboot = config["onboot"] == "1"
        protection = config["protection"] == "1"
        tags = (config["tags"] ?? "").replacingOccurrences(of: ";", with: " ")
        description = config["description"] ?? ""
        let agentProps = PropertyString(config["agent"] ?? "0")
        agent = agentProps.positional == "1" || agentProps["enabled"] == "1"
        let features = PropertyString(config["features"] ?? "")
        nesting = features["nesting"] == "1"
        keyctl = features["keyctl"] == "1"
        startOrder = PropertyString(config["startup"] ?? "")["order"] ?? ""
    }

    private func save() async throws {
        let tagList = tags.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" })
            .map { $0.lowercased() }
            .joined(separator: ";")
        var values: [(String, String)] = [
            (isVM ? "name" : "hostname", CommandBuilder.sanitizedHostname(name)),
            ("onboot", onboot ? "1" : "0"),
            ("protection", protection ? "1" : "0"),
            ("tags", tagList),
            ("description", description),
        ]
        var startup = PropertyString(config["startup"] ?? "")
        startup["order"] = startOrder.filter(\.isNumber)
        values.append(("startup", startup.raw))

        var restart = false
        if isVM {
            var props = PropertyString(config["agent"] ?? "")
            if let idx = props.items.firstIndex(where: { $0.key.isEmpty }) { props.items.remove(at: idx) }
            props["enabled"] = agent ? "1" : "0"
            if props.raw != PropertyString(config["agent"] ?? "").raw { restart = true }
            values.append(("agent", props.raw))
        } else {
            var features = PropertyString(config["features"] ?? "")
            features["nesting"] = nesting ? "1" : nil
            features["keyctl"] = keyctl ? "1" : nil
            if features.raw != (config["features"] ?? "") { restart = true }
            values.append(("features", features.raw))
        }
        try await client.updateConfig(guest, set: values)
        onSave(restart)
    }
}

// MARK: - Disks

struct AddDiskEditor: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let config: GuestConfig
    let onSave: (Bool) -> Void

    @StateObject private var choices = NodeChoices()
    @State private var bus = "scsi"
    @State private var storage = ""
    @State private var sizeGB = 32
    @State private var discard = true
    @State private var ssd = true
    @State private var iothread = true
    @State private var mountPath = "/mnt/data"
    @State private var backup = true

    private var isVM: Bool { guest.kind == .qemu }

    var body: some View {
        EditorForm(title: "Disk hinzufügen", saveTitle: "Hinzufügen",
                   canSave: !storage.isEmpty && sizeGB > 0 && (isVM || mountPath.hasPrefix("/")), save: save) {
            Section {
                if isVM {
                    Picker("Bus", selection: $bus) {
                        ForEach(["scsi", "virtio", "sata", "ide"], id: \.self) { Text($0.uppercased()).tag($0) }
                    }
                } else {
                    TextField("Einhängepunkt (z. B. /mnt/data)", text: $mountPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                StoragePicker(title: "Storage", storages: choices.storages, selection: $storage)
                Stepper("Größe: \(sizeGB) GB", value: $sizeGB, in: 1...65536, step: sizeGB < 32 ? 1 : 8)
            } footer: {
                Text("Neuer Eintrag: \(newKey)")
            }
            Section("Optionen") {
                if isVM {
                    Toggle("Discard (TRIM)", isOn: $discard)
                    if bus != "virtio" { Toggle("SSD-Emulation", isOn: $ssd) }
                    if bus == "scsi" || bus == "virtio" { Toggle("IO-Thread", isOn: $iothread) }
                } else {
                    Toggle("In Backups einschließen", isOn: $backup)
                }
            }
            if let error = choices.error {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        }
        .task {
            await choices.load(client: client, node: guest.node, content: isVM ? "images" : "rootdir")
            if storage.isEmpty { storage = choices.storages.first?.storage ?? "" }
        }
    }

    private var newKey: String {
        isVM ? "\(bus)\(config.nextIndex(prefix: bus, limit: bus == "ide" ? 3 : 30))" : "mp\(config.nextIndex(prefix: "mp", limit: 255))"
    }

    private func save() async throws {
        var value = "\(storage):\(sizeGB)"
        if isVM {
            if discard { value += ",discard=on" }
            if ssd && bus != "virtio" { value += ",ssd=1" }
            if iothread && (bus == "scsi" || bus == "virtio") { value += ",iothread=1" }
        } else {
            value += ",mp=\(mountPath)"
            if backup { value += ",backup=1" }
        }
        try await client.updateConfig(guest, set: [(newKey, value)])
        onSave(false)
    }
}

struct ResizeDiskEditor: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let config: GuestConfig
    let key: String
    let onSave: (Bool) -> Void

    @State private var addGB = 8

    var body: some View {
        EditorForm(title: "Disk vergrößern", saveTitle: "Vergrößern", save: {
            try await client.resizeDisk(guest, disk: key, addGB: addGB)
            onSave(false)
        }) {
            Section {
                LabeledContent("Disk", value: key)
                LabeledContent("Aktuelle Größe", value: PropertyString(config[key] ?? "")["size"] ?? "?")
                Stepper("Hinzufügen: +\(addGB) GB", value: $addGB, in: 1...16384)
                HStack {
                    ForEach([8, 16, 32, 64, 128], id: \.self) { value in
                        Button("+\(value)") { addGB = value }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            } footer: {
                Text("Verkleinern ist nicht möglich. Bei VMs muss die Partition danach im Gast vergrößert werden (z. B. mit growpart und resize2fs). Container passen das Dateisystem automatisch an.")
            }
        }
    }
}

// MARK: - CD/DVD

struct CDROMEditor: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let config: GuestConfig
    let key: String
    let onSave: (Bool) -> Void

    @StateObject private var choices = NodeChoices()
    @State private var storage = ""
    @State private var isos: [StorageItem] = []
    @State private var selection = ""
    @State private var downloadURL = ""
    @State private var loadingISOs = false

    var body: some View {
        EditorForm(title: "CD/DVD (\(key))", save: save) {
            Section {
                StoragePicker(title: "ISO-Storage", storages: choices.storages, selection: $storage)
                Picker("Medium", selection: $selection) {
                    Text("Kein Medium").tag("none")
                    ForEach(isos) { Text($0.fileName).tag($0.volid) }
                    if selection != "none" && !isos.contains(where: { $0.volid == selection }) {
                        Text(selection).tag(selection)
                    }
                }
                .pickerStyle(.inline)
                if loadingISOs { ProgressView() }
            }
            ISODownloadSection(client: client, node: guest.node, storage: storage, url: $downloadURL) {
                Task { await loadISOs() }
            }
        }
        .task {
            selection = PropertyString(config[key] ?? "none").positional ?? "none"
            await choices.load(client: client, node: guest.node, content: "iso")
            if storage.isEmpty {
                let current = selection.split(separator: ":").first.map(String.init)
                storage = choices.storages.first { $0.storage == current }?.storage ?? choices.storages.first?.storage ?? ""
            }
        }
        .onChange(of: storage) { Task { await loadISOs() } }
    }

    private func loadISOs() async {
        guard !storage.isEmpty else { return }
        loadingISOs = true
        isos = (try? await client.storageContent(node: guest.node, storage: storage, content: "iso")) ?? []
        loadingISOs = false
    }

    private func save() async throws {
        var props = PropertyString(config[key] ?? "")
        if let idx = props.items.firstIndex(where: { $0.key.isEmpty }) {
            props.items[idx].value = selection
        } else {
            props.items.insert((key: "", value: selection), at: 0)
        }
        props["media"] = "cdrom"
        try await client.updateConfig(guest, set: [(key, props.raw)])
        onSave(false)
    }
}

/// ISO direkt aus dem Internet auf den Storage laden (Proxmox lädt selbst herunter).
struct ISODownloadSection: View {
    let client: PVEClient
    let node: String
    let storage: String
    @Binding var url: String
    let onFinished: () -> Void

    @StateObject private var runner = ActionRunner()

    var body: some View {
        Section {
            TextField("https://…/image.iso", text: $url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Herunterladen", systemImage: "arrow.down.circle") { download() }
                .disabled(fileName == nil || storage.isEmpty || runner.isBusy)
            if let busy = runner.busy {
                HStack { ProgressView(); Text(busy).font(.footnote) }
            }
            if let error = runner.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("ISO von URL laden")
        } footer: {
            Text("Der Proxmox-Host lädt die Datei direkt auf „\(storage)“.")
        }
    }

    private var fileName: String? {
        guard let u = URL(string: url), let scheme = u.scheme, scheme.hasPrefix("http") else { return nil }
        let name = u.lastPathComponent
        return name.lowercased().hasSuffix(".iso") || name.lowercased().hasSuffix(".img") ? name : nil
    }

    private func download() {
        guard let fileName else { return }
        let url = self.url
        runner.run("Download läuft …") {
            let upid = try await client.create("/nodes/\(node)/storage/\(storage)/download-url", [
                ("content", "iso"), ("filename", fileName), ("url", url),
            ])
            try await client.wait(upid, timeout: 7200)
            onFinished()
        }
    }
}

// MARK: - Netzwerk

struct NetworkEditor: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let config: GuestConfig
    let key: String?
    let onSave: (Bool) -> Void

    @StateObject private var choices = NodeChoices()
    @State private var model = "virtio"
    @State private var bridge = "vmbr0"
    @State private var vlan = ""
    @State private var firewall = true
    @State private var linkDown = false
    @State private var mtu = ""
    // LXC
    @State private var name = "eth0"
    @State private var ipMode = "dhcp"
    @State private var ip = ""
    @State private var gateway = ""
    @State private var ip6Mode = "none"

    static let models = ["virtio", "e1000", "e1000e", "rtl8139", "vmxnet3"]
    private var isVM: Bool { guest.kind == .qemu }
    private var targetKey: String { key ?? "net\(config.nextIndex(prefix: "net"))" }

    var body: some View {
        EditorForm(title: key == nil ? "Netzwerkkarte hinzufügen" : targetKey, canSave: valid, save: save) {
            Section {
                if isVM {
                    Picker("Modell", selection: $model) {
                        ForEach(Self.models, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    TextField("Name im Container", text: $name)
                        .textInputAutocapitalization(.never)
                }
                BridgePicker(bridges: choices.bridges, selection: $bridge)
                TextField("VLAN-Tag (optional)", text: $vlan).keyboardType(.numberPad)
                Toggle("Firewall", isOn: $firewall)
                if isVM { Toggle("Verbindung getrennt", isOn: $linkDown) }
                TextField("MTU (optional)", text: $mtu).keyboardType(.numberPad)
            }
            if !isVM {
                Section("IPv4") {
                    Picker("Modus", selection: $ipMode) {
                        Text("DHCP").tag("dhcp")
                        Text("Statisch").tag("static")
                        Text("Keine").tag("manual")
                    }
                    .pickerStyle(.segmented)
                    if ipMode == "static" {
                        TextField("Adresse/CIDR, z. B. 192.168.1.50/24", text: $ip)
                            .keyboardType(.numbersAndPunctuation)
                        TextField("Gateway", text: $gateway)
                            .keyboardType(.numbersAndPunctuation)
                    }
                }
                Section("IPv6") {
                    Picker("Modus", selection: $ip6Mode) {
                        Text("Keine").tag("none")
                        Text("SLAAC").tag("auto")
                        Text("DHCP").tag("dhcp")
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .task {
            populate()
            await choices.load(client: client, node: guest.node, content: nil, bridges: true)
        }
    }

    private var valid: Bool {
        !bridge.isEmpty && (isVM || !name.isEmpty) && (isVM || ipMode != "static" || ip.contains("/"))
    }

    private func populate() {
        guard let key, let raw = config[key] else { return }
        let p = PropertyString(raw)
        bridge = p["bridge"] ?? bridge
        vlan = p["tag"] ?? ""
        firewall = p["firewall"] == "1"
        linkDown = p["link_down"] == "1"
        mtu = p["mtu"] ?? ""
        if isVM {
            if let first = p.items.first, Self.models.contains(first.key) { model = first.key }
        } else {
            name = p["name"] ?? name
            let v4 = p["ip"] ?? "manual"
            if v4 == "dhcp" || v4 == "manual" { ipMode = v4 } else { ipMode = "static"; ip = v4 }
            gateway = p["gw"] ?? ""
            ip6Mode = ["auto", "dhcp"].contains(p["ip6"] ?? "") ? p["ip6"]! : "none"
        }
    }

    private func save() async throws {
        let existing = key.flatMap { config[$0] }.map(PropertyString.init)
        var p: PropertyString
        if isVM {
            // MAC-Adresse behalten, wenn das Modell gleich bleibt.
            if let existing, let first = existing.items.first, first.key == model {
                p = PropertyString(items: [(model, first.value)])
            } else {
                p = PropertyString(model)
            }
            p["bridge"] = bridge
        } else {
            p = PropertyString(items: [("name", name), ("bridge", bridge)])
            if let mac = existing?["hwaddr"] { p["hwaddr"] = mac }
            switch ipMode {
            case "static":
                p["ip"] = ip
                p["gw"] = gateway.isEmpty ? nil : gateway
            case "dhcp": p["ip"] = "dhcp"
            default: p["ip"] = "manual"
            }
            if ip6Mode != "none" { p["ip6"] = ip6Mode }
            p["type"] = "veth"
        }
        p["tag"] = vlan.filter(\.isNumber)
        p["firewall"] = firewall ? "1" : nil
        if isVM { p["link_down"] = linkDown ? "1" : nil }
        p["mtu"] = mtu.filter(\.isNumber)
        // Weitere, hier nicht bearbeitete Optionen (rate, queues, …) übernehmen.
        if let existing {
            var handled: Set<String> = ["", "bridge", "tag", "firewall", "link_down", "mtu", "name", "hwaddr", "ip", "gw", "ip6", "type"]
            handled.formUnion(Self.models)
            for item in existing.items where !handled.contains(item.key) && p[item.key] == nil {
                p[item.key] = item.value
            }
        }
        try await client.updateConfig(guest, set: [(targetKey, p.raw)])
        onSave(false)
    }
}

// MARK: - Roh-Konfiguration

struct RawConfigEditor: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let config: GuestConfig
    let onSave: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = ActionRunner()
    @State private var values: [String: String] = [:]
    @State private var editingKey: String?
    @State private var editValue = ""
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var changed = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(values.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { key in
                        Button {
                            editingKey = key
                            editValue = values[key] ?? ""
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key).font(.subheadline.weight(.semibold).monospaced())
                                Text(values[key] ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(4)
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Löschen", role: .destructive) { apply(key: key, value: "") }
                        }
                    }
                } footer: {
                    Text("Direkter Zugriff auf alle Optionen wie in /etc/pve/…/\(guest.vmid).conf. Änderungen werden sofort übernommen.")
                }
                Section("Neuer Eintrag") {
                    TextField("Schlüssel (z. B. hostpci0)", text: $newKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Wert", text: $newValue)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Hinzufügen") {
                        apply(key: newKey.trimmingCharacters(in: .whitespaces), value: newValue)
                        newKey = ""; newValue = ""
                    }
                    .disabled(newKey.isEmpty || newValue.isEmpty)
                }
            }
            .navigationTitle("Konfiguration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        if changed { onSave(true) }
                        dismiss()
                    }
                }
            }
            .alert(editingKey ?? "", isPresented: Binding(get: { editingKey != nil }, set: { if !$0 { editingKey = nil } })) {
                TextField("Wert", text: $editValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Sichern") {
                    if let key = editingKey { apply(key: key, value: editValue) }
                }
                Button("Abbrechen", role: .cancel) {}
            }
            .actionRunner(runner)
            .onAppear { values = config.values }
        }
    }

    private func apply(key: String, value: String) {
        runner.run(value.isEmpty ? "\(key) wird gelöscht …" : "\(key) wird gesetzt …") {
            try await client.updateConfig(guest, set: [(key, value)])
            let fresh = try await client.config(guest)
            values = fresh.values
            changed = true
        }
    }
}

// MARK: - Klonen & Backup

struct CloneEditor: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let onStarted: (String?) -> Void

    @State private var newID = 0
    @State private var name = ""
    @State private var full = true

    var body: some View {
        EditorForm(title: "Klonen", saveTitle: "Klonen", canSave: newID >= 100, save: {
            let upid = try await client.clone(guest, newID: newID, name: CommandBuilder.sanitizedHostname(name), full: full)
            onStarted(upid)
        }) {
            Section {
                NumberField(title: "Neue ID", value: $newID)
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if guest.isTemplate {
                    Toggle("Vollständiger Klon", isOn: $full)
                }
            } footer: {
                Text(guest.isTemplate && !full
                     ? "Ein verknüpfter Klon teilt sich die Disks mit der Vorlage und ist sofort fertig."
                     : "Ein vollständiger Klon kopiert alle Disks und kann einige Minuten dauern.")
            }
        }
        .task {
            name = "\(guest.displayName)-clone"
            newID = (try? await client.nextID()) ?? 0
        }
    }
}

struct BackupEditor: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let onStarted: (String?) -> Void

    @StateObject private var choices = NodeChoices()
    @State private var storage = ""
    @State private var mode = "snapshot"
    @State private var compress = "zstd"
    @State private var notes = "{{guestname}}"
    @State private var protected = false

    var body: some View {
        EditorForm(title: "Backup", saveTitle: "Starten", canSave: !storage.isEmpty, save: {
            var params: [(String, String)] = [
                ("vmid", String(guest.vmid)), ("storage", storage), ("mode", mode), ("compress", compress),
            ]
            if !notes.isEmpty { params.append(("notes-template", notes)) }
            if protected { params.append(("protected", "1")) }
            let upid = try await client.create("/nodes/\(guest.node)/vzdump", params)
            onStarted(upid)
        }) {
            Section {
                StoragePicker(title: "Ziel-Storage", storages: choices.storages, selection: $storage)
                Picker("Modus", selection: $mode) {
                    Text("Snapshot").tag("snapshot")
                    Text("Suspend").tag("suspend")
                    Text("Stopp").tag("stop")
                }
                Picker("Kompression", selection: $compress) {
                    Text("ZSTD (schnell & gut)").tag("zstd")
                    Text("LZO").tag("lzo")
                    Text("GZIP").tag("gzip")
                    Text("Keine").tag("0")
                }
                TextField("Notiz", text: $notes)
                Toggle("Geschützt", isOn: $protected)
            } footer: {
                Text("„Snapshot“ sichert im laufenden Betrieb, „Stopp“ fährt den Gast für maximale Konsistenz kurz herunter.")
            }
            if let error = choices.error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .task {
            await choices.load(client: client, node: guest.node, content: "backup")
            if storage.isEmpty { storage = choices.storages.first?.storage ?? "" }
        }
    }
}
