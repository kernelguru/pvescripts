import Foundation

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [ProxmoxHost] = []
    @Published var defaultHostID: UUID? {
        didSet { UserDefaults.standard.set(defaultHostID?.uuidString, forKey: Self.defaultKey) }
    }

    private static let hostsKey = "hosts.v1"
    private static let defaultKey = "hosts.default"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.hostsKey),
           let decoded = try? JSONDecoder().decode([ProxmoxHost].self, from: data) {
            hosts = decoded
        }
        if let raw = UserDefaults.standard.string(forKey: Self.defaultKey) {
            defaultHostID = UUID(uuidString: raw)
        }
    }

    var defaultHost: ProxmoxHost? {
        hosts.first { $0.id == defaultHostID } ?? hosts.first
    }

    func host(id: UUID?) -> ProxmoxHost? {
        guard let id else { return nil }
        return hosts.first { $0.id == id }
    }

    func upsert(_ host: ProxmoxHost, credentials: HostCredentials? = nil) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        credentials?.save(for: host.id)
        if defaultHostID == nil { defaultHostID = host.id }
        persist()
    }

    func trustHostKey(_ key: String, for id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].trustedHostKey = key
        persist()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            HostCredentials.delete(for: hosts[index].id)
        }
        hosts.remove(atOffsets: offsets)
        if let id = defaultHostID, !hosts.contains(where: { $0.id == id }) {
            defaultHostID = hosts.first?.id
        }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        hosts.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) {
            UserDefaults.standard.set(data, forKey: Self.hostsKey)
        }
    }
}
