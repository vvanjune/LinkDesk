import Foundation

struct LinkInputSettings {
    var command = "super"
    var control = "ctrl"
    var option = "alt"
    var shift = "shift"
    var invertVertical = false
    var invertHorizontal = false
    var verticalSpeed = 1.0
    var horizontalSpeed = 1.0
    static let modifiers = ["ctrl", "super", "alt", "shift", "meta", "altgr", "none"]
    static let macToWindows = LinkInputSettings(command: "ctrl", control: "super")
    var valid: Bool {
        [command, control, option, shift].allSatisfy { Self.modifiers.contains($0) } &&
        verticalSpeed.isFinite && horizontalSpeed.isFinite &&
        (0.1...10).contains(verticalSpeed) && (0.1...10).contains(horizontalSpeed)
    }
    var mapping: String {
        "modifierSuper=\(command)\nmodifierMeta=\(command)\nmodifierCtrl=\(control)\nmodifierAlt=\(option)\nmodifierShift=\(shift)"
    }
}

enum LinkConfiguration {
    static func validName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$", options: .regularExpression) != nil
    }
    static func validHost(_ value: String) -> Bool {
        // IPv4, DNS and bracketed IPv6 only; never permit INI sections or line injection.
        !value.isEmpty && value.count <= 255 && value.range(of: "^[A-Za-z0-9_.:\\[\\]-]+$", options: .regularExpression) != nil
    }
    static func settings(local: String, peer: String, server: Bool, host: String, layout: String, configPath: String, input: LinkInputSettings = LinkInputSettings()) throws -> String {
        guard validName(local), validName(peer), local != peer else { throw NSError(domain: "LinkDesk", code: 1, userInfo: [NSLocalizedDescriptionKey: "电脑名称只能包含英文字母、数字、点、短横线和下划线，而且两台不能重名。"] ) }
        guard server || validHost(host) else { throw NSError(domain: "LinkDesk", code: 2, userInfo: [NSLocalizedDescriptionKey: "请输入有效的共享端 IP 地址或主机名。"] ) }
        guard input.valid else { throw NSError(domain: "LinkDesk", code: 3, userInfo: [NSLocalizedDescriptionKey: "请使用有效的按键映射及 0.1–10 倍滚动速度。"] ) }
        return """
        [core]
        computerName=\(local)
        coreMode=\(server ? 2 : 1)
        processMode=0
        port=24800
        [computer_\(local)]
        name=\(local)
        [computer_\(peer)]
        name=\(peer)
        \(server ? input.mapping : "")
        [client]
        remoteHost=\(host)
        languageSync=false
        dynamicConnectionInterval=true
        invertYScroll=\(input.invertVertical)
        invertXScroll=\(input.invertHorizontal)
        yScrollScale=\(input.verticalSpeed)
        xScrollScale=\(input.horizontalSpeed)
        [server]
        externalConfig=true
        externalConfigFile=\(configPath)
        protocol=barrier
        enableClipboard=true
        clipboardSize=3
        [security]
        tlsEnabled=true
        checkPeerFingerprints=true
        [log]
        level=Info
        """ + "\n"
    }
    static func links(local: String, peer: String, layout: String) -> String {
        let reverse = ["right":"left", "left":"right", "up":"down", "down":"up"]
        let direction = reverse[layout] == nil ? "right" : layout
        return "section: links\n\t\(local):\n\t\t\(direction) = \(peer)\n\t\(peer):\n\t\t\(reverse[direction]!) = \(local)\nend\n\nsection: options\nend\n"
    }
    static func fingerprintLine(_ value: String) -> String? {
        let hex = value.replacingOccurrences(of: ":", with: "").lowercased()
        guard hex.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        return "v2:sha256:\(hex)"
    }
}
