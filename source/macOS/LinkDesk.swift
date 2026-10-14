import SwiftUI
import AppKit
import ServiceManagement
import ApplicationServices
import Darwin
import Network

let ink = Color(red: 0.14, green: 0.17, blue: 0.23)
let accent = Color(red: 0.30, green: 0.32, blue: 0.83)
let paper = Color(red: 0.96, green: 0.96, blue: 0.94)

final class CoreChannel {
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var stopped = false
    func connect(onMessage: @escaping (String) -> Void, onClosed: @escaping () -> Void = {}) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("deskflow-core").path
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            var descriptor: Int32 = -1
            for _ in 0..<20 {
                self.lock.lock(); let cancelled = self.stopped; self.lock.unlock(); if cancelled { return }
                let candidate = socket(AF_UNIX, SOCK_STREAM, 0); guard candidate >= 0 else { return }
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(candidate, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                if result == 0 { descriptor = candidate; break }
                Darwin.close(candidate); usleep(250_000)
            }
            guard descriptor >= 0 else { return }
            var one: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            self.lock.lock()
            if self.stopped { self.lock.unlock(); Darwin.close(descriptor); return }
            self.fd = descriptor; self.lock.unlock()
            self.send("hello=LinkDesk")
            var pending = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count <= 0 { break }
                pending.append(contentsOf: buffer.prefix(count))
                while let index = pending.firstIndex(of: 10) {
                    let line = String(decoding: pending.prefix(upTo: index), as: UTF8.self)
                    pending.removeSubrange(...index)
                    if line.hasPrefix("versionMismatch=") { self.send("hello=" + line.dropFirst(16)); continue }
                    DispatchQueue.main.async { onMessage(line) }
                }
                if pending.count > 65536 { break }
            }
            self.lock.lock()
            if self.fd == descriptor { self.fd = -1 }
            let reportClosure = !self.stopped
            self.lock.unlock()
            Darwin.close(descriptor)
            if reportClosure { DispatchQueue.main.async { onClosed() } }
        }
    }
    func send(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 else { return }
        let bytes = Array((message + "\n").utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, bytes.count) }
    }
    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }
}

final class LinkModel: ObservableObject {
    @Published var tab = "connection"
    @Published var localName = ""
    @Published var peerName = ""
    @Published var host = ""
    @Published var server = true
    @Published var layout = "right"
    @Published var commandMap = "super"
    @Published var controlMap = "ctrl"
    @Published var optionMap = "alt"
    @Published var shiftMap = "shift"
    @Published var invertVertical = false
    @Published var invertHorizontal = false
    @Published var verticalSpeed = 1.0
    @Published var horizontalSpeed = 1.0
    @Published var running = false
    @Published var connected = false
    @Published var title = "准备连接"
    @Published var detail = "启动共享后，另一台电脑就可以连接。"
    @Published var logs: [String] = []
    @Published var issue: String?
    @Published var pairing: String?
    @Published var devices: [PairedDevice] = []
    @Published var renameID: String?
    @Published var renameText = ""
    @Published var forgetID: String?
    @Published var manualName = ""
    @Published var manualAddress = ""
    @Published var manualFingerprint = ""
    @Published var manualPlatform = "unknown"
    private var pendingPairID: String?
    private var peers: PeerStore?
    private var activeProfile: URL?
    private var browser: DiscoveryClient?
    private var discoveryIdentity: String?
    private var discoveryGeneration = UUID()
    private var lastSelectedSeen = Date.distantPast
    var selectedDevice: PairedDevice? { peers?.selected }
    var selectedLabel: String { selectedDevice?.label ?? "尚未选择设备" }
    var pairingLabel: String { devices.first(where: { $0.id == pendingPairID })?.label ?? "另一台电脑" }
    @Published var localFingerprint = "正在准备本机身份…"
    @Published var loginEnabled = false
    @Published var background = true { didSet { UserDefaults.standard.set(background, forKey: "background") } }
    @Published var autoConnect = false { didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") } }
    @Published var addresses: [String] = []
    @Published var allowDiscovery = true { didSet { UserDefaults.standard.set(allowDiscovery, forKey: "allowDiscovery"); updateDiscovery() } }
    @Published var discoveryStatus = "正在查找局域网设备。"
    private let networkMonitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var recoveryWork: DispatchWorkItem?
    private var pathSignature: String?
    private var waking = false
    private var restarting = false
    private var closing = false
    private var recoveryBlocked = false
    private var responder: DiscoveryResponder?
    private var child: Process?
    private var channel: CoreChannel?
    private var desired = false
    private var failures = 0
    private var generation = UUID()
    private var partial = ""
    private var coreReady = false
    private var handledFingerprints = Set<String>()
    let settingsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LinkDesk")
    let engine = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/deskflow-core")
    init() {
        let d = UserDefaults.standard
        background = d.object(forKey: "background") as? Bool ?? true
        autoConnect = d.bool(forKey: "autoConnect")
        localName = d.string(forKey: "localName") ?? localName
        peerName = d.string(forKey: "peerName") ?? peerName
        host = d.string(forKey: "host") ?? host
        server = d.object(forKey: "server") as? Bool ?? true
        layout = d.string(forKey: "layout") ?? "right"
        commandMap = d.string(forKey: "commandMap") ?? "super"
        controlMap = d.string(forKey: "controlMap") ?? "ctrl"
        optionMap = d.string(forKey: "optionMap") ?? "alt"
        shiftMap = d.string(forKey: "shiftMap") ?? "shift"
        invertVertical = d.bool(forKey: "invertVertical"); invertHorizontal = d.bool(forKey: "invertHorizontal")
        verticalSpeed = d.object(forKey: "verticalSpeed") as? Double ?? 1
        horizontalSpeed = d.object(forKey: "horizontalSpeed") as? Double ?? 1
        allowDiscovery = d.object(forKey: "allowDiscovery") as? Bool ?? true
        do {
            try prepareIdentity()
            if !LinkConfiguration.validName(localName) {
                let hostName = ProcessInfo.processInfo.hostName.components(separatedBy: ".")[0].replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "-", options: .regularExpression)
                localName = "Mac-" + String(hostName.prefix(100)) + "-" + String((PeerStore.pin(localFingerprint) ?? UUID().uuidString).prefix(6))
            }
            let catalog = try PeerStore(profile: settingsDir)
            try catalog.migrate(name: peerName, address: host, server: server, input: inputSettings)
            peers = catalog; applySelected(restoreInput: true); refreshDevices(); save()
        } catch { append("身份或设备列表准备失败：" + error.localizedDescription); detail = error.localizedDescription }
        syncLogin(); refreshAddresses(); updateDiscovery()
        watchNetwork()
        if autoConnect { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() } }
    }
    private func prepareIdentity() throws {
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Deskflow/tls")
        localFingerprint = try LinkIdentity.prepare(at: settingsDir, legacy: legacy)
    }
    private func watchNetwork() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.refreshAddresses()
                let signature = "\(path.status)" + self.addresses.sorted().joined(separator: ",")
                defer { self.pathSignature = signature }
                if self.pathSignature != nil, path.status == .satisfied {
                    self.scheduleRecovery("网络恢复或地址变化")
                }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "LinkDesk.Network"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.waking = true; self?.scheduleRecovery("电脑唤醒")
        }
    }
    private func scheduleRecovery(_ reason: String, force: Bool = false) {
        guard autoConnect, !closing else { return }
        if force { waking = true }
        recoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recover(reason) }
        recoveryWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
    private func recover(_ reason: String) {
        guard autoConnect, !closing, !restarting, !recoveryBlocked else { return }
        refreshAddresses(); let wasWaking = waking; waking = false
        guard !addresses.isEmpty else { return }
        guard AXIsProcessTrusted() else { title = "需要设备控制权限"; return }
        if running && coreReady && !wasWaking && (connected || server) { return }
        append("\(reason)，正在恢复共享。")
        guard let owned = child, owned.isRunning else { start(); return }
        restarting = true; desired = true; generation = UUID(); let token = generation
        channel?.send("stop"); channel?.disconnect(); channel = nil; coreReady = false; connected = false
        title = "正在恢复共享"; detail = "网络就绪后继续使用上次配置。"
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(2)
            while owned.isRunning && Date() < deadline { usleep(50_000) }
            if owned.isRunning { owned.terminate() }
            let exitDeadline = Date().addingTimeInterval(2)
            while owned.isRunning && Date() < exitDeadline { usleep(50_000) }
            DispatchQueue.main.async {
                guard self.generation == token else { return }
                self.restarting = false; self.running = owned.isRunning
                if self.autoConnect && !self.closing && !owned.isRunning { self.start() }
            }
        }
    }
    private func refreshDevices() { devices = peers?.devices ?? [] }
    private func applySelected(restoreInput: Bool) {
        guard let peer = selectedDevice else { return }
        peerName = peer.name; host = peer.address
        if restoreInput {
            let input = peer.input ?? (peer.platform == "Windows" ? LinkInputSettings.macToWindows : LinkInputSettings())
            commandMap = input.command; controlMap = input.control; optionMap = input.option; shiftMap = input.shift
            invertVertical = input.invertVertical; invertHorizontal = input.invertHorizontal
            verticalSpeed = input.verticalSpeed; horizontalSpeed = input.horizontalSpeed
        }
    }
    func chooseDevice(_ id: String) {
        guard !running else { issue = "请先停止共享，再切换设备。"; return }
        guard let peer = devices.first(where: { $0.id == id }) else { return }
        if !peer.paired { pendingPairID = id; pairing = peer.formattedFingerprint; return }
        do { stop(); try peers?.setInput(inputSettings); try peers?.select(id); applySelected(restoreInput: true); refreshDevices(); save(); title = "已选择 \(selectedLabel)"; detail = "点击启动共享；另一端也需选择本机并确认配对。" } catch { issue = error.localizedDescription }
    }
    func addManualDevice() {
        guard LinkConfiguration.validName(manualName), LinkConfiguration.validHost(manualAddress), let pin = PeerStore.pin(manualFingerprint), pin != PeerStore.pin(localFingerprint) else { issue = "请输入对方的本机名称、地址和完整 SHA-256 本机指纹；不能与本机配对。"; return }
        do {
            _ = try peers?.observe(PairedDevice(fingerprint: pin, name: manualName, address: manualAddress, platform: manualPlatform, role: server ? "client" : "server"))
            refreshDevices(); chooseDevice(pin)
        } catch { issue = error.localizedDescription }
    }
    func renameDevice(_ id: String, alias: String) { do { try peers?.rename(id, alias: alias); refreshDevices() } catch { issue = error.localizedDescription } }
    func forgetDevice(_ id: String) {
        guard !running else { issue = "请先停止共享，再忘记设备。"; return }
        do { if selectedDevice?.id == id { stop() }; try peers?.forget(id); refreshDevices(); title = "配对已移除"; detail = "再次连接需要重新核对指纹。" } catch { issue = error.localizedDescription }
    }
    func refreshDiscovery() { browser?.refresh() }
    private func updateDiscovery() {
        guard allowDiscovery, !closing, LinkConfiguration.validName(localName), let pin = PeerStore.pin(localFingerprint) else { stopDiscovery(); return }
        let signature = localName + ":" + (server ? "server" : "client") + ":" + pin
        if discoveryIdentity == signature { return }
        stopDiscovery(); discoveryIdentity = signature; let token = discoveryGeneration
        let service = DiscoveryResponder()
        if service.start(name: localName, identity: settingsDir.appendingPathComponent("tls/deskflow.pem"), role: server ? "server" : "client") { responder = service }
        else { append("设备公告启动失败；可使用手动添加。") }
        browser = DiscoveryClient(ownPin: pin, lastAddress: { [weak self] in self?.host ?? "" }, found: { [weak self] incoming in
            DispatchQueue.main.async {
                guard let self = self, !self.closing, self.discoveryGeneration == token else { return }
                self.observeDevice(incoming)
            }
        }, status: { [weak self] message in DispatchQueue.main.async { guard let self = self, self.discoveryGeneration == token, !self.closing else { return }; self.discoveryStatus = message; self.refreshDevices() } })
    }
    func observeDevice(_ incoming: PairedDevice) {
        guard !closing, let peers = peers else { return }
        do {
            let old = selectedDevice
            let selected = try peers.observe(incoming); refreshDevices()
            if selected {
                let returned = Date().timeIntervalSince(lastSelectedSeen) > 12; lastSelectedSeen = Date()
                applySelected(restoreInput: false); save()
                if old?.address != incoming.address || old?.name != incoming.name || returned {
                    scheduleRecovery("已核对所选设备的身份", force: old?.name != incoming.name || (!server && old?.address != incoming.address))
                }
            }
        } catch { append("设备列表：" + error.localizedDescription) }
    }
    private func stopDiscovery() {
        discoveryGeneration = UUID(); discoveryIdentity = nil
        responder?.stop(); responder = nil; browser?.stop(); browser = nil
        discoveryStatus = "局域网发现已关闭，可手动添加设备。"
    }
    func refreshAddresses() {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return }; defer { freeifaddrs(head) }
        var list: [String] = []; var cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = String(cString: name)
                if !value.hasPrefix("127.") && !value.hasPrefix("198.18.") { list.append(value) }
            }
        }
        addresses = list
    }
    func save() {
        let d = UserDefaults.standard
        d.set(localName, forKey: "localName"); d.set(peerName, forKey: "peerName")
        d.set(host, forKey: "host"); d.set(server, forKey: "server"); d.set(layout, forKey: "layout")
        d.set(commandMap, forKey: "commandMap"); d.set(controlMap, forKey: "controlMap")
        d.set(optionMap, forKey: "optionMap"); d.set(shiftMap, forKey: "shiftMap")
        d.set(invertVertical, forKey: "invertVertical"); d.set(invertHorizontal, forKey: "invertHorizontal")
        d.set(verticalSpeed, forKey: "verticalSpeed"); d.set(horizontalSpeed, forKey: "horizontalSpeed")
        do { try peers?.setInput(inputSettings) } catch { issue = error.localizedDescription }
        updateDiscovery()
    }
    var inputSettings: LinkInputSettings {
        LinkInputSettings(command: commandMap, control: controlMap, option: optionMap, shift: shiftMap, invertVertical: invertVertical, invertHorizontal: invertHorizontal, verticalSpeed: verticalSpeed, horizontalSpeed: horizontalSpeed)
    }
    func inputPreset(_ macHabit: Bool) {
        commandMap = macHabit ? "ctrl" : "super"; controlMap = macHabit ? "super" : "ctrl"
        optionMap = "alt"; shiftMap = "shift"
    }
    func append(_ line: String) {
        logs.append(line); if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }
    func start() {
        guard !running else { return }
        recoveryBlocked = false
        guard selectedDevice != nil else { tab = "devices"; issue = "请先选择并核对一台电脑。"; return }
        applySelected(restoreInput: false)
        guard AXIsProcessTrusted() else {
            recoveryBlocked = true
            title = "需要设备控制权限"
            detail = "请在系统设置中允许 LinkDesk，然后再次启动。"
            issue = "请在“系统设置 → 隐私与安全”中允许 LinkDesk。macOS 27 的项目名称是“设备控制和数据访问”，旧系统叫“辅助功能”。这是读取和转发键鼠所需的权限。"
            return
        }
        guard FileManager.default.isExecutableFile(atPath: engine.path) else {
            issue = "安装包中的连接核心不完整，请重新下载完整 LinkDesk 安装包。"; return
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "org.deskflow.deskflow").isEmpty {
            issue = "请先从 Deskflow 菜单选择“退出 Deskflow”，再在这里启动。两个界面不能同时管理同一个连接核心。"; return
        }
        if anotherCoreRunning() { issue = "Deskflow 连接核心仍在运行。请先退出原版 Deskflow，再启动 LinkDesk。"; return }
        do {
            try prepareIdentity()
            guard let session = try peers?.session(server: server) else { throw NSError(domain: "LinkDesk", code: 7, userInfo: [NSLocalizedDescriptionKey: "设备列表未就绪。"] ) }
            activeProfile = session
            let config = session.appendingPathComponent("linkdesk-server.conf")
            let text = try LinkConfiguration.settings(local: localName, peer: peerName, server: server, host: host, layout: layout, configPath: config.path, input: inputSettings)
            try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
            try text.write(to: session.appendingPathComponent("LinkDesk.conf"), atomically: true, encoding: .utf8)
            try LinkConfiguration.links(local: localName, peer: peerName, layout: layout).write(to: config, atomically: true, encoding: .utf8)
            save(); desired = true; failures = 0; autoConnect = true; launch()
        } catch { issue = error.localizedDescription }
    }
    private func launch() {
        if anotherCoreRunning() { desired = false; running = false; title = "另一个连接正在运行"; detail = "请先退出原版 Deskflow，再启动共享。"; return }
        generation = UUID(); let token = generation
        partial = ""; handledFingerprints.removeAll(); connected = false; coreReady = false
        let p = Process(); p.executableURL = engine
        guard let activeProfile = activeProfile, selectedDevice != nil else { desired = false; return }
        p.environment = ProcessInfo.processInfo.environment.merging(["XDG_STATE_HOME": activeProfile.path]) { _, new in new }
        p.arguments = [server ? "server" : "client", "--new-instance", "--settings", activeProfile.appendingPathComponent("LinkDesk.conf").path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { guard let self = self, self.generation == token else { return }; self.readLog(text) }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self = self, self.generation == token else { return }
                self.running = false; self.connected = false; self.channel?.disconnect(); self.channel = nil
                if self.desired && proc.terminationStatus != 0 {
                    self.failures += 1; self.title = "连接未启动"; self.detail = "请查看日志，检查权限或是否有其他连接程序在运行。"
                    if self.failures <= 3 {
                        let delay = Double(self.failures * 5); self.append("将在 \(Int(delay)) 秒后重试启动。")
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if self.desired && self.generation == token { self.launch() } }
                    } else { self.desired = false; self.append("已停止自动重试，请处理错误后再次启动。") }
                } else { self.title = "已停止"; self.detail = "点击启动，恢复键鼠共享。"; self.desired = false }
            }
        }
        do {
            try p.run(); child = p; running = true; title = "正在启动连接"; detail = "正在准备加密连接。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                guard self.running, self.generation == token else { return }
                let channel = CoreChannel(); self.channel = channel
                channel.connect(onMessage: { [weak self] message in guard self?.generation == token else { return }; self?.handle(message) }, onClosed: { [weak self] in
                    guard let self = self, self.generation == token, self.running else { return }
                    self.coreReady = false; self.connected = false; self.scheduleRecovery("共享状态通道断开")
                })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                guard self.generation == token, self.running, !self.coreReady else { return }
                self.desired = false; self.channel?.send("stop"); if p.isRunning { p.terminate() }
                self.issue = "连接核心启动超时。请检查设备控制权限，以及是否有另一份 Deskflow 在运行。"
                self.append("启动超过 10 秒且未收到核心状态，已停止本次启动。")
            }
        } catch { desired = false; issue = error.localizedDescription; title = "启动失败" }
    }
    private func anotherCoreRunning() -> Bool {
        let check = Process(); check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); check.arguments = ["-x", "deskflow-core"]
        check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
        do { try check.run(); check.waitUntilExit(); return check.terminationStatus == 0 } catch { return false }
    }
    func stop() {
        desired = false; autoConnect = false; connected = false
        recoveryWork?.cancel(); waking = false
        guard let child = child, child.isRunning else { running = false; return }
        channel?.send("stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if child.isRunning { child.terminate() }
            if self.child === child && !self.autoConnect { self.running = false; self.title = "已停止"; self.detail = "点击启动，恢复键鼠共享。" }
        }
        title = "正在停止"; detail = "正在结束共享连接。"
    }
    func shutdown() {
        closing = true; recoveryWork?.cancel(); networkMonitor.cancel(); stopDiscovery()
        if let observer = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        desired = false; channel?.send("stop")
        if let child = child {
            let deadline = Date().addingTimeInterval(2)
            while child.isRunning && Date() < deadline { usleep(50_000) }
            if child.isRunning { child.terminate() }
        }
        channel?.disconnect()
    }
    func readLog(_ text: String) {
        partial += text
        while let index = partial.firstIndex(of: "\n") {
            let line = String(partial[..<index]); partial.removeSubrange(...index); append(line)
            if line.contains("FATAL") || line.contains("ERROR") { detail = "启动遇到问题，请在“连接日志”中查看详情。" }
            if line.contains("accessibility") || line.contains("Accessibility") || line.contains("assistive devices") {
                desired = false
                recoveryBlocked = true
                detail = "请在系统设置中允许 LinkDesk 的辅助功能权限，然后再次启动。"
            }
        }
    }
    func handle(_ message: String) {
        let pieces = message.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let command = String(pieces[0]); let args = pieces.count > 1 ? String(pieces[1]) : ""
        switch command {
        case "hello": coreReady = true; updateDiscovery(); title = server ? "等待所选设备" : "正在连接所选设备"; detail = "加密连接开启，网络恢复后会自动重连。"
        case "connectionState":
            connected = args == "Connected"
            title = connected ? "两台电脑已连接" : (running ? (server ? "等待所选设备" : "正在重连") : "已停止")
            detail = connected ? "可以把指针移到另一台电脑，键盘会跟随。" : "保持两台电脑联网，连接会自动恢复。"
        case "connectedClients":
            connected = !args.isEmpty; title = connected ? "两台电脑已连接" : "等待所选设备"
            detail = connected ? "已连接：\(args) · 加密传输" : "另一台电脑恢复联网后会自动连接。"
        case "peerFingerprint":
            guard let pin = PeerStore.pin(args), !handledFingerprints.contains(pin) else { return }
            handledFingerprints.insert(pin)
            if pin != selectedDevice?.fingerprint { stop(); recoveryBlocked = true; title = "设备身份不一致"; detail = "对方指纹与所选设备不同，连接已停止。请先在设备列表重新核对身份。"; append("拒绝身份不一致的连接；没有修改配对。") }
        case "connectionRefused": detail = "对方拒绝连接（\(args)），请核对电脑名称与配对。"
        default: break
        }
    }
    func trustPeer() {
        guard let id = pendingPairID, let value = pairing, PeerStore.pin(value) == id else { return }
        do { stop(); try peers?.setInput(inputSettings); try peers?.pair(id); applySelected(restoreInput: true); refreshDevices(); pairing = nil; pendingPairID = nil; save(); title = "已选择 \(selectedLabel)"; detail = "指纹已绑定。点击启动共享，并在另一端选择本机。" } catch { issue = error.localizedDescription }
    }
    func syncLogin() { loginEnabled = SMAppService.mainApp.status == .enabled }
    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register(); autoConnect = true }
            else { try SMAppService.mainApp.unregister() }
            syncLogin()
            if value && !loginEnabled { issue = "请在系统设置的“登录项与扩展”中批准 LinkDesk。"; SMAppService.openSystemSettingsLoginItems() }
        } catch { syncLogin(); issue = "自启动设置未生效：\(error.localizedDescription)。请先把 LinkDesk 移到“应用程序”目录后重试。" }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: LinkModel?
    var item: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "LinkDesk", withExtension: "icns"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = NSImage(systemSymbolName: "rectangle.connected.to.line.below", accessibilityDescription: "LinkDesk")
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开 LinkDesk", action: #selector(showWindow), keyEquivalent: ""); open.target = self; menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出并停止共享", action: #selector(quitApp), keyEquivalent: ""); quit.target = self; menu.addItem(quit)
        item?.menu = menu
    }
    @objc func showWindow() { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.title == "LinkDesk" })?.makeKeyAndOrderFront(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return false }
    @objc func quitApp() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model?.background == true { sender.orderOut(nil); return false }
        NSApp.terminate(nil); return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
}
struct WindowHook: NSViewRepresentable {
    let delegate: AppDelegate
    func makeNSView(context: Context) -> NSView { let view = NSView(); DispatchQueue.main.async { view.window?.delegate = delegate; view.window?.title = "LinkDesk" }; return view }
    func updateNSView(_ view: NSView, context: Context) {}
}

@main struct LinkDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = LinkModel()
    var body: some Scene {
        Window("LinkDesk", id: "main") {
            RootView(model: model).background(WindowHook(delegate: delegate)).onAppear { delegate.model = model }
                .alert("需要处理", isPresented: Binding(get: { model.issue != nil }, set: { if !$0 { model.issue = nil } })) {
                    if model.issue?.contains("设备控制") == true || model.issue?.contains("辅助功能") == true { Button("打开系统设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!); model.issue = nil } }
                    Button("知道了") { model.issue = nil }
                } message: { Text(model.issue ?? "") }
                .sheet(isPresented: Binding(get: { model.pairing != nil }, set: { if !$0 { model.pairing = nil } })) {
                    VStack(alignment: .leading, spacing: 18) {
                        Image(systemName: "lock.shield").font(.system(size: 32)).foregroundStyle(accent)
                        Text("确认 \(model.pairingLabel)").font(.title2.bold())
                        Text("请与另一台电脑显示的本地指纹核对。只有完全一致时才允许配对。")
                        Text(model.pairing ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        HStack { Button("暂不配对") { model.pairing = nil }; Spacer(); Button("指纹一致，配对并选择") { model.trustPeer() }.buttonStyle(.borderedProminent).tint(accent) }
                    }.padding(28).frame(width: 480)
                }
        }.defaultSize(width: 1030, height: 720).windowResizability(.contentSize)
    }
}

struct RootView: View {
    @ObservedObject var model: LinkModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) { Image(systemName: "rectangle.connected.to.line.below").font(.title2).foregroundStyle(accent); Text("LinkDesk").font(.system(size: 22, weight: .bold)) }
                Text("一套键鼠，两台电脑").font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    nav("connection", "电脑连接", "rectangle.connected.to.line.below")
                nav("devices", "配对设备", "link")
                    nav("settings", "偏好设置", "slider.horizontal.3")
                    nav("input", "键盘与鼠标", "keyboard")
                    nav("logs", "连接日志", "text.alignleft")
                }.padding(.top, 16)
                Spacer()
                Label("基于 Deskflow 1.27", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Text("LinkDesk · 0.4.2").font(.caption2).foregroundStyle(.tertiary)
            }.padding(24).frame(width: 210).frame(maxHeight: .infinity).background(.white.opacity(0.72))
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) { Text(model.tab == "connection" ? "让工作自然流动" : model.tab == "devices" ? "配对与选择设备" : model.tab == "settings" ? "按你的习惯运行" : model.tab == "input" ? "熟悉的按键，顺手的滚动" : "连接日志").font(.system(size: 28, weight: .bold)); Text(model.tab == "connection" ? "把注意力留给工作，让键鼠跟随你。" : model.tab == "devices" ? "连接所选电脑，身份由完整指纹确认。" : model.tab == "settings" ? "设置一次，以后轻松连接。" : model.tab == "input" ? "按键映射与滚动设置，在这里一起调整。" : "这里记录真实的连接与错误信息。").foregroundStyle(.secondary) }
                        Spacer()
                        Text("MAC").font(.caption.bold()).tracking(2).padding(.horizontal, 12).padding(.vertical, 8).background(.white, in: Capsule())
                    }
                    if model.tab == "connection" { connection }
                    else if model.tab == "devices" { deviceView }
                    else if model.tab == "settings" { settings }
                    else if model.tab == "input" { inputView }
                    else { logView }
                }.padding(32)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 1000, minHeight: 680).background(paper).foregroundStyle(ink)
    }
    func nav(_ id: String, _ label: String, _ icon: String) -> some View {
        Button { model.tab = id } label: { Label(label, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(13).background(model.tab == id ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(model.tab == id ? accent : ink).contentShape(RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain).frame(maxWidth: .infinity)
    }
    @ViewBuilder var connection: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Circle().fill(model.connected ? Color.green : model.running ? accent : .gray).frame(width: 9, height: 9)
                Text(model.title).font(.headline)
                Spacer()
                Label(model.connected ? "已加密" : "加密连接", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.detail).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                computer(model.localName, model.server ? "共享键鼠 · 本机" : "接收键鼠 · 本机", "laptopcomputer")
                Image(systemName: model.layout == "up" || model.layout == "down" ? "arrow.up.arrow.down" : "arrow.left.arrow.right").font(.title2).foregroundStyle(accent)
                computer(model.selectedLabel, model.selectedDevice?.platformLabel ?? "先选择配对设备", model.selectedDevice?.platform == "macOS" ? "laptopcomputer" : "desktopcomputer")
            }.padding(.vertical, 16)
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.server ? "另一台电脑连接这个地址" : "连接共享端地址").font(.caption).foregroundStyle(.secondary)
                    Text(model.server ? (model.addresses.first ?? "尚未获取网络地址") : model.host).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                }
                Spacer()
                if model.server { Button("刷新地址") { model.refreshAddresses() }.buttonStyle(.borderless) }
                Button(model.running ? "停止共享" : "启动共享") { model.running ? model.stop() : model.start() }.buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
            }
            Divider().padding(.top, 4)
            Text("本机指纹 · 首次配对时供另一台电脑核对").font(.caption).foregroundStyle(.secondary)
            Text(model.localFingerprint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.padding(26).background(.white, in: RoundedRectangle(cornerRadius: 22))
        VStack(alignment: .leading, spacing: 14) {
            Label("连接方式", systemImage: "arrow.triangle.branch").font(.headline)
            HStack {
                Text("另一台电脑在本机的")
                Picker("位置", selection: $model.layout) { Text("右侧").tag("right"); Text("左侧").tag("left"); Text("上方").tag("up"); Text("下方").tag("down") }.labelsHidden().frame(width: 100).disabled(model.running || !model.server)
                Spacer(); Button("选择配对设备") { model.tab = "devices" }.buttonStyle(.borderless)
            }
            Text(model.server ? "指针移出对应屏幕边缘时切换，键盘会跟随。更改位置后在下次启动生效。" : "接收端的屏幕位置由共享键鼠的电脑设置。") .font(.caption).foregroundStyle(.secondary)
        }.padding(22).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
        Label(model.discoveryStatus, systemImage: "antenna.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary)
    }
    func computer(_ name: String, _ subtitle: String, _ symbol: String) -> some View {
        VStack(spacing: 13) { Image(systemName: symbol).font(.system(size: 52, weight: .light)).foregroundStyle(ink.opacity(0.75)); Text(name).font(.headline).lineLimit(1); Text(subtitle).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(20).background(paper, in: RoundedRectangle(cornerRadius: 16))
    }
    @ViewBuilder var deviceView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("选择当前连接的电脑").font(.headline); Spacer(); Button("刷新发现") { model.refreshDiscovery() }.buttonStyle(.bordered) }
            Text("可以配对多台电脑，每次选择一台连接。名称相同也会按指纹区分，地址变化不会改变设备身份。").font(.callout).foregroundStyle(.secondary)
            Text(model.discoveryStatus).font(.caption).foregroundStyle(.secondary)
            if model.devices.isEmpty { Text("尚未发现设备。请在另一台电脑打开新版 LinkDesk，并在两端分别选择共享与接收；也可在下方手动添加。").foregroundStyle(.secondary).padding(.vertical, 12) }
            ForEach(model.devices) { device in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: device.platform == "macOS" ? "laptopcomputer" : "desktopcomputer").foregroundStyle(accent)
                        Text(device.label).font(.headline)
                        Spacer()
                        Text(model.selectedDevice?.id == device.id ? "当前选择" : device.paired ? "已配对" : "未配对").font(.caption).foregroundStyle(device.paired ? accent : .secondary)
                    }
                    Text("\(device.platformLabel) · \(device.roleLabel) · \(device.online ? "应用在线" : "上次地址") · \(device.address)").font(.caption).foregroundStyle(.secondary)
                    Text("指纹 \(device.shortID)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    DisclosureGroup("完整指纹") { Text(device.formattedFingerprint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.top, 8) }.font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(device.paired ? "选择连接" : "核对指纹并配对") { model.chooseDevice(device.id) }.buttonStyle(.borderedProminent).tint(accent)
                        if device.paired {
                            Button("重命名") { model.renameText = device.alias.isEmpty ? device.name : device.alias; model.renameID = device.id }.buttonStyle(.bordered)
                            Button("忘记设备") { model.forgetID = device.id }.buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.disabled(model.running)
                }.padding(18).background(paper, in: RoundedRectangle(cornerRadius: 16))
            }
            if model.running { Text("请先停止共享，再切换或忘记设备。").font(.caption).foregroundStyle(.secondary) }
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
        DisclosureGroup("手动添加设备（发现不可用时）") {
            VStack(alignment: .leading, spacing: 16) {
                field("对方本机名称", $model.manualName)
                field("对方地址", $model.manualAddress)
                field("完整指纹", $model.manualFingerprint)
                HStack { Text("对方系统").frame(width: 100, alignment: .leading); Picker("对方系统", selection: $model.manualPlatform) { Text("未知").tag("unknown"); Text("macOS").tag("macOS"); Text("Windows").tag("Windows") }.labelsHidden() }
                Text("名称、地址和完整指纹都从另一台电脑的连接页获取。另一端用途应设为" + (model.server ? "接收键鼠。" : "共享键鼠。")).font(.caption).foregroundStyle(.secondary)
                Button("添加并核对指纹") { model.addManualDevice() }.buttonStyle(.borderedProminent).tint(accent)
            }.padding(.top, 16).disabled(model.running)
        }.padding(24).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
        .sheet(isPresented: Binding(get: { model.renameID != nil }, set: { if !$0 { model.renameID = nil } })) {
            VStack(alignment: .leading, spacing: 18) { Text("设备备注名称").font(.title2.bold()); TextField("备注名称", text: $model.renameText).textFieldStyle(.roundedBorder); Text("只改变本机列表中的备注，指纹和对方名称保持不变。").font(.caption).foregroundStyle(.secondary); HStack { Button("取消") { model.renameID = nil }; Spacer(); Button("保存") { if let id = model.renameID { model.renameDevice(id, alias: model.renameText) }; model.renameID = nil }.buttonStyle(.borderedProminent).tint(accent) } }.padding(28).frame(width: 420)
        }
        .alert("忘记这台设备？", isPresented: Binding(get: { model.forgetID != nil }, set: { if !$0 { model.forgetID = nil } })) {
            Button("取消", role: .cancel) { model.forgetID = nil }; Button("忘记设备", role: .destructive) { if let id = model.forgetID { model.forgetDevice(id) }; model.forgetID = nil }
        } message: { Text("将撤销配对；再次连接需要重新核对完整指纹。") }
    }
    @ViewBuilder var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("启动与后台").font(.headline)
            settingRow("登录后自启动", "登录这台 Mac 后，自动打开 LinkDesk 并启动连接。", Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            Divider()
            settingRow("自动连接与恢复", "打开应用、网络恢复或唤醒后，继续上次共享。手动停止后保持停止。", $model.autoConnect)
            Divider()
            settingRow("关闭窗口后留在后台", "窗口关闭后继续共享，通过菜单栏图标重新打开。", $model.background)
            Divider()
            settingRow("局域网发现与自动查找", "发现同一局域网的电脑，核对所选设备身份后更新地址。", $model.allowDiscovery)
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
        VStack(alignment: .leading, spacing: 16) {
            Text("电脑与网络").font(.headline)
            HStack(spacing: 8) {
                Text("本机用途").frame(width: 100, alignment: .leading)
                Picker("本机用途", selection: $model.server) { Text("共享本机键鼠").tag(true); Text("接收另一台电脑的键鼠").tag(false) }.labelsHidden().pickerStyle(.segmented)
            }
            field("本机名称", $model.localName)
            Text("当前选择：" + model.selectedLabel)
            Text("Mac 与 Windows 都可共享或接收键鼠。两台电脑连接同一路由器、热点或可互通的局域网即可，无需固定的热点形式。") .font(.caption).foregroundStyle(.secondary)
            HStack { Button("保存电脑信息") { model.save() }.buttonStyle(.bordered); Spacer() }
        }.disabled(model.running).padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
        Button("打开设备控制权限设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }.buttonStyle(.borderless)
        Text("已内置连接核心。首次配对请核对两端显示的本机指纹；已有配对会自动迁移。快捷键暂未设置。") .font(.caption).foregroundStyle(.secondary)
    }
    func settingRow(_ title: String, _ subtitle: String, _ value: Binding<Bool>) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 14, weight: .semibold)); Text(subtitle).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).tint(accent).accessibilityLabel(title).accessibilityHint(subtitle)
        }
    }
    func field(_ label: String, _ value: Binding<String>) -> some View { HStack(spacing: 8) { Text(label).frame(width: 100, alignment: .leading); TextField(label, text: value).textFieldStyle(.roundedBorder) } }
    @ViewBuilder var inputView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("控制另一台电脑时的按键映射").font(.headline)
            Text(model.server ? "作用于 \(model.selectedLabel)，本机按键保持原样。" : "按键映射由共享端设置，请在另一台电脑的 LinkDesk 调整。") .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                HStack { Button("跨系统常用习惯") { model.inputPreset(true) }; Button("保持原样") { model.inputPreset(false) } }.buttonStyle(.bordered)
                modifierRow("Command / ⌘", $model.commandMap)
                modifierRow("Control / ⌃", $model.controlMap)
                modifierRow("Option / ⌥", $model.optionMap)
                modifierRow("Shift / ⇧", $model.shiftMap)
                Text("不同系统默认交换 Command/Windows 与 Ctrl/Control，同系统保持原样。设置分别随所选设备保存。") .font(.caption).foregroundStyle(.secondary)
            }.disabled(!model.server || model.running)
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
        VStack(alignment: .leading, spacing: 18) {
            Text("接收键鼠时的滚动").font(.headline)
            Text(model.server ? "接收端的滚动方向与速度，请在另一台电脑的“键盘与鼠标”设置。" : "仅调整这台 Mac 收到的远程滚动，不修改本机鼠标或 Mos。") .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 18) {
                settingRow("反转纵向滚动", "远程滚轮上下方向相反时开启。", $model.invertVertical)
                settingRow("反转横向滚动", "单独调整左右滚动方向。", $model.invertHorizontal)
                scrollSpeed("纵向滚动速度", $model.verticalSpeed)
                scrollSpeed("横向滚动速度", $model.horizontalSpeed)
                Button("恢复滚动默认值") { model.invertVertical = false; model.invertHorizontal = false; model.verticalSpeed = 1; model.horizontalSpeed = 1 }.buttonStyle(.bordered)
            }.disabled(model.server || model.running)
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
        HStack { Text(model.running ? "请先停止共享，再修改设置。" : "保存后，下次启动共享生效。") .font(.caption).foregroundStyle(.secondary); Spacer(); Button("保存键鼠设置") { model.save() }.buttonStyle(.borderedProminent).tint(accent).disabled(model.running) }
    }
    func modifierRow(_ label: String, _ value: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 140, alignment: .leading)
            Picker(label, selection: value) {
                Text("Ctrl / Control").tag("ctrl"); Text("Windows / Command").tag("super")
                Text("Alt / Option").tag("alt"); Text("Shift").tag("shift")
                Text("Meta").tag("meta"); Text("AltGr").tag("altgr"); Text("不发送此修饰键").tag("none")
            }.labelsHidden().frame(maxWidth: .infinity)
        }
    }
    func scrollSpeed(_ title: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 16) { Text(title).frame(width: 140, alignment: .leading); Slider(value: value, in: 0.1...3, step: 0.1).accessibilityLabel(title); Text(String(format: "%.1f×", value.wrappedValue)).monospacedDigit().frame(width: 50) }
    }
    var logView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("最近 300 条记录").font(.headline); Spacer(); Button("复制日志") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.logs.joined(separator: "\n"), forType: .string) }; Button("清空显示") { model.logs.removeAll() } }
            Text(model.logs.isEmpty ? "还没有连接记录。启动共享后，这里会显示日志。" : model.logs.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
    }
}
