import Foundation

enum HostAuthMethod: String, Codable, CaseIterable, Identifiable {
    case password, privateKey
    var id: String { rawValue }
    var title: String { self == .password ? "Passwort" : "SSH-Schlüssel" }
}

struct ProxmoxHost: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var address: String = ""
    var port: Int = 22
    var username: String = "root"
    var authMethod: HostAuthMethod = .password
    /// Host-Schlüssel im OpenSSH-Format ("ssh-ed25519 AAAA…"), per Trust-On-First-Use gespeichert.
    var trustedHostKey: String?

    var displayName: String { name.isEmpty ? address : name }
    var endpoint: String { port == 22 ? "\(username)@\(address)" : "\(username)@\(address):\(port)" }
}

/// Zugangsdaten werden nie in UserDefaults, sondern nur im Schlüsselbund abgelegt.
struct HostCredentials {
    var password: String = ""
    var privateKey: String = ""
    var passphrase: String = ""

    static func load(for id: UUID) -> HostCredentials {
        HostCredentials(
            password: Keychain.get("\(id).password") ?? "",
            privateKey: Keychain.get("\(id).privateKey") ?? "",
            passphrase: Keychain.get("\(id).passphrase") ?? ""
        )
    }

    func save(for id: UUID) {
        Keychain.set(password, for: "\(id).password")
        Keychain.set(privateKey, for: "\(id).privateKey")
        Keychain.set(passphrase, for: "\(id).passphrase")
    }

    static func delete(for id: UUID) {
        ["password", "privateKey", "passphrase"].forEach { Keychain.delete("\(id).\($0)") }
    }
}
