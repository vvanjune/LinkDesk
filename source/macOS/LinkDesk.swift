import SwiftUI
import AppKit
import ServiceManagement
import ApplicationServices
import Darwin
import Network
import CryptoKit

let ink = Color(red: 0.14, green: 0.17, blue: 0.23)
let accent = Color(red: 0.30, green: 0.32, blue: 0.83)
let paper = Color(red: 0.96, green: 0.96, blue: 0.94)

final class CoreChannel {
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var stopped = false
    private let socketPath: String
    init(path: String? = nil) { socketPath = path ?? FileManager.default.temporaryDirectory.appendingPathComponent("deskflow-core").path }
    func connect(onMessage: @escaping (String) -> Void, onClosed: @escaping () -> Void = {}) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let path = self.socketPath
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
    @Published var addressID: String?
    @Published var addressText = ""
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
    @Published var background = true { didSet { defaults.set(background, forKey: "background") } }
    @Published var autoConnect = false { didSet { defaults.set(autoConnect, forKey: "autoConnect"); if !autoConnect { recoveryWork?.cancel(); recoveryRevision = UUID() } } }
    @Published var autoStartOnLaunch = false { didSet { defaults.set(autoStartOnLaunch, forKey: "autoStartOnLaunch"); if !autoStartOnLaunch { cancelAutomaticStart() } } }
    @Published var wakeDisplayOnRemoteInput = false { didSet { defaults.set(wakeDisplayOnRemoteInput, forKey: "wakeDisplayOnRemoteInput") } }
    @Published var switchDelay = 0 { didSet { defaults.set(switchDelay, forKey: "switchDelay") } }
    private var lastSessionRequested = false
    private var startupWork: DispatchWorkItem?
    private var startupRevision = UUID()
    private var recoveryRevision = UUID()
    private var activeConfiguration = ""
    private var probeNonce: String?
    private var probeCompletion: ((Bool) -> Void)?
    private var suspended = false
    private var displaySleeping = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private let observeSystemEvents: Bool
    private let hasDeviceControl: () -> Bool
    private let desktopState: () -> MacDesktopSnapshot
    private let foreignCore: (() -> Bool)?
    private let failureNotice: TimeInterval
    private let failureEscalate: TimeInterval
    private var failingSince: Date?
    private var lastRefreshAt = Date.distantPast
    private var failureCount = 0
    private var failureEscalated = false
    private var failureRevision = UUID()
    private(set) var failureRefreshes = 0
    private func resetFailure() { connectionFailure = ""; refusalDetail = ""; failingSince = nil; failureCount = 0; failureEscalated = false; lastRefreshAt = .distantPast; failureRevision = UUID() }
    private func connectionRecovered() {
        if let since = failingSince { let seconds = Int(Date().timeIntervalSince(since)); append("连接恢复，本次中断 \(seconds / 60) 分 \(seconds % 60) 秒") }
        resetFailure()
    }
    private func observeConnectionOutput(_ line: String) -> Bool {
        guard desired, !closing, !server else { return false }
        let lower = line.lowercased()
        if lower.contains("connected to secure socket") { if connected || !refusalDetail.isEmpty { return false }; title = "正在确认共享连接"; detail = "加密通道已建立，等待共享会话确认。"; return false }
        guard lower.contains("failed to connect to server") || lower.contains("server is dead") else { return false }
        connectionFailure = lower.contains("refused") ? "当前地址的连接被拒绝，请确认对端已启动共享并允许局域网访问。" : lower.contains("timed out") ? "连接超时，尚不能判断是对端未就绪、网络隔离还是防火墙阻断。" : lower.contains("server is dead") ? "与共享端的连接已中断，正在等待重新连接。" : "暂时无法建立连接，请确认地址和对端共享状态。"
        connected = false; failureCount += 1
        if failingSince == nil { title = "正在重连所选设备"; detail = "当前地址：" + host; failingSince = Date(); append("连接失败开始：" + host); failureRevision = UUID(); watchFailure(failureRevision) }
        return true
    }
    private func watchFailure(_ revision: UUID) {
        guard revision == failureRevision, let since = failingSince, desired, !closing, !server else { return }
        if running && !restarting && !suspended && !recoveryBlocked {
            let now = Date(); let elapsed = now.timeIntervalSince(since)
            if autoConnect && elapsed >= failureNotice && now.timeIntervalSince(lastRefreshAt) >= 15 { lastRefreshAt = now; failureRefreshes += 1; browser?.refresh() }
            if elapsed >= failureEscalate && !failureEscalated { failureEscalated = true; append("连接失败持续：" + host + "；请检查对端共享与网络。") }
            showConnectionFailure()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.watchFailure(revision) }
    }
    var connectionDiagnosis: String {
        let found: String
        if let peer = selectedDevice, peer.online {
            found = peer.role == "client" ? "最近发现对端应用，但它公告为接收端；请核对另一端已切换到共享。" : "最近发现对端应用；发现成功不代表共享连接已建立。"
        } else { found = allowDiscovery ? "暂未发现所选设备，这不代表 Wi-Fi 已断开。" : "局域网发现已关闭，请核对保存的地址。" }
        return "当前地址：" + host + "。" + found + " " + connectionFailure + " 若地址已变，可停止共享后在“配对设备”更新地址。"
    }
    private func showConnectionFailure() {
        guard desired, !connected, !restarting, !recoveryBlocked else { return }
        if !refusalDetail.isEmpty { title = "连接被拒绝"; detail = refusalDetail; return }
        guard let since = failingSince else { return }
        title = failureEscalated ? "无法连接所选设备" : Date().timeIntervalSince(since) >= failureNotice ? (autoConnect && allowDiscovery ? "正在重新查找所选设备" : "正在等待重新连接") : "正在重连所选设备"
        detail = connectionDiagnosis
    }
    private let recoveryDelay: TimeInterval
    private let ipcPath: String?
    @Published var addresses: [String] = []
    @Published var allowDiscovery = true { didSet { defaults.set(allowDiscovery, forKey: "allowDiscovery"); updateDiscovery() } }
    @Published var discoveryStatus = "正在查找局域网设备。" { didSet { if oldValue != discoveryStatus { append("发现状态：" + discoveryStatus) } } }
    private let networkMonitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    private var recoveryWork: DispatchWorkItem?
    private var pathSignature: String?
    private var restarting = false
    private var urgentRecovery = false
    private var restartPending = false
    private var settingsPending = false
    private var identityRejected = false
    private var stopRevision = UUID()
    private var coreStartedAt = Date.distantPast
    private var connectionFailure = ""
    private var refusalDetail = ""
    private var desktopReady: Bool { !suspended && desktopState().ready && hasDeviceControl() }
    private var closing = false
    private var recoveryBlocked = false
    private var responder: DiscoveryResponder?
    private var child: Process?
    private var channel: CoreChannel?
    private var desired = false
    private var generation = UUID()
    private var partial = ""
    private var coreReady = false
    private var handledFingerprints = Set<String>()
    let settingsDir: URL
    let engine: URL
    init(defaults: UserDefaults = .standard, profile: URL? = nil, engine: URL? = nil, observeSystemEvents: Bool = true, hasDeviceControl: @escaping () -> Bool = { AXIsProcessTrusted() }, desktopState: @escaping () -> MacDesktopSnapshot = MacDesktopState.read, foreignCore: (() -> Bool)? = nil, recoveryDelay: TimeInterval = 10, ipcPath: String? = nil, failureNotice: TimeInterval = 30, failureEscalate: TimeInterval = 60) {
        self.failureNotice = failureNotice; self.failureEscalate = failureEscalate
        self.defaults = defaults; self.settingsDir = profile ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LinkDesk")
        self.engine = engine ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/deskflow-core")
        self.observeSystemEvents = observeSystemEvents; self.hasDeviceControl = hasDeviceControl; self.desktopState = desktopState; self.foreignCore = foreignCore; self.recoveryDelay = recoveryDelay; self.ipcPath = ipcPath
        let d = defaults
        background = d.object(forKey: "background") as? Bool ?? true
        autoConnect = d.object(forKey: "autoConnect") as? Bool ?? true
        autoStartOnLaunch = d.bool(forKey: "autoStartOnLaunch")
        wakeDisplayOnRemoteInput = d.bool(forKey: "wakeDisplayOnRemoteInput")
        switchDelay = d.integer(forKey: "switchDelay")
        lastSessionRequested = d.bool(forKey: "lastSessionRequested")
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
        if observeSystemEvents { syncLogin(); watchNetwork() }
        refreshAddresses(); updateDiscovery()
        append("启动应用与自动开始共享已分开；不继承旧版自动启动行为。")
    }
    private func prepareIdentity() throws {
        let legacy = observeSystemEvents ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Deskflow/tls") : settingsDir.appendingPathComponent("no-legacy")
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
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.pauseSignal() })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.resumeSignal() })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.pauseSignal() })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.resumeSignal() })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.displaySleeping = true; self?.cancelAutomaticStart() })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.displaySleeping = false; self?.applyPendingSettings(); if self?.desired == true { self?.scheduleRecovery("屏幕唤醒") } else { self?.beginAutomaticStart() } })
    }
    func beginAutomaticStart() {
        cancelAutomaticStart()
        guard !closing, autoStartOnLaunch, lastSessionRequested, !running, !desired else { return }
        let revision = startupRevision; var stability = MacDesktopStability()
        title = "等待桌面准备就绪"; detail = "登录桌面和显示路径稳定后恢复共享；停止可取消。"
        func check() {
            guard !self.closing, self.startupRevision == revision, self.autoStartOnLaunch, self.lastSessionRequested, !self.running else { return }
            let snapshot = self.desktopState()
            if !self.suspended && !self.displaySleeping && self.hasDeviceControl() && stability.observe(snapshot, at: Date()) { self.start(); return }
            let work = DispatchWorkItem { check() }; self.startupWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
        let work = DispatchWorkItem { check() }; startupWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }
    private func cancelAutomaticStart() { startupRevision = UUID(); startupWork?.cancel(); startupWork = nil }
    private func cancelQueuedRecovery() { cancelAutomaticStart(); recoveryRevision = UUID(); recoveryWork?.cancel() }
    func pauseSignal() { suspended = true; cancelQueuedRecovery() }
    func resumeSignal() { suspended = false; applyPendingSettings(); append("电脑唤醒：检查已有核心，不强制重启。"); if desired { scheduleRecovery("电脑唤醒") } else { beginAutomaticStart() } }
    func networkSignal() { refreshAddresses(); scheduleRecovery("网络变化") }
    private var configurationSignature: String { "\(server)|\(localName)|\(peerName)|\(server ? "" : host)|\(layout)|\(inputSettings)|\(wakeDisplayOnRemoteInput)|\(switchDelay)|\(selectedDevice?.fingerprint ?? "")" }
    private func probeCore(_ completion: @escaping (Bool) -> Void) {
        guard coreReady, let channel = channel else { completion(false); return }
        let nonce = UUID().uuidString; probeNonce = nonce; probeCompletion = completion
        channel.send("ping=" + nonce)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.probeNonce == nonce else { return }
            self.finishProbe(false)
        }
    }
    private func finishProbe(_ result: Bool) { let completion = probeCompletion; probeNonce = nil; probeCompletion = nil; completion?(result) }
    private func scheduleRecovery(_ reason: String, immediate: Bool = false) {
        guard autoConnect, desired, !closing, !suspended, !recoveryBlocked else { return }
        urgentRecovery = urgentRecovery || immediate
        recoveryWork?.cancel(); let revision = UUID(); recoveryRevision = revision
        let work = DispatchWorkItem { [weak self] in self?.recover(reason, revision: revision) }
        recoveryWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + (urgentRecovery ? 0 : recoveryDelay), execute: work)
    }
    private func recover(_ reason: String, revision: UUID) {
        guard autoConnect, desired, !closing, !suspended, !recoveryBlocked, recoveryRevision == revision else { return }
        if restarting || (running && !coreReady && Date().timeIntervalSince(coreStartedAt) < 10) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.recover(reason, revision: revision) }; return }
        refreshAddresses()
        guard !addresses.isEmpty, desktopReady else { append(reason + "：网络或桌面尚未就绪，保留核心。"); return }
        if restartPending && child == nil && !running { urgentRecovery = false; start(); restartPending = false; return }
        guard let owned = child, owned.isRunning else { desired = false; recoveryBlocked = true; lastSessionRequested = false; defaults.set(false, forKey: "lastSessionRequested"); return }
        restarting = true
        probeCore { [weak self] responsive in
            guard let self = self else { return }
            guard self.autoConnect, self.desired, !self.closing, self.recoveryRevision == revision else { self.restarting = false; return }
            let changed = self.configurationSignature != self.activeConfiguration
            guard self.desktopReady else { self.restarting = false; return }
            if !responsive {
                self.restarting = false; self.recoveryBlocked = true; self.title = "共享核心暂未响应"; self.detail = "保留进程，不自动反复重启。请查看日志后手动停止并重试。"; return
            }
            if !changed {
                self.urgentRecovery = false; self.restarting = false
                self.append(reason + "：核心正常，保留进程 pid=\(owned.processIdentifier)。")
                return
            }
            self.reloadCore(reason: reason, automatic: true)
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
    func updateSelectedAddress(_ id: String, address: String) throws {
        guard !running, !desired, !restarting else { throw NSError(domain: "LinkDesk", code: 10, userInfo: [NSLocalizedDescriptionKey: "请先停止共享，再更新地址。"]) }
        guard let peers = peers else { throw NSError(domain: "LinkDesk", code: 11, userInfo: [NSLocalizedDescriptionKey: "设备列表尚未就绪。"]) }
        let old = selectedDevice?.address ?? ""
        try peers.updateSelectedAddress(id, address: address.trimmingCharacters(in: .whitespacesAndNewlines))
        applySelected(restoreInput: false); save(); refreshDevices(); lastSelectedSeen = .distantPast
        append("手动更新所选设备地址：\(old) → \(host)；配对指纹不变。")
        title = "设备地址已更新"; detail = "点击启动共享，仍会核对原有配对身份。"
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
                let returned = lastSelectedSeen != .distantPast && Date().timeIntervalSince(lastSelectedSeen) > 12; lastSelectedSeen = Date()
                applySelected(restoreInput: false); save()
                if old?.address != incoming.address || old?.name != incoming.name || returned {
                    let addressChanged = old?.address != incoming.address
                    if addressChanged { append("所选设备地址更新：\(old?.address ?? "") → \(incoming.address)（\(incoming.name)）") }
                    if returned { append("所选设备重新在线：" + incoming.address) }
                    scheduleRecovery(addressChanged ? "所选设备地址已更新" : "已核对所选设备的身份", immediate: addressChanged)
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
        let d = defaults
        d.set(localName, forKey: "localName"); d.set(peerName, forKey: "peerName")
        d.set(host, forKey: "host"); d.set(server, forKey: "server"); d.set(layout, forKey: "layout")
        d.set(commandMap, forKey: "commandMap"); d.set(controlMap, forKey: "controlMap")
        d.set(optionMap, forKey: "optionMap"); d.set(shiftMap, forKey: "shiftMap")
        d.set(invertVertical, forKey: "invertVertical"); d.set(invertHorizontal, forKey: "invertHorizontal")
        d.set(verticalSpeed, forKey: "verticalSpeed"); d.set(horizontalSpeed, forKey: "horizontalSpeed")
        d.set(switchDelay, forKey: "switchDelay")
        do { try peers?.setInput(inputSettings) } catch { issue = error.localizedDescription }
        updateDiscovery()
    }
    var inputSettings: LinkInputSettings {
        LinkInputSettings(command: commandMap, control: controlMap, option: optionMap, shift: shiftMap, invertVertical: invertVertical, invertHorizontal: invertHorizontal, verticalSpeed: verticalSpeed, horizontalSpeed: horizontalSpeed)
    }
    func saveAndApply() { save(); if desired { settingsPending = true; applyPendingSettings() } }
    private func applyPendingSettings() {
        guard desired, settingsPending, !closing, !recoveryBlocked else { return }
        if restarting {
            let revision = stopRevision
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self = self, self.stopRevision == revision else { return }; self.applyPendingSettings()
            }
            return
        }
        guard desktopReady else {
            let revision = stopRevision
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self = self, self.stopRevision == revision else { return }; self.applyPendingSettings()
            }
            return
        }
        guard running || restartPending else { return }
        if running && configurationSignature == activeConfiguration { settingsPending = false; return }
        reloadCore(reason: "设置已更改")
    }
    private func reloadCore(reason: String, automatic: Bool = false) {
        guard let owned = child, owned.isRunning else {
            restarting = false
            if restartPending && desired && desktopReady && !closing && !recoveryBlocked && (!automatic || autoConnect) { start(); restartPending = false; settingsPending = false }
            return
        }
        restarting = true
        append(reason + "：请求连接核心正常退出并重新启动。")
        generation = UUID(); let token = generation; restartPending = true
        channel?.send("stop"); channel?.disconnect(); channel = nil; coreReady = false; connected = false
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(5)
            while owned.isRunning && Date() < deadline { usleep(50_000) }
            DispatchQueue.main.async {
                self.restarting = false
                guard self.generation == token else { return }
                guard !owned.isRunning else { self.recoveryBlocked = true; self.title = "等待旧共享进程退出"; self.detail = "自动重载已暂停，避免强制终止后反复启动。"; return }
                self.child = nil
                self.running = false
                guard self.desired, !self.closing, !self.recoveryBlocked else { return }
                guard self.desktopReady, !automatic || self.autoConnect else { self.title = "等待桌面或恢复设置就绪"; self.detail = "已正常退出旧核心；桌面可用后再继续，停止可取消。"; self.applyPendingSettings(); return }
                self.urgentRecovery = false; self.start(); self.restartPending = false; self.settingsPending = false
            }
        }
    }
    func inputPreset(_ macHabit: Bool) {
        commandMap = macHabit ? "ctrl" : "super"; controlMap = macHabit ? "super" : "ctrl"
        optionMap = "alt"; shiftMap = "shift"
    }
    func append(_ line: String) {
        let entry = ISO8601DateFormatter().string(from: Date()) + " " + line
        logs.append(entry); if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        let file = settingsDir.appendingPathComponent("linkdesk-session.log")
        do {
            try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_097_152 { let backup = file.appendingPathExtension("1"); try? FileManager.default.removeItem(at: backup); try FileManager.default.moveItem(at: file, to: backup) }
            if !FileManager.default.fileExists(atPath: file.path) { _ = FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.seekToEnd(); try handle.write(contentsOf: Data((entry + "\n").utf8))
        } catch { }

    }
    func start() {
        cancelAutomaticStart()
        guard !running, !closing, !restarting else { return }
        recoveryBlocked = false; identityRejected = false
        if !desired { resetFailure() }
        guard selectedDevice != nil else { tab = "devices"; issue = "请先选择并核对一台电脑。"; return }
        applySelected(restoreInput: false)
        guard hasDeviceControl() else {
            recoveryBlocked = true
            title = "需要设备控制权限"
            detail = "请在系统设置中允许 LinkDesk，然后再次启动。"
            issue = "请在“系统设置 → 隐私与安全”中允许 LinkDesk。macOS 27 的项目名称是“设备控制和数据访问”，旧系统叫“辅助功能”。这是读取和转发键鼠所需的权限。"
            return
        }
        guard FileManager.default.isExecutableFile(atPath: engine.path) else {
            issue = "安装包中的连接核心不完整，请重新下载完整 LinkDesk 安装包。"; return
        }
        if observeSystemEvents && !NSRunningApplication.runningApplications(withBundleIdentifier: "org.deskflow.deskflow").isEmpty {
            issue = "请先从 Deskflow 菜单选择“退出 Deskflow”，再在这里启动。两个界面不能同时管理同一个连接核心。"; return
        }
        if anotherCoreRunning() { issue = "Deskflow 连接核心仍在运行。请先退出原版 Deskflow，再启动 LinkDesk。"; return }
        do {
            try prepareIdentity()
            guard let session = try peers?.session(server: server) else { throw NSError(domain: "LinkDesk", code: 7, userInfo: [NSLocalizedDescriptionKey: "设备列表未就绪。"] ) }
            activeProfile = session
            let config = session.appendingPathComponent("linkdesk-server.conf")
            let text = try LinkConfiguration.settings(local: localName, peer: peerName, server: server, host: host, layout: layout, configPath: config.path, input: inputSettings, wakeDisplay: wakeDisplayOnRemoteInput, switchDelay: server ? switchDelay : 0, logPath: session.appendingPathComponent("linkdesk-core.log").path)
            try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
            try text.write(to: session.appendingPathComponent("LinkDesk.conf"), atomically: true, encoding: .utf8)
            try LinkConfiguration.links(local: localName, peer: peerName, layout: layout).write(to: config, atomically: true, encoding: .utf8)
            try verifyProtectedCore()
            save(); desired = true; lastSessionRequested = true; defaults.set(true, forKey: "lastSessionRequested"); activeConfiguration = configurationSignature
            append("明确启动共享；用途=" + (server ? "共享" : "接收")); launch()
        } catch { issue = error.localizedDescription }
    }
    private func verifyProtectedCore() throws {
        let directory = engine.deletingLastPathComponent()
        let manifest = directory.lastPathComponent == "MacOS" ? directory.deletingLastPathComponent().appendingPathComponent("Resources/linkdesk-core.json") : directory.appendingPathComponent("linkdesk-core.json")
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
        let hash = SHA256.hash(data: try Data(contentsOf: engine)).map { String(format: "%02x", $0) }.joined()
        guard metadata?["displaySafetyVersion"] as? Int == 1, metadata?["sha256"] as? String == hash else { throw NSError(domain: "LinkDesk", code: 9, userInfo: [NSLocalizedDescriptionKey: "显示保护核心校验失败，请重新下载完整安装包。"] ) }
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
            DispatchQueue.main.async { guard let self = self, self.generation == token, self.desired else { return }; self.readLog(text) }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self = self, self.generation == token else { return }
                self.running = false; self.connected = false; self.channel?.disconnect(); self.channel = nil
                if !self.desired { if !self.identityRejected { self.title = "已停止"; self.detail = "点击启动，恢复键鼠共享。" }; return }
                self.resetFailure(); self.restartPending = false
                self.desired = false; self.lastSessionRequested = false; self.defaults.set(false, forKey: "lastSessionRequested"); self.recoveryBlocked = true; self.finishProbe(false)
                self.title = proc.terminationStatus == 0 ? "已停止" : "共享核心意外停止"
                self.detail = "请查看连接日志；确认后手动启动，不自动反复重试。"
                self.append("核心退出：pid=\(proc.processIdentifier) exit=\(proc.terminationStatus)；不自动反复拉起。")
            }
        }
        do {
            try p.run(); coreStartedAt = Date(); child = p; append("核心启动：pid=\(p.processIdentifier)"); running = true; title = "正在启动连接"; detail = "正在准备加密连接。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                guard self.running, self.desired, self.generation == token else { return }
                let channel = CoreChannel(path: self.ipcPath); self.channel = channel
                channel.connect(onMessage: { [weak self] message in guard self?.generation == token else { return }; self?.handle(message) }, onClosed: { [weak self] in
                    guard let self = self, self.generation == token, self.running, self.desired else { return }
                    self.coreReady = false; self.connected = false; self.scheduleRecovery("共享状态通道断开")
                })
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                guard self.generation == token, self.running, self.desired, !self.coreReady else { return }
                self.recoveryBlocked = true; self.title = "共享状态通道暂未响应"
                self.detail = "保留进程，请检查权限与日志后手动停止重试。"
                self.append("启动超过 10 秒且未收到核心状态，暂停自动恢复，不强制终止。")
            }
        } catch { desired = false; issue = error.localizedDescription; title = "启动失败" }
    }
    private func anotherCoreRunning() -> Bool {
        if let check = foreignCore { return check() }
        let check = Process(); check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); check.arguments = ["-x", "deskflow-core"]
        check.standardOutput = FileHandle.nullDevice; check.standardError = FileHandle.nullDevice
        do { try check.run(); check.waitUntilExit(); return check.terminationStatus == 0 } catch { return false }
    }
    func stop() {
        stopRevision = UUID(); restartPending = false; settingsPending = false; urgentRecovery = false; resetFailure()
        desired = false; lastSessionRequested = false; defaults.set(false, forKey: "lastSessionRequested"); connected = false
        cancelQueuedRecovery(); finishProbe(false)
        guard let child = child, child.isRunning else { running = false; return }
        channel?.send("stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if child.isRunning { self.append("用户停止超时，终止持有的核心：pid=\(child.processIdentifier)"); child.terminate() }
            if self.child === child && !self.desired { self.running = false; if !self.identityRejected { self.title = "已停止"; self.detail = "点击启动，恢复键鼠共享。" } }
        }
        title = "正在停止"; detail = "正在结束共享连接。"
    }
    func shutdown() {
        resetFailure()
        closing = true; generation = UUID(); cancelQueuedRecovery(); finishProbe(false); networkMonitor.cancel(); stopDiscovery()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; workspaceObservers.removeAll()
        desired = false; channel?.send("stop")
        if let child = child {
            let deadline = Date().addingTimeInterval(5)
            while child.isRunning && Date() < deadline { usleep(50_000) }
            if child.isRunning { child.terminate() }
        }
        channel?.disconnect()
    }
    func readLog(_ text: String) {
        guard desired, !closing else { return }
        partial += text
        while let index = partial.firstIndex(of: "\n") {
            let line = String(partial[..<index]); partial.removeSubrange(...index); if observeConnectionOutput(line) { continue }; append(line)
            if line.contains("FATAL") || line.contains("ERROR") { detail = "启动遇到问题，请在“连接日志”中查看详情。" }
            if line.contains("accessibility") || line.contains("Accessibility") || line.contains("assistive devices") {
                desired = false
                recoveryBlocked = true
                detail = "请在系统设置中允许 LinkDesk 的辅助功能权限，然后再次启动。"
            }
        }
    }
    func handle(_ message: String) {
        guard desired, !closing else { return }
        let pieces = message.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let command = String(pieces[0]); let args = pieces.count > 1 ? String(pieces[1]) : ""
        switch command {
        case "pong": if args == probeNonce { finishProbe(true) }
        case "hello": coreReady = true; updateDiscovery(); title = server ? "等待所选设备" : "正在连接所选设备"; detail = "加密连接开启，网络恢复后会自动重连。"
        case "connectionState":
            connected = args == "Connected"; if connected && desired { connectionRecovered() }
            title = connected ? "两台电脑已连接" : (running ? (server ? "等待所选设备" : "正在重连") : "已停止")
            detail = connected ? "可以把指针移到另一台电脑，键盘会跟随。" : "保持两台电脑联网，连接会自动恢复。"
        case "connectedClients":
            guard server else { return }
            connected = !args.isEmpty; if connected && desired { connectionRecovered() }; title = connected ? "两台电脑已连接" : "等待所选设备"
            detail = connected ? "已连接：\(args) · 加密传输" : "另一台电脑恢复联网后会自动连接。"
        case "peerFingerprint":
            guard let pin = PeerStore.pin(args), !handledFingerprints.contains(pin) else { return }
            handledFingerprints.insert(pin)
            if pin != selectedDevice?.fingerprint { stop(); identityRejected = true; recoveryBlocked = true; title = "设备身份不一致"; detail = "对方指纹与所选设备不同，连接已停止。请先在设备列表重新核对身份。"; append("拒绝身份不一致的连接；没有修改配对。") }
        case "connectionRefused": connected = false; refusalDetail = LinkConfiguration.refusalMessage(args); title = "连接被拒绝"; detail = refusalDetail
        default: break
        }
        if !connected { showConnectionFailure() }
    }
    func trustPeer() {
        guard let id = pendingPairID, let value = pairing, PeerStore.pin(value) == id else { return }
        do { stop(); try peers?.setInput(inputSettings); try peers?.pair(id); applySelected(restoreInput: true); refreshDevices(); pairing = nil; pendingPairID = nil; save(); title = "已选择 \(selectedLabel)"; detail = "指纹已绑定。点击启动共享，并在另一端选择本机。" } catch { issue = error.localizedDescription }
    }
    func syncLogin() { loginEnabled = SMAppService.mainApp.status == .enabled }
    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister(); cancelAutomaticStart() }
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
            RootView(model: model).background(WindowHook(delegate: delegate)).onAppear { delegate.model = model; model.beginAutomaticStart() }
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
                Text("LinkDesk · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本")").font(.caption2).foregroundStyle(.tertiary)
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
                Picker("位置", selection: $model.layout) { Text("右侧").tag("right"); Text("左侧").tag("left"); Text("上方").tag("up"); Text("下方").tag("down") }.labelsHidden().frame(width: 100).disabled(!model.server).onChange(of: model.layout) { _ in model.saveAndApply() }
                Spacer(); Button("选择配对设备") { model.tab = "devices" }.buttonStyle(.borderless)
            }
            HStack {
                Text("切换方式")
                Picker("切换方式", selection: $model.switchDelay) {
                    Text("立即切换").tag(0)
                    Text("停留 250 毫秒").tag(250)
                    Text("停留 500 毫秒").tag(500)
                    Text("停留 1 秒").tag(1000)
                }.labelsHidden().frame(width: 140).disabled(!model.server).onChange(of: model.switchDelay) { _ in model.saveAndApply() }
                Spacer()
            }
            Text(model.server ? "指针移出对应屏幕边缘时切换，键盘会跟随。选择“停留”可避免指针擦边时误切换；保存后自动应用。" : "接收端的屏幕位置与切换方式由共享键鼠的电脑设置。") .font(.caption).foregroundStyle(.secondary)
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
                            if model.selectedDevice?.id == device.id { Button("更新地址") { model.addressText = device.address; model.addressID = device.id }.buttonStyle(.bordered) }
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
        .sheet(isPresented: Binding(get: { model.addressID != nil }, set: { if !$0 { model.addressID = nil } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text("更新设备地址").font(.title2.bold())
                TextField("对方 IP 地址或主机名", text: $model.addressText).textFieldStyle(.roundedBorder)
                Text("填写对方连接页显示的地址。配对身份不变，连接时仍会核对原有指纹；自动发现仍可更新地址。").font(.caption).foregroundStyle(.secondary)
                HStack { Button("取消") { model.addressID = nil }; Spacer(); Button("保存地址") {
                    do { if let id = model.addressID { try model.updateSelectedAddress(id, address: model.addressText) }; model.addressID = nil }
                    catch { model.issue = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(accent) }
            }.padding(28).frame(width: 440)
        }
        .alert("忘记这台设备？", isPresented: Binding(get: { model.forgetID != nil }, set: { if !$0 { model.forgetID = nil } })) {
            Button("取消", role: .cancel) { model.forgetID = nil }; Button("忘记设备", role: .destructive) { if let id = model.forgetID { model.forgetDevice(id) }; model.forgetID = nil }
        } message: { Text("将撤销配对；再次连接需要重新核对完整指纹。") }
    }
    @ViewBuilder var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("启动与后台").font(.headline)
            settingRow("登录后自启动", "登录 Mac 后只打开应用，不会强制开始共享。", Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            Divider()
            settingRow("启动后自动开始共享", "默认关闭。开启后等待登录桌面与显示路径稳定，恢复上次主动开始且未停止的共享。", $model.autoStartOnLaunch)
            Divider()
            settingRow("网络恢复与唤醒后重连", "保留正常核心；只恢复已开始的共享。手动停止后保持停止。", $model.autoConnect)
            Divider()
            settingRow("关闭窗口后留在后台", "窗口关闭后继续共享，通过菜单栏图标重新打开。", $model.background)
            Divider()
            settingRow("局域网发现与自动查找", "发现同一局域网的电脑，核对所选设备身份后更新地址。", $model.allowDiscovery)
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
        VStack(alignment: .leading, spacing: 16) {
            Text("显示保护").font(.headline)
            settingRow("允许远程键鼠请求点亮屏幕", "默认关闭。接收端只在实际远程输入时请求，每次熄屏最多一次；连接和切换电脑不主动点亮。", $model.wakeDisplayOnRemoteInput)
            Text("这是接收端本机的设置。普通键鼠输入仍可能被系统视为活动，不控制另一台电脑的显示器。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
        VStack(alignment: .leading, spacing: 16) {
            Text("电脑与网络").font(.headline)
            HStack(spacing: 8) {
                Text("本机用途").frame(width: 100, alignment: .leading)
                Picker("本机用途", selection: $model.server) { Text("共享本机键鼠").tag(true); Text("接收另一台电脑的键鼠").tag(false) }.labelsHidden().pickerStyle(.segmented).disabled(model.running)
            }
            field("本机名称", $model.localName)
            Text("当前选择：" + model.selectedLabel)
            Text("Mac 与 Windows 都可共享或接收键鼠。两台电脑连接同一路由器、热点或可互通的局域网即可，无需固定的热点形式。更改用途前请先停止两端共享。") .font(.caption).foregroundStyle(.secondary)
            HStack { Button("保存电脑信息") { model.saveAndApply() }.buttonStyle(.bordered); Spacer() }
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
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
            }.disabled(!model.server)
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
            }.disabled(model.server)
        }.padding(24).background(.white, in: RoundedRectangle(cornerRadius: 20))
        HStack { Text(model.running ? "保存后将自动重新加载共享连接。" : "保存后，下次启动共享生效。") .font(.caption).foregroundStyle(.secondary); Spacer(); Button("保存键鼠设置") { model.saveAndApply() }.buttonStyle(.borderedProminent).tint(accent) }
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
