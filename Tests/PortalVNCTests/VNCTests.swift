import XCTest
import PortalVNC

private final class Capture {
    var pixels = Data()
    var clipboard = ""
    var screens: [PortalScreen] = []
    var pcm = Data()
    var audioAvailable = false
    var allowUnencrypted = true
}

final class VNCTests: XCTestCase {
    func testRealRFBConnectionExchangesPixelsInputClipboardLayoutAndAudio() throws { try exchange(mode: "multi") }
    func testPasswordAuthenticationAndSingleDisplayResize() throws { try exchange(mode: "auth") }
    func testDecliningUnencryptedConnectionSendsNoDesktopRequests() throws { try exchange(mode: "deny") }
    func testUnsupportedAuthenticationExplainsConnectionFailure() throws { try exchange(mode: "unsupported") }
    private func exchange(mode: String) throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [Bundle.module.url(forResource: "rfb_server", withExtension: "py")!.path, output.path, mode]
        let pipe = Pipe(); server.standardOutput = pipe
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        var line = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 10 { break }; line.append(byte)
        }
        let port = try XCTUnwrap(Int32(String(decoding: line, as: UTF8.self)))
        let capture = Capture(); capture.allowUnencrypted = mode != "deny"
        var callbacks = PortalCallbacks()
        callbacks.context = Unmanaged.passUnretained(capture).toOpaque()
        callbacks.authorize = { ctx,_,_ in Unmanaged<Capture>.fromOpaque(ctx!).takeUnretainedValue().allowUnencrypted ? 1 : 0 }
        callbacks.credentials = { _,_,user,password in user?.pointee = strdup(""); password?.pointee = strdup("secret"); return 1 }
        callbacks.frame = { ctx, bytes,w,h in
            Unmanaged<Capture>.fromOpaque(ctx!).takeUnretainedValue().pixels = Data(bytes: bytes!, count: Int(w*h*4))
        }
        callbacks.clipboard = { ctx,text,n,_ in
            Unmanaged<Capture>.fromOpaque(ctx!).takeUnretainedValue().clipboard = String(decoding: UnsafeRawBufferPointer(start:text,count:Int(n)), as:UTF8.self)
        }
        callbacks.layout = { ctx,screens,n,_ in
            Unmanaged<Capture>.fromOpaque(ctx!).takeUnretainedValue().screens = Array(UnsafeBufferPointer(start:screens,count:Int(n)))
        }
        callbacks.audio = { ctx,bytes,n in
            let c=Unmanaged<Capture>.fromOpaque(ctx!).takeUnretainedValue()
            if let bytes { c.pcm.append(bytes,count:Int(n)) } else { c.audioAvailable=true }
        }
        let client=try XCTUnwrap(portal_vnc_create(callbacks))
        var destroyed = false
        defer { if !destroyed { portal_vnc_destroy(client) } }
        let connected = portal_vnc_connect(client,"127.0.0.1",port,0,0,"")
        if mode == "unsupported" {
            XCTAssertEqual(connected, 0)
            let error = String(cString: portal_vnc_error(client))
            XCTAssertTrue(error.contains("authentication"), error)
            XCTAssertTrue(error.contains("129, 5"), error)
            return
        }
        if mode == "deny" {
            XCTAssertEqual(connected,0)
            XCTAssertTrue(String(cString:portal_vnc_error(client)).contains("cancelled"))
            portal_vnc_destroy(client); destroyed = true; server.waitUntilExit()
            let observed = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any])
            XCTAssertTrue(observed.isEmpty)
            return
        }
        guard connected == 1 else {
            XCTFail(String(cString:portal_vnc_error(client))); return
        }
        let deadline=Date().addingTimeInterval(4)
        while (capture.pixels.isEmpty || capture.clipboard.isEmpty || !capture.audioAvailable), Date()<deadline {
            XCTAssertGreaterThanOrEqual(portal_vnc_poll(client),0)
        }
        XCTAssertEqual(Array(capture.pixels.prefix(12)),[255,0,0,0,0,255,0,0,0,0,255,0])
        XCTAssertEqual(capture.clipboard,"hello")
        XCTAssertEqual(capture.screens.map(\.id),mode == "multi" ? [10,20] : [10])
        XCTAssertEqual(capture.screens.map(\.x),mode == "multi" ? [0,2] : [0])
        XCTAssertEqual(portal_vnc_key(client,0x61,1),1)
        XCTAssertEqual(portal_vnc_pointer(client,3,1,1),1)
        XCTAssertEqual(portal_vnc_clipboard(client,"café",5),1)
        // Multiple physical displays must not be collapsed by an automatic resize.
        XCTAssertEqual(portal_vnc_resize(client,800,600),mode == "multi" ? 0 : 1)
        XCTAssertEqual(portal_vnc_audio(client,1),1)
        while capture.pcm.isEmpty, Date()<deadline { XCTAssertGreaterThanOrEqual(portal_vnc_poll(client),0) }
        XCTAssertEqual(capture.pcm,Data([0,0,255,127,0,128,0,0]))
        portal_vnc_destroy(client); destroyed = true
        server.waitUntilExit()
        XCTAssertEqual(server.terminationStatus,0)
        let observed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String:Any])
        XCTAssertEqual(observed["key"] as? [Int],[97,1])
        XCTAssertEqual(observed["pointer"] as? [Int],[3,1,1])
        XCTAssertEqual(observed["clipboard"] as? String,"café")
        XCTAssertEqual(observed["audio"] as? Bool,true)
        if mode == "multi" { XCTAssertNil(observed["resize"]) } else { XCTAssertEqual(observed["resize"] as? [Int],[800,600]) }
    }
}
