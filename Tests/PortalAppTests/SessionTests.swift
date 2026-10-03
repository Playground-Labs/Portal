import XCTest
import AppKit
import PortalCore
import PortalVNC
@testable import Portal

@MainActor final class SessionTests: XCTestCase {
    func testContinuousUpdatesDeliverPixelsAfterCursorAndFollowResizeAndFallback() async throws {
        let (server,address) = try peer("continuous")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address
        let session = Session(computer); session.start(); defer { session.stop() }
        try await until { self.firstPixel(session) == [0,255,0,0] }
        session.key(0x61,down:true); session.key(0x61,down:false)
        try await until { session.image?.width == 6 && self.firstPixel(session) == [0,0,255,0] }
        session.key(0x62,down:true); session.key(0x62,down:false)
        try await until { self.firstPixel(session) == [255,255,0,0] }
    }
    func testBlockedFramePreparationLeavesInputFreeAndStopDiscardsTheFrame() async throws {
        let (server,address) = try peer("key-count")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address
        let session = Session(computer)
        session.frameQueue.suspend()
        session.start()
        try await until { session.connected }
        session.key(0xff0d,down:true); session.key(0xff0d,down:false)
        let inputDelivered = expectation(description:"Input worker runs while image preparation is blocked")
        session.send { _ in inputDelivered.fulfill() }
        await fulfillment(of:[inputDelivered],timeout:1)
        try await Task.sleep(nanoseconds:350_000_000)
        XCTAssertNil(session.image)
        session.stop()
        session.frameQueue.resume()
        let drained = expectation(description:"Pending frame is discarded after stop")
        session.frameQueue.async { DispatchQueue.main.async { drained.fulfill() } }
        await fulfillment(of:[drained],timeout:1)
        XCTAssertNil(session.image)
    }
    func testCommandModifierSurvivesEventsWithoutDeviceSpecificFlags() async throws {
        let (server,address) = try peer("canvas-input")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address
        let session = Session(computer); session.start(); defer { session.stop() }
        try await until { session.image != nil }
        let canvas = DesktopCanvas(session:session)
        let window = CursorTestWindow(contentRect:NSRect(x:0,y:0,width:100,height:100),styleMask:.borderless,backing:.buffered,defer:false)
        window.contentView = canvas; window.makeFirstResponder(canvas); session.captured = true
        defer { canvas.releaseInput(); withExtendedLifetime(window) {} }
        for (type,flags,code,text) in [(NSEvent.EventType.flagsChanged,NSEvent.ModifierFlags.command,UInt16(55),""),(.keyDown,.command,9,"v"),(.keyUp,.command,9,"v"),(.flagsChanged,[],55,"")] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with:type,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code))
            XCTAssertTrue(canvas.handleKeyboardEvent(event))
        }
        try await until { self.firstPixel(session) == [0,255,0,0] }
    }
    func testConnectionLossClearsStaleScreenAndReportsAnEstablishedSessionDrop() async throws {
        let old = UserDefaults.standard.object(forKey:"autoReconnect")
        UserDefaults.standard.set(false,forKey:"autoReconnect")
        defer { if let old { UserDefaults.standard.set(old,forKey:"autoReconnect") } else { UserDefaults.standard.removeObject(forKey:"autoReconnect") } }
        let (server,address) = try peer("disconnect")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address
        let session = Session(computer); session.start(); defer { session.stop() }
        try await until { session.image != nil && session.connected }
        try await until { !session.connected }
        XCTAssertNil(session.image,"A disconnected desktop must not look live behind an error")
        XCTAssertEqual(session.status,"Connection lost")
    }
    func testLatePreparedFrameCannotReappearAfterConnectionLoss() async throws {
        let (server,address) = try peer("disconnect")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address
        let session = Session(computer)
        session.frameQueue.suspend()
        session.start()
        defer { session.stop() }
        try await until { session.connected }
        try await until { !session.connected }
        session.frameQueue.resume()
        let drained = expectation(description:"In-flight preparation finishes")
        session.frameQueue.async { DispatchQueue.main.async { drained.fulfill() } }
        await fulfillment(of:[drained],timeout:1)
        XCTAssertNil(session.image,"A frame queued before the failure must not replace the disconnected state")
    }
    func testFragmentedMessageDoesNotExhaustTimeoutWhileDataKeepsArriving() async throws {
        for mode in ["fragment-stress","fragment-stress-large"] {
            let (server,address) = try peer(mode)
            defer { if server.isRunning { server.terminate() } }
            var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address; computer.clipboard = .off
            let session = Session(computer); session.start(); defer { session.stop() }
            try await until { self.firstPixel(session) == [0,255,0,0] }
            XCTAssertTrue(session.connected)
        }
    }
    func testStalledReadStillTimesOutAfterEightSeconds() async throws {
        let (server,address) = try peer("stalled-read")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address; computer.clipboard = .off
        let session = Session(computer); session.start(); defer { session.stop() }
        try await until { session.image != nil }
        let start = Date()
        try await until(timeout:10) { !session.connected }
        XCTAssertGreaterThan(Date().timeIntervalSince(start),7.5)
        XCTAssertFalse(session.error.isEmpty)
    }
    func testTwoEnterTapsProduceExactlyTwoPressReleasePairs() async throws {
        let (server,address) = try peer("key-count")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address
        let session = Session(computer); session.start(); defer { session.stop() }
        try await until { session.image != nil }
        for _ in 0..<2 { session.key(0xff0d,down:true); session.key(0xff0d,down:false) }
        try await until { self.firstPixel(session) == [2,2,0,0] }
    }
    func testKeyReleaseReachesServerDuringPartialFrameRead() async throws {
        let (server,address) = try peer("key-delay")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address
        let session = Session(computer); session.start(); defer { session.stop() }
        try await until { session.image != nil }
        session.key(0xff0d,down:true)
        try await Task.sleep(nanoseconds:100_000_000)
        session.key(0xff0d,down:false)
        try await until { self.firstPixel(session) != [255,0,0,0] }
        XCTAssertEqual(firstPixel(session),[0,255,0,0],"A slow frame must not delay Enter release until the remote machine can repeat it")
    }
    func testRequestsNextFrameBeforeCurrentPixelsArrive() async throws {
        let (server,address) = try peer("pipeline")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address
        let session = Session(computer); session.start(); defer { session.stop() }
        try await until { session.image != nil }
        XCTAssertEqual(firstPixel(session),[0,255,0,0],"The peer sends green only when the next request arrives before this frame's pixels")
    }
    func testServerCursorShapeHotspotAndHide() async throws {
        let (server,address) = try peer("cursor")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address
        let session = Session(computer); session.start(); defer { session.stop() }
        try await until { session.remoteCursor != nil }
        let cursor = try XCTUnwrap(session.remoteCursor)
        XCTAssertEqual(cursor.hotSpot,NSPoint(x:1,y:0))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(cursor.image.tiffRepresentation)))
        XCTAssertEqual(bitmap.pixelsWide,2); XCTAssertEqual(bitmap.pixelsHigh,1)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x:0,y:0)).redComponent,1,accuracy:0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x:0,y:0)).alphaComponent,1)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x:1,y:0)).alphaComponent,0)
        session.key(0xff1b,down:true)
        try await until { session.remoteCursor == nil }
    }
    func testCursorOnlyUpdateDoesNotReplaceDesktopImage() async throws {
        let (server,address) = try peer("cursor")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address
        let session = Session(computer); session.start(); defer { session.stop() }
        try await until { session.remoteCursor != nil && session.image != nil }
        let image = try XCTUnwrap(session.image)
        session.key(0xff1b,down:true)
        try await until { session.remoteCursor == nil }
        await withCheckedContinuation { continuation in
            session.send { _ in DispatchQueue.main.async { continuation.resume() } }
        }
        XCTAssertTrue(session.image === image,"A cursor-only update must not copy and present the entire desktop")
    }
    func testIdlePollingDoesNotBlockInputQueue() throws {
        let (server,address) = try peer("idle")
        defer { if server.isRunning { server.terminate() } }
        var callbacks = PortalCallbacks(); callbacks.authorize = { _,_,_ in 1 }
        let client = try XCTUnwrap(portal_vnc_create(callbacks)); defer { portal_vnc_destroy(client) }
        let port = try XCTUnwrap(Int32(address.split(separator:":").last!))
        XCTAssertEqual(portal_vnc_connect(client,"127.0.0.1",port,0,6,""),1)
        let start = Date()
        for _ in 0..<50 { XCTAssertEqual(portal_vnc_poll(client),0) }
        XCTAssertLessThan(Date().timeIntervalSince(start),0.1,"Idle reads must not hold the input queue")
    }
    func testRemoteCursorRemainsHiddenAfterKeyboardRelease() throws {
        let session = Session(Computer(name:"Test",address:"127.0.0.1"))
        let canvas = DesktopCanvas(session:session)
        let window = CursorTestWindow(contentRect:NSRect(x:0,y:0,width:100,height:100),styleMask:.borderless,backing:.buffered,defer:false)
        window.contentView = canvas
        session.connected = true
        session.captured = true
        canvas.releaseInput()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with:.mouseMoved,location:NSPoint(x:50,y:50),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0))
        defer { NSCursor.arrow.set() }
        NSCursor.arrow.set()
        canvas.cursorUpdate(with:event)
        XCTAssertFalse(NSCursor.current === NSCursor.arrow,"The remote desktop must hide the local cursor even after the notch releases keyboard capture")
        session.computer.viewOnly = true
        canvas.cursorUpdate(with:event)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
        session.computer.viewOnly = false; session.connected = false
        canvas.cursorUpdate(with:event)
        XCTAssertTrue(NSCursor.current === NSCursor.arrow)
    }
    func testCanvasReleasesControlWhenDisconnectedOrViewOnly() {
        let session = Session(Computer(name:"Test",address:"127.0.0.1"))
        let scroll = DesktopScrollView()
        let canvas = DesktopCanvas(session:session)
        scroll.documentView = canvas; scroll.canvas = canvas
        session.connected = true; session.captured = true; session.computer.viewOnly = true
        scroll.refresh()
        XCTAssertFalse(session.captured)
        session.computer.viewOnly = false; session.captured = true; session.connected = false
        scroll.refresh()
        XCTAssertFalse(session.captured)
    }
    func testBurstKeepsFinalFrameAndSessionCanBeReleased() async throws {
        let (server,address) = try peer("burst")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address; computer.audioEnabled = false
        var session: Session? = Session(computer)
        weak let released = session
        session!.start()
        try await until { session!.connected }
        // Hold the UI while two real framebuffer messages arrive.
        blockUIForBurst()
        try await until { session!.image != nil }
        XCTAssertEqual(firstPixel(session!),[0,255,0,0])
        session!.stop(); session = nil
        try await until { released == nil }
    }
    func testReconnectContinuesWhileTheServerIsStillOffline() async throws {
        let (server,address) = try peer("reconnect")
        defer { if server.isRunning { server.terminate() } }
        var computer = Computer(name:"Test",address:address); computer.acceptedInsecureAddress = address; computer.audioEnabled = false
        let session = Session(computer); session.start(); defer { session.stop() }
        try await until { session.connected }
        try await until { session.retrying }
        try await until(timeout:14) { session.connected && self.firstPixel(session) == [0,255,0,0] }
    }
    private func blockUIForBurst() { Thread.sleep(forTimeInterval:0.6) }
    private func firstPixel(_ session: Session) -> [UInt8] {
        guard let image = session.image,
              let context = CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        context.draw(image,in:CGRect(x:0,y:1-image.height,width:image.width,height:image.height))
        guard let bytes = context.data?.assumingMemoryBound(to:UInt8.self) else { return [] }
        return [bytes[0],bytes[1],bytes[2],0]
    }
    private func until(timeout:Double = 5,_ predicate:() -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date()<deadline { try await Task.sleep(nanoseconds:20_000_000) }
        XCTAssertTrue(predicate(),"Timed out waiting for session behavior")
    }
    private func peer(_ mode:String) throws -> (Process,String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments = [Bundle.module.url(forResource:"session_server",withExtension:"py")!.path,mode]
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount:1), !byte.isEmpty { if byte[0] == 10 { break }; line.append(byte) }
        return (process,"127.0.0.1:\(String(decoding:line,as:UTF8.self))")
    }
}

private final class CursorTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
