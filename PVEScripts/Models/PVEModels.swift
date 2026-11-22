import Foundation

// MARK: - Generic JSON

/// Beliebiger JSON-Wert – Proxmox liefert Zahlen mal als Zahl, mal als String.
enum JSONValue: Decodable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): b ? "1" : "0"
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var arrayValue: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }
}

// MARK: - Guests

enum GuestKind: String, Codable, Hashable {
    case qemu, lxc
    var title: String { self == .qemu ? "VM" : "CT" }
    var longTitle: String { self == .qemu ? "Virtuelle Maschine" : "Container" }
    var symbol: String { self == .qemu ? "desktopcomputer" : "shippingbox.fill" }
}

/// Ein LXC-Container oder eine VM auf dem Proxmox-Cluster (aus /cluster/resources).
struct ProxmoxGuest: Identifiable, Hashable, Decodable {
    var vmid: Int
    var name: String?
    var status: String?
    var type: String
    var node: String
    var cpu: Double?
    var maxcpu: Double?
    var mem: Double?
    var maxmem: Double?
    var disk: Double?
    var maxdisk: Double?
    var netin: Double?
    var netout: Double?
    var uptime: Double?
    var tags: String?
    var template: Int?
    var lock: String?

    var id: String { "\(type)-\(vmid)" }
    var kind: GuestKind { type == "lxc" ? .lxc : .qemu }
    var isContainer: Bool { kind == .lxc }
    var isRunning: Bool { status == "running" }
    var isTemplate: Bool { template == 1 }
    var displayName: String { (name?.isEmpty == false ? name : nil) ?? "\(kind.title) \(vmid)" }
    var tagList: [String] {
        (tags ?? "").split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " }).map(String.init)
    }
    var isCommunityScript: Bool { tagList.contains("community-script") }
    var apiPath: String { "/nodes/\(node)/\(kind.rawValue)/\(vmid)" }

    enum CodingKeys: String, CodingKey {
        case vmid, name, status, type, node, cpu, maxcpu, mem, maxmem, disk, maxdisk, netin, netout, uptime, tags, template, lock
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vmid = c.lossyInt(.vmid) ?? 0
        name = c.lossyString(.name)
        status = c.lossyString(.status)
        type = c.lossyString(.type) ?? "qemu"
        node = c.lossyString(.node) ?? ""
        cpu = c.lossyDouble(.cpu)
        maxcpu = c.lossyDouble(.maxcpu)
        mem = c.lossyDouble(.mem)
        maxmem = c.lossyDouble(.maxmem)
        disk = c.lossyDouble(.disk)
        maxdisk = c.lossyDouble(.maxdisk)
        netin = c.lossyDouble(.netin)
        netout = c.lossyDouble(.netout)
        uptime = c.lossyDouble(.uptime)
        tags = c.lossyString(.tags)
        template = c.lossyInt(.template)
        lock = c.lossyString(.lock)
    }
}

/// Live-Status aus /status/current.
struct GuestStatus: Decodable {
    var status: String?
    var qmpstatus: String?
    var cpu: Double?
    var cpus: Double?
    var mem: Double?
    var maxmem: Double?
    var disk: Double?
    var maxdisk: Double?
    var netin: Double?
    var netout: Double?
    var diskread: Double?
    var diskwrite: Double?
    var uptime: Double?
    var agent: Int?
    var lock: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case status, qmpstatus, cpu, cpus, mem, maxmem, disk, maxdisk, netin, netout, diskread, diskwrite, uptime, agent, lock, name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lossyString(.status)
        qmpstatus = c.lossyString(.qmpstatus)
        cpu = c.lossyDouble(.cpu)
        cpus = c.lossyDouble(.cpus)
        mem = c.lossyDouble(.mem)
        maxmem = c.lossyDouble(.maxmem)
        disk = c.lossyDouble(.disk)
        maxdisk = c.lossyDouble(.maxdisk)
        netin = c.lossyDouble(.netin)
        netout = c.lossyDouble(.netout)
        diskread = c.lossyDouble(.diskread)
        diskwrite = c.lossyDouble(.diskwrite)
        uptime = c.lossyDouble(.uptime)
        agent = c.lossyInt(.agent)
        lock = c.lossyString(.lock)
        name = c.lossyString(.name)
    }

    var isRunning: Bool { status == "running" }
    var isPaused: Bool { qmpstatus == "paused" || qmpstatus == "suspended" }
}

enum GuestAction: String, CaseIterable {
    case start, shutdown, reboot, stop, suspend, resume

    var title: String {
        switch self {
        case .start: "Starten"
        case .shutdown: "Herunterfahren"
        case .reboot: "Neu starten"
        case .stop: "Stoppen (hart)"
        case .suspend: "Pausieren"
        case .resume: "Fortsetzen"
        }
    }

    var symbol: String {
        switch self {
        case .start: "play.fill"
        case .shutdown: "power"
        case .reboot: "arrow.clockwise"
        case .stop: "stop.fill"
        case .suspend: "pause.fill"
        case .resume: "playpause.fill"
        }
    }
}

// MARK: - Nodes & Storage

struct PVENode: Decodable, Identifiable, Hashable {
    var node: String
    var status: String?
    var cpu: Double?
    var maxcpu: Double?
    var mem: Double?
    var maxmem: Double?
    var disk: Double?
    var maxdisk: Double?
    var uptime: Double?

    var id: String { node }
    var isOnline: Bool { status == "online" }

    enum CodingKeys: String, CodingKey { case node, status, cpu, maxcpu, mem, maxmem, disk, maxdisk, uptime }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        node = c.lossyString(.node) ?? "?"
        status = c.lossyString(.status)
        cpu = c.lossyDouble(.cpu)
        maxcpu = c.lossyDouble(.maxcpu)
        mem = c.lossyDouble(.mem)
        maxmem = c.lossyDouble(.maxmem)
        disk = c.lossyDouble(.disk)
        maxdisk = c.lossyDouble(.maxdisk)
        uptime = c.lossyDouble(.uptime)
    }
}

struct NodeStatus {
    var cpu: Double
    var cpus: Int
    var cpuModel: String
    var memUsed: Double
    var memTotal: Double
    var swapUsed: Double
    var swapTotal: Double
    var rootUsed: Double
    var rootTotal: Double
    var uptime: Double
    var loadavg: [String]
    var pveVersion: String
    var kernel: String
    var ioWait: Double

    init(json: JSONValue) {
        cpu = json["cpu"]?.doubleValue ?? 0
        cpus = Int(json["cpuinfo"]?["cpus"]?.doubleValue ?? 0)
        cpuModel = json["cpuinfo"]?["model"]?.stringValue ?? ""
        memUsed = json["memory"]?["used"]?.doubleValue ?? 0
        memTotal = json["memory"]?["total"]?.doubleValue ?? 0
        swapUsed = json["swap"]?["used"]?.doubleValue ?? 0
        swapTotal = json["swap"]?["total"]?.doubleValue ?? 0
        rootUsed = json["rootfs"]?["used"]?.doubleValue ?? 0
        rootTotal = json["rootfs"]?["total"]?.doubleValue ?? 0
        uptime = json["uptime"]?.doubleValue ?? 0
        loadavg = json["loadavg"]?.arrayValue.compactMap(\.stringValue) ?? []
        pveVersion = json["pveversion"]?.stringValue ?? ""
        kernel = json["kversion"]?.stringValue ?? ""
        ioWait = json["wait"]?.doubleValue ?? 0
    }
}

struct PVEStorage: Decodable, Identifiable, Hashable {
    var storage: String
    var type: String?
    var content: String?
    var active: Int?
    var enabled: Int?
    var shared: Int?
    var avail: Double?
    var total: Double?
    var used: Double?

    var id: String { storage }
    var contentTypes: [String] { (content ?? "").split(separator: ",").map(String.init) }
    var usage: Double? {
        guard let total, total > 0, let used else { return nil }
        return used / total
    }

    enum CodingKeys: String, CodingKey { case storage, type, content, active, enabled, shared, avail, total, used }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        storage = c.lossyString(.storage) ?? "?"
        type = c.lossyString(.type)
        content = c.lossyString(.content)
        active = c.lossyInt(.active)
        enabled = c.lossyInt(.enabled)
        shared = c.lossyInt(.shared)
        avail = c.lossyDouble(.avail)
        total = c.lossyDouble(.total)
        used = c.lossyDouble(.used)
    }
}

struct StorageItem: Decodable, Identifiable, Hashable {
    var volid: String
    var size: Double?
    var format: String?
    var content: String?

    var id: String { volid }
    var fileName: String { volid.split(separator: "/").last.map(String.init) ?? volid }

    enum CodingKeys: String, CodingKey { case volid, size, format, content }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volid = c.lossyString(.volid) ?? ""
        size = c.lossyDouble(.size)
        format = c.lossyString(.format)
        content = c.lossyString(.content)
    }
}

struct NetworkBridge: Decodable, Identifiable, Hashable {
    var iface: String
    var type: String?
    var comments: String?
    var cidr: String?
    var id: String { iface }

    enum CodingKeys: String, CodingKey { case iface, type, comments, cidr }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        iface = c.lossyString(.iface) ?? "?"
        type = c.lossyString(.type)
        comments = c.lossyString(.comments)
        cidr = c.lossyString(.cidr)
    }
}

/// Verfügbare LXC-Vorlage aus /nodes/{node}/aplinfo.
struct ApplianceTemplate: Decodable, Identifiable, Hashable {
    var template: String
    var section: String?
    var headline: String?
    var os: String?
    var version: String?
    var id: String { template }

    enum CodingKeys: String, CodingKey { case template, section, headline, os, version }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = c.lossyString(.template) ?? "?"
        section = c.lossyString(.section)
        headline = c.lossyString(.headline)
        os = c.lossyString(.os)
        version = c.lossyString(.version)
    }
}

// MARK: - Snapshots & Tasks

struct GuestSnapshot: Decodable, Identifiable, Hashable {
    var name: String
    var description: String?
    var snaptime: Double?
    var parent: String?
    var vmstate: Int?
    var id: String { name }
    var isCurrent: Bool { name == "current" }
    var date: Date? { snaptime.map { Date(timeIntervalSince1970: $0) } }

    enum CodingKeys: String, CodingKey { case name, description, snaptime, parent, vmstate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lossyString(.name) ?? "?"
        description = c.lossyString(.description)
        snaptime = c.lossyDouble(.snaptime)
        parent = c.lossyString(.parent)
        vmstate = c.lossyInt(.vmstate)
    }
}

struct PVETask: Decodable, Identifiable, Hashable {
    var upid: String
    var node: String
    var type: String?
    var id_: String?
    var user: String?
    var status: String?
    var starttime: Double?
    var endtime: Double?

    var id: String { upid }
    var isRunning: Bool { endtime == nil && (status == nil || status == "running") }
    var isOK: Bool { status == "OK" }
    var start: Date? { starttime.map { Date(timeIntervalSince1970: $0) } }

    var title: String {
        let names: [String: String] = [
            "qmstart": "VM starten", "qmstop": "VM stoppen", "qmshutdown": "VM herunterfahren",
            "qmreboot": "VM neu starten", "qmcreate": "VM erstellen", "qmdestroy": "VM löschen",
            "qmclone": "VM klonen", "qmsnapshot": "Snapshot", "qmrollback": "Rollback",
            "qmdelsnapshot": "Snapshot löschen", "qmsuspend": "VM pausieren", "qmresume": "VM fortsetzen",
            "vzstart": "CT starten", "vzstop": "CT stoppen", "vzshutdown": "CT herunterfahren",
            "vzreboot": "CT neu starten", "vzcreate": "CT erstellen", "vzdestroy": "CT löschen",
            "vzdump": "Backup", "vzsnapshot": "Snapshot", "vzrollback": "Rollback",
            "download": "Download", "aptupdate": "Paketliste aktualisieren", "qmigrate": "Migration",
            "vncproxy": "VNC-Konsole", "vncshell": "Node-Shell (VNC)", "termproxy": "xterm.js-Konsole",
            "resize": "Disk vergrößern",
        ]
        let base = names[type ?? ""] ?? (type ?? "Task")
        if let id_, !id_.isEmpty { return "\(base) \(id_)" }
        return base
    }

    enum CodingKeys: String, CodingKey {
        case upid, node, type, user, status, starttime, endtime
        case id_ = "id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        upid = c.lossyString(.upid) ?? UUID().uuidString
        node = c.lossyString(.node) ?? ""
        type = c.lossyString(.type)
        id_ = c.lossyString(.id_)
        user = c.lossyString(.user)
        status = c.lossyString(.status)
        starttime = c.lossyDouble(.starttime)
        endtime = c.lossyDouble(.endtime)
    }
}

/// Ermittelte IP-Adresse eines Gastes.
struct GuestAddress: Identifiable, Hashable {
    var interface: String
    var address: String
    var mac: String?
    var isIPv6: Bool
    var id: String { "\(interface)-\(address)" }
}

// MARK: - Config parsing

/// Proxmox-Optionen wie "virtio=AA:BB,bridge=vmbr0,tag=10" als geordnete Liste.
struct PropertyString: Hashable {
    var items: [(key: String, value: String)]

    init(_ raw: String) {
        items = raw.split(separator: ",", omittingEmptySubsequences: true).map { part in
            let pieces = part.split(separator: "=", maxSplits: 1)
            if pieces.count == 2 { return (String(pieces[0]), String(pieces[1])) }
            return ("", String(part))
        }
    }

    init(items: [(String, String)]) { self.items = items.map { (key: $0.0, value: $0.1) } }

    subscript(key: String) -> String? {
        get { items.first { $0.key == key }?.value }
        set {
            if let index = items.firstIndex(where: { $0.key == key }) {
                if let newValue, !newValue.isEmpty { items[index].value = newValue } else { items.remove(at: index) }
            } else if let newValue, !newValue.isEmpty {
                items.append((key: key, value: newValue))
            }
        }
    }

    /// Erster Eintrag ohne "=" (z. B. das Volume einer Disk).
    var positional: String? { items.first { $0.key.isEmpty }?.value }

    var raw: String {
        items.map { $0.key.isEmpty ? $0.value : "\($0.key)=\($0.value)" }.joined(separator: ",")
    }

    static func == (lhs: PropertyString, rhs: PropertyString) -> Bool { lhs.raw == rhs.raw }
    func hash(into hasher: inout Hasher) { hasher.combine(raw) }
}

/// Konfiguration eines Gastes als Schlüssel/Wert-Liste.
struct GuestConfig {
    var values: [String: String]
    var digest: String?

    init(json: JSONValue) {
        var values: [String: String] = [:]
        if case .object(let o) = json {
            for (key, value) in o {
                if let s = value.stringValue { values[key] = s }
            }
        }
        digest = values.removeValue(forKey: "digest")
        self.values = values
    }

    subscript(key: String) -> String? { values[key] }

    var sortedKeys: [String] { values.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    static let diskPattern = try! NSRegularExpression(pattern: "^(scsi|sata|virtio|ide|efidisk|tpmstate|unused|mp)\\d+$|^rootfs$")
    static let netPattern = try! NSRegularExpression(pattern: "^net\\d+$")

    static func matches(_ regex: NSRegularExpression, _ key: String) -> Bool {
        regex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    var diskKeys: [String] {
        sortedKeys.filter { Self.matches(Self.diskPattern, $0) && !isCDROM($0) }
    }

    var cdromKeys: [String] { sortedKeys.filter { isCDROM($0) } }

    var netKeys: [String] { sortedKeys.filter { Self.matches(Self.netPattern, $0) } }

    static let pciPattern = try! NSRegularExpression(pattern: "^hostpci\\d+$")
    static let usbPattern = try! NSRegularExpression(pattern: "^usb\\d+$")
    static let devPattern = try! NSRegularExpression(pattern: "^dev\\d+$")

    var pciKeys: [String] { sortedKeys.filter { Self.matches(Self.pciPattern, $0) } }
    var usbKeys: [String] { sortedKeys.filter { Self.matches(Self.usbPattern, $0) } }
    var deviceKeys: [String] { sortedKeys.filter { Self.matches(Self.devPattern, $0) } }

    func isCDROM(_ key: String) -> Bool {
        guard let value = values[key] else { return false }
        return value.contains("media=cdrom")
    }

    /// Nächste freie Nummer für z. B. "net" oder "scsi".
    func nextIndex(prefix: String, limit: Int = 31) -> Int {
        (0...limit).first { values["\(prefix)\($0)"] == nil } ?? limit
    }
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ value: Double?) -> String {
        guard let value, value > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f %%", value * 100)
    }

    static func uptime(_ seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "–" }
        let s = Int(seconds)
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) T \(h) Std" }
        if h > 0 { return "\(h) Std \(m) Min" }
        return "\(m) Min"
    }
}

extension KeyedDecodingContainer {
    func lossyDouble(_ key: Key) -> Double? {
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

// MARK: - Passthrough

struct PCIDevice: Decodable, Identifiable, Hashable {
    var id: String              // 0000:01:00.0
    var classCode: String       // 0x030000
    var vendor: String          // 0x10de
    var device: String
    var vendorName: String?
    var deviceName: String?
    var subsystemName: String?
    var iommuGroup: Int
    var mdev: Bool

    enum CodingKeys: String, CodingKey {
        case id, vendor, device, mdev
        case classCode = "class"
        case vendorName = "vendor_name"
        case deviceName = "device_name"
        case subsystemName = "subsystem_device_name"
        case iommuGroup = "iommugroup"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossyString(.id) ?? "?"
        classCode = (c.lossyString(.classCode) ?? "").lowercased()
        vendor = (c.lossyString(.vendor) ?? "").lowercased()
        device = (c.lossyString(.device) ?? "").lowercased()
        vendorName = c.lossyString(.vendorName)
        deviceName = c.lossyString(.deviceName)
        subsystemName = c.lossyString(.subsystemName)
        iommuGroup = c.lossyInt(.iommuGroup) ?? -1
        mdev = c.lossyBool(.mdev) ?? false
    }

    /// "0000:01:00" – alle Funktionen des Geräts.
    var slot: String { id.components(separatedBy: ".").first ?? id }
    var function: String { id.components(separatedBy: ".").last ?? "0" }
    /// "10de:2484" für vfio-pci ids=
    var vendorDevice: String {
        func strip(_ s: String) -> String { s.hasPrefix("0x") ? String(s.dropFirst(2)) : s }
        return "\(strip(vendor)):\(strip(device))"
    }
    private var classPrefix: String {
        let c = classCode.hasPrefix("0x") ? String(classCode.dropFirst(2)) : classCode
        return String(c.prefix(4))
    }
    var isGPU: Bool { classPrefix.hasPrefix("03") }
    var isAudio: Bool { classPrefix == "0403" }
    var category: String {
        switch String(classPrefix.prefix(2)) {
        case "03": return "Grafik"
        case "02": return "Netzwerk"
        case "01": return "Storage"
        case "04": return "Multimedia"
        case "0c": return classPrefix == "0c03" ? "USB-Controller" : "Serieller Bus"
        case "08": return "System"
        case "12": return "Beschleuniger"
        default: return "Sonstige"
        }
    }
    var symbol: String {
        switch category {
        case "Grafik": "display"
        case "Netzwerk": "network"
        case "Storage": "internaldrive"
        case "Multimedia": "speaker.wave.2"
        case "USB-Controller": "cable.connector"
        default: "cpu"
        }
    }
    var title: String { deviceName ?? "Gerät \(vendorDevice)" }
}

struct USBDevice: Decodable, Identifiable, Hashable {
    var busnum: Int
    var devnum: Int
    var port: Int
    var usbpath: String?
    var vendid: String
    var prodid: String
    var manufacturer: String?
    var product: String?
    var speed: String?
    var usbClass: Int

    var id: String { "\(busnum)-\(devnum)" }
    var deviceID: String {
        func strip(_ s: String) -> String { (s.hasPrefix("0x") ? String(s.dropFirst(2)) : s).lowercased() }
        return "\(strip(vendid)):\(strip(prodid))"
    }
    var portID: String { "\(busnum)-\(usbpath ?? String(port))" }
    var isHub: Bool { usbClass == 9 }
    var title: String {
        let name = [manufacturer, product].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? "USB-Gerät \(deviceID)" : name
    }

    enum CodingKeys: String, CodingKey {
        case busnum, devnum, port, usbpath, vendid, prodid, manufacturer, product, speed
        case usbClass = "class"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        busnum = c.lossyInt(.busnum) ?? 0
        devnum = c.lossyInt(.devnum) ?? 0
        port = c.lossyInt(.port) ?? 0
        usbpath = c.lossyString(.usbpath)
        vendid = c.lossyString(.vendid) ?? ""
        prodid = c.lossyString(.prodid) ?? ""
        manufacturer = c.lossyString(.manufacturer)
        product = c.lossyString(.product)
        speed = c.lossyString(.speed)
        usbClass = c.lossyInt(.usbClass) ?? 0
    }
}

/// Ergebnis der Passthrough-Prüfung eines Hosts.
struct PassthroughCheck {
    var cpuVendor: String = ""
    var cmdline: String = ""
    var iommuGroups: Int = 0
    var iommuMessages: Int = 0
    var interruptRemapping: Bool = false
    var modules: [String: Bool] = [:]
    var bootloader: String = ""
    var pveVersion: String = ""
    var vfioConfig: String = ""

    init() {}

    init(output: String) {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (key, value) = (parts[0], parts[1].trimmingCharacters(in: .whitespaces))
            switch key {
            case "cpu": cpuVendor = value
            case "cmdline": cmdline = value
            case "groups": iommuGroups = Int(value) ?? 0
            case "iommu_msgs": iommuMessages = Int(value) ?? 0
            case "remap": interruptRemapping = (Int(value) ?? 0) > 0
            case "boot": bootloader = value
            case "pve": pveVersion = value
            case "vfio_conf": vfioConfig = value
            default:
                if key.hasPrefix("mod_") { modules[String(key.dropFirst(4))] = value == "1" }
            }
        }
    }

    var isIntel: Bool { cpuVendor == "GenuineIntel" }
    var isAMD: Bool { cpuVendor == "AuthenticAMD" }
    var iommuActive: Bool { iommuGroups > 0 }
    var hasIntelParam: Bool { cmdline.contains("intel_iommu=on") }
    var hasPassthroughParam: Bool { cmdline.contains("iommu=pt") }
    var vfioLoaded: Bool { ["vfio", "vfio_iommu_type1", "vfio_pci"].allSatisfy { modules[$0] == true } }
    var kernelParamsOK: Bool { isIntel ? hasIntelParam : true }
    var ready: Bool { iommuActive && vfioLoaded }

    static let script = """
    echo "cpu=$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')"
    echo "cmdline=$(cat /proc/cmdline)"
    echo "groups=$(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l)"
    echo "iommu_msgs=$(dmesg 2>/dev/null | grep -ciE 'DMAR: IOMMU enabled|AMD-Vi|iommu: Default domain')"
    echo "remap=$(dmesg 2>/dev/null | grep -ciE 'remapping.*enabled|x2apic enabled')"
    for m in vfio vfio_iommu_type1 vfio_pci; do if grep -q "^$m " /proc/modules || [ -d /sys/module/$m ]; then echo "mod_$m=1"; else echo "mod_$m=0"; fi; done
    if [ -f /etc/kernel/cmdline ]; then echo boot=systemd-boot; else echo boot=grub; fi
    echo "pve=$(pveversion 2>/dev/null | cut -d/ -f2)"
    echo "vfio_conf=$(cat /etc/modprobe.d/vfio*.conf 2>/dev/null | tr '\\n' ';')"
    """
}
