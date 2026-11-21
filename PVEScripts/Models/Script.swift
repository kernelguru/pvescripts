import Foundation

/// Art des Community-Scripts – bestimmt den Ordner im Repository und das Badge.
enum ScriptType: String, Codable, CaseIterable, Identifiable {
    case lxc, vm, addon, pve, turnkey, unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lxc: "LXC"
        case .vm: "VM"
        case .addon: "Add-on"
        case .pve: "PVE-Tool"
        case .turnkey: "TurnKey"
        case .unknown: "Script"
        }
    }

    var symbol: String {
        switch self {
        case .lxc: "shippingbox"
        case .vm: "desktopcomputer"
        case .addon: "puzzlepiece.extension"
        case .pve: "server.rack"
        case .turnkey: "key"
        case .unknown: "doc.text"
        }
    }

    /// Ordner im ProxmoxVE-Repository (wie auf community-scripts.org).
    var directory: String {
        switch self {
        case .lxc, .unknown: "ct"
        case .vm: "vm"
        case .addon: "tools/addon"
        case .pve: "tools/pve"
        case .turnkey: "turnkey"
        }
    }
}

struct ScriptResources: Codable, Hashable {
    var cpu: Int?
    var ram: Int?
    var hdd: Int?
    var os: String?
    var version: String?

    init(cpu: Int? = nil, ram: Int? = nil, hdd: Int? = nil, os: String? = nil, version: String? = nil) {
        self.cpu = cpu; self.ram = ram; self.hdd = hdd; self.os = os; self.version = version
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpu = c.lossyInt(.cpu)
        ram = c.lossyInt(.ram)
        hdd = c.lossyInt(.hdd)
        os = c.lossyString(.os)
        version = c.lossyString(.version)
    }

    var isEmpty: Bool { cpu == nil && ram == nil && hdd == nil && (os ?? "").isEmpty }
}

struct InstallMethod: Codable, Hashable {
    var type: String
    var script: String?
    var configPath: String?
    var resources: ScriptResources?

    enum CodingKeys: String, CodingKey {
        case type, script, resources
        case configPath = "config_path"
    }

    init(type: String, script: String? = nil, configPath: String? = nil, resources: ScriptResources? = nil) {
        self.type = type; self.script = script; self.configPath = configPath; self.resources = resources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.lossyString(.type) ?? "default"
        script = c.lossyString(.script)
        configPath = c.lossyString(.configPath)
        resources = try? c.decodeIfPresent(ScriptResources.self, forKey: .resources)
    }

    var isAlpine: Bool {
        type.lowercased().contains("alpine") || (resources?.os ?? "").lowercased().contains("alpine")
    }

    /// Betriebssystem in Kleinbuchstaben, wie es `var_os` erwartet.
    var osSlug: String? {
        guard let os = resources?.os?.trimmingCharacters(in: .whitespaces).lowercased(), !os.isEmpty else { return nil }
        return os
    }
}

struct ScriptNote: Codable, Hashable {
    var text: String
    var type: String

    var isWarning: Bool { type.lowercased() == "warning" }

    init(text: String, type: String) { self.text = text; self.type = type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.lossyString(.text) ?? ""
        type = c.lossyString(.type) ?? "info"
    }
}

struct Script: Identifiable, Codable, Hashable {
    var id: String
    var slug: String
    var name: String
    var description: String
    var logo: String?
    var port: Int?
    var website: String?
    var documentation: String?
    var isDev: Bool
    var isDisabled: Bool
    var disableMessage: String?
    var updateable: Bool
    var privileged: Bool
    var defaultUser: String?
    var defaultPassword: String?
    var installMethods: [InstallMethod]
    var notes: [ScriptNote]
    var categoryIDs: [String]
    var type: ScriptType
    var executeIn: [String]
    var updatedAt: String?
    var hasArm: Bool

    var logoURL: URL? { logo.flatMap(URL.init(string:)) }
    var websiteURL: URL? { website.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
    var documentationURL: URL? { documentation.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
    var pageURL: URL? { URL(string: "https://community-scripts.org/scripts/\(slug)") }

    var defaultMethod: InstallMethod? { installMethods.first { !$0.isAlpine } ?? installMethods.first }
    var alpineMethod: InstallMethod? { installMethods.first { $0.isAlpine } }

    /// Add-ons, die nicht auf dem Host, sondern in einem bestehenden LXC laufen.
    var runsInsideGuest: Bool {
        type == .addon && !executeIn.contains("pve") && (executeIn.contains("lxc") || executeIn.contains("vm"))
    }

    /// Scripts, die auf einem anderen Proxmox-Produkt laufen (PBS, PMG, PDM).
    var foreignProduct: String? {
        let others = executeIn.filter { ["pbs", "pmg", "pdm"].contains($0) }
        guard !executeIn.contains("pve"), let first = others.first else { return nil }
        switch first {
        case "pbs": return "Proxmox Backup Server"
        case "pmg": return "Proxmox Mail Gateway"
        case "pdm": return "Proxmox Datacenter Manager"
        default: return first.uppercased()
        }
    }
}

struct ScriptCategory: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var icon: String?
    var sortOrder: Int

    /// Übersetzt die Lucide-Iconnamen der Website grob in SF Symbols.
    var symbol: String {
        switch icon ?? "" {
        case "server": "server.rack"
        case "monitor": "desktopcomputer"
        case "box": "shippingbox"
        case "shield": "shield"
        case "key": "key"
        case "ban": "nosign"
        case "lock": "lock"
        case "home": "house"
        case "film", "video", "tv": "film"
        case "music": "music.note"
        case "database": "cylinder.split.1x2"
        case "activity", "chart", "bar-chart": "chart.bar"
        case "code", "terminal": "chevron.left.forwardslash.chevron.right"
        case "cloud": "cloud"
        case "file", "file-text", "folder": "folder"
        case "message-circle", "mail": "bubble.left.and.bubble.right"
        case "dollar-sign", "wallet": "dollarsign.circle"
        case "camera", "image": "photo"
        case "book": "book"
        case "download": "arrow.down.circle"
        case "bot", "brain", "cpu": "cpu"
        case "gamepad", "gamepad-2": "gamecontroller"
        case "network", "globe", "wifi": "network"
        default: "square.grid.2x2"
        }
    }
}

// MARK: - Lenient decoding helpers

extension KeyedDecodingContainer {
    func lossyInt(_ key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return Int(v) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func lossyString(_ key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        return nil
    }

    func lossyBool(_ key: Key) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        return nil
    }
}
