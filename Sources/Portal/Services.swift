import AppKit
import Security
import AVFoundation
import PortalCore

let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Portal", isDirectory: true)

func showError(_ error: Error) { let alert = NSAlert(error: error); alert.runModal() }
func onMain<T>(_ work: () -> T) -> T { Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work) }

struct PortalError: LocalizedError { var message: String; var errorDescription: String? { message } }
enum Keychain {
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.portal.vnc", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func write(_ password: String?, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.portal.vnc", kSecAttrAccount as String: account]
        if let password {
            let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
            guard status == errSecSuccess else { throw PortalError(message: "The password could not be saved in Keychain (\(status)).") }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PortalError(message: "The saved password could not be removed (\(status)).") }
        }
    }
}

final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private var pending = 0
    private var started = false
    var volume: Float = 0.7 { didSet { player.volume = volume } }
    func play(_ data: Data) throws {
        if !started { engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format); try engine.start(); player.play(); player.volume = volume; started = true }
        let frames = data.count / 4
        guard frames > 0, pending + frames <= 44100 / 2, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)), let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { bytes in
            for frame in 0..<frames { for channel in 0..<2 {
                let index = frame * 4 + channel * 2
                let value = Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
                channels[channel][frame] = Float(value) / 32768
            } }
        }
        pending += frames
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in DispatchQueue.main.async { self?.pending = max(0, (self?.pending ?? frames) - frames) } }
    }
    func stop() { player.stop(); engine.stop(); pending = 0; if started { engine.detach(player) }; started = false }
    deinit { engine.stop() }
}

final class Discovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published var computers: [Computer] = []
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    override init() { super.init(); browser.delegate = self }
    func setEnabled(_ enabled: Bool) { browser.stop(); services.forEach { $0.stop() }; services.removeAll(); computers.removeAll(); if enabled { browser.searchForServices(ofType: "_rfb._tcp.", inDomain: "local.") } }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) { services.append(service); service.delegate = self; service.resolve(withTimeout: 5) }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) { services.removeAll { $0 == service }; refresh() }
    func netServiceDidResolveAddress(_ sender: NetService) { refresh() }
    private func refresh() {
        computers = services.compactMap { service in
            guard let host = service.hostName, service.port > 0 else { return nil }
            return Computer(name: service.name, address: "\(host):\(service.port)")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    deinit { browser.stop(); services.forEach { $0.stop() } }
}

final class SSHTunnel {
    private let process = Process()
    private let errors = Pipe()
    private var errorData = Data()
    private let errorLock = NSLock()
    func start(_ settings: SSHConfiguration, destination: Endpoint, cancelled: () -> Bool) throws -> Int {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw PortalError(message: "Could not create the SSH connection.") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
        close(socketFD)
        guard bound == 0, named == 0 else { throw PortalError(message: "Could not reserve a local SSH port.") }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let helper = Bundle.main.url(forResource: "ssh-askpass", withExtension: "sh") ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/ssh-askpass.sh")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let remoteHost = destination.host.contains(":") ? "[\(destination.host)]" : destination.host
        var arguments = ["-F", "/dev/null", "-N", "-T", "-o", "ExitOnForwardFailure=yes", "-o", "StrictHostKeyChecking=ask", "-o", "UserKnownHostsFile=\(supportDirectory.appendingPathComponent("known_hosts").path)", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-o", "ConnectTimeout=10", "-o", "NumberOfPasswordPrompts=1", "-o", "PermitLocalCommand=no", "-p", String(settings.port), "-L", "127.0.0.1:\(port):\(remoteHost):\(destination.port)"]
        if !settings.keyPath.isEmpty { arguments += ["-i", NSString(string: settings.keyPath).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        arguments += ["\(settings.username)@\(settings.host)"]
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = helper.path; environment["SSH_ASKPASS_REQUIRE"] = "force"; environment["DISPLAY"] = "portal"; environment["PORTAL_EXECUTABLE"] = Bundle.main.executablePath ?? CommandLine.arguments[0]
        process.environment = environment; process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] file in
            let data = file.availableData
            guard let self else { return }
            self.errorLock.lock(); self.errorData.append(data); if self.errorData.count > 8192 { self.errorData = self.errorData.suffix(8192) }; self.errorLock.unlock()
        }
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline && !cancelled() {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var local = address
            let result = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) } }
            close(fd)
            if result == 0 { return port }
            Thread.sleep(forTimeInterval: 0.1)
        }
        errorLock.lock(); let detail = String(decoding: errorData, as: UTF8.self); errorLock.unlock()
        stop(); throw PortalError(message: detail.isEmpty ? "SSH did not open a connection. Check the server and your credentials." : detail)
    }
    func stop() { if process.isRunning { process.terminate() }; errors.fileHandleForReading.readabilityHandler = nil }
    deinit { stop() }
}

func runAskpass() -> Never {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.activate(ignoringOtherApps: true)
    let prompt = CommandLine.arguments.dropFirst(2).joined(separator: " ")
    let alert = NSAlert(); alert.messageText = "SSH connection"; alert.informativeText = prompt
    let confirmation = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] == "confirm" || prompt.contains("yes/no")
    alert.addButton(withTitle: confirmation ? "Trust and Connect" : "Connect"); alert.addButton(withTitle: "Cancel")
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    if !confirmation { field.placeholderString = "Password or key passphrase"; alert.accessoryView = field; alert.window.initialFirstResponder = field }
    guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
    print(confirmation ? "yes" : field.stringValue); exit(0)
}
