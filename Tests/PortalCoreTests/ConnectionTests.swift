import XCTest
@testable import PortalCore

final class ConnectionTests: XCTestCase {
    func testSavedComputersRoundTripPreferencesAndRejectCorruptFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("computers.json")
        let store = try ComputerStore(url: url)
        var computer = Computer(name: "Studio", address: "studio.local:5901")
        computer.ssh.enabled = true
        computer.ssh.host = "gateway.example.net"
        computer.ssh.username = "brandon"
        computer.clipboard = .off
        try store.save(computer)
        XCTAssertEqual(try ComputerStore(url: url).computers, [computer])
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(saved.lowercased().contains("password"))
        try store.remove(computer.id)
        XCTAssertEqual(try ComputerStore(url: url).computers, [])
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try ComputerStore(url: url))
    }
    func testAddressAcceptsHostIPv4IPv6AndVNCURLsWithoutLosingPorts() throws {
        XCTAssertEqual(try Endpoint(" studio.local ").host, "studio.local")
        XCTAssertEqual(try Endpoint("192.168.1.2:5901").port, 5901)
        XCTAssertEqual(try Endpoint("[::1]:5902").host, "::1")
        XCTAssertEqual(try Endpoint("2001:db8::1").port, 5900)
        XCTAssertEqual(try Endpoint("vnc://studio.local:5999").port, 5999)
        for invalid in ["", "-oProxyCommand=bad", "host:0", "host:65536", "host:no", "vnc://user:secret@host", "https://host", "host/path", "host\nother", "[bad]:5900"] {
            XCTAssertThrowsError(try Endpoint(invalid), invalid)
        }
    }
}
