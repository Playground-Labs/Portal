import XCTest
import AppKit
import PortalCore
import PortalVNC
@testable import Portal

@MainActor final class RenderingTests: XCTestCase {
    func testDisplayPreservesOrientationMonitorCropAndLetterboxing() throws {
        let session = Session(Computer(name:"Test",address:"127.0.0.1"))
        let pixels = Data([255,0,0,0, 0,255,0,0, 0,0,255,0, 255,255,0,0])
        let provider = try XCTUnwrap(CGDataProvider(data:pixels as CFData))
        session.image = try XCTUnwrap(CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:8,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let canvas = DesktopCanvas(session:session)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:100,height:100),styleMask:.borderless,backing:.buffered,defer:false)
        window.contentView = canvas
        defer { withExtendedLifetime(window) {} }
        func snapshot(refresh:Bool = true) throws -> NSBitmapImageRep {
            if refresh { canvas.refreshImage() }
            let context = try XCTUnwrap(CGContext(data:nil,width:100,height:100,bitsPerComponent:8,bytesPerRow:400,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x:0,y:100); context.scaleBy(x:1,y:-1)
            try XCTUnwrap(canvas.layer).render(in:context)
            return NSBitmapImageRep(cgImage:try XCTUnwrap(context.makeImage()))
        }
        var bitmap = try snapshot()
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x:5,y:5)).redComponent,1,accuracy:0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x:5,y:95)).blueComponent,1,accuracy:0.01)
        session.screens = [PortalScreen(id:1,x:0,y:1,width:2,height:1)]; session.selectedScreen = 1
        bitmap = try snapshot()
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x:5,y:50)).blueComponent,1,accuracy:0.01)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x:95,y:50)).redComponent,1,accuracy:0.01)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x:50,y:5)).redComponent,0.15)
        session.computer.sizing = .actual
        bitmap = try snapshot()
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x:5,y:50)).blueComponent,0.15)
        var controlUpdates = 0
        let observation = session.objectWillChange.sink { controlUpdates += 1 }
        session.image = try XCTUnwrap(session.image?.copy())
        XCTAssertEqual(controlUpdates,0,"Same-size frames must not redraw the surrounding SwiftUI controls")
        withExtendedLifetime(observation) {}
        session.image = nil
        bitmap = try snapshot(refresh:false)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x:50,y:50)).redComponent,0.15)
    }
}
