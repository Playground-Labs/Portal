import AppKit
import SwiftUI
import Combine
import PortalCore

struct RemoteDesktop: NSViewRepresentable {
    @ObservedObject var session: Session
    func makeNSView(context: Context) -> DesktopScrollView {
        let scroll = DesktopScrollView(); scroll.drawsBackground = true; scroll.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        let canvas = DesktopCanvas(session: session); scroll.documentView = canvas; scroll.canvas = canvas
        return scroll
    }
    func updateNSView(_ scroll: DesktopScrollView, context: Context) { scroll.refresh() }
}

final class DesktopScrollView: NSScrollView {
    weak var canvas: DesktopCanvas?
    override func layout() { super.layout(); refresh() }
    func refresh() {
        guard let canvas else { return }
        let actual = canvas.session.computer.sizing == .actual
        hasVerticalScroller = actual; hasHorizontalScroller = actual; autohidesScrollers = true
        let size = canvas.sourceRect.size
        let next = actual ? NSSize(width: max(contentSize.width,size.width),height: max(contentSize.height,size.height)) : contentSize
        if canvas.frame.size != next { canvas.setFrameSize(next) }
        if canvas.session.computer.viewOnly { canvas.releaseInput() }
        if !canvas.session.connected { canvas.releaseInput() }
        canvas.window?.invalidateCursorRects(for:canvas)
        canvas.refreshImage()
        canvas.session.resize(to: contentSize)
    }
}

final class DesktopCanvas: NSView {
    let session: Session
    private let desktopLayer = CALayer()
    private var frameObservation: AnyCancellable?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var held: [UInt16: UInt32] = [:]
    private var buttons = 0
    private var lastPoint = (0,0)
    private var capsLock = false
    // Device masks from IOKit/hidsystem/IOLLEvent.h distinguish left and right keys.
    private let modifierKeys: [(NSEvent.ModifierFlags,[(UInt16,UInt,UInt32)])] = [
        (.shift,[(56,0x2,0xffe1),(60,0x4,0xffe2)]),
        (.control,[(59,0x1,0xffe3),(62,0x2000,0xffe4)]),
        (.option,[(58,0x20,0xffe9),(61,0x40,0xffea)]),
        (.command,[(55,0x8,0xffeb),(54,0x10,0xffec)])
    ]
    private var tracking: NSTrackingArea?
    private static let hiddenCursor = NSCursor(image:NSImage(size:NSSize(width:16,height:16),flipped:false) { _ in true },hotSpot:.zero)
    private var usesRemoteCursor: Bool { session.connected && !session.computer.viewOnly && window?.isKeyWindow == true }
    override func cursorUpdate(with event: NSEvent) {
        (usesRemoteCursor && point(event) != nil ? (session.remoteCursor ?? Self.hiddenCursor) : NSCursor.arrow).set()
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if usesRemoteCursor {
            addCursorRect(destinationRect.intersection(visibleRect),cursor:session.remoteCursor ?? Self.hiddenCursor)
        }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(session: Session) {
        self.session = session; super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite:0.08,alpha:1).cgColor
        layer?.addSublayer(desktopLayer)
        frameObservation = session.frames.sink { [weak self] in self?.refreshImage() }
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Remote desktop. Click to control. Press Control Option Escape to release the keyboard.")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown,.keyUp,.flagsChanged]) { [weak self] event in
            self?.handleKeyboardEvent(event) == true ? nil : event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? NSWindow === self.window else { return }; self.releaseInput()
        })
    }
    required init?(coder: NSCoder) { fatalError("Use init(session:)") }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) }; observers.forEach(NotificationCenter.default.removeObserver) }
    override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }
    var sourceRect: CGRect {
        if let id = session.selectedScreen, let screen = session.screens.first(where: { $0.id == id }) { return CGRect(x: Int(screen.x),y: Int(screen.y),width: Int(screen.width),height: Int(screen.height)) }
        return CGRect(x: 0,y: 0,width: session.image?.width ?? 1,height: session.image?.height ?? 1)
    }
    var destinationRect: CGRect {
        let source = sourceRect
        let scale = session.computer.sizing == .actual ? 1 : min(bounds.width/source.width,bounds.height/source.height)
        let size = CGSize(width: source.width*scale,height: source.height*scale)
        return CGRect(x: max(0,(bounds.width-size.width)/2),y: max(0,(bounds.height-size.height)/2),width:size.width,height:size.height)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { refreshImage() }
    func refreshImage() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        desktopLayer.frame = destinationRect
        desktopLayer.contents = session.image
        if let image = session.image {
            let source = sourceRect
            desktopLayer.contentsRect = CGRect(x:source.minX/CGFloat(image.width),y:source.minY/CGFloat(image.height),width:source.width/CGFloat(image.width),height:source.height/CGFloat(image.height))
        }
        desktopLayer.magnificationFilter = session.computer.sizing == .actual ? .nearest : .linear
        desktopLayer.minificationFilter = .linear
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero,options:[.mouseMoved,.cursorUpdate,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil); addTrackingArea(tracking!)
    }
    func releaseInput() {
        guard session.captured || !held.isEmpty || buttons != 0 else { return }
        for key in held.values { session.sendInput { _ = portal_vnc_key($0,key,0) } }; held.removeAll()
        if buttons != 0 { let (x,y) = lastPoint; session.sendInput { _ = portal_vnc_pointer($0,Int32(x),Int32(y),0) }; buttons = 0 }
        session.captured = false
        window?.invalidateCursorRects(for:self)
    }
    private func point(_ event: NSEvent) -> (Int,Int)? {
        let point = convert(event.locationInWindow,from:nil), destination = destinationRect, source = sourceRect
        guard destination.width > 0, destination.height > 0, destination.contains(point) else { return nil }
        return (Int(source.minX+(point.x-destination.minX)*source.width/destination.width),Int(source.minY+(point.y-destination.minY)*source.height/destination.height))
    }
    private func pointer(_ event: NSEvent) { cursorUpdate(with:event); guard let position = point(event) else { if buttons == 0 { session.pointer(x:lastPoint.0,y:lastPoint.1,buttons:0) }; return }; lastPoint = position; session.pointer(x:position.0,y:position.1,buttons:buttons) }
    override func mouseDown(with event: NSEvent) { guard session.connected, !session.computer.viewOnly, point(event) != nil else { return }; capture(event); buttons |= 1; pointer(event) }
    override func mouseUp(with event: NSEvent) { buttons &= ~1; pointer(event) }
    override func rightMouseDown(with event: NSEvent) { guard !session.computer.viewOnly else { return }; capture(event); buttons |= 4; pointer(event) }
    override func rightMouseUp(with event: NSEvent) { buttons &= ~4; pointer(event) }
    override func otherMouseDown(with event: NSEvent) { guard session.connected, !session.computer.viewOnly, point(event) != nil else { return }; capture(event); buttons |= 2; pointer(event) }
    override func otherMouseUp(with event: NSEvent) { buttons &= ~2; pointer(event) }
    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }
    override func scrollWheel(with event: NSEvent) {
        guard let (x,y) = point(event) else { return }
        let vertical = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
        let delta = vertical ? event.scrollingDeltaY : event.scrollingDeltaX
        guard abs(delta)>0 else { return }; let mask = vertical ? (delta>0 ? 8 : 16) : (delta>0 ? 32 : 64)
        session.pointer(x:x,y:y,buttons:buttons|mask); session.pointer(x:x,y:y,buttons:buttons)
    }
    @discardableResult func handleKeyboardEvent(_ event: NSEvent) -> Bool {
        guard (event.window == window || (event.window == nil && window?.isKeyWindow == true)), session.captured, window?.firstResponder === self else { return false }
        if event.type == .keyDown, event.keyCode == 53, event.modifierFlags.contains([.control,.option]) { releaseInput(); return true }
        modifiers(event)
        if event.type != .flagsChanged { keyboard(event,down:event.type == .keyDown) }
        return true
    }
    private func keyboard(_ event: NSEvent,down: Bool) {
        if !down { if let key = held.removeValue(forKey:event.keyCode) { session.key(key,down:false) }; return }
        let special: [UInt16:UInt32] = [36:0xff0d,48:0xff09,49:0x20,51:0xff08,53:0xff1b,117:0xffff,123:0xff51,124:0xff53,125:0xff54,126:0xff52,115:0xff50,119:0xff57,116:0xff55,121:0xff56,122:0xffbe,120:0xffbf,99:0xffc0,118:0xffc1,96:0xffc2,97:0xffc3,98:0xffc4,100:0xffc5,101:0xffc6,109:0xffc7,103:0xffc8,111:0xffc9,76:0xff8d]
        let value: UInt32?
        if let key = special[event.keyCode] { value = key }
        else if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first { value = scalar.value <= 255 ? scalar.value : 0x01000000|scalar.value }
        else { value = nil }
        if let value { held[event.keyCode] = value; session.key(value,down:true) }
    }
    private func capture(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        guard !session.captured else { return }
        session.captured = true; window?.invalidateCursorRects(for:self); capsLock = event.modifierFlags.contains(.capsLock)
        modifiers(event)
    }
    private func modifiers(_ event: NSEvent) {
        if event.keyCode == 57 {
            let state = event.modifierFlags.contains(.capsLock)
            if state != capsLock { session.special([0xffe5]); capsLock = state }
        }
        for (flag,keys) in modifierKeys {
            let deviceFlags = event.modifierFlags.rawValue & keys.reduce(0) { $0 | $1.1 }
            let fallback = event.type == .flagsChanged && keys.contains(where:{ $0.0 == event.keyCode })
                ? event.keyCode : (keys.first(where:{ held[$0.0] != nil })?.0 ?? keys[0].0)
            for (code,mask,key) in keys {
                let down = deviceFlags != 0 ? deviceFlags & mask != 0 : event.modifierFlags.contains(flag) && code == fallback
                guard down != (held[code] != nil) else { continue }
                if down { held[code] = key } else { held.removeValue(forKey:code) }
                session.key(key,down:down)
            }
        }
    }
}
import PortalVNC
