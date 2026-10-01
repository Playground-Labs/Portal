import AppKit
import SwiftUI
import Combine
import PortalCore
import PortalVNC

final class Session: ObservableObject {
    @Published var computer: Computer
    let frames = PassthroughSubject<Void,Never>()
    var image: CGImage? {
        willSet {
            if image?.width != newValue?.width || image?.height != newValue?.height { objectWillChange.send() }
        }
        didSet { frames.send() }
    }
    @Published var remoteCursor: NSCursor?
    @Published var status = "Connecting"
    @Published var error = ""
    @Published var connected = false
    @Published var encrypted = false
    @Published var audioAvailable = false
    @Published var audioError = ""
    @Published var clipboardError = ""
    @Published var screens: [PortalScreen] = []
    @Published var selectedScreen: UInt32?
    @Published var canResize = false
    @Published var captured = false
    @Published var retrying = false
    var save: ((Computer, Bool) -> Void)?
    weak var window: NSWindow?
    let queue = DispatchQueue(label: "app.portal.session", qos: .userInteractive)
    private var client: OpaquePointer?
    private var tunnel: SSHTunnel?
    private var tunnelReady = false
    private var generation = 0
    private let lock = NSLock()
    private var workerGeneration = 0
    private var credential: String?
    private var rememberCredential = false
    private var promptedCredential = false
    private var skipStoredCredential = false
    private let audioGate = DispatchSemaphore(value: 8)
    private var cancelledPrompt = false
    private var retryCount = 0
    private var timer: Timer?
    private var pasteboardCount = NSPasteboard.general.changeCount
    private let audio = AudioPlayer()
    private let frameLock = NSLock()
    private var pendingFrame: (Data, Int, Int, Int)?
    private var frameDeliveryScheduled = false
    private var resizeWork: DispatchWorkItem?
    private var pendingSize: CGSize?
    init(_ computer: Computer) { self.computer = computer }
    private func isCurrent(_ value: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == value }
    private func advance() -> Int { lock.lock(); defer { lock.unlock() }; generation += 1; return generation }
    func start() {
        let reconnecting = retrying
        let token = advance()
        pendingSize = nil; status = "Connecting"; error = ""; connected = false; retrying = false; image = nil; remoteCursor = nil; audioAvailable = false; canResize = false; screens = []; selectedScreen = nil
        let settings = computer
        queue.async { [self] in
            cleanup(); tunnelReady = false; workerGeneration = token; cancelledPrompt = false; promptedCredential = false
            guard isCurrent(token) else { return }
            do {
                let endpoint = try Endpoint(settings.address)
                var host = endpoint.host; var port = Int(endpoint.port)
                if settings.ssh.enabled {
                    let tunnel = SSHTunnel(); self.tunnel = tunnel
                    port = try tunnel.start(settings.ssh, destination: endpoint, cancelled: { !self.isCurrent(token) }); host = "127.0.0.1"; tunnelReady = true
                }
                guard isCurrent(token) else { cleanup(); return }
                var cb = PortalCallbacks(); cb.context = Unmanaged.passUnretained(self).toOpaque()
                cb.frame = { ctx, bytes, width, height in
                    let session = Unmanaged<Session>.fromOpaque(ctx!).takeUnretainedValue()
                    session.receiveFrame(bytes!, width: Int(width), height: Int(height))
                }
                cb.cursor = { ctx, bytes, width, height, x, y in
                    let session = Unmanaged<Session>.fromOpaque(ctx!).takeUnretainedValue()
                    let token = session.workerGeneration
                    let data = bytes.map { Data(bytes:$0,count:Int(width)*Int(height)*4) }
                    DispatchQueue.main.async {
                        guard session.isCurrent(token) else { return }
                        guard let data, let provider = CGDataProvider(data:data as CFData),
                              let image = CGImage(width:Int(width),height:Int(height),bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:Int(width)*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { session.remoteCursor = nil; return }
                        session.remoteCursor = NSCursor(image:NSImage(cgImage:image,size:NSSize(width:Int(width),height:Int(height))),hotSpot:NSPoint(x:min(max(0,Int(x)),Int(width)-1),y:min(max(0,Int(y)),Int(height)-1)))
                    }
                }
                cb.clipboard = { ctx, text, length, utf8 in
                    let session = Unmanaged<Session>.fromOpaque(ctx!).takeUnretainedValue()
                    let data = Data(bytes: text!, count: Int(length)); let token = session.workerGeneration
                    guard let string = String(data: data, encoding: utf8 != 0 ? .utf8 : .isoLatin1) else { return }
                    DispatchQueue.main.async { if session.isCurrent(token), session.computer.clipboard != .off { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string); session.pasteboardCount = NSPasteboard.general.changeCount } }
                }
                cb.layout = { ctx, screens, count, resize in
                    let session = Unmanaged<Session>.fromOpaque(ctx!).takeUnretainedValue()
                    let values = Array(UnsafeBufferPointer(start: screens, count: Int(count))); let token = session.workerGeneration
                    DispatchQueue.main.async { if session.isCurrent(token) { if count > 0 { session.screens = values }; session.canResize = resize != 0 } }
                }
                cb.audio = { ctx, bytes, count in
                    let session = Unmanaged<Session>.fromOpaque(ctx!).takeUnretainedValue(); let token = session.workerGeneration
                    if let bytes {
                        guard session.audioGate.wait(timeout: .now()) == .success else { return }
                        let data = Data(bytes: bytes, count: Int(count))
                        DispatchQueue.main.async { defer { session.audioGate.signal() }; if session.isCurrent(token), session.computer.audioEnabled { do { try session.audio.play(data) } catch { session.audioError = error.localizedDescription; session.setAudio(false) } } }
                    } else { DispatchQueue.main.async { if session.isCurrent(token) { session.audioAvailable = true; session.setAudio(session.computer.audioEnabled) } } }
                }
                cb.credentials = { ctx, kind, user, password in
                    let session = Unmanaged<Session>.fromOpaque(ctx!).takeUnretainedValue()
                    guard let pair = onMain({ session.requestCredential(needsUser: kind == 2) }) else { session.cancelledPrompt = true; return 0 }
                    user?.pointee = strdup(pair.0); password?.pointee = strdup(pair.1); return 1
                }
                cb.authorize = { ctx, kind, detail in
                    let session = Unmanaged<Session>.fromOpaque(ctx!).takeUnretainedValue()
                    let allowed = onMain { session.authorize(kind: kind, detail: String(cString: detail!)) }
                    if !allowed { session.cancelledPrompt = true }; return allowed ? 1 : 0
                }
                guard let vnc = portal_vnc_create(cb) else { throw PortalError(message: "Could not start the connection.") }
                client = vnc
                let fingerprint = UserDefaults.standard.string(forKey: "certificate:\(settings.destinationIdentity)") ?? ""
                let success = portal_vnc_connect(vnc, host, Int32(port), settings.ssh.enabled ? 1 : 0, settings.quality.value, fingerprint)
                guard isCurrent(token) else { cleanup(); return }
                guard success != 0 else { skipStoredCredential = promptedCredential; throw PortalError(message: String(cString: portal_vnc_error(vnc))) }
                let secure = portal_vnc_encrypted(vnc) != 0
                DispatchQueue.main.async { [self] in
                    guard isCurrent(token) else { return }
                    connected = true; status = "Connected"; encrypted = secure; retryCount = 0; computer.lastUsed = Date(); save?(computer, false)
                    if rememberCredential, let credential { do { try Keychain.write(credential, account: computer.credentialAccount); save?(computer, true) } catch { showError(error) } }
                    audio.volume = computer.volume
                    timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.sendClipboardIfChanged() }
                }
                poll(token)
            } catch {
                let message = error.localizedDescription
                let retry = reconnecting && !promptedCredential && !cancelledPrompt && (tunnel == nil || tunnelReady || (error as? PortalError)?.retryable == true)
                cleanup(); DispatchQueue.main.async { [self] in if isCurrent(token) { failed(message, retry: retry) } }
            }
        }
    }
    private func receiveFrame(_ bytes: UnsafePointer<UInt8>, width: Int, height: Int) {
        // ponytail: upload whole frames; use dirty rectangles if profiling shows this is the bottleneck.
        let data = Data(bytes: bytes, count: width * height * 4)
        frameLock.lock()
        pendingFrame = (data, width, height, workerGeneration)
        let needsDelivery = !frameDeliveryScheduled
        frameDeliveryScheduled = true
        frameLock.unlock()
        guard needsDelivery else { return }
        DispatchQueue.main.async { [self] in
            frameLock.lock(); let frame = pendingFrame; pendingFrame = nil; frameDeliveryScheduled = false; frameLock.unlock()
            guard let (data,width,height,token) = frame, isCurrent(token), let provider = CGDataProvider(data: data as CFData) else { return }
            image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder32Big), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }
    // Idle pacing leaves the serial queue free for input; active reads still finish one RFB message.
    private func poll(_ token: Int, idle: Bool = false) {
        queue.asyncAfter(deadline:.now() + (idle ? 0.005 : 0)) { [self] in
            guard isCurrent(token), workerGeneration == token, let client else { return }
            let result = portal_vnc_poll(client)
            if result < 0 {
                let message = String(cString: portal_vnc_error(client)); cleanup()
                DispatchQueue.main.async { [self] in if isCurrent(token) { failed(message, retry: true) } }
            } else { poll(token,idle:result == 0) }
        }
    }
    private func cleanup() { if let client { portal_vnc_destroy(client); self.client = nil }; tunnel?.stop(); tunnel = nil }
    private func failed(_ message: String, retry: Bool) {
        connected = false; captured = false; timer?.invalidate(); audio.stop(); error = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if retry && UserDefaults.standard.object(forKey: "autoReconnect") as? Bool != false {
            retryCount += 1; let delay = min(30, pow(2, Double(min(retryCount,5))))
            retrying = true; status = "Reconnecting in \(Int(delay)) seconds"; let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in guard let self, self.isCurrent(token), self.retrying else { return }; self.start() }
        } else { retrying = false; status = cancelledPrompt ? "Connection cancelled" : "Couldn’t connect" }
    }
    func stop() { _ = advance(); resizeWork?.cancel(); timer?.invalidate(); connected = false; captured = false; retrying = false; status = "Disconnected"; audio.stop(); queue.async { [self] in cleanup() } }
    func send(_ action: @escaping (OpaquePointer) -> Void) { let token = generation; queue.async { [self] in if isCurrent(token), let client { action(client) } } }
    func key(_ key: UInt32, down: Bool) { guard connected, !computer.viewOnly else { return }; send { _ = portal_vnc_key($0,key,down ? 1 : 0) } }
    func pointer(x: Int, y: Int, buttons: Int) { guard connected, !computer.viewOnly else { return }; send { _ = portal_vnc_pointer($0,Int32(x),Int32(y),Int32(buttons)) } }
    func special(_ keys: [UInt32]) { keys.forEach { key($0,down: true) }; keys.reversed().forEach { key($0,down: false) } }
    func resize(to size: CGSize) {
        guard connected, canResize, computer.sizing == .automatic, selectedScreen == nil, size.width >= 320, size.height >= 200 else { return }
        let width = min(8192,Int(size.width)), height = min(8192,Int(size.height))
        let target = CGSize(width:width,height:height)
        guard pendingSize != target, image?.width != width || image?.height != height else { return }
        pendingSize = target; resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.send { _ = portal_vnc_resize($0,Int32(width),Int32(height)) } }; resizeWork = work; DispatchQueue.main.asyncAfter(deadline: .now()+0.4, execute: work)
    }
    func updatePreferences() { save?(computer, false); audio.volume = computer.volume; send { [quality = computer.quality.value] in _ = portal_vnc_quality($0,quality) } }
    func setAudio(_ enabled: Bool) { computer.audioEnabled = enabled; if !enabled { audio.stop() }; send { _ = portal_vnc_audio($0,enabled ? 1 : 0) }; save?(computer, false) }
    private func sendClipboardIfChanged() {
        guard connected, captured, !computer.viewOnly, computer.clipboard == .bidirectional else { return }
        let board = NSPasteboard.general
        guard board.changeCount != pasteboardCount else { return }; pasteboardCount = board.changeCount
        guard let text = board.string(forType: .string), text.utf8.count <= 1048576 else { return }
        send { [weak self] client in
            let success = text.withCString { portal_vnc_clipboard(client,$0,Int32(text.utf8.count)) }
            DispatchQueue.main.async { self?.clipboardError = success == 0 ? "This server could not receive the clipboard text." : "" }
        }
    }
    private func requestCredential(needsUser: Bool) -> (String,String)? {
        guard isCurrent(workerGeneration) else { return nil }
        if !promptedCredential { promptedCredential = true; if !skipStoredCredential, (!needsUser || !computer.username.isEmpty), let stored = Keychain.read(computer.credentialAccount) { credential = stored; return (computer.username,stored) } }
        rememberCredential = false
        let input = CredentialInput(username:computer.username)
        let dialog = PortalDialog()
        guard dialog.run("Connect to \(computer.name)",message:"Enter the credentials required by the remote computer.",accept:"Connect",content:{ CredentialFields(input:input,needsUser:needsUser) }), isCurrent(workerGeneration) else { return nil }
        computer.username = input.username; credential = input.password; rememberCredential = input.remember
        return (computer.username,input.password)
    }
    private func authorize(kind: Int32, detail: String) -> Bool {
        guard isCurrent(workerGeneration) else { return false }
        if kind == 1, computer.acceptedInsecureAddress == computer.address { return true }
        let trustKey = "\(kind == 3 ? "rsa-key" : "certificate"):\(computer.destinationIdentity)"
        let previousKey = UserDefaults.standard.string(forKey: trustKey)
        if kind == 3, previousKey == detail { return true }
        let title = kind == 1 ? "This connection isn’t encrypted" : (kind == 3 && previousKey != nil ? "This computer’s identity has changed" : "Verify this computer’s identity")
        let message = kind == 1 ? "Your screen, clipboard, and input may be visible to others on this network. Use an SSH tunnel or a trusted VPN when needed. Portal cannot detect your VPN." : "Confirm this SHA-256 fingerprint with the computer’s owner before trusting it. A changed fingerprint may indicate a different computer.\n\n\(detail)"
        guard PortalDialog.confirm(title,message:message,accept:kind == 1 ? "Connect Anyway" : "Trust and Connect"), isCurrent(workerGeneration) else { return false }
        if kind == 1 { computer.acceptedInsecureAddress = computer.address; save?(computer, false) }
        else { UserDefaults.standard.set(detail,forKey: trustKey) }
        return true
    }
}

extension ImageQuality { var value: Int32 { switch self { case .automatic: return -1; case .balanced: return 6; case .high: return 9; case .low: return 3 } } }
