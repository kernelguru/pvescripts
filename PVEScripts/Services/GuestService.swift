import Foundation
import Citadel
import NIOCore

/// Ein LXC-Container oder eine VM auf dem Proxmox-Cluster.
struct ProxmoxGuest: Identifiable, Hashable, Decodable {
    var vmid: Int
    var name: String?
    var status: String?
    var type: String
    var node: String?
    var maxmem: Double?
    var mem: Double?
    var cpus: Double?
    var uptime: Double?
    var tags: String?
    var template: Int?

    var id: String { "\(type)-\(vmid)" }
    var isContainer: Bool { type == "lxc" }
    var isRunning: Bool { status == "running" }
    var displayName: String { name ?? (isContainer ? "CT \(vmid)" : "VM \(vmid)") }
    var tagList: [String] {
        (tags ?? "").split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " }).map(String.init)
    }
    var isCommunityScript: Bool { tagList.contains("community-script") }

    enum CodingKeys: String, CodingKey {
        case vmid, name, status, type, node, maxmem, mem, uptime, tags, template
        case cpus = "maxcpu"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vmid = c.lossyInt(.vmid) ?? 0
        name = c.lossyString(.name)
        status = c.lossyString(.status)
        type = c.lossyString(.type) ?? "qemu"
        node = c.lossyString(.node)
        maxmem = try? c.decodeIfPresent(Double.self, forKey: .maxmem)
        mem = try? c.decodeIfPresent(Double.self, forKey: .mem)
        cpus = try? c.decodeIfPresent(Double.self, forKey: .cpus)
        uptime = try? c.decodeIfPresent(Double.self, forKey: .uptime)
        tags = c.lossyString(.tags)
        template = c.lossyInt(.template)
    }
}

enum GuestAction: String {
    case start, shutdown, reboot, stop
    var title: String {
        switch self {
        case .start: "Starten"
        case .shutdown: "Herunterfahren"
        case .reboot: "Neu starten"
        case .stop: "Stoppen (hart)"
        }
    }
}

enum GuestService {
    /// Liest alle Gäste über `pvesh` auf dem Host.
    static func listGuests(host: ProxmoxHost) async throws -> [ProxmoxGuest] {
        let output = try await run("pvesh get /cluster/resources --type vm --output-format json", on: host)
        let data = Data(output.utf8)
        let guests = try JSONDecoder().decode([ProxmoxGuest].self, from: data)
        return guests.filter { $0.template != 1 }.sorted { $0.vmid < $1.vmid }
    }

    static func perform(_ action: GuestAction, on guest: ProxmoxGuest, host: ProxmoxHost) async throws {
        let tool = guest.isContainer ? "pct" : "qm"
        _ = try await run("\(tool) \(action.rawValue) \(guest.vmid)", on: host)
    }

    static func hostInfo(host: ProxmoxHost, credentials: HostCredentials? = nil) async throws -> String {
        try await run("pveversion 2>/dev/null || uname -sr", on: host, credentials: credentials)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(_ command: String, on host: ProxmoxHost, credentials: HostCredentials? = nil) async throws -> String {
        let client = try await SSHConnector.connect(to: host, credentials: credentials ?? HostCredentials.load(for: host.id))
        defer { Task { try? await client.close() } }
        do {
            let buffer = try await client.executeCommand(command, maxResponseSize: 16 * 1024 * 1024, mergeStreams: true)
            return String(buffer: buffer)
        } catch let error as SSHClient.CommandFailed {
            throw SSHConnectError.underlying("Befehl fehlgeschlagen (Exit-Code \(error.exitCode)): \(command)")
        }
    }
}
