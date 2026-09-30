import AppKit
import SwiftUI
import PortalCore

final class AppModel: ObservableObject {
    @Published var computers: [Computer] = []
    @Published var alert: String?
    private var store: ComputerStore?
    private var sessions: [UUID: SessionWindow] = [:]
    init() {
        do { let store = try ComputerStore(url: supportDirectory.appendingPathComponent("computers.json")); self.store = store; computers = store.computers }
        catch { alert = "Saved computers could not be opened. The existing file has been preserved.\n\n\(error.localizedDescription)" }
    }
    func save(_ computer: Computer) {
        do { guard let store else { throw PortalError(message:"Saved computers are unavailable until the saved file is repaired.") }; try store.save(computer); computers = store.computers }
        catch { alert = error.localizedDescription }
    }
    func remove(_ computer: Computer) {
        do { try store?.remove(computer.id); try Keychain.write(nil,account:computer.credentialAccount); computers = store?.computers ?? [] }
        catch { alert = error.localizedDescription }
    }
    func connect(_ computer: Computer) {
        do { try computer.validate() } catch { alert = error.localizedDescription; return }
        if let existing = sessions.values.first(where: { $0.session.computer.id == computer.id || ($0.session.computer.destinationIdentity == computer.destinationIdentity && (computer.username.isEmpty || $0.session.computer.username == computer.username)) }) { existing.window?.makeKeyAndOrderFront(nil); return }
        let session = Session(computer)
        session.save = { [weak self] updated in guard let self, self.computers.contains(where: { $0.id == updated.id }) else { return }; self.save(updated) }
        let controller = SessionWindow(session:session)
        controller.onClose = { [weak self] in self?.sessions.removeValue(forKey:computer.id) }
        sessions[computer.id] = controller; controller.showWindow(nil); session.start()
    }
    func resetTrust() {
        for var computer in computers { computer.acceptedInsecureAddress = nil; save(computer) }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("certificate:") { UserDefaults.standard.removeObject(forKey:key) }
    }
    func stopAll() { sessions.values.forEach { $0.session.stop() } }
}

final class SessionWindow: NSWindowController, NSWindowDelegate {
    let session: Session
    var onClose: (() -> Void)?
    init(session: Session) {
        self.session = session
        let window = makeWindow(title:session.computer.name,size:NSSize(width:1100,height:740))
        super.init(window:window); session.window = window; window.delegate = self
        window.contentView = NSHostingView(rootView: SessionView(session:session))
        window.minSize = NSSize(width:580,height:380); window.center()
    }
    required init?(coder:NSCoder) { fatalError("Use init(session:)") }
    func windowWillClose(_ notification:Notification) { session.stop(); onClose?() }
}

func makeWindow(title:String,size:NSSize) -> NSWindow {
    let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
    window.title = title; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenPrimary]; window.toolbarStyle = .unifiedCompact
    return window
}
