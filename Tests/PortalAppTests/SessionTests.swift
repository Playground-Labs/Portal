import XCTest
import AppKit
import PortalCore
@testable import Portal

@MainActor final class SessionTests: XCTestCase {
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
        guard let data = session.image?.dataProvider?.data else { return [] }
        return Array((data as Data).prefix(4))
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
