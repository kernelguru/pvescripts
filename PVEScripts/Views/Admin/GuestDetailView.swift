import SwiftUI

struct GuestDetailView: View {
    let hostID: UUID
    @State var guest: ProxmoxGuest

    @EnvironmentObject private var hosts: HostStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = ActionRunner()

    @State private var status: GuestStatus?
    @State private var config: GuestConfig?
    @State private var addresses: [GuestAddress] = []
    @State private var addressError: String?
    @State private var loadError: String?
    @State private var session: TerminalSession?
    @State private var sheet: SheetKind?
    @State private var vnc: VNCTarget?
    @State private var taskUPID: TaskRef?
    @State private var confirmDelete = false
    @State private var confirmStop = false
    @State private var restartHint = false

    enum SheetKind: Identifiable {
        case cpuMemory, options, addDisk, addNetwork, editNetwork(String), resize(String), cdrom(String)
        case clone, backup, agent, raw
        case pci(String?), usb(String?), lxcDevice(String?)
        var id: String {
            switch self {
            case .editNetwork(let k): "net-\(k)"
            case .resize(let k): "resize-\(k)"
            case .cdrom(let k): "cd-\(k)"
            case .pci(let k): "pci-\(k ?? "neu")"
            case .usb(let k): "usb-\(k ?? "neu")"
            case .lxcDevice(let k): "dev-\(k ?? "neu")"
            default: String(describing: self)
            }
        }
    }

    private var host: ProxmoxHost? { hosts.host(id: hostID) }
    private var client: PVEClient? { host.map(PVEClient.init) }
    private var isVM: Bool { guest.kind == .qemu }
    private var running: Bool { status?.isRunning ?? guest.isRunning }
    private var paused: Bool { status?.isPaused ?? false }

    var body: some View {
        List {
            headerSection
            if loadError != nil { errorSection }
            if !guest.isTemplate { powerSection }
            if running { resourcesSection }
            if running { addressSection }
            if !guest.isTemplate { consoleSection }
            hardwareSection
            optionsSection
            managementSection
            dangerSection
        }
        .navigationTitle(guest.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: guest.id) {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await refreshStatus()
            }
        }
        .sheet(item: $sheet) { kind in
            if let client, let config {
                sheetContent(kind, client: client, config: config)
            }
        }
        .sheet(item: $taskUPID) { ref in
            if let client {
                TaskLogView(client: client, upid: ref.upid, title: ref.title) {
                    Task { await load() }
                }
            }
        }
        .fullScreenCover(item: $session) { TerminalScreen(session: $0) }
        .fullScreenCover(item: $vnc) { target in
            if let host { NoVNCScreen(host: host, target: target) }
        }
        .confirmationDialog("\(guest.displayName) löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Endgültig löschen (inkl. Disks)", role: .destructive) { destroy() }
        } message: {
            Text("\(guest.kind.longTitle) \(guest.vmid) und alle zugehörigen Disks werden unwiderruflich gelöscht. Auch aus Backup-Jobs und HA wird sie entfernt.")
        }
        .confirmationDialog("Hart stoppen?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stoppen", role: .destructive) { act(.stop) }
        } message: {
            Text("Entspricht dem Ziehen des Netzsteckers – ungespeicherte Daten gehen verloren.")
        }
        .alert("Neustart nötig", isPresented: $restartHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Einige Änderungen werden erst nach einem vollständigen Herunterfahren und erneuten Starten wirksam (ein Neustart aus dem Gast heraus reicht dafür nicht).")
        }
        .actionRunner(runner)
    }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: guest.kind.symbol)
                    .font(.title)
                    .foregroundStyle(running ? Color.accentColor : .secondary)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        StatusDot(running: running, paused: paused)
                        Text(paused ? "pausiert" : (running ? "läuft" : (status?.status ?? guest.status ?? "unbekannt")))
                            .font(.subheadline.weight(.semibold))
                        if let lock = status?.lock ?? guest.lock { Badge(text: "🔒 \(lock)", color: .orange) }
                    }
                    Text("\(guest.kind.longTitle) \(guest.vmid) · Node \(guest.node)")
                        .font(.caption).foregroundStyle(.secondary)
                    if running {
                        Text("Laufzeit \(Fmt.uptime(status?.uptime ?? guest.uptime))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !guest.tagList.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(guest.tagList, id: \.self) { Badge(text: $0, color: .teal) }
                        }
                    }
                }
            }
        }
    }

    private var errorSection: some View {
        Section {
            Label(loadError ?? "", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.callout)
        }
    }

    private var powerSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if !running {
                        powerButton(.start, tint: .green)
                    } else {
                        if paused {
                            powerButton(.resume, tint: .green)
                        } else {
                            powerButton(.shutdown, tint: .orange)
                            powerButton(.reboot, tint: .blue)
                            if isVM { powerButton(.suspend, tint: .yellow) }
                        }
                        Button { confirmStop = true } label: {
                            powerLabel(.stop)
                        }
                        .tint(.red)
                    }
                }
                .buttonStyle(.bordered)
                .padding(.vertical, 4)
            }
            .disabled(runner.isBusy)
        }
    }

    private func powerButton(_ action: GuestAction, tint: Color) -> some View {
        Button { act(action) } label: { powerLabel(action) }.tint(tint)
    }

    private func powerLabel(_ action: GuestAction) -> some View {
        VStack(spacing: 4) {
            Image(systemName: action.symbol).font(.title3)
            Text(action.title).font(.caption2).lineLimit(1)
        }
        .frame(minWidth: 72, minHeight: 44)
    }

    private var resourcesSection: some View {
        Section("Ressourcen") {
            let s = status
            let cpus = Int(s?.cpus ?? guest.maxcpu ?? 0)
            UsageBar(title: "CPU", fraction: s?.cpu ?? guest.cpu,
                     detail: "\(Fmt.percent(s?.cpu ?? guest.cpu)) von \(cpus) vCPU", symbol: "cpu")
            let mem = s?.mem ?? guest.mem, maxmem = s?.maxmem ?? guest.maxmem
            UsageBar(title: "RAM", fraction: (maxmem ?? 0) > 0 ? (mem ?? 0) / maxmem! : nil,
                     detail: "\(Fmt.bytes(mem)) / \(Fmt.bytes(maxmem))", symbol: "memorychip")
            if !isVM {
                let disk = s?.disk ?? guest.disk, maxdisk = s?.maxdisk ?? guest.maxdisk
                UsageBar(title: "Root-Disk", fraction: (maxdisk ?? 0) > 0 ? (disk ?? 0) / maxdisk! : nil,
                         detail: "\(Fmt.bytes(disk)) / \(Fmt.bytes(maxdisk))", symbol: "internaldrive")
            }
            LabeledContent {
                Text("↓ \(Fmt.bytes(s?.netin ?? guest.netin))  ↑ \(Fmt.bytes(s?.netout ?? guest.netout))")
                    .font(.caption.monospacedDigit())
            } label: {
                Label("Netzwerk (gesamt)", systemImage: "network")
            }
            if let read = s?.diskread, let write = s?.diskwrite {
                LabeledContent {
                    Text("R \(Fmt.bytes(read))  W \(Fmt.bytes(write))").font(.caption.monospacedDigit())
                } label: {
                    Label("Disk-I/O (gesamt)", systemImage: "externaldrive")
                }
            }
        }
    }

    private var addressSection: some View {
        Section {
            if addresses.isEmpty {
                if let addressError {
                    Text(addressError).font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Keine IP-Adressen gefunden.").font(.footnote).foregroundStyle(.secondary)
                }
                if isVM {
                    Button("QEMU-Agent einrichten …", systemImage: "wrench.and.screwdriver") { sheet = .agent }
                }
            }
            ForEach(addresses) { address in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(address.address).font(.body.monospaced()).textSelection(.enabled)
                        Text([address.interface, address.mac].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = address.address.components(separatedBy: "/").first
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("IP-Adressen")
        } footer: {
            if isVM && addresses.isEmpty == false {
                Text("Ermittelt über den QEMU-Gast-Agent.")
            }
        }
    }

    @ViewBuilder
    private var consoleSection: some View {
        Section {
            if isVM {
                if config?["serial0"] != nil {
                    Button("Serielle Konsole", systemImage: "terminal") {
                        openNodeTerminal(title: "Seriell – \(guest.displayName)", command: "qm terminal \(guest.vmid)")
                    }
                    .disabled(!running)
                } else {
                    Button("Serielle Schnittstelle hinzufügen", systemImage: "cable.connector") {
                        updateConfig("Serielle Schnittstelle wird hinzugefügt …", set: [("serial0", "socket")], needsRestart: true)
                    }
                }
            } else {
                Button("Konsole (Login)", systemImage: "terminal") {
                    openNodeTerminal(title: "Konsole – \(guest.displayName)", command: "pct console \(guest.vmid)")
                }
                .disabled(!running)
                Button("Root-Shell (pct enter)", systemImage: "apple.terminal") {
                    openNodeTerminal(title: "Shell – \(guest.displayName)", command: "pct enter \(guest.vmid)")
                }
                .disabled(!running)
            }
            Button("VNC-Konsole (noVNC)", systemImage: "display") {
                vnc = VNCTarget(guest: guest)
            }
            .disabled(!running)
        } header: {
            Text("Konsole")
        } footer: {
            Text(isVM
                 ? "Serielle Konsole beenden mit Strg-O. Der Gast muss eine Konsole auf ttyS0 anbieten (bei Cloud-Images Standard)."
                 : "Konsole beenden mit Strg-A, dann Q. Die Root-Shell mit „exit“.")
        }
    }

    @ViewBuilder
    private var hardwareSection: some View {
        if let config {
            Section("Hardware") {
                Button { sheet = .cpuMemory } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent("CPU", value: cpuSummary(config))
                        LabeledContent("Arbeitsspeicher", value: memorySummary(config))
                    }
                }
                .foregroundStyle(.primary)

                ForEach(config.diskKeys, id: \.self) { key in
                    diskRow(key, config: config)
                }
                Button("Disk hinzufügen", systemImage: "plus.circle") { sheet = .addDisk }

                ForEach(config.cdromKeys, id: \.self) { key in
                    Button { sheet = .cdrom(key) } label: {
                        LabeledContent {
                            Text(PropertyString(config[key] ?? "").positional ?? "–")
                                .font(.caption).lineLimit(2).multilineTextAlignment(.trailing)
                        } label: {
                            Label("CD/DVD (\(key))", systemImage: "opticaldisc")
                        }
                    }
                    .foregroundStyle(.primary)
                }

                ForEach(config.netKeys, id: \.self) { key in
                    Button { sheet = .editNetwork(key) } label: {
                        LabeledContent {
                            Text(networkSummary(config[key] ?? ""))
                                .font(.caption).lineLimit(2).multilineTextAlignment(.trailing)
                        } label: {
                            Label(key, systemImage: "network")
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        Button("Entfernen", role: .destructive) {
                            updateConfig("Netzwerkkarte wird entfernt …", set: [], delete: [key])
                        }
                    }
                }
                Button("Netzwerkkarte hinzufügen", systemImage: "plus.circle") { sheet = .addNetwork }
            }
            passthroughSection(config)
            Section("System") {

                if isVM {
                    LabeledContent("BIOS", value: config["bios"] == "ovmf" ? "OVMF (UEFI)" : "SeaBIOS")
                    LabeledContent("Maschine", value: config["machine"] ?? "i440fx (Standard)")
                    if let boot = config["boot"] {
                        LabeledContent("Boot-Reihenfolge") { Text(boot).font(.caption) }
                    }
                } else {
                    LabeledContent("Betriebssystem", value: config["ostype"] ?? "–")
                    LabeledContent("Typ", value: config["unprivileged"] == "1" ? "Unprivilegiert" : "Privilegiert")
                    if let features = config["features"] {
                        LabeledContent("Features") { Text(features).font(.caption) }
                    }
                }
                Button("Alle Einstellungen (Experte)", systemImage: "slider.horizontal.3") { sheet = .raw }
            }
        }
    }

    @ViewBuilder
    private func diskRow(_ key: String, config: GuestConfig) -> some View {
        let props = PropertyString(config[key] ?? "")
        let isUnused = key.hasPrefix("unused")
        let resizable = !isUnused && !key.hasPrefix("efidisk") && !key.hasPrefix("tpmstate")
        Menu {
            if resizable {
                Button("Vergrößern …", systemImage: "arrow.up.left.and.arrow.down.right") { sheet = .resize(key) }
            }
            if key != "rootfs" {
                Button(isUnused ? "Disk endgültig löschen" : "Disk aushängen", systemImage: "trash", role: .destructive) {
                    updateConfig(isUnused ? "Disk wird gelöscht …" : "Disk wird ausgehängt …", set: [], delete: [key])
                }
            }
        } label: {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(props["size"] ?? "")
                        .font(.subheadline.monospacedDigit())
                    Text(props.positional ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } label: {
                Label(diskTitle(key, props: props), systemImage: isUnused ? "externaldrive.badge.xmark" : "internaldrive")
            }
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func passthroughSection(_ config: GuestConfig) -> some View {
        Section {
            if isVM {
                ForEach(config.pciKeys, id: \.self) { key in
                    passthroughRow(key, value: config[key] ?? "", symbol: "display") { sheet = .pci(key) }
                }
                ForEach(config.usbKeys, id: \.self) { key in
                    passthroughRow(key, value: config[key] ?? "", symbol: "cable.connector") { sheet = .usb(key) }
                }
                Button("PCI-Gerät / GPU hinzufügen", systemImage: "plus.circle") { sheet = .pci(nil) }
                Button("USB-Gerät hinzufügen", systemImage: "plus.circle") { sheet = .usb(nil) }
            } else {
                ForEach(config.deviceKeys, id: \.self) { key in
                    passthroughRow(key, value: config[key] ?? "", symbol: "cpu") { sheet = .lxcDevice(key) }
                }
                Button("Gerät hinzufügen (GPU, USB, TUN …)", systemImage: "plus.circle") { sheet = .lxcDevice(nil) }
            }
            if let host {
                NavigationLink {
                    HostPassthroughView(host: host, node: guest.node)
                } label: {
                    Label("Host prüfen & einrichten", systemImage: "checkmark.shield")
                }
            }
        } header: {
            Text("Durchgereichte Geräte")
        } footer: {
            Text(isVM
                 ? "PCI-Geräte (z. B. GPUs) erfordern aktives IOMMU auf dem Host und einen vollständigen Neustart der VM."
                 : "Gerätedateien des Hosts (z. B. /dev/dri für Hardware-Transcoding oder USB-Sticks) im Container verfügbar machen.")
        }
    }

    private func passthroughRow(_ key: String, value: String, symbol: String, edit: @escaping () -> Void) -> some View {
        Button(action: edit) {
            LabeledContent {
                Text(value).font(.caption.monospaced()).lineLimit(2).multilineTextAlignment(.trailing)
            } label: {
                Label(key, systemImage: symbol)
            }
        }
        .foregroundStyle(.primary)
        .swipeActions {
            Button("Entfernen", role: .destructive) {
                updateConfig("\(key) wird entfernt …", set: [], delete: [key], needsRestart: true)
            }
        }
    }

    private var optionsSection: some View {
        Section("Optionen") {
            if let config {
                Button { sheet = .options } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(isVM ? "Name" : "Hostname", value: config[isVM ? "name" : "hostname"] ?? "–")
                        LabeledContent("Autostart", value: config["onboot"] == "1" ? "Ja" : "Nein")
                        LabeledContent("Schutz", value: config["protection"] == "1" ? "Aktiv" : "Aus")
                        if isVM {
                            LabeledContent("QEMU-Agent", value: PropertyString(config["agent"] ?? "0").positional == "1"
                                           || PropertyString(config["agent"] ?? "")["enabled"] == "1" ? "Aktiviert" : "Aus")
                        }
                        if let desc = config["description"], !desc.isEmpty {
                            Text(desc).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
                .foregroundStyle(.primary)
            } else {
                ProgressView()
            }
        }
    }

    private var managementSection: some View {
        Section("Verwaltung") {
            if let host {
                NavigationLink {
                    SnapshotsView(client: PVEClient(host: host), guest: guest)
                } label: {
                    Label("Snapshots", systemImage: "camera.on.rectangle")
                }
            }
            Button("Backup jetzt …", systemImage: "archivebox") { sheet = .backup }
            Button("Klonen …", systemImage: "plus.square.on.square") { sheet = .clone }
            if isVM {
                Button("QEMU-Gast-Agent installieren …", systemImage: "wrench.and.screwdriver") { sheet = .agent }
            }
        }
    }

    private var dangerSection: some View {
        Section {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("\(guest.kind.longTitle) löschen", systemImage: "trash")
            }
            .disabled(running)
        } footer: {
            if running { Text("Zum Löschen muss der Gast gestoppt sein.") }
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ kind: SheetKind, client: PVEClient, config: GuestConfig) -> some View {
        let done: (Bool) -> Void = { needsRestart in
            Task { await load() }
            if needsRestart && running { restartHint = true }
        }
        switch kind {
        case .cpuMemory:
            CPUMemoryEditor(client: client, guest: guest, config: config, onSave: done)
        case .options:
            OptionsEditor(client: client, guest: guest, config: config, onSave: done)
        case .addDisk:
            AddDiskEditor(client: client, guest: guest, config: config, onSave: done)
        case .addNetwork:
            NetworkEditor(client: client, guest: guest, config: config, key: nil, onSave: done)
        case .editNetwork(let key):
            NetworkEditor(client: client, guest: guest, config: config, key: key, onSave: done)
        case .resize(let key):
            ResizeDiskEditor(client: client, guest: guest, config: config, key: key, onSave: done)
        case .cdrom(let key):
            CDROMEditor(client: client, guest: guest, config: config, key: key, onSave: done)
        case .raw:
            RawConfigEditor(client: client, guest: guest, config: config, onSave: done)
        case .pci(let key):
            PCIPassthroughEditor(client: client, guest: guest, config: config, key: key, onSave: done)
        case .usb(let key):
            USBPassthroughEditor(client: client, guest: guest, config: config, key: key, onSave: done)
        case .lxcDevice(let key):
            LXCDeviceEditor(client: client, guest: guest, config: config, key: key, onSave: done)
        case .clone:
            CloneEditor(client: client, guest: guest) { upid in
                if let upid { showTask(TaskRef(upid: upid, title: "Klonen")) }
            }
        case .backup:
            BackupEditor(client: client, guest: guest) { upid in
                if let upid { showTask(TaskRef(upid: upid, title: "Backup")) }
            }
        case .agent:
            AgentSetupView(client: client, guest: guest, config: config, addresses: addresses) { needsRestart in
                done(needsRestart)
            } openTerminal: { session in
                sheet = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.session = session }
            }
        }
    }

    // MARK: Actions

    /// Task-Log erst zeigen, wenn das vorherige Sheet geschlossen ist.
    private func showTask(_ ref: TaskRef) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { taskUPID = ref }
    }

    private func act(_ action: GuestAction) {
        guard let client else { return }
        runner.run("\(action.title) …") {
            let upid = try await client.perform(action, on: guest)
            try await client.wait(upid, timeout: 300)
            await refreshStatus()
        }
    }

    private func updateConfig(_ title: String, set: [(String, String)], delete: [String] = [], needsRestart: Bool = false) {
        guard let client else { return }
        runner.run(title) {
            try await client.updateConfig(guest, set: set, delete: delete)
            await load()
            if needsRestart && running { restartHint = true }
        }
    }

    private func destroy() {
        guard let client else { return }
        runner.run("Wird gelöscht …") {
            let upid = try await client.destroy(guest, purge: true)
            try await client.wait(upid, timeout: 600)
            dismiss()
        }
    }

    private func openNodeTerminal(title: String, command: String) {
        guard let host, let client else { return }
        Task {
            let full = await client.commandOnNode(guest.node, command)
            session = makeTerminalSession(host: host, title: title, command: full, hosts: hosts)
        }
    }

    // MARK: Loading

    private func load() async {
        guard let client else { return }
        do {
            async let s = client.status(guest)
            async let c = client.config(guest)
            let (newStatus, newConfig) = try await (s, c)
            status = newStatus
            config = newConfig
            if let name = newConfig[isVM ? "name" : "hostname"] { guest.name = name }
            guest.tags = newConfig["tags"]
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        await loadAddresses()
    }

    private func refreshStatus() async {
        guard let client else { return }
        if let s = try? await client.status(guest) {
            let wasRunning = status?.isRunning
            status = s
            if wasRunning != s.isRunning { await loadAddresses() }
        }
    }

    private func loadAddresses() async {
        guard let client, running else { addresses = []; return }
        do {
            addresses = try await client.addresses(guest)
            addressError = nil
        } catch {
            addresses = []
            if isVM {
                addressError = "Der QEMU-Gast-Agent antwortet nicht. Installiere ihn im Gast und aktiviere ihn in den Optionen, um IP-Adressen zu sehen."
            } else {
                addressError = error.localizedDescription
            }
        }
    }

    // MARK: Formatting

    private func cpuSummary(_ config: GuestConfig) -> String {
        let cores = Int(config["cores"] ?? "1") ?? 1
        let sockets = Int(config["sockets"] ?? "1") ?? 1
        var text = "\(cores * sockets) Kerne"
        if sockets > 1 { text += " (\(sockets)×\(cores))" }
        if let type = config["cpu"] { text += " · \(PropertyString(type).positional ?? type)" }
        if let limit = config["cpulimit"], limit != "0" { text += " · Limit \(limit)" }
        return text
    }

    private func memorySummary(_ config: GuestConfig) -> String {
        let mem = Int(config["memory"] ?? "512") ?? 512
        var text = mem >= 1024 ? String(format: "%.1f GiB", Double(mem) / 1024) : "\(mem) MiB"
        if isVM, let balloon = config["balloon"], balloon != "0", balloon != config["memory"] {
            text += " (min. \(balloon) MiB)"
        }
        if !isVM, let swap = config["swap"] { text += " · Swap \(swap) MiB" }
        return text
    }

    private func diskTitle(_ key: String, props: PropertyString) -> String {
        if key == "rootfs" { return "Root-Disk" }
        if key.hasPrefix("mp") { return "\(key) → \(props["mp"] ?? "?")" }
        if key.hasPrefix("efidisk") { return "EFI-Disk" }
        if key.hasPrefix("tpmstate") { return "TPM" }
        if key.hasPrefix("unused") { return "Ungenutzt (\(key))" }
        return key
    }

    private func networkSummary(_ raw: String) -> String {
        let p = PropertyString(raw)
        var parts: [String] = []
        if isVM {
            if let first = p.items.first, !first.key.isEmpty, first.key != "bridge" {
                parts.append(first.key)
            }
        } else if let name = p["name"] {
            parts.append(name)
        }
        if let bridge = p["bridge"] { parts.append(bridge) }
        if let tag = p["tag"] { parts.append("VLAN \(tag)") }
        if let ip = p["ip"] { parts.append(ip) }
        if p["firewall"] == "1" { parts.append("FW") }
        if p["link_down"] == "1" { parts.append("getrennt") }
        return parts.joined(separator: " · ")
    }
}

struct TaskRef: Identifiable {
    let upid: String
    let title: String
    var id: String { upid }
}
