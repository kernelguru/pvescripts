import SwiftUI

/// Zeigt das Log eines laufenden Tasks live an (Backup, Klonen, Erstellen …).
struct TaskLogView: View {
    let client: PVEClient
    let upid: String
    let title: String
    var onFinished: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var running = true
    @State private var exitStatus: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(10)
                }
                .background(Color.black)
                .onChange(of: lines.count) {
                    if let last = lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    if running {
                        ProgressView().controlSize(.small)
                        Text("Läuft …")
                    } else if exitStatus == "OK" {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Erfolgreich abgeschlossen")
                    } else {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        Text(exitStatus ?? error ?? "Fehlgeschlagen").lineLimit(2)
                    }
                    Spacer()
                }
                .font(.callout.weight(.medium))
                .padding(12)
                .background(.bar)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(running ? "Im Hintergrund" : "Fertig") { dismiss() }
                }
                if running {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen", role: .destructive) {
                            Task { try? await client.delete("/nodes/\(PVEClient.node(ofUPID: upid) ?? "")/tasks/\(upid)") }
                        }
                    }
                }
            }
            .task { await poll() }
            .onDisappear { onFinished?() }
        }
        .preferredColorScheme(.dark)
    }

    private func poll() async {
        while !Task.isCancelled {
            do {
                let log = try await client.taskLog(upid, start: lines.count)
                if !log.isEmpty && !(log.count == 1 && log[0] == "no content") {
                    lines.append(contentsOf: log)
                }
                let status = try await client.taskStatus(upid)
                if !status.running {
                    // Letzte Zeilen nachladen.
                    let rest = (try? await client.taskLog(upid, start: lines.count)) ?? []
                    lines.append(contentsOf: rest.filter { $0 != "no content" })
                    running = false
                    exitStatus = status.exitStatus
                    return
                }
            } catch {
                self.error = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
}

/// Letzte Aufgaben im Cluster.
struct TasksView: View {
    let host: ProxmoxHost

    @State private var tasks: [PVETask] = []
    @State private var error: String?
    @State private var selected: TaskRef?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(tasks) { task in
                Button {
                    selected = TaskRef(upid: task.upid, title: task.title)
                } label: {
                    HStack(spacing: 10) {
                        Group {
                            if task.isRunning {
                                ProgressView().controlSize(.small)
                            } else if task.isOK {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                        }
                        .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).font(.subheadline.weight(.medium))
                            HStack(spacing: 6) {
                                Text(task.node)
                                if let user = task.user { Text(user) }
                                if let start = task.start { Text(start, style: .relative) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            if !task.isRunning && !task.isOK, let status = task.status {
                                Text(status).font(.caption).foregroundStyle(.orange).lineLimit(2)
                            }
                        }
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions {
                    if task.isRunning {
                        Button("Stoppen", role: .destructive) { stop(task) }
                    }
                }
            }
        }
        .navigationTitle("Aufgaben")
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $selected) { ref in
            TaskLogView(client: PVEClient(host: host), upid: ref.upid, title: ref.title)
        }
    }

    private func stop(_ task: PVETask) {
        Task {
            do {
                try await PVEClient(host: host).delete("/nodes/\(task.node)/tasks/\(task.upid)")
                try? await Task.sleep(for: .seconds(1))
            } catch {
                self.error = error.localizedDescription
            }
            await load()
        }
    }

    private func load() async {
        do {
            tasks = try await PVEClient(host: host).recentTasks()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Snapshots eines Gastes: anlegen, zurückrollen, löschen.
struct SnapshotsView: View {
    let client: PVEClient
    let guest: ProxmoxGuest

    @StateObject private var runner = ActionRunner()
    @State private var snapshots: [GuestSnapshot] = []
    @State private var loading = true
    @State private var creating = false
    @State private var newName = ""
    @State private var newDescription = ""
    @State private var includeRAM = false
    @State private var rollbackTarget: GuestSnapshot?

    var body: some View {
        List {
            Section {
                Button("Snapshot erstellen", systemImage: "camera") {
                    newName = "snap-\(Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))"
                    newDescription = ""
                    creating = true
                }
            }
            Section {
                if loading && snapshots.isEmpty { ProgressView() }
                ForEach(snapshots.filter { !$0.isCurrent }) { snap in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(snap.name).font(.body.weight(.medium))
                            if snap.vmstate == 1 { Badge(text: "RAM", color: .purple) }
                        }
                        if let date = snap.date {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let desc = snap.description, !desc.isEmpty {
                            Text(desc).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Löschen", role: .destructive) { delete(snap) }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Rollback") { rollbackTarget = snap }.tint(.orange)
                    }
                    .contextMenu {
                        Button("Zurückrollen", systemImage: "arrow.uturn.backward") { rollbackTarget = snap }
                        Button("Löschen", systemImage: "trash", role: .destructive) { delete(snap) }
                    }
                }
                if !loading && snapshots.filter({ !$0.isCurrent }).isEmpty {
                    Text("Noch keine Snapshots.").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Wische nach rechts zum Zurückrollen, nach links zum Löschen. Snapshots benötigen einen Storage mit Snapshot-Unterstützung (z. B. LVM-thin, ZFS, Ceph, qcow2).")
            }
        }
        .navigationTitle("Snapshots")
        .refreshable { await load() }
        .task { await load() }
        .alert("Snapshot erstellen", isPresented: $creating) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Beschreibung", text: $newDescription)
            Button("Erstellen") { create(withRAM: false) }
            if guest.kind == .qemu && guest.isRunning {
                Button("Mit RAM-Inhalt erstellen") { create(withRAM: true) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Nur Buchstaben, Ziffern, - und _ erlaubt.")
        }
        .confirmationDialog("Auf „\(rollbackTarget?.name ?? "")“ zurückrollen?", isPresented: Binding(get: { rollbackTarget != nil }, set: { if !$0 { rollbackTarget = nil } }), titleVisibility: .visible) {
            Button("Zurückrollen", role: .destructive) {
                if let snap = rollbackTarget { rollback(snap) }
            }
        } message: {
            Text("Alle Änderungen seit diesem Snapshot gehen verloren.")
        }
        .actionRunner(runner)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            snapshots = try await client.snapshots(guest)
        } catch {
            runner.error = error.localizedDescription
        }
    }

    private func create(withRAM: Bool) {
        let name = newName.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard let first = name.first, first.isLetter else {
            runner.error = "Der Name muss mit einem Buchstaben beginnen."
            return
        }
        var params: [(String, String)] = [("snapname", name)]
        if !newDescription.isEmpty { params.append(("description", newDescription)) }
        if withRAM { params.append(("vmstate", "1")) }
        runner.run("Snapshot wird erstellt …") {
            let upid = try await client.create("\(guest.apiPath)/snapshot", params)
            try await client.wait(upid, timeout: 1800)
            await load()
        }
    }

    private func rollback(_ snap: GuestSnapshot) {
        runner.run("Rollback läuft …", success: "Auf „\(snap.name)“ zurückgerollt.") {
            let upid = try await client.create("\(guest.apiPath)/snapshot/\(snap.name)/rollback")
            try await client.wait(upid, timeout: 1800)
            await load()
        }
    }

    private func delete(_ snap: GuestSnapshot) {
        runner.run("Snapshot wird gelöscht …") {
            let upid = try await client.delete("\(guest.apiPath)/snapshot/\(snap.name)")
            try await client.wait(upid, timeout: 1800)
            await load()
        }
    }
}
