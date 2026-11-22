import Foundation
import Citadel
import NIOCore

/// Hält pro Host eine SSH-Verbindung offen, damit API-Aufrufe schnell sind.
actor SSHPool {
    static let shared = SSHPool()

    private var clients: [UUID: SSHClient] = [:]
    private var nodeNames: [UUID: String] = [:]

    func client(for host: ProxmoxHost) async throws -> SSHClient {
        if let client = clients[host.id], client.isConnected { return client }
        let client = try await SSHConnector.connect(to: host, credentials: HostCredentials.load(for: host.id))
        clients[host.id] = client
        return client
    }

    func drop(_ hostID: UUID) {
        if let client = clients.removeValue(forKey: hostID) {
            Task { try? await client.close() }
        }
    }

    func cachedNodeName(_ hostID: UUID) -> String? { nodeNames[hostID] }
    func setNodeName(_ name: String, for hostID: UUID) { nodeNames[hostID] = name }
}

struct PVEError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Zugriff auf die Proxmox-API über `pvesh` per SSH – funktioniert clusterweit
/// ohne API-Token und mit denselben Rechten wie in der Web-Oberfläche als root.
struct PVEClient {
    let host: ProxmoxHost

    // MARK: Low level

    /// Führt einen Befehl aus und liefert stdout. Bei Exit-Code ≠ 0 wird stderr als Fehler geworfen.
    func run(_ command: String, retry: Bool = true) async throws -> String {
        let client = try await SSHPool.shared.client(for: host)
        var stdout = ByteBuffer()
        var stderr = ByteBuffer()
        do {
            let stream = try await client.executeCommandStream(command)
            for try await chunk in stream {
                switch chunk {
                case .stdout(var buffer): stdout.writeBuffer(&buffer)
                case .stderr(var buffer): stderr.writeBuffer(&buffer)
                }
            }
        } catch let failed as SSHClient.CommandFailed {
            let message = String(buffer: stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let out = String(buffer: stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            throw PVEError(message: Self.cleanError(message.isEmpty ? out : message, code: failed.exitCode))
        } catch let error as SSHConnectError {
            throw error
        } catch {
            // Verbindung evtl. abgelaufen – einmal mit neuer Verbindung probieren.
            await SSHPool.shared.drop(host.id)
            if retry { return try await run(command, retry: false) }
            throw PVEError(message: SSHConnector.readable(error))
        }
        return String(buffer: stdout)
    }

    private static func cleanError(_ text: String, code: Int) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let relevant = lines.filter { !$0.hasPrefix("Use of uninitialized") }
        if relevant.isEmpty { return "Befehl fehlgeschlagen (Exit-Code \(code))." }
        return relevant.suffix(4).joined(separator: "\n")
    }

    private func pvesh(_ method: String, _ path: String, _ params: [(String, String)]) -> String {
        var parts = ["pvesh", method, CommandBuilder.shellQuote(path)]
        for (key, value) in params {
            parts.append("--\(key)")
            parts.append(CommandBuilder.shellQuote(value))
        }
        parts.append("--output-format")
        parts.append("json")
        return parts.joined(separator: " ")
    }

    func getJSON(_ path: String, _ params: [(String, String)] = []) async throws -> JSONValue {
        let output = try await run(pvesh("get", path, params))
        return try Self.decode(JSONValue.self, from: output)
    }

    func get<T: Decodable>(_ path: String, _ params: [(String, String)] = [], as type: T.Type = T.self) async throws -> T {
        let output = try await run(pvesh("get", path, params))
        return try Self.decode(T.self, from: output)
    }

    /// POST – liefert bei asynchronen Aktionen die UPID des Tasks.
    @discardableResult
    func create(_ path: String, _ params: [(String, String)] = []) async throws -> String? {
        Self.extractUPID(try await run(pvesh("create", path, params)))
    }

    /// PUT
    @discardableResult
    func set(_ path: String, _ params: [(String, String)] = []) async throws -> String? {
        Self.extractUPID(try await run(pvesh("set", path, params)))
    }

    /// DELETE
    @discardableResult
    func delete(_ path: String, _ params: [(String, String)] = []) async throws -> String? {
        Self.extractUPID(try await run(pvesh("delete", path, params)))
    }

    static func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Eventuelle Warnungen vor dem JSON überspringen.
        let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" || $0 == "\"" }) ?? trimmed.startIndex
        let json = String(trimmed[start...])
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            if json.isEmpty || json == "null", let empty = try? JSONDecoder().decode(T.self, from: Data("[]".utf8)) {
                return empty
            }
            throw PVEError(message: "Unerwartete Antwort vom Host: \(json.prefix(200))")
        }
    }

    static func extractUPID(_ output: String) -> String? {
        guard let range = output.range(of: "UPID:[^\"\\s]+", options: .regularExpression) else { return nil }
        return String(output[range])
    }

    static func node(ofUPID upid: String) -> String? {
        let parts = upid.split(separator: ":")
        return parts.count > 1 ? String(parts[1]) : nil
    }

    // MARK: Tasks

    struct TaskStatus {
        var running: Bool
        var exitStatus: String?
        var ok: Bool { exitStatus == "OK" || (exitStatus?.hasPrefix("WARNINGS") ?? false) }
    }

    func taskStatus(_ upid: String) async throws -> TaskStatus {
        let node = Self.node(ofUPID: upid) ?? ""
        let json = try await getJSON("/nodes/\(node)/tasks/\(upid)/status")
        return TaskStatus(running: json["status"]?.stringValue == "running", exitStatus: json["exitstatus"]?.stringValue)
    }

    func taskLog(_ upid: String, start: Int = 0) async throws -> [String] {
        let node = Self.node(ofUPID: upid) ?? ""
        let json = try await getJSON("/nodes/\(node)/tasks/\(upid)/log", [("start", String(start)), ("limit", "5000")])
        return json.arrayValue.compactMap { $0["t"]?.stringValue }
    }

    /// Wartet auf das Ende eines Tasks und wirft bei Fehlern.
    func wait(_ upid: String?, timeout: TimeInterval = 600) async throws {
        guard let upid else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = try await taskStatus(upid)
            if !status.running {
                if status.ok { return }
                throw PVEError(message: status.exitStatus ?? "Task fehlgeschlagen")
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw PVEError(message: "Zeitüberschreitung beim Warten auf den Task.")
    }

    func recentTasks(limit: Int = 50) async throws -> [PVETask] {
        let tasks: [PVETask] = try await get("/cluster/tasks")
        return Array(tasks.sorted { ($0.starttime ?? 0) > ($1.starttime ?? 0) }.prefix(limit))
    }

    // MARK: Cluster & Nodes

    /// Verbindungstest mit (noch nicht gespeicherten) Zugangsdaten.
    static func testConnection(host: ProxmoxHost, credentials: HostCredentials) async throws -> String {
        let client = try await SSHConnector.connect(to: host, credentials: credentials)
        defer { Task { try? await client.close() } }
        let buffer = try await client.executeCommand("pveversion 2>/dev/null || uname -sr", mergeStreams: true)
        return String(buffer: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hostInfo() async throws -> String {
        try await run("pveversion 2>/dev/null || uname -sr").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Name des Nodes, mit dem die SSH-Verbindung besteht.
    func localNodeName() async throws -> String {
        if let cached = await SSHPool.shared.cachedNodeName(host.id) { return cached }
        let name = try await run("hostname").trimmingCharacters(in: .whitespacesAndNewlines)
        await SSHPool.shared.setNodeName(name, for: host.id)
        return name
    }

    func nodes() async throws -> [PVENode] {
        let nodes: [PVENode] = try await get("/nodes")
        return nodes.sorted { $0.node < $1.node }
    }

    func nodeStatus(_ node: String) async throws -> NodeStatus {
        NodeStatus(json: try await getJSON("/nodes/\(node)/status"))
    }

    func guests() async throws -> [ProxmoxGuest] {
        let guests: [ProxmoxGuest] = try await get("/cluster/resources", [("type", "vm")])
        return guests.sorted { $0.vmid < $1.vmid }
    }

    func storages(node: String, content: String? = nil) async throws -> [PVEStorage] {
        var params: [(String, String)] = []
        if let content { params.append(("content", content)) }
        let list: [PVEStorage] = try await get("/nodes/\(node)/storage", params)
        return list.filter { ($0.enabled ?? 1) == 1 }.sorted { $0.storage < $1.storage }
    }

    func storageContent(node: String, storage: String, content: String) async throws -> [StorageItem] {
        let items: [StorageItem] = try await get("/nodes/\(node)/storage/\(storage)/content", [("content", content)])
        return items.sorted { $0.volid.localizedStandardCompare($1.volid) == .orderedAscending }
    }

    func bridges(node: String) async throws -> [NetworkBridge] {
        let list: [NetworkBridge] = try await get("/nodes/\(node)/network", [("type", "any_bridge")])
        return list.sorted { $0.iface < $1.iface }
    }

    func nextID() async throws -> Int {
        let json = try await getJSON("/cluster/nextid")
        guard let id = json.doubleValue else { throw PVEError(message: "Keine freie ID gefunden.") }
        return Int(id)
    }

    func applianceTemplates(node: String) async throws -> [ApplianceTemplate] {
        let list: [ApplianceTemplate] = try await get("/nodes/\(node)/aplinfo")
        return list.sorted { $0.template < $1.template }
    }

    // MARK: Guests

    func status(_ guest: ProxmoxGuest) async throws -> GuestStatus {
        try await get("\(guest.apiPath)/status/current")
    }

    func config(_ guest: ProxmoxGuest) async throws -> GuestConfig {
        GuestConfig(json: try await getJSON("\(guest.apiPath)/config"))
    }

    @discardableResult
    func perform(_ action: GuestAction, on guest: ProxmoxGuest) async throws -> String? {
        try await create("\(guest.apiPath)/status/\(action.rawValue)")
    }

    /// Setzt Config-Werte; leere Werte werden gelöscht.
    func updateConfig(_ guest: ProxmoxGuest, set values: [(String, String)], delete: [String] = []) async throws {
        var params = values.filter { !$0.1.isEmpty }
        let deletions = delete + values.filter { $0.1.isEmpty }.map(\.0)
        if !deletions.isEmpty { params.append(("delete", deletions.joined(separator: ","))) }
        guard !params.isEmpty else { return }
        let upid = try await set("\(guest.apiPath)/config", params)
        try await wait(upid)
    }

    func resizeDisk(_ guest: ProxmoxGuest, disk: String, addGB: Int) async throws {
        let upid = try await set("\(guest.apiPath)/resize", [("disk", disk), ("size", "+\(addGB)G")])
        try await wait(upid)
    }

    func destroy(_ guest: ProxmoxGuest, purge: Bool) async throws -> String? {
        var params: [(String, String)] = [("destroy-unreferenced-disks", "1")]
        if purge { params.append(("purge", "1")) }
        return try await delete(guest.apiPath, params)
    }

    func clone(_ guest: ProxmoxGuest, newID: Int, name: String, full: Bool) async throws -> String? {
        var params: [(String, String)] = [("newid", String(newID))]
        if guest.kind == .qemu {
            if !name.isEmpty { params.append(("name", name)) }
        } else if !name.isEmpty {
            params.append(("hostname", name))
        }
        params.append(("full", full ? "1" : "0"))
        return try await create("\(guest.apiPath)/clone", params)
    }

    func snapshots(_ guest: ProxmoxGuest) async throws -> [GuestSnapshot] {
        let list: [GuestSnapshot] = try await get("\(guest.apiPath)/snapshot")
        return list.sorted { ($0.snaptime ?? .greatestFiniteMagnitude) > ($1.snaptime ?? .greatestFiniteMagnitude) }
    }

    /// IP-Adressen über den QEMU-Agent (VM) bzw. /interfaces (LXC).
    func addresses(_ guest: ProxmoxGuest) async throws -> [GuestAddress] {
        var result: [GuestAddress] = []
        if guest.kind == .qemu {
            let json = try await getJSON("\(guest.apiPath)/agent/network-get-interfaces")
            let interfaces = (json["result"] ?? json).arrayValue
            for iface in interfaces {
                let name = iface["name"]?.stringValue ?? "?"
                if name == "lo" || name.hasPrefix("Loopback") { continue }
                let mac = iface["hardware-address"]?.stringValue
                for ip in iface["ip-addresses"]?.arrayValue ?? [] {
                    guard let address = ip["ip-address"]?.stringValue else { continue }
                    let v6 = ip["ip-address-type"]?.stringValue == "ipv6"
                    if v6 && address.lowercased().hasPrefix("fe80") { continue }
                    let prefix = ip["prefix"]?.stringValue.map { "/\($0)" } ?? ""
                    result.append(GuestAddress(interface: name, address: address + prefix, mac: mac, isIPv6: v6))
                }
            }
        } else {
            let json = try await getJSON("\(guest.apiPath)/interfaces")
            for iface in json.arrayValue {
                let name = iface["name"]?.stringValue ?? "?"
                if name == "lo" { continue }
                let mac = iface["hwaddr"]?.stringValue
                if let v4 = iface["inet"]?.stringValue, !v4.isEmpty {
                    result.append(GuestAddress(interface: name, address: v4, mac: mac, isIPv6: false))
                }
                if let v6 = iface["inet6"]?.stringValue, !v6.isEmpty, !v6.lowercased().hasPrefix("fe80") {
                    result.append(GuestAddress(interface: name, address: v6, mac: mac, isIPv6: true))
                }
            }
        }
        return result
    }

    /// Erstellt ein Login-Ticket für die Web-Oberfläche (für noVNC), ohne Passwort.
    func webTicket(user: String = "root@pam") async throws -> String {
        let script = "use PVE::AccessControl; print PVE::AccessControl::assemble_ticket('\(user)');"
        let ticket = try await run("perl -e \(CommandBuilder.shellQuote(script))")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard ticket.hasPrefix("PVE:") else { throw PVEError(message: "Ticket konnte nicht erzeugt werden.") }
        return ticket
    }

    /// Befehl, der auf dem richtigen Cluster-Node läuft (für interaktive Konsolen).
    func commandOnNode(_ node: String, _ command: String) async -> String {
        let local = (try? await localNodeName()) ?? node
        if local == node { return command }
        return "ssh -t -o BatchMode=yes root@\(node) \(CommandBuilder.shellQuote(command))"
    }
}
