import Foundation

/// Wie das Script gestartet wird.
enum InstallMode: String, CaseIterable, Identifiable {
    /// Zeigt das normale Whiptail-Menü der Community Scripts.
    case menu
    /// Überspringt das Menü und installiert mit Standardwerten (+ optionalen Overrides).
    case `default`
    /// Springt direkt in die erweiterten Einstellungen.
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menu: "Menü"
        case .default: "Standard"
        case .advanced: "Erweitert"
        }
    }

    var explanation: String {
        switch self {
        case .menu: "Startet das Script mit seinem gewohnten Auswahlmenü im Terminal."
        case .default: "Installiert ohne Menü mit Standardwerten. Unten kannst du CPU, RAM, Disk usw. überschreiben."
        case .advanced: "Öffnet direkt die erweiterten Einstellungen (Netzwerk, Storage, Features …) im Terminal."
        }
    }
}

enum ContainerPrivilege: String, CaseIterable, Identifiable {
    case scriptDefault, unprivileged, privileged
    var id: String { rawValue }
    var title: String {
        switch self {
        case .scriptDefault: "Script-Standard"
        case .unprivileged: "Unprivilegiert"
        case .privileged: "Privilegiert"
        }
    }
    var unprivilegedFlag: String? {
        switch self {
        case .scriptDefault: nil
        case .unprivileged: "1"
        case .privileged: "0"
        }
    }
}

enum InstallVariant: String, CaseIterable, Identifiable {
    case standard, alpine
    var id: String { rawValue }
    var title: String { self == .standard ? "Standard" : "Alpine" }
}

struct InstallOptions: Equatable {
    var variant: InstallVariant = .standard
    var mode: InstallMode = .menu
    var cpu: Int?
    var ramMB: Int?
    var diskGB: Int?
    var hostname: String = ""
    var containerID: String = ""
    var privilege: ContainerPrivilege = .scriptDefault
    var verbose = false
    /// Für Add-ons, die in einem bestehenden LXC laufen.
    var targetGuestID: String = ""
}

enum CommandBuilder {
    static let mainRepo = "https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"
    static let devRepo = "https://raw.githubusercontent.com/community-scripts/DevScripts/main"

    /// Relativer Pfad des Scripts im Repository (gleiche Logik wie community-scripts.org).
    static func scriptPath(for script: Script) -> String {
        for method in script.installMethods {
            if let path = method.script?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                return path.hasSuffix(".sh") ? path : path + ".sh"
            }
        }
        return "\(script.type.directory)/\(script.slug).sh"
    }

    static func scriptURL(for script: Script) -> URL {
        let base = script.isDev ? devRepo : mainRepo
        return URL(string: "\(base)/\(scriptPath(for: script))")!
    }

    static func sourceURL(for script: Script) -> URL {
        let repo = script.isDev ? "DevScripts" : "ProxmoxVE"
        return URL(string: "https://github.com/community-scripts/\(repo)/blob/main/\(scriptPath(for: script))")!
    }

    /// Der Einzeiler, wie er auf der Website steht.
    static func websiteCommand(for script: Script, variant: InstallVariant = .standard) -> String {
        command(for: script, options: InstallOptions(variant: variant))
    }

    /// Kompletter Befehl inkl. Umgebungsvariablen.
    static func command(for script: Script, options: InstallOptions) -> String {
        var env: [(String, String)] = []

        // Alpine-/Standard-Variante wie auf der Website über var_os wählen.
        if let alpine = script.alpineMethod {
            if options.variant == .alpine {
                env.append(("var_os", alpine.osSlug ?? "alpine"))
            } else if let os = script.installMethods.first(where: { !$0.isAlpine })?.osSlug {
                env.append(("var_os", os))
            }
        }

        let createsGuest = script.type == .lxc || script.type == .vm || script.type == .turnkey
        if createsGuest {
            switch options.mode {
            case .menu: break
            case .default: env.append(("mode", "default"))
            case .advanced: env.append(("mode", "advanced"))
            }
            if options.mode == .default {
                if let cpu = options.cpu, cpu > 0 { env.append(("var_cpu", String(cpu))) }
                if let ram = options.ramMB, ram > 0 { env.append(("var_ram", String(ram))) }
                if let disk = options.diskGB, disk > 0 { env.append(("var_disk", String(disk))) }
                let host = sanitizedHostname(options.hostname)
                if !host.isEmpty { env.append(("var_hostname", host)) }
                let ctid = options.containerID.filter(\.isNumber)
                if !ctid.isEmpty { env.append(("var_ctid", ctid)) }
                if script.type == .lxc, let flag = options.privilege.unprivilegedFlag {
                    env.append(("var_unprivileged", flag))
                }
                if options.verbose { env.append(("var_verbose", "yes")) }
            }
        }

        let prefix = env.map { "\($0.0)=\(shellQuote($0.1))" }.joined(separator: " ")
        let run = "bash -c \"$(curl -fsSL \(scriptURL(for: script).absoluteString))\""

        if script.runsInsideGuest, let guest = Int(options.targetGuestID.filter(\.isNumber)) {
            // Script auf dem Host laden und im Container ausführen.
            let inner = prefix.isEmpty ? "" : "env \(prefix) "
            return "pct exec \(guest) -- \(inner)bash -c \"$(curl -fsSL \(scriptURL(for: script).absoluteString))\""
        }
        return prefix.isEmpty ? run : "\(prefix) \(run)"
    }

    static func sanitizedHostname(_ value: String) -> String {
        let lowered = value.lowercased()
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII ? Character(scalar) : "-"
        }
        var result = String(allowed)
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        return String(result.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(63))
    }

    static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:,@%+="))
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) && $0.isASCII }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
