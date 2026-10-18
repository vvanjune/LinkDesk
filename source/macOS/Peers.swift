import Foundation
import Darwin

struct PairedDevice: Codable, Identifiable {
    var fingerprint: String
    var name: String
    var address: String
    var platform: String
    var role: String
    var alias = ""
    var paired = false
    var lastSeen: Double = 0
    var input: LinkInputSettings?
    var id: String { fingerprint }
    var label: String { alias.isEmpty ? name : alias }
    var shortID: String { String(fingerprint.prefix(12)).uppercased() }
    var formattedFingerprint: String { stride(from: 0, to: fingerprint.count, by: 2).map { i in
        let start = fingerprint.index(fingerprint.startIndex, offsetBy: i)
        return String(fingerprint[start..<fingerprint.index(start, offsetBy: 2)]).uppercased()
    }.joined(separator: ":") }
    var online: Bool { Date().timeIntervalSince1970 - lastSeen < 25 }
    var platformLabel: String { ["macOS", "Windows"].contains(platform) ? platform : "系统待确认" }
    var roleLabel: String { role == "server" ? "共享键鼠" : "接收键鼠" }
}

struct DeviceDatabase: Codable {
    var version = 1
    var selectedID: String?
    var devices: [PairedDevice] = []
}

final class PeerStore {
    let profile: URL
    private(set) var database: DeviceDatabase
    var devices: [PairedDevice] { database.devices.sorted {
        if $0.paired != $1.paired { return $0.paired }
        return ($0.label, $0.id) < ($1.label, $1.id)
    } }
    var selected: PairedDevice? { database.devices.first { $0.id == database.selectedID && $0.paired } }
    static func pin(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hex = (clean.hasPrefix("v2:sha256:") ? String(clean.dropFirst(10)) : clean).replacingOccurrences(of: ":", with: "")
        return hex.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil ? hex : nil
    }
    init(profile: URL) throws {
        self.profile = profile
        let file = profile.appendingPathComponent("devices.json")
        if FileManager.default.fileExists(atPath: file.path) {
            database = try JSONDecoder().decode(DeviceDatabase.self, from: Data(contentsOf: file))
            guard database.version == 1,
                  Set(database.devices.map(\.id)).count == database.devices.count,
                  database.devices.allSatisfy({ Self.pin($0.fingerprint) == $0.fingerprint && LinkConfiguration.validName($0.name) && ["server", "client"].contains($0.role) }) else {
                throw NSError(domain: "LinkDesk.Peers", code: 1, userInfo: [NSLocalizedDescriptionKey: "设备列表无效，已保留原文件。请恢复设备列表备份。"])
            }
            if let id = database.selectedID, !database.devices.contains(where: { $0.id == id && $0.paired }) { database.selectedID = nil }
        } else { database = DeviceDatabase() }
    }
    func save() throws {
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        var persisted = database
        persisted.devices = database.devices.filter(\.paired).map { item in var item = item; item.lastSeen = 0; return item }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(persisted).write(to: profile.appendingPathComponent("devices.json"), options: .atomic)
    }
    func migrate(name: String, address: String, server: Bool, input: LinkInputSettings) throws {
        if FileManager.default.fileExists(atPath: profile.appendingPathComponent("devices.json").path) {
            var changed = false
            for index in database.devices.indices where database.devices[index].paired && database.devices[index].input == nil && database.devices[index].name.hasPrefix("Imported-") {
                database.devices[index].input = input; changed = true
            }
            if changed { try save() }; return
        }
        let marker = profile.appendingPathComponent("device-migration.done")
        if FileManager.default.fileExists(atPath: marker.path) { try save(); return }
        for (file, role) in [("trusted-servers", "server"), ("trusted-clients", "client")] {
            let lines = ((try? String(contentsOf: profile.appendingPathComponent("tls/\(file)"), encoding: .utf8)) ?? "").components(separatedBy: .newlines)
            let pins = Array(Set(lines.compactMap(Self.pin))).sorted()
            for pin in pins {
                let compatible = role == (server ? "client" : "server")
                let known = compatible && pins.count == 1 && LinkConfiguration.validName(name)
                database.devices.append(PairedDevice(fingerprint: pin, name: known ? name : "Imported-" + String(pin.prefix(8)),
                    address: known ? address : "", platform: "unknown", role: role, alias: known ? "" : "旧配对 " + String(pin.prefix(8)),
                    paired: true, input: input))
                if known { database.selectedID = pin }
            }
        }
        // A certificate can be trusted in both historical roles. Keep one record,
        // preferring the role matching the saved connection.
        var unique: [String: PairedDevice] = [:]
        for device in database.devices {
            if unique[device.id] == nil || device.role == (server ? "client" : "server") { unique[device.id] = device }
        }
        database.devices = Array(unique.values)
        try save()
        try "1\n".write(to: marker, atomically: true, encoding: .utf8)
    }
    @discardableResult func observe(_ incoming: PairedDevice) throws -> Bool {
        guard Self.pin(incoming.fingerprint) == incoming.fingerprint, LinkConfiguration.validName(incoming.name),
              LinkConfiguration.validHost(incoming.address), ["server", "client"].contains(incoming.role) else { return false }
        if let index = database.devices.firstIndex(where: { $0.id == incoming.id }) {
            var device = database.devices[index]
            let changed = device.name != incoming.name || device.address != incoming.address || device.platform != incoming.platform || device.role != incoming.role
            if device.alias == "旧配对 " + String(device.id.prefix(8)) { device.alias = "" }
            device.name = incoming.name; device.address = incoming.address; device.platform = incoming.platform
            device.role = incoming.role; device.lastSeen = incoming.lastSeen
            database.devices[index] = device
            if changed && device.paired { try save() }
        } else if database.devices.filter({ !$0.paired }).count < 64 {
            var device = incoming; device.paired = false; device.input = nil; device.alias = ""
            database.devices.append(device)
        }
        return database.selectedID == incoming.id && selected != nil
    }
    func pair(_ id: String) throws {
        guard let index = database.devices.firstIndex(where: { $0.id == id }) else { return }
        database.devices[index].paired = true; database.selectedID = id; try save()
    }
    func select(_ id: String) throws {
        guard database.devices.contains(where: { $0.id == id && $0.paired }) else { return }
        database.selectedID = id; try save()
    }
    func updateSelectedAddress(_ id: String, address: String) throws {
        guard selected?.id == id, let index = database.devices.firstIndex(where: { $0.id == id && $0.paired }) else {
            throw NSError(domain: "LinkDesk.Peers", code: 4, userInfo: [NSLocalizedDescriptionKey: "只能更新当前已选择的配对设备。"])
        }
        var ipv6 = in6_addr()
        let raw = address.hasPrefix("[") && address.hasSuffix("]") ? String(address.dropFirst().dropLast()) : address
        let valid = address.contains(":") ? inet_pton(AF_INET6, raw, &ipv6) == 1 : address.range(of: "^[A-Za-z0-9_](?:[A-Za-z0-9_.-]*[A-Za-z0-9_])?\\.?$", options: .regularExpression) != nil
        guard LinkConfiguration.validHost(address), valid else { throw NSError(domain: "LinkDesk.Peers", code: 5, userInfo: [NSLocalizedDescriptionKey: "请输入有效的 IP 地址或主机名，不含端口、路径或空格。"]) }
        let previous = database.devices[index]
        database.devices[index].address = address; database.devices[index].lastSeen = 0
        do { try save() } catch { database.devices[index] = previous; throw error }
    }
    func rename(_ id: String, alias: String) throws {
        guard let index = database.devices.firstIndex(where: { $0.id == id && $0.paired }) else { return }
        database.devices[index].alias = String(alias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)); try save()
    }
    func setInput(_ input: LinkInputSettings) throws {
        guard let index = database.devices.firstIndex(where: { $0.id == database.selectedID }) else { return }
        database.devices[index].input = input; try save()
    }
    func forget(_ id: String) throws {
        guard Self.pin(id) == id else { return }
        database.devices.removeAll { $0.id == id }; if database.selectedID == id { database.selectedID = nil }
        try save()
        let connection = profile.appendingPathComponent("connections/\(id)")
        if FileManager.default.fileExists(atPath: connection.path) { try FileManager.default.removeItem(at: connection) }
    }
    // Advertised roles may be stale during switching; trust is bound only to the selected paired fingerprint.
    func session(server: Bool) throws -> URL {
        guard let peer = selected else {
            throw NSError(domain: "LinkDesk.Peers", code: 2, userInfo: [NSLocalizedDescriptionKey: "请在配对设备中选择并确认另一台电脑。"])
        }
        return try Self.prepareSession(profile: profile, fingerprint: peer.fingerprint)
    }
    static func prepareSession(profile: URL, fingerprint: String) throws -> URL {
        guard let pin = Self.pin(fingerprint) else { throw NSError(domain: "LinkDesk.Peers", code: 3) }
        let folder = profile.appendingPathComponent("connections/\(pin)")
        let tls = folder.appendingPathComponent("tls")
        let fm = FileManager.default
        try fm.createDirectory(at: tls, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(contentsOf: profile.appendingPathComponent("tls/deskflow.pem")).write(to: tls.appendingPathComponent("deskflow.pem"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tls.appendingPathComponent("deskflow.pem").path)
        for name in ["trusted-clients", "trusted-servers"] {
            try "v2:sha256:\(pin)\n".write(to: tls.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return folder
    }
}
