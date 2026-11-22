import SwiftUI

/// Übersicht eines Proxmox-Hosts/Clusters: Nodes, Ressourcen, Gäste, Storage.
struct NodeDashboardView: View {
    let hostID: UUID

    @EnvironmentObject private var hosts: HostStore
    @StateObject private var runner = ActionRunner()

    @State private var nodes: [PVENode] = []
    @State private var statuses: [String: NodeStatus] = [:]
    @State private var guests: [ProxmoxGuest] = []
    @State private var storages: [String: [PVEStorage]] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var pendingKey: PendingHostKey?
    @State private var session: TerminalSession?
    @State private var editingHost = false
    @State private var creating: GuestKind?
    @State private var filter: Filter = .all
    @State private var search = ""

    enum Filter: String, CaseIterable, Identifiable {
        case all, running, vms, cts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Alle"
            case .running: "Laufend"
            case .vms: "VMs"
            case .cts: "CTs"
            }
        }
    }

    private var host: ProxmoxHost? { hosts.host(id: hostID) }

    private var filteredGuests: [ProxmoxGuest] {
        guests.filter { guest in
            switch filter {
            case .all: break
            case .running: if !guest.isRunning { return false }
            case .vms: if guest.kind != .qemu { return false }
            case .cts: if guest.kind != .lxc { return false }
            }
            guard !search.isEmpty else { return true }
            return guest.displayName.localizedCaseInsensitiveContains(search)
                || String(guest.vmid).contains(search)
                || guest.tagList.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        Group {
            if let host {
                list(host)
            } else {
                ContentUnavailableView("Host gelöscht", systemImage: "trash")
            }
        }
        .navigationTitle(host?.displayName ?? "Host")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Gast suchen (Name, ID, Tag)")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Neue VM", systemImage: "desktopcomputer") { creating = .qemu }
                    Button("Neuer Container", systemImage: "shippingbox") { creating = .lxc }
                    Divider()
                    Button("Host bearbeiten", systemImage: "pencil") { editingHost = true }
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
        }
        .navigationDestination(for: ProxmoxGuest.self) { guest in
            GuestDetailView(hostID: hostID, guest: guest)
        }
        .sheet(isPresented: $editingHost) {
            if let host { HostEditView(host: host) }
        }
        .sheet(item: $creating) { kind in
            if let host {
                CreateGuestView(host: host, kind: kind, nodes: nodes.filter(\.isOnline).map(\.node)) {
                    Task { await load() }
                }
            }
        }
        .fullScreenCover(item: $session) { TerminalScreen(session: $0) }
        .task(id: hostID) {
            await load()
            // Ressourcen alle 10 Sekunden aktualisieren, solange die Ansicht offen ist.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                await load(silent: true)
            }
        }
        .refreshable { await load() }
        .hostKeyAlert($pendingKey) { key in
            hosts.trustHostKey(key, for: hostID)
            Task {
                await SSHPool.shared.drop(hostID)
                await load()
            }
        }
        .actionRunner(runner)
    }

    @ViewBuilder
    private func list(_ host: ProxmoxHost) -> some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            ForEach(nodes) { node in
                Section {
                    nodeSummary(node)
                } header: {
                    HStack {
                        StatusDot(running: node.isOnline)
                        Text("Node \(node.node)")
                        Spacer()
                        if loading { ProgressView().controlSize(.mini) }
                    }
                }
            }

            Section("Werkzeuge") {
                Button {
                    openTerminal(host, title: "Shell – \(host.displayName)", command: nil)
                } label: {
                    Label("Shell öffnen", systemImage: "terminal")
                }
                Button {
                    openTerminal(host, title: "Updates – \(host.displayName)", command: "apt update && apt -y dist-upgrade")
                } label: {
                    Label("Host aktualisieren", systemImage: "arrow.down.circle")
                }
                NavigationLink {
                    TasksView(host: host)
                } label: {
                    Label("Aufgaben (Tasks)", systemImage: "list.bullet.rectangle")
                }
                ForEach(nodes.filter(\.isOnline)) { node in
                    NavigationLink {
                        HostPassthroughView(host: host, node: node.node)
                    } label: {
                        Label(nodes.count > 1 ? "PCI/GPU-Passthrough (\(node.node))" : "PCI/GPU-Passthrough", systemImage: "checkmark.shield")
                    }
                }
            }

            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if guests.isEmpty && !loading && error == nil {
                    Text("Keine Container oder VMs vorhanden.").foregroundStyle(.secondary)
                }
                ForEach(filteredGuests) { guest in
                    NavigationLink(value: guest) {
                        GuestRow(guest: guest)
                    }
                    .swipeActions(edge: .trailing) {
                        if !guest.isTemplate {
                            if guest.isRunning {
                                Button("Stopp") { act(.shutdown, guest, host) }.tint(.red)
                            } else {
                                Button("Start") { act(.start, guest, host) }.tint(.green)
                            }
                        }
                    }
                    .contextMenu { quickActions(guest, host) }
                }
            } header: {
                Text("Gäste (\(guests.count))")
            }

            ForEach(nodes.filter { storages[$0.node] != nil }) { node in
                Section("Storage – \(node.node)") {
                    ForEach(storages[node.node] ?? []) { storage in
                        UsageBar(
                            title: storage.storage,
                            fraction: storage.usage,
                            detail: "\(Fmt.bytes(storage.used)) / \(Fmt.bytes(storage.total))",
                            symbol: storage.shared == 1 ? "externaldrive.connected.to.line.below" : "internaldrive"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func nodeSummary(_ node: PVENode) -> some View {
        if node.isOnline, let host {
            NavigationLink {
                MetricsView(client: PVEClient(host: host), scope: .node(node.node))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Verlauf (CPU, RAM, Netz, Disk)", systemImage: "chart.xyaxis.line")
                    MetricSparkline(client: PVEClient(host: host), scope: .node(node.node))
                }
            }
        }
        if let status = statuses[node.node] {
            UsageBar(title: "CPU", fraction: status.cpu,
                     detail: "\(Fmt.percent(status.cpu)) von \(status.cpus) Threads", symbol: "cpu")
            UsageBar(title: "RAM", fraction: status.memTotal > 0 ? status.memUsed / status.memTotal : nil,
                     detail: "\(Fmt.bytes(status.memUsed)) / \(Fmt.bytes(status.memTotal))", symbol: "memorychip")
            UsageBar(title: "Root-Disk", fraction: status.rootTotal > 0 ? status.rootUsed / status.rootTotal : nil,
                     detail: "\(Fmt.bytes(status.rootUsed)) / \(Fmt.bytes(status.rootTotal))", symbol: "internaldrive")
            if status.swapTotal > 0 {
                UsageBar(title: "Swap", fraction: status.swapUsed / status.swapTotal,
                         detail: "\(Fmt.bytes(status.swapUsed)) / \(Fmt.bytes(status.swapTotal))", symbol: "arrow.left.arrow.right")
            }
            LabeledContent("Laufzeit", value: Fmt.uptime(status.uptime))
            if !status.loadavg.isEmpty {
                LabeledContent("Load", value: status.loadavg.joined(separator: " · "))
            }
            if !status.pveVersion.isEmpty {
                LabeledContent("Version") {
                    Text(status.pveVersion).font(.caption).multilineTextAlignment(.trailing)
                }
            }
            if !status.cpuModel.isEmpty {
                LabeledContent("CPU-Modell") {
                    Text(status.cpuModel).font(.caption).multilineTextAlignment(.trailing)
                }
            }
        } else if node.isOnline {
            UsageBar(title: "CPU", fraction: node.cpu, detail: Fmt.percent(node.cpu), symbol: "cpu")
            UsageBar(title: "RAM", fraction: (node.maxmem ?? 0) > 0 ? (node.mem ?? 0) / node.maxmem! : nil,
                     detail: "\(Fmt.bytes(node.mem)) / \(Fmt.bytes(node.maxmem))", symbol: "memorychip")
        } else {
            Text("Node ist offline").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func quickActions(_ guest: ProxmoxGuest, _ host: ProxmoxHost) -> some View {
        if guest.isRunning {
            Button("Neu starten", systemImage: "arrow.clockwise") { act(.reboot, guest, host) }
            Button("Herunterfahren", systemImage: "power") { act(.shutdown, guest, host) }
            Button("Stoppen (hart)", systemImage: "stop.fill", role: .destructive) { act(.stop, guest, host) }
        } else if !guest.isTemplate {
            Button("Starten", systemImage: "play.fill") { act(.start, guest, host) }
        }
    }

    private func openTerminal(_ host: ProxmoxHost, title: String, command: String?) {
        session = makeTerminalSession(host: host, title: title, command: command, hosts: hosts)
    }

    private func act(_ action: GuestAction, _ guest: ProxmoxGuest, _ host: ProxmoxHost) {
        let client = PVEClient(host: host)
        runner.run("\(guest.displayName): \(action.title) …") {
            let upid = try await client.perform(action, on: guest)
            try await client.wait(upid, timeout: 180)
            await load(silent: true)
        }
    }

    private func load(silent: Bool = false) async {
        guard let host else { return }
        let client = PVEClient(host: host)
        if !silent { loading = true }
        defer { loading = false }
        do {
            async let nodeList = client.nodes()
            async let guestList = client.guests()
            let (n, g) = try await (nodeList, guestList)
            nodes = n
            guests = g
            error = nil
            for node in n where node.isOnline {
                if let status = try? await client.nodeStatus(node.node) { statuses[node.node] = status }
                if !silent, let list = try? await client.storages(node: node.node) { storages[node.node] = list }
            }
        } catch SSHConnectError.unknownHostKey(let key, let fp) {
            pendingKey = PendingHostKey(key: key, fingerprint: fp, changed: false)
        } catch SSHConnectError.hostKeyMismatch(let key, let fp) {
            pendingKey = PendingHostKey(key: key, fingerprint: fp, changed: true)
            error = "Der Host-Schlüssel hat sich geändert."
        } catch {
            if !silent || self.error != nil { self.error = error.localizedDescription }
        }
    }
}

extension GuestKind: Identifiable {
    var id: String { rawValue }
}

struct GuestRow: View {
    let guest: ProxmoxGuest

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: guest.isTemplate ? "doc.on.doc" : guest.kind.symbol)
                    .font(.title3)
                    .foregroundStyle(guest.isRunning ? Color.accentColor : .secondary)
                    .frame(width: 32, height: 32)
                StatusDot(running: guest.isRunning)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(guest.displayName).font(.body.weight(.medium)).lineLimit(1)
                    if guest.isCommunityScript { Badge(text: "CS", color: .teal) }
                    if guest.isTemplate { Badge(text: "Vorlage", color: .gray) }
                    if let lock = guest.lock { Badge(text: lock, color: .orange) }
                }
                HStack(spacing: 8) {
                    Text("\(guest.kind.title) \(guest.vmid)")
                    Text(guest.node)
                    if guest.isRunning {
                        Text("CPU \(Fmt.percent(guest.cpu))")
                        if let max = guest.maxmem, max > 0 {
                            Text("RAM \(Int((guest.mem ?? 0) / max * 100)) %")
                        }
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}
