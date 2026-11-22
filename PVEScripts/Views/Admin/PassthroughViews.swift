import SwiftUI

// MARK: - Host-Prüfung & Einrichtung

/// Prüft, ob ein Node für PCI-/GPU-Passthrough vorbereitet ist, und richtet ihn bei Bedarf ein.
struct HostPassthroughView: View {
    let host: ProxmoxHost
    let node: String

    @EnvironmentObject private var hosts: HostStore
    @StateObject private var runner = ActionRunner()
    @State private var check: PassthroughCheck?
    @State private var devices: [PCIDevice] = []
    @State private var drivers: [String: String] = [:]
    @State private var error: String?
    @State private var bindGPU: String = ""
    @State private var showScript = false
    @State private var session: TerminalSession?
    @State private var confirmReboot = false

    private var client: PVEClient { PVEClient(host: host) }
    private var gpus: [PCIDevice] { devices.filter { $0.isGPU && $0.function == "0" } }

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let check {
                statusSection(check)
                setupSection(check)
            } else if error == nil {
                ProgressView("Host wird geprüft …")
            }
            if !devices.isEmpty { groupsSection }
        }
        .navigationTitle("Passthrough – \(node)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .fullScreenCover(item: $session, onDismiss: { Task { await load() } }) { TerminalScreen(session: $0) }
        .sheet(isPresented: $showScript) { scriptSheet }
        .confirmationDialog("Node \(node) jetzt neu starten?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Neu starten", role: .destructive) {
                runner.run("Neustart wird ausgelöst …", success: "Der Node startet neu. Prüfe in ein paar Minuten erneut.") {
                    try await client.create("/nodes/\(node)/status", [("command", "reboot")])
                }
            }
        } message: {
            Text("Alle laufenden Gäste auf diesem Node werden heruntergefahren.")
        }
        .actionRunner(runner)
    }

    // MARK: Sections

    private func statusSection(_ c: PassthroughCheck) -> some View {
        Section {
            checkRow("CPU", value: c.isIntel ? "Intel" : (c.isAMD ? "AMD" : c.cpuVendor), ok: true)
            checkRow("IOMMU aktiv", value: c.iommuActive ? "\(c.iommuGroups) Gruppen" : "nein", ok: c.iommuActive,
                     hint: c.iommuActive ? nil : "VT-d / AMD-Vi im BIOS aktivieren und Kernel-Parameter setzen.")
            if c.isIntel {
                checkRow("Kernel-Parameter intel_iommu=on", value: c.hasIntelParam ? "gesetzt" : "fehlt", ok: c.hasIntelParam)
            }
            checkRow("iommu=pt (empfohlen)", value: c.hasPassthroughParam ? "gesetzt" : "fehlt", ok: c.hasPassthroughParam, optional: true)
            checkRow("Interrupt-Remapping", value: c.interruptRemapping ? "aktiv" : "nicht erkannt", ok: c.interruptRemapping, optional: true,
                     hint: c.interruptRemapping ? nil : "Ohne Remapping kann Passthrough instabil sein (ggf. allow_unsafe_interrupts).")
            checkRow("vfio-Module geladen", value: c.vfioLoaded ? "ja" : "nein", ok: c.vfioLoaded)
            LabeledContent("Bootloader", value: c.bootloader == "systemd-boot" ? "systemd-boot (proxmox-boot-tool)" : "GRUB")
            if !c.pveVersion.isEmpty { LabeledContent("Proxmox VE", value: c.pveVersion) }
            if !c.vfioConfig.isEmpty {
                LabeledContent("vfio-Konfiguration") { Text(c.vfioConfig).font(.caption2.monospaced()) }
            }
        } header: {
            Text("Status")
        } footer: {
            Text(c.ready
                 ? "Der Host ist für PCI-Passthrough bereit."
                 : "Der Host ist noch nicht vollständig eingerichtet. Nutze den Assistenten unten.")
        }
    }

    private func setupSection(_ c: PassthroughCheck) -> some View {
        Section {
            if !gpus.isEmpty {
                Picker("GPU fest an vfio-pci binden", selection: $bindGPU) {
                    Text("Nicht binden").tag("")
                    ForEach(gpus) { gpu in
                        Text("\(gpu.slot) – \(gpu.title)").tag(gpu.slot)
                    }
                }
            }
            Button("Einrichtungsskript anzeigen & ausführen", systemImage: "wand.and.stars") { showScript = true }
            Button("Node neu starten", systemImage: "power", role: .destructive) { confirmReboot = true }
        } header: {
            Text("Einrichten")
        } footer: {
            Text("Das Skript setzt die IOMMU-Kernel-Parameter, lädt die vfio-Module beim Booten und bindet optional die gewählte GPU an vfio-pci (der Host nutzt sie danach nicht mehr). Von geänderten Dateien wird vorher eine Sicherung angelegt. Danach ist ein Neustart nötig.\nVT-d bzw. AMD-Vi/IOMMU muss zusätzlich im BIOS/UEFI aktiviert sein.")
        }
    }

    private var groupsSection: some View {
        Section {
            ForEach(devices.filter { $0.isGPU || $0.category == "USB-Controller" || $0.category == "Netzwerk" || $0.category == "Storage" }) { dev in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Image(systemName: dev.symbol).foregroundStyle(.tint).frame(width: 22)
                        Text(dev.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Text(dev.id)
                        Text(dev.iommuGroup >= 0 ? "Gruppe \(dev.iommuGroup)" : "keine Gruppe")
                        if let driver = drivers[dev.id] { Text("Treiber: \(driver)") }
                    }
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    if sharedGroup(dev) {
                        Label("Teilt sich die IOMMU-Gruppe mit anderen Geräten", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Geräte & IOMMU-Gruppen")
        } footer: {
            Text("Gezeigt werden GPUs, USB-, Netzwerk- und Storage-Controller.")
        }
    }

    private func checkRow(_ title: String, value: String, ok: Bool, optional: Bool = false, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: ok ? "checkmark.circle.fill" : (optional ? "exclamationmark.circle.fill" : "xmark.circle.fill"))
                    .foregroundStyle(ok ? .green : (optional ? .orange : .red))
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary).font(.callout)
            }
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func sharedGroup(_ dev: PCIDevice) -> Bool {
        guard dev.iommuGroup >= 0 else { return false }
        return devices.contains { $0.iommuGroup == dev.iommuGroup && $0.slot != dev.slot }
    }

    // MARK: Script

    private var setupScript: String {
        var ids: [String] = []
        if !bindGPU.isEmpty {
            ids = devices.filter { $0.slot == bindGPU }.map(\.vendorDevice)
        }
        return Self.makeScript(vfioIDs: Array(Set(ids)).sorted())
    }

    static func makeScript(vfioIDs: [String]) -> String {
        var s = """
        set -e
        TS=$(date +%Y%m%d-%H%M%S)
        CPU=$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')
        PARAMS="iommu=pt"
        [ "$CPU" = "GenuineIntel" ] && PARAMS="intel_iommu=on iommu=pt"
        echo "==> Kernel-Parameter: $PARAMS"
        if [ -f /etc/kernel/cmdline ]; then
          cp /etc/kernel/cmdline /etc/kernel/cmdline.bak-$TS
          for P in $PARAMS; do grep -qw "$P" /etc/kernel/cmdline || sed -i "1 s|\\$| $P|" /etc/kernel/cmdline; done
          cat /etc/kernel/cmdline
          BOOT=systemd
        else
          cp /etc/default/grub /etc/default/grub.bak-$TS
          for P in $PARAMS; do grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=.*$P" /etc/default/grub || sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\\"\\(.*\\)\\"|GRUB_CMDLINE_LINUX_DEFAULT=\\"\\1 $P\\"|" /etc/default/grub; done
          grep ^GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub
          BOOT=grub
        fi
        echo "==> vfio-Module"
        cp /etc/modules /etc/modules.bak-$TS
        for M in vfio vfio_iommu_type1 vfio_pci; do grep -qx "$M" /etc/modules || echo "$M" >> /etc/modules; done

        """
        if !vfioIDs.isEmpty {
            let joined = vfioIDs.joined(separator: ",")
            s += """
            echo "==> GPU an vfio-pci binden: \(joined)"
            [ -f /etc/modprobe.d/vfio.conf ] && cp /etc/modprobe.d/vfio.conf /etc/modprobe.d/vfio.conf.bak-$TS
            echo "options vfio-pci ids=\(joined) disable_vga=1" > /etc/modprobe.d/vfio.conf
            for D in nvidia nvidiafb nouveau amdgpu radeon i915 xe snd_hda_intel; do echo "softdep $D pre: vfio-pci" >> /etc/modprobe.d/vfio.conf; done
            cat /etc/modprobe.d/vfio.conf

            """
        }
        s += """
        echo "==> initramfs & Bootloader aktualisieren"
        update-initramfs -u -k all
        if [ "$BOOT" = systemd ] || proxmox-boot-tool status >/dev/null 2>&1; then proxmox-boot-tool refresh; else update-grub; fi
        echo
        echo "Fertig. Bitte den Node neu starten, damit die Änderungen wirksam werden."
        """
        return s
    }

    private var scriptSheet: some View {
        NavigationStack {
            ScrollView {
                Text(setupScript)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Einrichtungsskript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { showScript = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ausführen") {
                        showScript = false
                        let script = setupScript
                        Task {
                            let command = await client.commandOnNode(node, "bash -c \(CommandBuilder.shellQuote(script))")
                            try? await Task.sleep(for: .seconds(0.6))
                            session = makeTerminalSession(host: host, title: "Passthrough einrichten", command: command, hosts: hosts)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                Label("Wird als root auf Node \(node) ausgeführt. Bitte vorher lesen.", systemImage: "exclamationmark.shield")
                    .font(.footnote)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.orange.opacity(0.15))
            }
        }
    }

    private func load() async {
        do {
            async let c = client.passthroughCheck(node: node)
            async let d = client.pciDevices(node: node)
            let (newCheck, newDevices) = try await (c, d)
            check = newCheck
            devices = newDevices
            error = nil
            for dev in newDevices where dev.isGPU || dev.category == "USB-Controller" {
                if let driver = await client.pciDriver(node: node, id: dev.id) { drivers[dev.id] = driver }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - PCI-Passthrough (VM)

struct PCIPassthroughEditor: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let config: GuestConfig
    let key: String?
    let onSave: (Bool) -> Void

    @State private var devices: [PCIDevice] = []
    @State private var mappings: [String] = []
    @State private var check: PassthroughCheck?
    @State private var selection = ""
    @State private var mapping = ""
    @State private var useMapping = false
    @State private var allFunctions = true
    @State private var primaryGPU = false
    @State private var pcie = true
    @State private var rombar = true
    @State private var driver: String?
    @State private var loading = true

    private var targetKey: String { key ?? "hostpci\(config.nextIndex(prefix: "hostpci", limit: 15))" }
    private var selected: PCIDevice? { devices.first { $0.id == selection } }
    private var isQ35: Bool { (config["machine"] ?? "").contains("q35") }
    private var groupMembers: [PCIDevice] {
        guard let sel = selected, sel.iommuGroup >= 0 else { return [] }
        return devices.filter { $0.iommuGroup == sel.iommuGroup && $0.slot != sel.slot }
    }

    var body: some View {
        EditorForm(title: key == nil ? "PCI-Gerät durchreichen" : targetKey,
                   saveTitle: key == nil ? "Hinzufügen" : "Sichern",
                   canSave: useMapping ? !mapping.isEmpty : !selection.isEmpty, save: save) {
            if let check, !check.ready {
                Section {
                    Label(check.iommuActive ? "Die vfio-Module sind auf dem Host nicht geladen." : "IOMMU ist auf dem Host nicht aktiv – Passthrough wird nicht funktionieren.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Unter Hosts → Host → Werkzeuge → „PCI/GPU-Passthrough“ kannst du den Host prüfen und einrichten.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if !mappings.isEmpty {
                Section {
                    Toggle("Cluster-Zuordnung verwenden", isOn: $useMapping)
                    if useMapping {
                        Picker("Zuordnung", selection: $mapping) {
                            Text("Bitte wählen").tag("")
                            ForEach(mappings, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
            }

            if !useMapping {
                Section {
                    if loading { ProgressView() }
                    Picker("Gerät", selection: $selection) {
                        Text("Bitte wählen").tag("")
                        ForEach(groupedCategories, id: \.self) { category in
                            Section(category) {
                                ForEach(devices.filter { $0.category == category }) { dev in
                                    Text("\(dev.id) – \(dev.title)").tag(dev.id)
                                }
                            }
                        }
                    }
                    .pickerStyle(.navigationLink)
                    if let sel = selected {
                        LabeledContent("Hersteller", value: sel.vendorName ?? sel.vendor)
                        LabeledContent("ID", value: sel.vendorDevice)
                        LabeledContent("IOMMU-Gruppe", value: sel.iommuGroup >= 0 ? String(sel.iommuGroup) : "–")
                        LabeledContent("Host-Treiber", value: driver ?? "keiner")
                    }
                } header: {
                    Text("Gerät")
                } footer: {
                    if let warning = deviceWarning { Text(warning).foregroundStyle(.orange) }
                }
            }

            Section {
                Toggle("Alle Funktionen", isOn: $allFunctions)
                if selected?.isGPU ?? true {
                    Toggle("Primäre GPU (x-vga)", isOn: $primaryGPU)
                }
                Toggle("PCI-Express", isOn: $pcie)
                Toggle("ROM-Bar", isOn: $rombar)
            } header: {
                Text("Optionen")
            } footer: {
                Text(optionsFooter)
            }
        }
        .task { await load() }
        .onChange(of: selection) {
            guard let sel = selected else { return }
            if key == nil { primaryGPU = false; allFunctions = sel.isGPU || sel.category != "Netzwerk" }
            Task { driver = await client.pciDriver(node: guest.node, id: sel.id) }
        }
    }

    private var groupedCategories: [String] {
        var seen: [String] = []
        for dev in devices where !seen.contains(dev.category) { seen.append(dev.category) }
        return seen.sorted { a, b in a == "Grafik" || (b != "Grafik" && a < b) }
    }

    private var deviceWarning: String? {
        guard let sel = selected else { return nil }
        var parts: [String] = []
        if sel.iommuGroup < 0 { parts.append("Keine IOMMU-Gruppe – IOMMU ist nicht aktiv.") }
        if !groupMembers.isEmpty {
            parts.append("In derselben IOMMU-Gruppe: " + groupMembers.map { "\($0.id) (\($0.title))" }.joined(separator: ", ") + ". Diese Geräte stehen dem Host während des Betriebs der VM nicht zur Verfügung.")
        }
        if let driver, driver != "vfio-pci", sel.isGPU {
            parts.append("Der Host nutzt die GPU gerade mit „\(driver)“. Für stabiles Passthrough die GPU im Passthrough-Assistenten an vfio-pci binden.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private var optionsFooter: String {
        var text = "„PCI-Express“ benötigt den Maschinentyp Q35"
        text += isQ35 ? " (bereits gesetzt)." : " – er wird beim Speichern automatisch umgestellt."
        text += " Für GPUs wird UEFI (OVMF) empfohlen."
        if config["bios"] != "ovmf" { text += " Diese VM nutzt SeaBIOS." }
        text += " Die VM muss danach vollständig gestoppt und neu gestartet werden; Live-Migration und RAM-Snapshots sind mit durchgereichten Geräten nicht möglich."
        return text
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let d = try? client.pciDevices(node: guest.node)
        async let m = client.mappings("pci")
        async let c = try? client.passthroughCheck(node: guest.node)
        devices = await d ?? []
        mappings = await m
        check = await c

        if let key, let raw = config[key] {
            let p = PropertyString(raw)
            if let map = p["mapping"] {
                useMapping = true
                mapping = map
            } else {
                let host = p["host"] ?? p.positional ?? ""
                let full = host.contains(":") && host.split(separator: ":").count == 2 ? "0000:\(host)" : host
                allFunctions = !full.contains(".")
                selection = devices.first { $0.id == full || $0.slot == full }?.id ?? ""
            }
            primaryGPU = p["x-vga"] == "1"
            pcie = p["pcie"] == "1"
            rombar = p["rombar"] != "0"
        } else {
            pcie = true
        }
    }

    private func save() async throws {
        var p: PropertyString
        if useMapping {
            p = PropertyString(items: [("mapping", mapping)])
        } else {
            guard let sel = selected else { return }
            p = PropertyString(allFunctions ? sel.slot : sel.id)
        }
        p["pcie"] = pcie ? "1" : nil
        p["x-vga"] = primaryGPU ? "1" : nil
        p["rombar"] = rombar ? nil : "0"
        if let key, let raw = config[key] {
            // Weitere Optionen (romfile, mdev, …) behalten.
            for item in PropertyString(raw).items where !["", "host", "mapping", "pcie", "x-vga", "rombar"].contains(item.key) {
                p[item.key] = item.value
            }
        }
        var values: [(String, String)] = [(targetKey, p.raw)]
        if pcie && !isQ35 { values.append(("machine", "q35")) }
        try await client.updateConfig(guest, set: values)
        onSave(true)
    }
}

// MARK: - USB (VM)

struct USBPassthroughEditor: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let config: GuestConfig
    let key: String?
    let onSave: (Bool) -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case device, port, mapping, spice
        var id: String { rawValue }
        var title: String {
            switch self {
            case .device: "Gerät"
            case .port: "Port"
            case .mapping: "Zuordnung"
            case .spice: "SPICE"
            }
        }
    }

    @State private var devices: [USBDevice] = []
    @State private var mappings: [String] = []
    @State private var mode: Mode = .device
    @State private var selection = ""
    @State private var mapping = ""
    @State private var usb3 = true
    @State private var loading = true

    private var targetKey: String { key ?? "usb\(config.nextIndex(prefix: "usb", limit: 13))" }
    private var selected: USBDevice? { devices.first { $0.id == selection } }

    var body: some View {
        EditorForm(title: key == nil ? "USB-Gerät durchreichen" : targetKey,
                   saveTitle: key == nil ? "Hinzufügen" : "Sichern",
                   canSave: canSave, save: save) {
            Section {
                Picker("Art", selection: $mode) {
                    ForEach(Mode.allCases.filter { $0 != .mapping || !mappings.isEmpty }) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(modeFooter)
            }

            switch mode {
            case .device, .port:
                Section("Angeschlossene Geräte") {
                    if loading { ProgressView() }
                    if !loading && devices.isEmpty { Text("Keine USB-Geräte gefunden.").foregroundStyle(.secondary) }
                    ForEach(devices) { dev in
                        Button {
                            selection = dev.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dev.title).font(.subheadline.weight(.medium))
                                    Text("ID \(dev.deviceID) · Port \(dev.portID)\(dev.speed.map { " · \($0) Mbit/s" } ?? "")")
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection == dev.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            case .mapping:
                Section {
                    Picker("Zuordnung", selection: $mapping) {
                        Text("Bitte wählen").tag("")
                        ForEach(mappings, id: \.self) { Text($0).tag($0) }
                    }
                }
            case .spice:
                EmptyView()
            }

            Section {
                Toggle("USB 3", isOn: $usb3)
            } footer: {
                Text("USB-Geräte lassen sich auch bei laufender VM hinzufügen und entfernen.")
            }
        }
        .task { await load() }
    }

    private var canSave: Bool {
        switch mode {
        case .device, .port: selected != nil
        case .mapping: !mapping.isEmpty
        case .spice: true
        }
    }

    private var modeFooter: String {
        switch mode {
        case .device: "Das Gerät wird an der Hersteller-/Produkt-ID erkannt – egal, an welchem Port es steckt."
        case .port: "Alles, was an diesem physischen Port steckt, wird durchgereicht (gut bei mehreren gleichen Geräten)."
        case .mapping: "Cluster-weite Zuordnung (Datacenter → Ressourcen-Zuordnungen)."
        case .spice: "Für USB-Weiterleitung über einen SPICE-Client."
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        devices = (try? await client.usbDevices(node: guest.node)) ?? []
        mappings = await client.mappings("usb")
        guard let key, let raw = config[key] else { return }
        let p = PropertyString(raw)
        usb3 = p["usb3"] == "1"
        if let map = p["mapping"] {
            mode = .mapping; mapping = map
        } else if let host = p["host"] ?? p.positional {
            if host == "spice" {
                mode = .spice
            } else if host.contains(":") {
                mode = .device
                selection = devices.first { $0.deviceID == host.lowercased() }?.id ?? ""
            } else {
                mode = .port
                selection = devices.first { $0.portID == host }?.id ?? ""
            }
        }
    }

    private func save() async throws {
        var p: PropertyString
        switch mode {
        case .device: p = PropertyString(items: [("host", selected?.deviceID ?? "")])
        case .port: p = PropertyString(items: [("host", selected?.portID ?? "")])
        case .mapping: p = PropertyString(items: [("mapping", mapping)])
        case .spice: p = PropertyString(items: [("host", "spice")])
        }
        p["usb3"] = usb3 ? "1" : nil
        try await client.updateConfig(guest, set: [(targetKey, p.raw)])
        onSave(false)
    }
}

// MARK: - Geräte für Container

struct LXCDeviceEditor: View {
    let client: PVEClient
    let guest: ProxmoxGuest
    let config: GuestConfig
    let key: String?
    let onSave: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var nodes: [String] = []
    @State private var path = ""
    @State private var gid = ""
    @State private var uid = ""
    @State private var mode = ""
    @State private var loading = true

    struct Preset: Identifiable {
        let id: String
        let title: String
        let devices: [(path: String, gid: String)]
    }

    static let presets: [Preset] = [
        Preset(id: "igpu", title: "Intel/AMD-GPU (Transcoding, z. B. Jellyfin/Plex)",
               devices: [("/dev/dri/renderD128", "104"), ("/dev/dri/card0", "44")]),
        Preset(id: "tun", title: "TUN/TAP (VPN, z. B. WireGuard/Tailscale)", devices: [("/dev/net/tun", "")]),
    ]

    private var existingPaths: Set<String> {
        Set(config.values.filter { $0.key.hasPrefix("dev") }.compactMap { PropertyString($0.value).positional })
    }

    var body: some View {
        EditorForm(title: key == nil ? "Gerät durchreichen" : (key ?? ""),
                   saveTitle: key == nil ? "Hinzufügen" : "Sichern",
                   canSave: path.hasPrefix("/dev/"), save: save) {
            if key == nil {
                Section {
                    ForEach(Self.presets) { preset in
                        Button {
                            Task { await applyPreset(preset) }
                        } label: {
                            Label(preset.title, systemImage: preset.id == "tun" ? "lock.shield" : "display")
                        }
                    }
                } header: {
                    Text("Schnellauswahl")
                } footer: {
                    Text("Fügt die benötigten Geräte mit passenden Gruppen-IDs (render=104, video=44 bei Debian/Ubuntu) hinzu.")
                }
            }

            Section {
                if loading { ProgressView() }
                Picker("Gerät auf dem Host", selection: $path) {
                    Text("Bitte wählen").tag("")
                    ForEach(nodes, id: \.self) { node in
                        Text(node + (existingPaths.contains(node) ? " ✓" : "")).tag(node)
                    }
                    if !path.isEmpty && !nodes.contains(path) { Text(path).tag(path) }
                }
                .pickerStyle(.navigationLink)
                TextField("oder Pfad eingeben, z. B. /dev/ttyUSB0", text: $path)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Gerät")
            } footer: {
                Text("Für USB-Sticks (Zigbee, Z-Wave) am besten den stabilen Pfad unter /dev/serial/by-id/ wählen.")
            }

            Section {
                TextField("Gruppen-ID im Container (optional)", text: $gid).keyboardType(.numberPad)
                TextField("Benutzer-ID im Container (optional)", text: $uid).keyboardType(.numberPad)
                TextField("Rechte, z. B. 0666 (optional)", text: $mode).keyboardType(.numberPad)
            } header: {
                Text("Zugriff")
            } footer: {
                Text("Das Durchreichen von Geräten über dev0, dev1 … benötigt Proxmox VE 8.1 oder neuer. Der Container muss danach neu gestartet werden.")
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        nodes = (try? await client.hostDeviceNodes(node: guest.node)) ?? []
        guard let key, let raw = config[key] else { return }
        let p = PropertyString(raw)
        path = p["path"] ?? p.positional ?? ""
        gid = p["gid"] ?? ""
        uid = p["uid"] ?? ""
        mode = p["mode"] ?? ""
    }

    private func value(path: String, gid: String, uid: String, mode: String) -> String {
        var p = PropertyString(path)
        p["gid"] = gid.filter(\.isNumber)
        p["uid"] = uid.filter(\.isNumber)
        p["mode"] = mode.filter(\.isNumber)
        return p.raw
    }

    private func save() async throws {
        let target = key ?? "dev\(config.nextIndex(prefix: "dev", limit: 255))"
        try await client.updateConfig(guest, set: [(target, value(path: path, gid: gid, uid: uid, mode: mode))])
        onSave(true)
    }

    private func applyPreset(_ preset: Preset) async {
        var used = Set(config.values.keys)
        var values: [(String, String)] = []
        for device in preset.devices where !existingPaths.contains(device.path) {
            // Nur Geräte übernehmen, die es auf dem Host gibt.
            if !nodes.isEmpty && !nodes.contains(device.path) { continue }
            let index = (0...255).first { !used.contains("dev\($0)") } ?? 0
            used.insert("dev\(index)")
            values.append(("dev\(index)", value(path: device.path, gid: device.gid, uid: "", mode: "")))
        }
        guard !values.isEmpty else {
            path = preset.devices.first?.path ?? ""
            return
        }
        do {
            try await client.updateConfig(guest, set: values)
            onSave(true)
            dismiss()
        } catch {
            path = preset.devices.first?.path ?? ""
        }
    }
}
